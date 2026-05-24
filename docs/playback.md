# Playback

The SDK reads recordings back with `TrinetPlayer` — a self-contained H.264 player that
decodes the MP4 to a `Surface`, paces frames at their recorded PTS, and exposes the IMU
sample aligned to the currently displayed frame. For offline analysis (no rendering) you
can read the sidecars directly with `ImuFileReader` and `VtsFileReader`.

- [Locating a recording](#locating-a-recording)
- [Playing a recording](#playing-a-recording)
- [Scrubbing](#scrubbing)
- [Reading sidecars directly](#reading-sidecars-directly)
- [Aligning IMU to frames](#aligning-imu-to-frames)
- [Browsing a library](#browsing-a-library)

---

## Locating a recording

A recording on disk is described by `RecordingFolder`:

```kotlin
import com.panoculon.trinet.sdk.playback.RecordingFolder

val folder = RecordingFolder(File(recordingsRoot, recordingId))

folder.video      // <dir>/video.mp4
folder.imu        // <dir>/imu.bin
folder.vts        // <dir>/frames.bin
folder.meta       // <dir>/meta.json
folder.isComplete // true if video + imu + vts all exist
```

It also has `delete()` (recursive) and `renameTo(newName)` (sanitizes the name and
returns a new `RecordingFolder`, or `null` if the target exists / rename failed).

---

## Playing a recording

`TrinetPlayer` needs a complete `RecordingFolder` and a render `Surface` (from a
`SurfaceView`).

```kotlin
import com.panoculon.trinet.sdk.playback.TrinetPlayer

val player = TrinetPlayer(folder, surface)

player.play()
player.pause()
player.togglePlayPause()
player.seekToFrame(120)     // jump to frame 120; IMU + current frame update to match
```

Observable state (all `StateFlow`):

```kotlin
player.currentFrame   // StateFlow<Int>          — index of the frame on screen
player.currentSample  // StateFlow<ImuSample?>   — IMU aligned to the current frame
player.isPlaying      // StateFlow<Boolean>
player.frameCount     // Int                     — total frames (from the VTS sidecar)
```

Wire them into your UI:

```kotlin
val sample by player.currentSample.collectAsState()
val frame  by player.currentFrame.collectAsState()
```

The player also exposes the underlying sidecar readers as `player.imu`
(`ImuFileReader`) and `player.vts` (`VtsFileReader`) if you need random access during
playback.

### Surface wiring (Compose)

```kotlin
AndroidView(factory = { ctx ->
    SurfaceView(ctx).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) {
                // Create the player once the surface exists.
                player = TrinetPlayer(folder, h.surface).also { it.play() }
            }
            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
            override fun surfaceDestroyed(h: SurfaceHolder) {}
        })
    }
})
```

Always `player.close()` when leaving the screen — it stops and releases the decoder,
extractor, and the mmap'd sidecar readers.

### Per-step IMU stream

`currentSample` only emits *distinct* values, so a consumer running orientation fusion
(which needs every step) should subscribe to `sampleStream` instead:

```kotlin
player.sampleStream
    .onEach { step ->     // SeekOrStep(sample, reset, frame)
        if (step.reset) madgwick.reset()   // history invalidated by a seek
        // feed step.sample into Madgwick, plot history, etc.
    }
    .launchIn(scope)
```

`reset == true` means the timeline jumped (a seek) and any rolling history should be
rebuilt from this sample.

---

## Scrubbing

`TrinetPlayer` supports VLC-style live scrubbing: as the user drags a slider, the player
decodes and renders the target frame so the video follows their thumb. The scrub calls
do real decode work (up to ~80 ms each), so drive them from a background dispatcher with
a conflated channel that collapses rapid drags to "latest target wins".

```kotlin
// 1. User grabs the slider:
player.beginScrub()

// 2. On each drag update (publish to a conflated SharedFlow, drained by one worker
//    on Dispatchers.Default that calls player.scrubTo(target)):
player.scrubTo(targetFrame)     // background thread only — never the main thread

// 3. User releases:
player.endScrub(resume = true)  // resume playback (or false to stay paused)
```

The player takes a fast path for monotonic forward drags within the current group of
pictures and a flush+seek-to-keyframe slow path for backward or cross-GOP jumps. Each
`scrubTo` is time-bounded so a slow seek can't stall the worker.

For a non-live jump (e.g. tapping a timestamp) use `seekToFrame(frame)` instead, which
seeks the decoder and updates the current frame + IMU without the scrub machinery.

---

## Reading sidecars directly

For offline analysis you don't need the player — open the sidecars directly. Both
readers `mmap` the file and provide O(1) random access.

### IMU sidecar

```kotlin
import com.panoculon.trinet.sdk.playback.ImuFileReader

ImuFileReader(folder.imu).use { imu ->
    imu.sampleRateHz   // configured rate from the header
    imu.accelFs        // accel full-scale code
    imu.gyroFs         // gyro full-scale code
    imu.startTimeNs    // timestamp of the first sample
    imu.version        // sidecar format version
    imu.sampleCount    // number of samples
    imu.deviceIdHex    // lowercase-hex public device id ("" for older recordings)

    val s = imu.sampleAt(0)             // ImuSample by index
    val all = imu.readAll()             // List<ImuSample> (bounded files only)
    val idx = imu.indexAt(123_456_789L) // nearest sample index to a timestamp (ns)
}
```

The reader is backward-compatible with older sidecar versions; older recordings report
fields they didn't store as zero/identity.

### VTS (frame-timestamp) sidecar

```kotlin
import com.panoculon.trinet.sdk.playback.VtsFileReader

VtsFileReader(folder.vts).use { vts ->
    vts.entryCount     // number of frames
    vts.fps            // frame rate
    val e = vts.entryAt(10)   // VtsEntry: frameNumber, sofTimestampNs, vencSeq, vencPtsUs
    val frames = vts.readAll()
}
```

Both readers implement `AutoCloseable` — use `.use { }` or close them explicitly.

---

## Aligning IMU to frames

To find the IMU sample(s) captured at a given video frame, use the frame's
**start-of-frame timestamp** from the VTS sidecar (not the video PTS, not wall-clock):

```kotlin
ImuFileReader(folder.imu).use { imu ->
    VtsFileReader(folder.vts).use { vts ->
        val frame = 42
        val sofNs = vts.entryAt(frame).sofTimestampNs   // hardware-aligned timestamp
        val idx = imu.indexAt(sofNs)                    // nearest IMU sample
        val sample = imu.sampleAt(idx)
    }
}
```

This is exactly how `TrinetPlayer` populates `currentSample`. To rebuild a rolling
window for plots/fusion, walk backward from the anchor index:

```kotlin
val window = 300
val start = (idx - window + 1).coerceAtLeast(0)
val samples = (start..idx).map { imu.sampleAt(it) }
```

See [file formats](file-formats.md) for what `sofTimestampNs` means and how it relates to
the frame-sync delay.

---

## Browsing a library

`RecordingFolder.listIn(root)` enumerates every recording under a directory, newest
first (sorted by the MP4's last-modified time, filtered to folders that actually contain
a `video.mp4`):

```kotlin
val recordings: List<RecordingFolder> = RecordingFolder.listIn(recordingsRoot)
```

---

Next: [File formats →](file-formats.md)
