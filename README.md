# Trinet SDK for Android

Open-source Kotlin SDK + reference demo app for capturing video and per-frame inertial data from **Trinet cameras** over USB on Android.

## What's in this repo

- **[`trinet-sdk/`](trinet-sdk/)** — the redistributable library. Handles USB/UVC transport, real-time sensor-data parsing, MP4 + sidecar recording, Madgwick orientation fusion, and ships opt-in Jetpack Compose widgets for live preview and IMU visualisation. See the [SDK README](trinet-sdk/README.md) for the full API reference, file-format spec, and integration guide.
- **[`app/`](app/)** — a minimal reference consumer that exercises the entire SDK: USB pairing, live preview, recording, a browsable library, frame-accurate VLC-style scrubbing, and IMU overlays.

## Requirements

- Android 9+ (API 28)
- Android Studio Ladybug or newer
- A Trinet camera

## Build

```bash
./gradlew :app:assembleDebug      # APK → app/build/outputs/apk/debug/
./gradlew :app:installDebug       # install on a connected device
./gradlew :trinet-sdk:test        # JVM unit tests
```

The first build fetches `libuvc` and `libusb` via CMake `FetchContent`; give it a minute.

## Demo app highlights

- Plug-and-play USB pairing with the right permission dance for Android 9–14
- Live 1080p30 preview with frame-accurate IMU overlays
- Record to a self-contained folder (`video.mp4` + `imu.bin` + `frames.bin` + `meta.json`)
- Library browser with share / rename / delete, long-press multi-select, bulk delete
- Frame-accurate scrubbing with synchronous video + IMU update (VLC-style)
- Fullscreen landscape playback mode
- Madgwick 6-DOF orientation computed live from the raw sensor streams

## License

MIT — see [`LICENSE`](LICENSE).

Bundled native libraries:
- **libuvc** v0.0.7 — BSD-3-Clause
- **libusb** v1.0.27 — LGPL-2.1
