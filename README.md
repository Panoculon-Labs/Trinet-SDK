# Trinet SDK

SDKs for capturing video and per-frame inertial data from **Trinet cameras** over
USB — on **Android** and **iOS**. Real-time IMU parsing, recording with synchronized
sidecars, and frame-accurate playback.

The Trinet camera is a wearable, synchronized video + inertial-measurement device for
**egocentric (first-person) data collection** in visual-inertial SLAM, camera–IMU
calibration, and dead-reckoning research. It streams H.264/H.265 video and embeds
inertial samples directly in the video bitstream, so every frame arrives with the IMU
samples captured alongside it. Each SDK wraps the USB transport, sensor parsing,
recording, and playback so app developers don't have to.

The two platforms use **different USB transports** (Android: UVC; iOS: CDC NCM) but
carry the same video + IMU payload and write the same on-disk format — see
[**docs/TRANSPORT.md**](docs/TRANSPORT.md).

The camera selects its USB mode from a one-line `trinet_mode.conf` on its SD card:
`mode=uvc` for Android, `mode=ncm` for iPhone. Insert the card and power on; the
status LED confirms the active mode.

## Platforms

| Platform | How it's distributed | Start here |
|---|---|---|
| **Android** | Prebuilt **AAR** (`com.panoculon:trinet-sdk:0.1.5`) + docs; demo APKs under [Releases](../../releases) | this page ↓ |
| **iOS** | **Swift source** via Swift Package Manager | [**ios/README.md**](ios/README.md) |

> The rest of this page documents the **Android** SDK. For **iOS**, see
> [ios/README.md](ios/README.md) (install, API, and a clone→Xcode→iPhone quickstart).

---

## Features

- **USB device discovery + permission flow** that handles the Android 9 → 14 quirks for
  UVC camera permission so you don't have to.
- **H.264 video streaming** over UVC, fanned out as a Kotlin `Flow` of access units to
  any number of consumers (preview + recorder simultaneously).
- **Inline IMU** — accelerometer, gyroscope, magnetometer, temperature, and a
  hardware frame-sync delay are embedded per-frame in the video bitstream and decoded
  for you (≈500–562 Hz).
- **Recording** to a self-contained folder: `video.mp4` + an IMU sidecar + a
  frame-timestamp sidecar + `meta.json`.
- **Playback** with a built-in H.264 player that paces frames, exposes the current
  frame's IMU sample, and supports VLC-style frame-accurate scrubbing.
- **Madgwick orientation fusion** helper to turn the raw accel/gyro streams into an
  orientation quaternion.
- **Drop-in Jetpack Compose UI**: a live preview surface, an IMU overlay panel,
  a quaternion-driven orientation cube, and time-series plot widgets.

---

## Requirements

| | |
|---|---|
| Min SDK | **28** (Android 9) |
| Bundled native ABIs | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| Hardware | An Android device with **USB host** support (USB-C OTG) and a Trinet camera |
| Language | Kotlin (the public API is Kotlin-first; Java interop works but is not the primary target) |

The SDK uses Jetpack Compose for its optional UI widgets and `kotlinx.coroutines`
`Flow`/`StateFlow` throughout. If you only consume the non-UI parts (discovery,
session, recording, playback, sidecar readers) you still need the coroutines
dependency, but the Compose dependencies are only required if you use the `ui` package.

---

## Install

The AAR lives in [`aar/`](aar/) (Maven coordinates `com.panoculon:trinet-sdk:0.1.5`).
Add it as a flat-dir dependency. Because a flat AAR carries no POM, you must declare the
SDK's runtime dependencies yourself.

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        flatDir { dirs("aar") }            // or an absolute path to the .aar
    }
}
```

```kotlin
// app/build.gradle.kts
android {
    compileSdk = 35
    defaultConfig {
        minSdk = 28
    }
    buildFeatures { compose = true }
}

