# Trinet SDK — Android

Kotlin library for capturing video and per-frame sensor data from a **Trinet camera** connected to an Android device over USB.

Trinet cameras stream H.264 over USB Video Class (UVC) with per-frame inertial samples carried as SEI NAL units. The SDK handles the USB/UVC transport, parses the sensor SEI in real time, and writes recordings to a standard MP4 plus companion binary sidecars. Opt-in Jetpack Compose widgets provide a live preview, a timeline scrubber, and IMU plots.

- Minimum Android: **API 28** (Android 9)
- Target Android: **API 34**
- Language: Kotlin + JNI (C++)
- Ships libuvc + libusb inside the AAR — works on any stock Android device

---

## Quick start

### 1. Gradle

```kotlin
// settings.gradle.kts
include(":trinet-sdk")

// app/build.gradle.kts
dependencies {
    implementation(project(":trinet-sdk"))
    implementation("androidx.compose.material3:material3:<bom-version>")
}
```

No extra NDK setup is needed. The SDK's CMake pulls libuvc (v0.0.7) and libusb (v1.0.27) through `FetchContent` on first build.

### 2. AndroidManifest

```xml
<uses-feature android:name="android.hardware.usb.host" android:required="true" />

<!-- Required on Android 9+; the OS silently denies USB permission for
     UVC-class devices unless the app holds CAMERA at request time. -->
<uses-permission android:name="android.permission.CAMERA" />

<activity …>
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/device_filter" />
</activity>
```

`res/xml/device_filter.xml`:

```xml
<resources>
    <usb-device vendor-id="8711" product-id="22" />
    <usb-device vendor-id="8711" product-id="24" />
    <usb-device vendor-id="8711" product-id="26" />
</resources>
```

### 3. End-to-end example

```kotlin
// 1. Discover
val device = DeviceDiscovery.openFirstAvailable(context)
    ?: error("no Trinet device connected")

// 2. Open and start streaming
val session = device.open(SessionConfig(width = 1920, height = 1080, fps = 30))
if (!session.start()) error("stream negotiation failed")

// 3. Live preview (optional)
LivePreview(frames = session.frames, width = 1920, height = 1080)

// 4. Record
val recorder = TrinetRecorder(
    rootDir = AppPaths.recordingsDir(context),
    width = 1920, height = 1080, fps = 30,
    sampleRateHz = 562,
)
val handle = recorder.start()
lifecycleScope.launch(Dispatchers.IO) {
    session.frames.collect { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
}

// 5. Stop
handle.stop()
session.close()
device.close()
```

A complete reference integration lives in the [`app/`](../app/) module of this repo.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Your Compose UI                       │
│   LivePreview   ImuOverlayPanel   OrientationCube            │
└──────┬──────────────┬────────────────┬──────────────┬────────┘
       ▼              ▼                ▼              ▼
┌──────────────────────────────────────────────────────────────┐
│                        Kotlin SDK                            │
│                                                              │
│   TrinetDevice / TrinetSession    TrinetRecorder  Player     │
│        │                                │            │       │
│        ▼                                ▼            ▼       │
│   NativeBridge ←— SEI IMU parser    Mp4Writer   MediaCodec   │
│        │           (Annex B)        ImuFileWriter            │
│        ▼                            VtsFileWriter            │
│   libuvc_jni.cpp                                             │
└──────┬───────────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────────────────────────────────────────────────┐
│            Native  ( src/main/cpp/ )                         │
│      libuvc  ← event thread → libusb (wrap_sys_device)       │
└──────┬───────────────────────────────────────────────────────┘
       │  USB-C
       ▼
    Trinet camera
