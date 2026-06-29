# API reference

Concise reference for every public type the AAR exposes, grouped by package. Package
root: `com.panoculon.trinet.sdk`.

- [`TrinetSdk`](#trinetsdk)
- [Package `device`](#package-device)
- [Package `session`](#package-session)
- [Package `recording`](#package-recording)
- [Package `playback`](#package-playback)
- [Package `model`](#package-model)
- [Package `sei`](#package-sei)
- [Package `fusion`](#package-fusion)
- [Package `io`](#package-io)
- [Package `ui`](#package-ui)

---

## `TrinetSdk`

`object TrinetSdk`

| Member | Description |
|---|---|
| `const val VERSION: String` | SDK version string. |
| `fun nativeVersion(): String` | Runtime version of the bundled native UVC shim. |

---

## Package `device`

### `DeviceInfo`

`data class DeviceInfo(vendorId, productId, serial, productName, deviceName)`

Identity of a connected (not necessarily opened) device.

| Member | Type | Description |
|---|---|---|
| `vendorId` | `Int` | USB vendor ID. |
| `productId` | `Int` | USB product ID. |
| `serial` | `String?` | USB serial (public per-unit device ID), or null. |
| `productName` | `String?` | USB product string. |
| `deviceName` | `String` | OS device node name. |
| `isTrinet` | `Boolean` | True if VID/PID match the Trinet set. |
| `Companion.TRINET_VID` | `Int` | `0x2207`. |
| `Companion.TRINET_PIDS` | `Set<Int>` | `{0x0016, 0x0018, 0x001A}`. |

### `DeviceDiscovery`

`object DeviceDiscovery`

| Member | Signature | Description |
|---|---|---|
| `connectedDevices` | `(context): List<UsbDevice>` | Currently attached Trinet-class USB devices. |
| `requestPermission` | `suspend (context, device): Boolean` | Request runtime USB permission; suspends until the user responds. `true` on grant (returns immediately if already held). |
| `openFirstAvailable` | `suspend (context): TrinetDevice?` | Discover + permission-prompt + open the first available camera. Null if none/denied. |

### `TrinetDevice`

`class TrinetDevice(usbDevice: UsbDevice, usbManager: UsbManager) : Closeable`

Owns a granted USB connection.

| Member | Signature | Description |
|---|---|---|
| `usbDevice` | `UsbDevice` | The underlying USB device. |
| `info` | `DeviceInfo` | Parsed identity. |
| `open` | `(config: SessionConfig = SessionConfig()): TrinetSession` | Open the device + init the native layer, returning a streaming session. **Call on a worker thread.** Throws if permission isn't held or the native open fails. |
| `close` | `()` | Release the USB handle (and the session). |

**Camera controls** (all run over the existing connection — never open a second
one while streaming. Call off the main thread.):

| Member | Signature | Description |
|---|---|---|
| `setLed` | `(red: Boolean, green: Boolean, blue: Boolean): Boolean` | Set the status-LED channels (on/off per channel; no brightness). |
| `setBitrate` | `(kbps: Int): Boolean` | Set the video bitrate target (256–30000 kbps). Saved on the camera and applied on the next stream; the camera briefly restarts to apply it. |
| `getBitrate` | `(): Int` | Current bitrate target (kbps), or -1. |
| `setRcMode` | `(mode: Int): Boolean` | Rate-control mode: 1 = CBR (constant quality), 2 = AVBR (clamps the average to the target). Saved + applied on restart. |
| `getRcMode` | `(): Int` | Current rate-control mode (0 = default, 1 = CBR, 2 = AVBR), or -1. |
| `setMode` | `(mode: String): Boolean` | Persistent start-up mode (`"uvc"` for this app, `"ncm"` for the iOS streaming path). The camera restarts into the new mode. |
| `getMode` | `(): String?` | Current persistent start-up mode. |
| `setExposureRange` | `(minMs: Float, maxMs: Float): Boolean` | Set the auto-exposure time range (ms). The minimum holds the flicker-free floor; the maximum caps motion blur. Saved on the camera and applied across all modes on the next start (the camera restarts). |
| `getExposureRange` | `(): Pair<Float, Float>?` | Current min/max exposure (ms), or null. |
| `setMainsFrequency` | `(hz: Int): Boolean` | Set the mains / anti-flicker frequency (50 or 60). Pick by region — 60 in the Americas, 50 in Europe/Asia — to remove flicker banding from indoor lighting. Saved + applied across all modes on restart. |
| `getMainsFrequency` | `(): Int` | Current mains frequency (50 or 60 Hz), or -1. |
| `setCalibration` / `getCalibration` | `(CalibrationData): Boolean` / `(): CalibrationData?` | Store / read the camera+IMU calibration on the device (intrinsics, distortion, extrinsics, time-shift). |
| `getThermal` | `(): ThermalStatus?` | Camera die temperature + a latched `paused` flag. Poll ~1 Hz while recording; when `paused` is true the camera is too hot — stop recording (and preview) and resume when it clears. `null` on older firmware. |

> Bitrate and rate-control changes persist on the camera and survive a power
> cycle; the camera restarts (~15 s) to apply them, and the SDK reconnects
> automatically.

**Calibration upload.** `CalibrationData.fromCalibrationJson(json)` parses a
Kalibr / Trinet-Calibration `calibration.json` into a `CalibrationData` you can
`setCalibration(...)`. (The demo app's file picker accepts either a
`calibration.json` or a ready 164-byte `.bin` blob.)

**Thermal pause.** `getThermal()` returns `ThermalStatus(tempC, state, paused)`.
The demo Record screen polls it while recording and auto-pauses/resumes recording
on `paused` (showing a "cooling down" banner) — mirroring the SD recorder's
pause/cool/resume on the streaming path.

---

## Package `session`

### `SessionConfig`

`data class SessionConfig(width: Int = 1920, height: Int = 1080, fps: Int = 30)`

Requested stream format. The device must advertise a matching combination.

### `TrinetSession`

`class TrinetSession : Closeable` (constructed via `TrinetDevice.open`)

| Member | Type / Signature | Description |
|---|---|---|
| `config` | `SessionConfig` | The config this session was opened with. |
| `frames` | `SharedFlow<Frame>` | Stream of H.264 access units (`replay = 1`). |
| `errors` | `SharedFlow<String>` | Recoverable native stream errors. |
| `start` | `(): Boolean` | Begin streaming. `false` if format negotiation failed. |
| `stop` | `()` | Stop streaming (re-startable). |
| `close` | `()` | Stop + mark unusable. Does **not** release the USB device. |
| `Frame` | `data class Frame(annexB: ByteArray, ptsUs: Long)` | One access unit (Annex B) + capture PTS (µs). |

### `FrameCallback`

`fun interface FrameCallback { fun onFrame(annexB: ByteArray, ptsUs: Long) }`

Functional interface for a per-frame callback. Implementers must not block.

---

## Package `recording`

### `TrinetRecorder`

`class TrinetRecorder(rootDir, width, height, fps, sampleRateHz, accelFsDefault = 2, gyroFsDefault = 3, device = DeviceMeta(...))`

Records a session to a folder (`video.mp4` + `imu.bin` + `frames.bin` + `meta.json`).

| Member | Signature | Description |
|---|---|---|
| `start` | `(): RecordingHandle` | Create the folder + open writers. Throws if already recording. |
| `submitAccessUnit` | `(annexB: ByteArray, ptsUs: Long)` | Mux one frame to MP4, split its SEI IMU into the sidecar, append a VTS entry. Run on `Dispatchers.IO`. |
| `DeviceMeta` | `data class DeviceMeta(vendorId, productId, serial)` | Device identity baked into `meta.json` + the IMU header. |

### `RecordingHandle`

`class RecordingHandle` (returned by `TrinetRecorder.start`)

| Member | Type | Description |
|---|---|---|
| `folder` | `File` | The recording folder. |
| `videoFile` / `imuFile` / `vtsFile` / `metaFile` | `File` | Output file paths. |
| `state` | `StateFlow<RecordingState>` | Live recording state. |
| `stop` | `()` | Finalize the MP4 + sidecars + `meta.json`. |

### `RecordingState`

`sealed interface RecordingState`

| Variant | Fields |
|---|---|
| `Idle` | — |
| `Active` | `frameCount, sampleCount, durationMs` |
| `Stopped` | `folder, frameCount, sampleCount, durationMs` |
| `Failed` | `error: Throwable` |

### `RecordingMeta` / `MetaWriter`

`data class RecordingMeta(id, createdAtEpochMs, deviceVendorId, deviceProductId, deviceSerial, width, height, fps, codec, sdkVersion)` and `object MetaWriter { fun write(file, meta) }` — write `meta.json`. Normally driven by `TrinetRecorder`.

### Low-level writers

Used internally by `TrinetRecorder`; available if you build a custom pipeline.

| Type | Purpose |
|---|---|
| `Mp4Writer(outFile, width, height, fps) : Closeable` | Mux Annex B H.264 into MP4 via `MediaMuxer`. `writeAccessUnit(annexB, ptsUs)`. |
| `ImuFileWriter(file, sampleRateHz, accelFs, gyroFs, flagsFsync = true, deviceId = null, batchSize = 64) : Closeable` | Write a `TRIMU001` v3 sidecar. `append(sample)`, `flush()`, `sampleCount`. |
| `VtsFileWriter(file, fps: Float) : Closeable` | Write a `TRIVTS01` v2 sidecar. `append(entry)`, `flush()`, `entryCount`. |

---

## Package `playback`

### `RecordingFolder`

`data class RecordingFolder(dir: File)`

| Member | Type / Signature | Description |
|---|---|---|
| `video` / `imu` / `vts` / `meta` | `File` | Paths to the four recording files. |
| `isComplete` | `Boolean` | video + imu + vts all present. |
| `delete` | `(): Boolean` | Recursively delete the folder. |
| `renameTo` | `(newName): RecordingFolder?` | Rename (sanitized); null on conflict/failure. |
| `Companion.listIn` | `(root: File): List<RecordingFolder>` | Recordings under a dir, newest first. |

### `TrinetPlayer`

`class TrinetPlayer(folder: RecordingFolder, surface: Surface) : Closeable`

| Member | Type / Signature | Description |
|---|---|---|
| `currentFrame` | `StateFlow<Int>` | Index of the displayed frame. |
| `currentSample` | `StateFlow<ImuSample?>` | IMU aligned to the displayed frame (distinct values). |
| `isPlaying` | `StateFlow<Boolean>` | Playback state. |
| `sampleStream` | `SharedFlow<SeekOrStep>` | Every sample stepped past, incl. seeks (for fusion). |
| `frameCount` | `Int` | Total frames (from VTS). |
| `imu` / `vts` | `ImuFileReader` / `VtsFileReader` | The open sidecar readers. |
| `play` / `pause` / `togglePlayPause` | `()` | Transport. |
| `seekToFrame` | `(frame: Int)` | Seek + update IMU; no scrub machinery. |
| `beginScrub` / `scrubTo` / `endScrub` | `()` / `(frame)` / `(resume: Boolean)` | Live scrub. `scrubTo` must run off the main thread. |
| `close` | `()` | Release decoder, extractor, sidecar readers. |
| `SeekOrStep` | `data class SeekOrStep(sample: ImuSample, reset: Boolean, frame: Int)` | `reset=true` → history invalidated by a seek. |

### `ImuFileReader`

`class ImuFileReader(file: File) : AutoCloseable` — mmap'd reader for `TRIMU001` sidecars (v1/v2/v3).

| Member | Type / Signature | Description |
|---|---|---|
| `version`, `sampleRateHz`, `accelFs`, `gyroFs`, `startTimeNs`, `videoStartNs`, `flags` | header fields | See [file formats](file-formats.md#imu-sidecar-imubin). |
| `sampleCount`, `sampleSize` | `Int` | Count + per-sample byte size. |
| `deviceId` / `deviceIdHex` | `ByteArray` / `String` | 16-byte public device id; hex is `""` for older recordings. |
| `sampleAt` | `(index): ImuSample` | Random access by index. |
| `readAll` | `(): List<ImuSample>` | All samples. |
| `indexAt` | `(timestampNs): Int` | Nearest sample index by timestamp (binary search); `-1` if empty. |

### `VtsFileReader`

`class VtsFileReader(file: File) : AutoCloseable` — reader for `TRIVTS01` sidecars.

| Member | Type / Signature | Description |
|---|---|---|
| `version`, `frameRateMilli` | header fields | — |
| `fps` | `Float` | `frameRateMilli / 1000`. |
| `entryCount` | `Int` | Number of frames. |
| `entryAt` | `(index): VtsEntry` | Random access by frame index. |
| `readAll` | `(): List<VtsEntry>` | All entries. |

---

## Package `model`

### `ImuSample`

`data class ImuSample(timestampNs, accel, gyro, mag, tempC, quatXyzw, linAccel, fsyncDelayUs)`

See [the IMU sample](imu.md#the-imu-sample) for fields and units. 80-byte wire layout;
`Companion.SIZE_BYTES = 80`.

### `VtsEntry`

`data class VtsEntry(frameNumber, sofTimestampNs, vencSeq, vencPtsUs)`

| Field | Type | Description |
|---|---|---|
| `frameNumber` | `Long` (u32) | 0-based frame index. |
| `sofTimestampNs` | `Long` | Start-of-frame timestamp (ns) — the IMU-alignment key. |
| `vencSeq` | `Long` (u32) | Encoder sequence number. |
| `vencPtsUs` | `Long` | Video PTS (µs) — used to seek the decoder. |

`Companion.SIZE_BYTES = 24`.

---

## Package `sei`

### `SeiImuParser`

`object SeiImuParser`

| Member | Signature | Description |
|---|---|---|
| `parse` | `(annexB, base = 0, length = ...): List<SeiImuPayload>` | Decode all Trinet IMU SEI payloads from an access unit. |
| `decodeSei` | `(seiNal: ByteArray): SeiImuPayload?` | Decode a single SEI NAL; null if no Trinet payload. |

### `SeiImuHeader` / `SeiImuPayload`

`data class SeiImuHeader(version, numSamples, accelFs, gyroFs)` ·
`data class SeiImuPayload(header: SeiImuHeader, samples: List<ImuSample>)`.

### `SeiConstants`

`object SeiConstants`

| Member | Value | Description |
|---|---|---|
| `TRIMU_UUID` | `ByteArray(16)` | UUID prefixing every Trinet IMU SEI payload. |
| `SEI_TYPE_USER_DATA_UNREGISTERED` | `5` | SEI payload type. |
| `SEI_HEADER_SIZE` | `23` | UUID(16) + version(1) + num_samples(2) + accel_fs(2) + gyro_fs(2). |
| `H264_NAL_TYPE_SEI` | `6` | H.264 NAL type for SEI. |
| `isVclNalType(nalType): Boolean` | — | True for coded-slice NAL types (1..5). |

### `NalParser` / `NalSlice`

`object NalParser`

| Member | Signature | Description |
|---|---|---|
| `splitNalUnits` | `(data, base = 0, length = ...): List<NalSlice>` | Split Annex B into NAL slices (start codes stripped). |
| `removeEmulationPrevention` | `(data, base = 0, length = ...): ByteArray` | Collapse `00 00 03` → `00 00`. |
| `addEmulationPrevention` | `(data, base = 0, length = ...): ByteArray` | Inverse of the above. |

`data class NalSlice(source, offset, length)` — `headerByte`, `h264Type` (header `& 0x1F`),
`payload()`, `copy()`.

---

## Package `fusion`

### `Madgwick`

`class Madgwick(var beta: Float = 0.1f)`

6-DOF Madgwick AHRS filter (accel + gyro). See [orientation fusion](imu.md#orientation-fusion-madgwick).

| Member | Signature | Description |
|---|---|---|
| `beta` | `Float` | Filter gain. |
| `reset` | `()` | Reset to identity quaternion. |
| `seedFromAccel` | `(ax, ay, az)` | Seed attitude from a tilt-only accelerometer reading. |
| `updateIMU` | `(gx, gy, gz, ax, ay, az, dt)` | One update step; `dt` in seconds. Ignores out-of-range `dt`. |
| `asXyzw` | `(out = FloatArray(4)): FloatArray` | Current quaternion as scalar-last `[x, y, z, w]`. |

---

## Package `io`

Little-endian primitive helpers used by the readers/writers. Available if you need to
parse or emit the binary formats yourself.

| Type | Purpose |
|---|---|
| `BinaryReader(data, base = 0, length = ...)` | `u8/u16/u32/i32/u64/f32`, `bytes(n)`, `floatArray(n)`, `seek`, `skip`, `position`, `remaining`. |
| `BinaryWriter(initialCapacity = 64)` | `u8/u16/u32/i32/u64/f32`, `bytes`, `zeros`, `toByteArray`, `writeTo(out)`. |

---

## Package `ui`

Jetpack Compose widgets (require the Compose dependencies). See [IMU UI helpers](imu.md#ui-helpers)
and [LivePreview](streaming.md#livepreview-compose-component).

| Composable / Type | Signature | Description |
|---|---|---|
| `LivePreview` | `@Composable (frames: SharedFlow<TrinetSession.Frame>, width, height, modifier)` | Decode + display a live session. |
| `ImuOverlayPanel` | `@Composable (history: ImuHistory, sample: ImuSample?, quatXyzw: FloatArray, modifier)` | Sensor cards + orientation header. |
| `OrientationCube` | `@Composable (quatXyzw: FloatArray, modifier, color)` | Quaternion-driven wireframe cube. |
| `TimeSeriesPlot` | `@Composable (values: FloatArray, modifier, color, minY, maxY, label)` | Single-channel scrolling line plot. |
| `TripleAxisPlot` | `@Composable (x, y, z: FloatArray, modifier, label)` | Three stacked axis plots. |
| `ImuHistory` | `class ImuHistory(capacity = 300)` | Synchronized ring buffer: `add(sample)`, `reset()`, `length`, `epoch`, per-channel `accelX/Y/Z`, `gyroX/Y/Z`, `magX/Y/Z`, `fsyncUs`. |

---

See also: [Getting started](getting-started.md) · [Streaming](streaming.md) ·
[IMU](imu.md) · [Recording](recording.md) · [Playback](playback.md) ·
[File formats](file-formats.md).
