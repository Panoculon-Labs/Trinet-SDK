# Streaming

Once you have an open [`TrinetDevice`](getting-started.md#opening-a-camera) you open a
**session** to start the H.264 video stream. The session exposes frames as a coroutine
`Flow` that any number of consumers can subscribe to simultaneously — a live preview and
a recorder can both read the same stream.

- [Opening a session](#opening-a-session)
- [The frame flow](#the-frame-flow)
- [LivePreview Compose component](#livepreview-compose-component)
- [Stereo cameras](#stereo-cameras)
- [Multiple consumers](#multiple-consumers)
- [Errors](#errors)
- [Stopping](#stopping)

---

## Opening a session

```kotlin
import com.panoculon.trinet.sdk.session.SessionConfig

val config = SessionConfig(width = 1920, height = 1080, fps = 30)   // defaults
val session = withContext(Dispatchers.IO) { device.open(config) }   // off main thread

if (!session.start()) {
    // The camera did not advertise a matching format/resolution/fps.
}
```

`SessionConfig` defaults to **1920×1080 @ 30 fps**, which is what a Trinet camera ships
with. The requested combination must be one the device advertises; if negotiation fails,
`start()` returns `false`.

`SessionConfig(width, height, fps, maxFrameBytes = 1 MiB, fallbackWidth = 0,
fallbackHeight = 0)`: `fallbackWidth`/`fallbackHeight` name a second resolution to try
when the first is not advertised — the way to ask for a stereo camera's wide frame and
still open a mono camera (see [stereo cameras](#stereo-cameras)). The miss on the way to
the fallback is quiet: it raises no error. `maxFrameBytes` is a per-frame size budget
expressed at 1080p (larger frames are dropped whole); the session scales it up with the
negotiated pixel area, so a 3840×1080 stereo frame gets twice the budget.

`TrinetDevice.open` must be called on a worker thread — it opens the USB device and
initializes the native streaming layer, both of which block.

---

## The frame flow

A started session emits `TrinetSession.Frame`s on `session.frames`:

```kotlin
data class Frame(val annexB: ByteArray, val ptsUs: Long)
```

- `annexB` — one H.264 access unit in **Annex B** framing (start codes preserved),
  typically one coded picture plus its SPS/PPS and an SEI NAL carrying that frame's IMU
  samples. On v4 cameras a second SEI NAL carries embedded AAC audio
  ([TRINETAAC](file-formats.md#in-stream-audio-sei-trinetaac)).
- `ptsUs` — capture timestamp in microseconds.

```kotlin
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

session.frames
    .onEach { frame ->
        // frame.annexB is an H.264 access unit; frame.ptsUs is microseconds.
    }
    .launchIn(scope)
```

`session.frames` is a `SharedFlow` with `replay = 1`, so a late subscriber (e.g. a
preview composable mounted after `start()` returned) still receives the most recent
frame — important for catching the first keyframe and its parameter sets.

> The native layer dispatches frames on its own stream thread, and the flow drops the
> oldest buffered frame under backpressure. **Do not block in the collector.** For
> disk-bound work (recording) hop to `Dispatchers.IO` with `.flowOn(Dispatchers.IO)`.

### Parsing the bitstream yourself

If you process frames directly, the SDK exposes Annex B helpers in the `sei` package:

```kotlin
import com.panoculon.trinet.sdk.sei.NalParser

val nals = NalParser.splitNalUnits(frame.annexB)   // List<NalSlice>, start codes stripped
for (nal in nals) {
    when (nal.h264Type) {           // nal_unit_type (header & 0x1F)
        5 -> { /* IDR keyframe slice */ }
        7 -> { /* SPS */ }
        8 -> { /* PPS */ }
        6 -> { /* SEI — may carry IMU; see the IMU guide */ }
    }
}
```

To pull the IMU out of the SEI NALs, see [IMU extraction](imu.md).

---

## LivePreview Compose component

The SDK ships a ready-made preview that decodes the frame flow into a `SurfaceView` via
`MediaCodec`. Hand it the session's flow and the resolution:

```kotlin
import com.panoculon.trinet.sdk.ui.LivePreview

@Composable
fun CameraView(session: TrinetSession) {
    LivePreview(
        frames = session.frames,
        width  = session.config.width,
        height = session.config.height,
        modifier = Modifier.fillMaxSize(),
    )
}
```

`LivePreview` handles the things a naïve decoder gets wrong:

- It **caches SPS/PPS** across frames and configures the decoder the first time it has
  both, so it works even if the parameter sets and the first IDR arrive in different
  access units.
- It **skips non-keyframes** until the first IDR is queued (MediaCodec requires the
  first queued buffer to be a keyframe).
- It runs the entire decode loop **off the main thread** so Compose doesn't ANR at
  30 fps.
- It **letterboxes** the surface to the source aspect ratio so 16:9 video isn't
  stretched in a portrait container.

Two optional parameters:

- `cropEye: Int?` — for a side-by-side stereo stream, show only one eye: `0` = left,
  `1` = right, `null` (default) = the whole frame. The decoder still receives both
  eyes, so switching eyes is instant and never interrupts a recording.
- `onFocusScore: ((Float) -> Unit)?` — manual-focus assist. When set, the preview
  scores the sharpness of its own surface (variance of the Laplacian over a centre
  region, smoothed) about 8 times a second and reports it; turn the lens until the
  score peaks. It scores the eye selected by `cropEye`. `FocusAssist` exposes the
  scoring (`scoreBitmap`, `scoreArgb`, `ema`, `roiOf`, `ROI_FRAC`) if you want to draw
  the region or score your own bitmaps. (Since 0.5.0 there is no separate
  `FocusAssist.run(...)` decoder.)

`LivePreview` is purely a decode-and-display sink: it reads from `frames` but never
controls the session. You still call `session.start()` / `session.stop()` yourself.

### Live audio

v4 cameras embed stereo AAC audio in the stream. To hear it, drop the `LiveAudio`
composable next to the preview — it decodes the audio SEI off the main thread and
plays it, tied to the composition lifecycle:

```kotlin
import com.panoculon.trinet.sdk.ui.LiveAudio

LivePreview(frames = session.frames, width = config.width, height = config.height)
LiveAudio(frames = session.frames)              // enabled = false to mute
```

On cameras without audio it simply stays silent — no version check needed. For
non-Compose apps, use `AudioPlayer` + `SeiAudioParser` directly (see the
[API reference](api-reference.md#package-audio)). Microphone gain/mute/AGC and
sample rate are controllable via `device.setAudio(...)` / `device.setAudioRate(...)`.

---

## Stereo cameras

The Pro Stereo and Pro Stereo GS do not open a second USB video function: they put
**both eyes side by side in one frame** (3840×1080 for a 1080p pair; the left half is
the physically left eye). IMU, audio and controls are the same as on a mono camera.

Ask for the wide frame with a mono fallback, and the same code opens either kind of
camera:

```kotlin
val config = SessionConfig(
    width = 3840, height = 1080, fps = 30,
    fallbackWidth = 1920, fallbackHeight = 1080,   // mono cameras
)
val session = withContext(Dispatchers.IO) { device.open(config) }
check(session.start())

session.negotiatedWidth    // 3840 on a stereo camera, 1920 on a mono one
session.negotiatedHeight
session.layout             // StreamLayout.SIDE_BY_SIDE or StreamLayout.MONO
session.isSideBySide       // true while streaming a stereo pair
```

- **Detect stereo from the stream shape** (`session.layout` / `isSideBySide`), not
  from the USB product id — a stereo camera enumerates with the same product id as a
  mono one. `TrinetGeneration.isStereo` is a label and a cross-check only.
  `StreamLayout.of(width, height)` classifies any frame size.
- **Preview**: pass the negotiated size and choose an eye with `cropEye`:

  ```kotlin
  LivePreview(
      frames = session.frames,
      width = session.negotiatedWidth,
      height = session.negotiatedHeight,
      cropEye = if (session.isSideBySide) eye else null,   // 0 = left, 1 = right
  )
  ```
- **Recording**: construct the `TrinetRecorder` with `session.negotiatedWidth` /
  `negotiatedHeight`. Recordings keep the full frame, both eyes, and `meta.json`
  gains `video.layout: "sbs"` ([file formats](file-formats.md#metajson)).
- **Calibration**: a stereo camera stores a two-eye calibration. Read it with
  `device.getCalibrationAny()`, which returns `Calibration.Mono` or
  `Calibration.Stereo` (per-eye intrinsics plus `baselineM`); see the
  [API reference](api-reference.md#calibration--stereocalibrationdata).
- **Global shutter**: the Pro Stereo GS behaves identically. Its frames report a
  readout time of zero, and `SeiImuHeader.shutter` returns `ShutterType.GLOBAL`
  (`ROLLING` on the other cameras). A calibration from a rolling-shutter camera is not
  valid on a global-shutter one.

Some phones' hardware decoders reject 3840-wide video; `LivePreview` falls back to a
software decoder on its own.

---

## Multiple consumers

Because `frames` is a `SharedFlow`, you can fan it out. The common pattern is preview +
recorder running at the same time off the one stream:

```kotlin
// In Compose, on the main hierarchy:
LivePreview(frames = session.frames, width = config.width, height = config.height)

// In your viewmodel, recording the same stream to disk on IO:
val job = session.frames
    .onEach { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
    .flowOn(Dispatchers.IO)
    .launchIn(viewModelScope)
```

Both subscribers see every frame the stream produces (subject to backpressure dropping
under sustained overload).

---

## Errors

Recoverable native stream errors surface as strings on `session.errors`:

```kotlin
session.errors
    .onEach { msg -> Log.w("camera", "stream error: $msg") }
    .launchIn(scope)
```

---

## Stopping

```kotlin
session.stop()    // stop the stream; the session can be re-started
session.close()   // stop + mark the session unusable (does NOT release the USB device)
device.close()    // release the USB device
```

Closing the session does **not** release the underlying USB handle — that belongs to the
`TrinetDevice`. Close the session, then the device. See
[lifecycle and cleanup](getting-started.md#lifecycle-and-cleanup).

---

Next: [IMU →](imu.md)