```

Two lifetimes to keep straight:

- **Device** — `TrinetDevice` owns the native handle. Created by `DeviceDiscovery.openFirstAvailable()`, closed when you're done.
- **Session** — `TrinetSession` is an active stream on that device. `session.close()` stops streaming. The native handle is released only by `device.close()`.

---

## Package map

| Package | Purpose |
|---|---|
| `device` | `TrinetDevice`, `DeviceDiscovery`, `DeviceInfo` — USB permission + open/close |
| `session` | `TrinetSession`, `SessionConfig`, `Frame` — active H.264 stream with a `SharedFlow<Frame>` |
| `transport` | `NativeBridge` — JNI entry points to libuvc/libusb |
| `sei` | `NalParser`, `SeiImuParser`, `SeiConstants` — split Annex B, decode Trinet IMU SEI |
| `model` | `ImuSample`, `VtsEntry`, `Quaternion` — data classes matching the on-disk layout |
| `io` | `BinaryReader`, `BinaryWriter` — little-endian helpers |
| `recording` | `TrinetRecorder`, `Mp4Writer`, `ImuFileWriter`, `VtsFileWriter`, `MetaWriter` |
| `playback` | `TrinetPlayer`, `ImuFileReader`, `VtsFileReader`, `RecordingFolder` |
| `fusion` | `Madgwick` — 6-DOF IMU orientation filter |
| `ui` | `LivePreview`, `ImuOverlayPanel`, `OrientationCube`, `PlotComposable`, `ImuHistory` |

---

## Key APIs

### `TrinetSession`

```kotlin
val frames: SharedFlow<Frame>
fun start(): Boolean        // negotiates H.264 format, kicks isoc transfers
fun stop()
override fun close()
data class Frame(val annexB: ByteArray, val ptsUs: Long)
```

`frames` uses `replay = 1` so a late-attaching subscriber still receives the most recent access unit — important because a Compose `LivePreview` that mounts after `session.start()` must still catch the first IDR to configure its decoder.

Frame PTS is stamped with `CLOCK_MONOTONIC` microseconds in the JNI callback, normalised against the first frame of each session (so a fresh recording always starts at PTS 0).

### `TrinetRecorder`

```kotlin
fun start(): RecordingHandle
fun submitAccessUnit(annexB: ByteArray, ptsUs: Long)
```

Each call passes the frame through the MP4 muxer and parses any IMU SEI NALs, appending decoded samples to `imu.bin` and a per-frame entry to `frames.bin`. Disk I/O must run off the main thread or you'll ANR at 30 fps:

```kotlin
session.frames
    .onEach { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
    .flowOn(Dispatchers.IO)
    .launchIn(viewModelScope)
```

### `TrinetPlayer`

```kotlin
val isPlaying: StateFlow<Boolean>
val currentFrame: StateFlow<Int>
val currentSample: StateFlow<ImuSample?>

fun play(); fun pause()
fun seekToFrame(frame: Int)
// VLC-style live scrubbing
fun beginScrub(); fun scrubTo(frame: Int); fun endScrub(resume: Boolean)
```

`scrubTo` decodes synchronously up to the requested frame and renders exactly that frame to the surface. Must be driven from a background dispatcher — see the demo app's `PlayerViewModel` for the full pattern (conflated channel + worker coroutine).

### `Madgwick` (6-DOF IMU fusion)

```kotlin
class Madgwick(var beta: Float = 0.1f) {
    fun reset()
    fun seedFromAccel(ax: Float, ay: Float, az: Float)
    fun updateIMU(gx: Float, gy: Float, gz: Float,
                  ax: Float, ay: Float, az: Float, dt: Float)
    fun asXyzw(out: FloatArray = FloatArray(4)): FloatArray
}
```

Accel + gyro only — yaw drifts without a magnetometer reference.

---

## USB permission flow

Android 9+ has two footguns that routinely stall first-time integrations:

1. **`CAMERA` permission is a precondition for UVC USB access.** Without it `UsbManager.requestPermission` returns a `false` broadcast immediately — no dialog shown. Request `CAMERA` before calling `requestPermission(device, …)`.
2. **The broadcast receiver must be `RECEIVER_EXPORTED`** on API 33+, and the pending intent must carry `setPackage(packageName)` to pass the Android 14 implicit-intent restriction. `DeviceDiscovery.requestPermission` handles this.

Device filter: VID `0x2207` with PIDs `0x0016 / 0x0018 / 0x001A`.

---

## File formats

A recording is a self-contained folder:

```
recording_<timestamp>/
 ├ video.mp4        # H.264, muxed with MediaMuxer
 ├ imu.bin          # TRIMU001 binary IMU log
 ├ frames.bin       # TRIVTS01 binary per-frame timing log
 └ meta.json        # session metadata
```

### `imu.bin` — TRIMU001

64-byte header followed by one 80-byte record per IMU sample:

```
header (64 bytes)
    magic[8]        "TRIMU001"
    version         uint32   (= 3)
    sample_rate_hz  uint32
    accel_fs        uint16
    gyro_fs         uint16
    start_time_ns   uint64
    video_start_ns  uint64
    flags           uint32
    reserved[24]

sample (80 bytes, little-endian)
    timestamp_ns     uint64
    accel[3]         float32   (m/s², includes gravity)
    gyro[3]          float32   (rad/s)
    mag[3]           float32   (µT)
    temp_c           float32
    quat_xyzw[4]     float32   (reserved — compute via Madgwick)
    lin_accel[3]     float32   (reserved)
    fsync_delay_us   float32
```

### `frames.bin` — TRIVTS01 v2

32-byte header + 24 bytes per frame:

```
header (32 bytes)
    magic[8]            "TRIVTS01"
    version             uint32   (= 2)
    frame_rate_milli    uint32
    reserved[16]

entry (24 bytes)
    frame_number        uint32
    sof_timestamp_ns    uint64
    venc_seq            uint32
    venc_pts_us         uint64
```

### `meta.json`

```json
{
  "id": "recording_20260414_210027",
  "createdAtEpochMs": 1765100427000,
  "deviceVendorId": 8711,
  "deviceProductId": 22,
  "deviceSerial": "…",
  "width": 1920, "height": 1080, "fps": 30,
  "codec": "h264",
  "sdkVersion": "0.1.0"
}
```

---

## Compose helpers

- **`LivePreview(frames, width, height)`** — `MediaCodec` decoder feeding a `SurfaceView`. Caches SPS/PPS across frames (late subscribers can miss the first IDR), runs decode on `Dispatchers.Default`, and only queues the first key-frame forward.
- **`ImuOverlayPanel(history, sample, quatXyzw)`** — scrollable panel: orientation cube + quaternion readout + per-sensor cards (accel, gyro, mag) with colour-coded x/y/z/|v| numeric readouts plus mini plots.
- **`ImuHistory(capacity = 300)`** — thread-safe fixed-capacity ring buffer for the plot window.
- **`OrientationCube`** — lightweight Canvas cube driven by a unit quaternion.
- **`TimeSeriesPlot` / `TripleAxisPlot`** — Canvas-based plots; no OpenGL.

---

## Native layer

`src/main/cpp/libuvc_jni.cpp`:

1. **`nativeOpen(fd)`** — sets `LIBUSB_OPTION_NO_DEVICE_DISCOVERY`, then `uvc_init(&ctx, NULL)` so **libuvc owns its libusb context**. Critical: passing your own context makes libuvc set `own_usb_ctx=0` and skip starting its event-handler thread, which means isochronous transfer completions never fire and no frames ever arrive.
2. **`nativeStartStream`** — rejects anything other than `UVC_FRAME_FORMAT_H264`. No silent fallback to MJPEG.
3. **Per-frame callback** — copies `frame->data` to a `jbyteArray` and calls back into Kotlin. Stamps each frame with `CLOCK_MONOTONIC` µs relative to the first frame of the session (libuvc's `capture_time` is unpopulated on Android).
4. **`nativeClose`** — `uvc_close(devh)` then `uvc_exit(ctx)`. Don't also call `libusb_exit` — libuvc does it for us.

---

## Testing

```bash
./gradlew :trinet-sdk:test                 # JVM unit tests (parsers, IO, formats)
./gradlew :trinet-sdk:connectedAndroidTest # instrumented round-trip (needs a device)
```

---

## Packaging as an AAR

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android { publishing { singleVariant("release") } }
publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.panoculon"
            artifactId = "trinet-sdk"
            version = "0.1.0"
            afterEvaluate { from(components["release"]) }
        }
    }
}
```

Then `./gradlew :trinet-sdk:publishToMavenLocal` or push to your Sonatype / JitPack endpoint.

---

## Licensing

- SDK source: **MIT** (see `LICENSE`).
- `libuvc` (v0.0.7) — BSD-3-Clause, © 2010-2015 Ken Tossell & libuvc authors.
- `libusb` (v1.0.27) — LGPL-2.1.

The native build produces `libusb-1.0.so` + `libuvc.so` shipped inside the AAR's `jniLibs/`. Include the upstream copyright notices in any redistribution.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Permission dialog never appears | `CAMERA` permission not held at the moment of the USB request. |
| `native open ok` but no frames arrive | Old JNI build passed a non-null libusb context to `uvc_init`, skipping the event-handler thread. |
| Black preview after decoder configure | First IDR arrived before the decoder subscribed. `frames` uses `replay = 1`; custom consumers should too. |
| `NO_MEMORY` at `MediaCodec.start()` | Truncated MP4 from an old build, or a leftover decoder from a previous screen. Release all decoders first. |
| Scroll position resets in the IMU panel | Don't wrap `ImuOverlayPanel` in `key(historyVersion) { … }` — it destroys `rememberScrollState()`. |
| Video freezes while dragging the slider | Bind `onValueChange` to a local `var` and call `seekToFrame` from `onValueChangeFinished`, or use the scrub API. |

---

## Versioning

`TrinetSdk.VERSION` — currently `0.1.0`. Bump on on-disk layout changes, non-additive Kotlin API changes, or native ABI changes.
