# Recording

`TrinetRecorder` records a streaming session to a self-contained folder containing the
video, two synchronized IMU/timestamp sidecars, and a metadata JSON. You feed it the
access units from `session.frames`; it muxes the H.264 into MP4 and splits the embedded
IMU out into the sidecars.

- [Output folder](#output-folder)
- [Creating a recorder](#creating-a-recorder)
- [Recording a session](#recording-a-session)
- [The recording handle and state](#the-recording-handle-and-state)
- [Threading](#threading)

---

## Output folder

Each recording is a single folder containing four files:

```
<folder>/
  video.mp4     # H.264 video (with the SEI IMU NALs muxed through)
  imu.bin       # IMU sidecar  — per-sample accel/gyro/mag/temp + frame-sync delay
  frames.bin    # VTS sidecar  — per-frame start-of-frame timestamp + video PTS
  meta.json     # recording metadata (device, resolution, fps, codec, SDK version)
```

The folder is named `<devShort>_recording_<yyyyMMdd_HHmmss>/`, where `devShort` is the
first 8 characters of the camera's public per-unit serial. That prefix lets you sort
recordings by physical camera in a file browser without opening `meta.json`. When the
camera doesn't advertise a serial, the folder falls back to `recording_<ts>/`.

The on-disk binary layouts are documented in [file formats](file-formats.md).

---

## Creating a recorder

```kotlin
import com.panoculon.trinet.sdk.recording.TrinetRecorder

val recorder = TrinetRecorder(
    rootDir = context.filesDir,        // parent dir for the recording folder
    width = 1920,
    height = 1080,
    fps = 30,
    sampleRateHz = 562,                // configured IMU rate (goes into the sidecar header)
    device = TrinetRecorder.DeviceMeta(
        vendorId = device.info.vendorId,
        productId = device.info.productId,
        serial = device.info.serial,   // public per-unit ID; null for older cameras
    ),
)
```

`width`/`height`/`fps` should match the `SessionConfig` you opened the session with.
`sampleRateHz` is the configured IMU rate recorded in the sidecar header; the recorder
also writes the actual full-scale codes it observes in the SEI as samples arrive.

The `DeviceMeta.serial` is the public device ID; when present it's written into both
`meta.json` and the IMU sidecar header (decoded from the 32-char hex serial to its 16
raw bytes), so downstream tools can attribute a recording to a physical camera.

Optional constructor params: `accelFsDefault` / `gyroFsDefault` (full-scale fallbacks
used before the first SEI is observed).

---

## Recording a session

```kotlin
import com.panoculon.trinet.sdk.recording.RecordingHandle

val handle: RecordingHandle = recorder.start()

// Pump access units from the session into the recorder (off the main thread):
val job = session.frames
    .onEach { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
    .flowOn(Dispatchers.IO)
    .launchIn(scope)

// ... later ...
job.cancel()
handle.stop()       // finalizes the MP4 container + flushes/closes all sidecars
```

`start()` creates the folder and opens the writers; it throws if a recording is already
in progress on the same recorder. `submitAccessUnit(annexB, ptsUs)` does three things
per frame:

1. Passes the access unit through to the MP4 muxer (SEI included).
2. Decodes any Trinet IMU SEI in the access unit and appends the samples to `imu.bin`.
3. Appends a frame entry to `frames.bin` (frame number, start-of-frame timestamp derived
   from the SEI's frame-sync delay, encoder sequence, and the video PTS).

`stop()` (via the handle) flushes and closes all three writers, finalizes the MP4
container, and writes `meta.json`.

---

## The recording handle and state

`recorder.start()` returns a `RecordingHandle`. It exposes the output file paths, a
live state flow, and the stop control.

```kotlin
class RecordingHandle {
    val folder: File
    val videoFile: File   // <folder>/video.mp4
    val imuFile: File     // <folder>/imu.bin
    val vtsFile: File     // <folder>/frames.bin
    val metaFile: File    // <folder>/meta.json

    val state: StateFlow<RecordingState>
    fun stop()
}
```

`RecordingState` is a sealed type you can observe to drive UI:

```kotlin
sealed interface RecordingState {
    data object Idle
    data class Active(val frameCount: Long, val sampleCount: Long, val durationMs: Long)
    data class Stopped(val folder: File, val frameCount: Long, val sampleCount: Long, val durationMs: Long)
    data class Failed(val error: Throwable)
}
```

```kotlin
handle.state
    .onEach { state ->
        when (state) {
            is RecordingState.Active  -> showHud(state.frameCount, state.sampleCount, state.durationMs)
            is RecordingState.Stopped -> onSaved(state.folder)
            is RecordingState.Failed  -> showError(state.error)
            RecordingState.Idle       -> Unit
        }
    }
    .launchIn(scope)
```

`Active` updates on every submitted frame (running frame count, IMU sample count, and
elapsed duration), so you can show a live counter and compute an effective IMU rate.

---

## Threading

`submitAccessUnit` does per-frame `writeSampleData` + sidecar appends, all disk I/O. At
30 fps this **will ANR** if run on the main thread. Always pump frames on
`Dispatchers.IO`:

```kotlin
session.frames
    .onEach { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
    .flowOn(Dispatchers.IO)
    .launchIn(scope)
```

When you're done, cancel the pumping job **before** `handle.stop()` so no frame races the
finalize. Then close the session and device as usual (see
[cleanup](getting-started.md#lifecycle-and-cleanup)).

---

Next: [Playback →](playback.md)
