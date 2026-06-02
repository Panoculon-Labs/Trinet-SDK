# Trinet SDK — iOS

Swift package for capturing video and per-frame inertial data from a **Trinet
camera** connected to an iPhone over USB.

On iOS the camera connects as a **CDC NCM (USB-Ethernet)** device — iPhone does
not expose external UVC cameras to third-party apps, so the firmware serves the
stream over IP. The SDK handles the USB-interface-pinned networking, parses the
in-stream IMU/temperature SEI in real time, decodes H.264/H.265 with
VideoToolbox, and writes recordings to a standard MP4 plus companion binary
sidecars. Opt-in SwiftUI widgets provide a live preview, IMU plots, an
orientation cube, and a playback IMU track.

- Minimum iOS: **17.0**
- Language: **Swift 5.9**, zero external dependencies (Network.framework,
  AVFoundation, VideoToolbox, CoreMedia, SwiftUI)
- Transport: **CDC NCM**. Why it differs from Android's UVC path:
  [`../docs/TRANSPORT.md`](../docs/TRANSPORT.md). Wire spec:
  [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md).

---

## Install (Swift Package Manager)

`Package.swift` lives at the **repository root** (SwiftPM requires it there), so
you depend on the repo directly:

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

In Xcode: **File → Add Package Dependencies…** → enter the repo URL → **Up to
Next Major `0.1.6`** → add the **TrinetSDK** product.

`import TrinetSDK` and you're set.

### Build & test from source

```bash
# from the repo root (where Package.swift lives):
swift build
swift test                 # runs the IMU/format unit tests
```

> Some UI/decoder code is iOS-only (UIKit / VideoToolbox). A host macOS
> `swift build` may need `xcodebuild -scheme TrinetSDK -destination
> 'generic/platform=iOS'` instead; device builds are the supported path.

---

## Quick start

```swift
import TrinetSDK

// 1. Discover (scans the USB-Ethernet subnet, off the default route)
let discovery = TrinetDiscovery()
let devices   = await discovery.scan(timeout: 2.0)
guard let device = devices.first else { return }

// 2. Connect + (optionally) configure
try await device.connect()
try await device.applyConfig(.init(codec: .h265, bitrateKbps: 15_000))

// 3. Open a live session
let session = await device.liveSession()
await session.start()

// 4a. Live preview — feed the SwiftUI view the sample stream …
//     LivePreviewView(stream: session.sampleStream)
// 4b. … and/or consume IMU batches yourself
Task {
    for await batch in session.imuStream {
        // batch.samples : [ImuSample], batch.accelFs / batch.gyroFs
    }
}

// 5. Record (MP4 with IMU SEI muxed in + .imu/.vts sidecars)
let handle = try await session.startRecording(in: outputDirectory)
// … user records …
session.stopRecording()

// 6. Tear down
await session.stop()
await device.disconnect()
```

A complete reference integration is the [`TrinetApp/`](TrinetApp/) demo.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       Your SwiftUI app                        │
│  LivePreviewView  ImuPlotView  OrientationCubeView  Track     │
└──────┬──────────────┬───────────────┬───────────────┬────────┘
       ▼              ▼               ▼               ▼
┌──────────────────────────────────────────────────────────────┐
│                          TrinetSDK                            │
│                                                              │
│  TrinetDiscovery → TrinetDevice → TrinetLiveSession          │
│        │                │                │                   │
│        ▼                ▼                ▼                   │
│  InterfacePinning   DeviceAPI(:8081)   VideoStream(:8080)    │
│  SyncCoordinator(:5557)  TrinetSEI     VideoDecoder         │
│                          (IMU/temp)    (VideoToolbox)        │
│                                │                             │
│                          Mp4Writer / ImuFileWriter /        │
│                          VtsFileWriter   (recording)        │
└──────┬───────────────────────────────────────────────────────┘
       │  USB-C  (CDC NCM / USB-Ethernet, DHCP 172.32.x.0/24)
       ▼
    Trinet camera