dependencies {
    implementation(":trinet-sdk-0.1.5@aar")

    // Transitive runtime dependencies the SDK expects on the classpath:
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Required only if you use the SDK's `ui` Compose widgets:
    implementation(platform("androidx.compose:compose-bom:2024.10.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
}
```

### AndroidManifest setup

The camera connects over USB, so your app must declare the USB-host feature and the
runtime CAMERA permission (Android silently denies USB permission for video-class
devices when CAMERA isn't granted). To make your activity launch automatically when a
Trinet camera is plugged in, add the `USB_DEVICE_ATTACHED` intent-filter plus a
`device_filter.xml` listing the camera's USB IDs.

```xml
<!-- AndroidManifest.xml -->
<uses-feature android:name="android.hardware.usb.host" android:required="true" />
<uses-permission android:name="android.permission.CAMERA" />

<activity
    android:name=".MainActivity"
    android:exported="true"
    android:launchMode="singleTask">

    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>

    <!-- Auto-launch this activity when a Trinet camera is attached -->
    <intent-filter>
        <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
    </intent-filter>
    <meta-data
        android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
        android:resource="@xml/device_filter" />
</activity>
```

```xml
<!-- res/xml/device_filter.xml — vendor-id/product-id are decimal -->
<resources>
    <usb-device vendor-id="8711" product-id="22" />   <!-- 0x2207 / 0x0016 -->
    <usb-device vendor-id="8711" product-id="24" />   <!-- 0x2207 / 0x0018 -->
    <usb-device vendor-id="8711" product-id="26" />   <!-- 0x2207 / 0x001A -->
</resources>
```

Full manifest + permission walkthrough: [docs/getting-started.md](docs/getting-started.md).

---

## Quickstart

A minimal end-to-end flow: discover a camera, open a streaming session, show a live
preview, record, then stop. (Run discovery/open/recording I/O off the main thread.)

```kotlin
import com.panoculon.trinet.sdk.device.DeviceDiscovery
import com.panoculon.trinet.sdk.recording.TrinetRecorder
import com.panoculon.trinet.sdk.session.SessionConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext

// 1. Discover + open (suspends on the USB permission prompt).
val device = withContext(Dispatchers.IO) {
    DeviceDiscovery.openFirstAvailable(context)
} ?: error("No Trinet camera attached")

val config = SessionConfig(width = 1920, height = 1080, fps = 30)
val session = withContext(Dispatchers.IO) { device.open(config) }

// 2. Start streaming. Frames are an H.264 Annex B Flow.
check(session.start()) { "stream negotiation failed" }

// 3. Live preview (Compose) — drop into your composable hierarchy:
//    LivePreview(frames = session.frames, width = config.width, height = config.height)

// 4. Record video + IMU + frame timestamps into a folder.
val recorder = TrinetRecorder(
    rootDir = filesDir,
    width = config.width, height = config.height, fps = config.fps,
    sampleRateHz = 562,
    device = TrinetRecorder.DeviceMeta(
        device.info.vendorId, device.info.productId, device.info.serial,
    ),
)
val handle = recorder.start()
val job = session.frames
    .onEach { f -> recorder.submitAccessUnit(f.annexB, f.ptsUs) }
    .flowOn(Dispatchers.IO)
    .launchIn(scope)

// 5. Stop.
job.cancel()
handle.stop()          // finalizes video.mp4 + sidecars in handle.folder
session.close()
device.close()
```

Play it back later:

```kotlin
import com.panoculon.trinet.sdk.playback.RecordingFolder
import com.panoculon.trinet.sdk.playback.TrinetPlayer

val folder = RecordingFolder(handle.folder)
val player = TrinetPlayer(folder, surface)   // surface from a SurfaceView
player.play()
// player.currentSample : StateFlow<ImuSample?> — the IMU aligned to the shown frame
```

---

## Documentation

| Guide | Covers |
|---|---|
| [Getting started](docs/getting-started.md) | Manifest, USB-host + CAMERA permissions, the runtime USB permission flow, auto-launch on attach, discovering and opening a camera |
| [Streaming](docs/streaming.md) | Opening a session, the frame `Flow`, the `LivePreview` Compose component, multiple consumers |
| [IMU](docs/imu.md) | The IMU sample model, sample rate, extracting samples live, Madgwick orientation fusion, the IMU/cube/plot UI widgets |
| [Recording](docs/recording.md) | `TrinetRecorder`, the recording handle + state machine, the on-disk output folder |
| [Playback](docs/playback.md) | `RecordingFolder`, `TrinetPlayer`, scrubbing, the sidecar readers, aligning IMU to frames |
| [File formats](docs/file-formats.md) | The recording triple (`.mp4` + IMU + VTS sidecars) and the in-stream SEI-embedded IMU format |
| [API reference](docs/api-reference.md) | Concise per-class reference for every public type |

---

## Demo app

Prebuilt demo APKs are attached to each [GitHub Release](../../releases). The demo
exercises the entire SDK: USB pairing, live preview, recording, a browsable library,
frame-accurate VLC-style scrubbing, and IMU overlays.

---

## iOS (Swift Package)

The iOS SDK is distributed as **Swift source** under [`ios/`](ios/) and consumed via
Swift Package Manager (zero external dependencies). On iOS the camera connects as a
**CDC NCM (USB-Ethernet)** device rather than UVC — see
[docs/TRANSPORT.md](docs/TRANSPORT.md). Put the camera in this mode with
`mode=ncm` in `Trinet/trinet_mode.conf` on its SD card
([details](ios/README.md#use-it-with-the-camera)).

```swift
// Consumer Package.swift
dependencies: [
    .package(url: "https://github.com/Panoculon-Labs/Trinet-SDK", from: "0.1.6"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "TrinetSDK", package: "Trinet-SDK"),
    ]),
]
```

In Xcode: **File → Add Package Dependencies…** → the repo URL → add the **TrinetSDK**
product. (`Package.swift` is at the repo root because SwiftPM requires it there.)

Full iOS guide — API, file formats, wire spec, and a **clone → Xcode → iPhone**
quickstart for the demo app — is in [**ios/README.md**](ios/README.md). iOS wire
protocol: [ios/docs/PROTOCOLS.md](ios/docs/PROTOCOLS.md).

## License

See [LICENSE](LICENSE).