```

Two lifetimes to keep straight:

- **Device** — `TrinetDevice` (an `actor`) owns the connection + HTTP/UDP
  clients. `connect()` / `disconnect()`.
- **Session** — `TrinetLiveSession` is an active video + IMU stream on that
  device, plus recording control. `start()` / `stop()`.

---

## Module map (`Sources/TrinetSDK/`)

| Folder | Purpose |
|---|---|
| `Device/` | `TrinetDiscovery`, `TrinetDevice` (connect/config/state/storage/time/sync), `TrinetLiveSession` (live streams + recording) |
| `Transport/` | `VideoStream` (Annex-B reader + NAL split), `DeviceAPI` (JSON `:8081`), `SyncCoordinator` (UDP `:5557`), `TrinetSEI` (in-stream IMU/temp), `InterfacePinning` (bind `NWConnection` to the USB iface), `TrinetSDK` (version) |
| `Decode/` | `VideoDecoder` (H.264/H.265 → `CMSampleBuffer` via VideoToolbox), `LivePreviewView` (UIViewRepresentable display) |
| `Model/` | `DeviceConfig` / `VideoCodec` / `VideoResolution`, `ImuSample` (80-byte), `VtsEntry` |
| `Recording/` | `TrinetRecorder` (`RecordingHandle`), `Mp4Writer`, `ImuFileWriter` (TRIMU001), `VtsFileWriter` (TRIVTS01) |
| `Playback/` | `RecordingInfo`/`RecordingInfoCollector`, `MadgwickAHRS` + `Quaternion`, `ImuPlaybackData` |
| `UI/` | `ImuPlotView` + `ImuHistory` + `ImuAxis`, `OrientationCubeView`, `PlaybackImuTrackView` |

---

## Key APIs

### `TrinetDiscovery` (actor)

```swift
func scan(timeout: TimeInterval = 1.5) async -> [TrinetDevice]
func enumerateCandidates() -> [Candidate]   // host + USB interfaceName
```

Scans the USB-Ethernet subnet only — discovery and connections are pinned to
the camera's interface so nothing leaks onto Wi-Fi/cellular.

### `TrinetDevice` (actor)

```swift
init(host: String, interfaceName: String? = nil)
func connect() async throws
func disconnect() async
func applyConfig(_ c: DeviceConfig) async throws
func setLocalConfig(_ c: DeviceConfig)
func storage() async throws -> DeviceAPI.StorageResponse
func state()   async throws -> DeviceAPI.StateResponse
func time()    async throws -> DeviceAPI.TimeResponse
func syncProbe(samples: Int = 10) async throws -> SyncCoordinator.Offset
func liveSession() async -> TrinetLiveSession
```

### `TrinetLiveSession` (final class)

```swift
var sampleStream: AsyncStream<CMSampleBuffer>   // decoded frames for preview
var imuStream:    AsyncStream<ImuBatch>          // per-frame IMU batches
func start() async
func stop()  async
@discardableResult
func startRecording(in directory: URL, baseName: String? = nil) async throws -> RecordingHandle
func stopRecording()
var isRecording: Bool
var recordingBytes: Int
```

`startRecording` snapshots the parameter sets immediately so the MP4 is valid
even if recording begins mid-GOP. `stopRecording()` finalizes off the calling
thread (safe to call from `@MainActor`) so the UI never hangs on finish.

### `DeviceConfig`

```swift
struct DeviceConfig { var codec; var resolution; var fps; var bitrateKbps; var gopSeconds }
static let `default`           // H.265, 1080p30
static let presets: [(label: String, config: DeviceConfig)]
enum VideoCodec { case h264, h265 }
enum VideoResolution { case res1080p, res720p, res480p }   // NCM streams 1080p30
```

### `MadgwickAHRS` (6-axis fusion)

```swift
final class MadgwickAHRS {
    init(beta: Float = 0.1)
    func update(gx: Float, gy: Float, gz: Float, ax: Float, ay: Float, az: Float, dt: Float)
    var quaternion: Quaternion          // w, x, y, z
}
```

Accel + gyro only — yaw drifts without a magnetometer reference. Drives
`OrientationCubeView`.

---

## SwiftUI helpers

- **`LivePreviewView(stream:)`** — wraps `AVSampleBufferDisplayLayer`; feed it
  `session.sampleStream`.
- **`ImuPlotView(history:)`** — real-time accel/gyro plot; `ImuHistory` is an
  `ObservableObject` ring buffer; `ImuAxis` supplies the Okabe-Ito colors +
  dash patterns used consistently across the UI.
- **`OrientationCubeView(quaternion:)`** — wireframe cube + colored X/Y/Z axes
  driven by a `Quaternion`.
- **`PlaybackImuTrackView`** — IMU timeline aligned to the video for playback
  scrubbing (windows on absolute device-ns).

---

## File formats

A recording is `<base>.mp4` plus two binary sidecars (extensions match the
Android SDK and the Linux toolchain, so parsers are shared):

```
<base>.mp4    # H.264/H.265, IMU SEI muxed in (self-contained, like the UVC path)
<base>.imu    # TRIMU001 v4 — 64-byte header + 80-byte samples
<base>.vts    # TRIVTS01 v2 — 32-byte header + 24-byte per-frame entries
```

### `<base>.imu` — TRIMU001 v4

```
header (64 bytes)            sample (80 bytes, little-endian)
  magic[8]  "TRIMU001"         timestamp_ns    uint64
  version   uint32 (=4)        accel[3]        float32  (m/s², incl. gravity)
  sample_rate_hz uint32        gyro[3]         float32  (rad/s)
  accel_fs  uint16             mag[3]          float32  (µT)
  gyro_fs   uint16             temp_c          float32
  start_time_ns  uint64        quat_xyzw[4]    float32  (reserved — use Madgwick)
  video_start_ns uint64        lin_accel[3]    float32  (reserved)
  flags     uint32             fsync_delay_us  float32
  reserved[…]
```

### `<base>.vts` — TRIVTS01 v2

```
header (32 bytes)            entry (24 bytes)
  magic[8] "TRIVTS01"          frame_number      uint32
  version  uint32 (=2)         sof_timestamp_ns  uint64
  frame_rate_milli uint32      venc_seq          uint32
  reserved[16]                 venc_pts_us       uint64
```

`RecordingInfoCollector.collect(mp4URL:)` reads codec / fps / bitrate / GOP /
IMU facts back out of a finished recording for display.

---

## Reference app (`TrinetApp/`)

A complete SwiftUI demo: device list, live preview with IMU plot, record
button, a library with full playback (play/pause/seek, fullscreen, share), and
codec/bitrate settings. It builds `TrinetSDK` as a sibling framework target.

> iOS has no "download an APK" equivalent — apps must be code-signed for your
> own device. The steps below build and install the demo on your iPhone from
> source with a **free Apple ID** (no paid Developer Program needed).

### Quickstart — clone, build, run on your iPhone

**Prerequisites:** a Mac with **Xcode 16+**, an **Apple ID**, and
[XcodeGen](https://github.com/yonomi/xcodegen) (`brew install xcodegen`).

```bash
# 1. Clone
git clone https://github.com/Panoculon-Labs/Trinet-SDK.git
cd Trinet-SDK/ios/TrinetApp

# 2. Generate the Xcode project (re-run after pulling changes)
xcodegen generate

# 3. Open it
open TrinetApp.xcodeproj
```

In Xcode:

4. **Set your signing team** (one-time): select the **TrinetApp** target →
   **Signing & Capabilities** → check *Automatically manage signing* → pick your
   **Team** (a personal Apple ID works). The project ships with no hardcoded
   team, so this step is required.
5. Plug your **iPhone** (USB-C, iOS 17+) into the Mac and **trust** the computer.
6. Pick your iPhone as the run destination and press **▶ Run**. First run:
   on the phone, go to **Settings → General → VPN & Device Management** and
   **trust** your developer certificate, then launch the app.

> **Free Apple ID caveat:** apps signed with a free account stop launching after
> **7 days** — just re-run from Xcode to refresh. A paid Apple Developer Program
> account removes this and enables TestFlight for wider distribution.

### Use it with the camera

The camera must be in **iPhone (CDC NCM) mode** before iOS can see it — in that
mode it presents as a USB-Ethernet device (see
[`../docs/TRANSPORT.md`](../docs/TRANSPORT.md)). You select the mode with a
one-line config file on the camera's SD card.

1. **Put the camera in iPhone mode.** Copy [`trinet_mode.conf`](trinet_mode.conf)
   — a one-line file containing `mode=ncm` — onto the camera's SD card so its
   path is `Trinet/trinet_mode.conf`, then insert the card and power the camera
   on. The status LED turns **cyan** to indicate iPhone (NCM) mode.
2. Plug the Trinet camera into the iPhone. **Settings → Ethernet** shows a new
   interface within ~3 s.
3. Open the app — the Home tab shows one Trinet on `172.32.<X>.x`.
4. Hit Record. Files land in the app's `Documents/Trinet/` folder (pull them via
   Finder → device → Files → TrinetApp).

> The config file is just plain text — `mode=ncm` on its own line. You can
> create it by hand instead of copying it; the camera reads it from the SD
> card's `Trinet/` folder on each boot.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| No device found, but Settings → Ethernet shows it | Wait for the DHCP lease; tap Rescan. Discovery binds to the USB interface — connections won't fall back to Wi-Fi. |
| Connection leaks to Wi-Fi / cellular | Ensure interface pinning resolved (`InterfacePinning`); as a last resort turn Wi-Fi off. |
| Recording screen hangs on open | Connection setup must run off the main thread (it does in `VideoStream.start`); don't call discovery/pinning on `@MainActor`. |
| Empty / 0 KB MP4 | The writer needs a `sourceFormatHint`; `Mp4Writer` creates the input lazily from the first parameter sets — start recording after `session.start()`. |
| Simulator can't see the camera | USB-Ethernet + camera are device-only; test on a physical iPhone. |
| Local Network permission prompt re-appears | iOS resets it on reinstall — allow it in Settings. |

---

## Versioning

`TrinetSDK.version` — currently **`0.1.6`**, tracking the git tag. Bump on
on-disk-format changes, wire-protocol changes, or non-additive API changes. The
Android SDK is versioned independently; both share the same on-disk and
wire formats. Release notes are published under [**Releases**](../../releases).

## License

MIT — see [`../LICENSE`](../LICENSE).
