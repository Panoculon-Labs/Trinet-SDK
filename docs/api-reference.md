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
- [Package `audio`](#package-audio)
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
| `getGeneration` | `(): String?` | Camera generation code (`"v2"`…`"v5"`), or `null` on older firmware — treat `null` as `"v2"`. Map it with [`TrinetGeneration.fromCode`](#trinetgeneration). |
| `getFirmwareVersion` | `(): String?` | Camera firmware version (e.g. `"0.5.2"`), or `null` when the camera doesn't answer. Uses the shared connection, so it is safe to call while streaming. |
| `resetSettings` | `(): Boolean` | Clear every host-set override and restart the camera on its shipped defaults: bitrate, GOP, rate control, mic gain/mute/AGC/sample-rate, the IMU-stream toggle, image controls, exposure range and mains frequency. Deliberately **kept**: the stored calibration and its lock, the boot mode, and the USB transport — resetting those could leave the camera somewhere the app can no longer reach it, which is not what "restore defaults" should mean. The camera disappears for ~15 s. `false` on older firmware. |
| `setExposureRange` | `(minMs: Float, maxMs: Float): Boolean` | Set the auto-exposure time range (ms). The minimum holds the flicker-free floor; the maximum caps motion blur. Saved on the camera and applied across all modes on the next start (the camera restarts). |
| `getExposureRange` | `(): Pair<Float, Float>?` | Current min/max exposure (ms), or null. |
| `setMainsFrequency` | `(hz: Int): Boolean` | Set the mains / anti-flicker frequency (50 or 60). Pick by region — 60 in the Americas, 50 in Europe/Asia — to remove flicker banding from indoor lighting. Saved + applied across all modes on restart. |
| `getMainsFrequency` | `(): Int` | Current mains frequency (50 or 60 Hz), or -1. |
| `setCalibration` / `getCalibration` | `(CalibrationData): Boolean` / `(): CalibrationData?` | Store / read the camera+IMU calibration on the device (intrinsics, distortion, extrinsics, time-shift). |
| `setCalibrationBlob` / `getCalibrationBlob` | `(ByteArray): Boolean` / `(): ByteArray?` | The same calibration as raw bytes, unparsed. This is what the recorder embeds verbatim as the MP4's `tmfc` box, so a round-trip through it is byte-exact. |
| `setCalibrationLock` / `getCalibrationLock` | `(locked: Boolean): Boolean` / `(): Boolean?` | Protect the stored calibration: while locked, `setCalibration` is rejected by the camera. Getter is `null` on older firmware. |
| `getThermal` | `(): ThermalStatus?` | Camera die temperature + a latched `paused` flag. Poll ~1 Hz while recording; when `paused` is true the camera is too hot — stop recording (and preview) and resume when it clears. `null` on older firmware. |
| `setGop` / `getGop` | `(frames: Int): Boolean` / `(): Int` | Keyframe interval (GOP length) in frames. Saved on the camera; the camera restarts to apply. Getter returns -1 on older firmware. |
| `setImuStream` / `getImuStream` | `(enabled: Boolean): Boolean` / `(): Boolean?` | Enable/disable the in-band IMU SEI. Applies live and persists across power cycles. |
| `setAudio` | `(gainQ8: Int, muted: Boolean, agc: Boolean): Boolean` | Live microphone control (v4 cameras): linear Q8 gain (256 = 0 dB; pass ≤0 to leave the gain unchanged), mute (embedded audio emits silence), and auto-gain (while on, the manual gain is ignored). Takes effect on the next audio frame. |
| `getAudio` | `(): AudioStatus?` | Current mic state as `AudioStatus(gainQ8, muted, agc)`, or `null` (pre-v4 firmware). |
| `setAudioRate` / `getAudioRate` | `(hz: Int): Boolean` / `(): Int` | Audio sample rate: 16000, 44100, or 48000 Hz. Saved; the camera restarts to apply. Getter returns -1 when unavailable. |

**Image controls** (standard UVC processing-unit controls — apply live to the
stream, no restart):

| Member | Signature | Description |
|---|---|---|
| `setBrightness` / `getBrightness` | `(value: Int): Boolean` / `(): Int` | Brightness. |
| `setContrast` / `getContrast` | `(value: Int): Boolean` / `(): Int` | Contrast. |
| `setSaturation` / `getSaturation` | `(value: Int): Boolean` / `(): Int` | Saturation. |
| `setSharpness` / `getSharpness` | `(value: Int): Boolean` / `(): Int` | Sharpness. |
| `setGain` / `getGain` | `(value: Int): Boolean` / `(): Int` | Sensor gain. |
| `setWhiteBalanceAuto` | `(auto: Boolean): Boolean` | Auto white balance on/off. |
| `setWhiteBalanceTemperature` / `getWhiteBalanceTemperature` | `(kelvin: Int): Boolean` / `(): Int` | Manual WB colour temperature (auto must be off). |
| `setWhiteBalanceComponent` | `(redGainX256: Int, blueGainX256: Int): Boolean` | Manual WB red/blue gains (×256 fixed point). |
| `setPowerLineFrequency` | `(mode: Int): Boolean` | Anti-flicker: 0 = off, 1 = 50 Hz, 2 = 60 Hz. |
| `setExposureManual` | `(manual: Boolean): Boolean` | Switch auto ↔ manual exposure. |
| `setExposureTime100us` | `(units: Int): Boolean` | Manual exposure time in 100 µs units (manual mode only). |

> **Settings are camera-wide and persistent.** Bitrate, GOP, rate control, image
> controls, exposure range, mains frequency and audio are stored on the camera,
> survive a power cycle, and apply to every way the camera records — this USB
> stream, the network streaming path, and the camera's own on-device recording.
> Set the bitrate here and the camera's own recordings change too. Controls that
> need a restart take ~15 s, and the SDK reconnects automatically; the image
> controls apply live.
>
> `resetSettings()` puts all of that back to defaults in one call.

**Calibration upload.** `CalibrationData.fromCalibrationJson(json)` parses a
Kalibr / Trinet-Calibration `calibration.json` into a `CalibrationData` you can
`setCalibration(...)`. (The demo app's file picker accepts either a
`calibration.json` or a ready `.bin` blob.)

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
| `submitAccessUnit` | `(annexB: ByteArray, ptsUs: Long)` | Mux one frame to MP4, split its SEI IMU into the sidecar, append a VTS entry. On v4 cameras also extracts the embedded AAC audio SEI and feeds the MP4's audio track. Run on `Dispatchers.IO`. |
| `DeviceMeta` | `data class DeviceMeta(vendorId, productId, serial)` | Device identity baked into `meta.json` + the IMU header. |

> **Audio is automatic.** When the camera embeds audio (v4), the recorded
> `video.mp4` gains a second AAC track with no extra wiring — see
> [Recording → Audio](recording.md#audio). Pre-v4 cameras produce video-only
> files, exactly as before.

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
| `Mp4Writer(outFile, width, height, fps) : Closeable` | Mux Annex B H.264 into MP4 via `MediaMuxer`. `writeAccessUnit(annexB, ptsUs)`; `writeAudioSample(adts, ptsUs)` adds an optional AAC audio track (the muxer start is deferred briefly so the audio track can join; if no audio arrives it starts video-only). Video and audio PTS must share a clock — pass the device timestamps. |
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
| `hasAudio` | `Boolean` | True if the recording carries an AAC audio track (v4 recordings). The player plays it in sync — pause, seek, and scrub all realign the audio automatically. |
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

`data class VtsEntry(frameNumber, sofTimestampNs, vencSeq, vencPtsUs, exposureUs = 0, timingFlags = 0, readoutTimeUs = 0)`

| Field | Type | Description |
|---|---|---|
| `frameNumber` | `Long` (u32) | 0-based frame index. |
| `sofTimestampNs` | `Long` | Frame timestamp (ns) — the IMU-alignment key. Start-of-frame, or exposure-centre when `isMidExposure`. |
| `vencSeq` | `Long` (u32) | Encoder sequence number. |
| `vencPtsUs` | `Long` | Video PTS (µs) — used to seek the decoder. |
| `exposureUs` | `Long` | v4+ files: applied integration time (µs); 0 if unknown. |
| `timingFlags` | `Int` | v4+ files: `TIMING_*` flags (below). |
| `readoutTimeUs` | `Long` | v4+ files: rolling-shutter readout span (µs); 0 if unknown / older firmware. |
| `isMidExposure` | `Boolean` | `sofTimestampNs` is exposure-centre (mid-exposure) rather than raw SoF. |
| `isFrameCentered` | `Boolean` | `sofTimestampNs` references the **middle row** of the rolling-shutter frame (reference row = `imageHeight/2`); when clear but `isMidExposure`, the reference row is 0 (older firmware). |
| `rowOffsetNs` | `(row, imageHeight): Long` | Nanoseconds to add to `sofTimestampNs` for image `row` (per-row rolling-shutter reconstruction; line delay = `readoutTimeUs / imageHeight`). 0 when readout is unknown. |

Constants: `SIZE_V2 = 24`, `SIZE_V4 = 36` (`SIZE_BYTES = SIZE_V4` — the writer emits
v4), `sizeFor(version)`, and the timing flags `TIMING_MID_EXPOSURE = 0x01`,
`TIMING_EXPOSURE_VALID = 0x02`, `TIMING_READOUT_VALID = 0x04`,
`TIMING_FRAME_CENTERED = 0x08`.

### `TrinetGeneration`

`enum class TrinetGeneration { LEGACY, V3, V4 }` — camera generation, with `label`
for UI display.

| Member | Type / Signature | Description |
|---|---|---|
| `hasLiveMag` | `Boolean` | V3/V4: the per-sample trailing float is `magAgeUs` (live magnetometer) rather than `fsyncDelayUs`. |
| `hasAudio` | `Boolean` | V4 only: the camera embeds audio (recordings gain a second AAC track). |
| `Companion.fromCode` | `(code: String?): TrinetGeneration` | Map the device-reported code (`"v2"`/`"v3"`/`"v4"`, from [`getGeneration`](#trinetdevice)) — the authoritative source. Unknown/null → `LEGACY`. |
| `Companion.fromFormatVersion` | `(version: Int?): TrinetGeneration` | Recording-time fallback from the IMU SEI/sidecar format version (≥5 → at least V3; cannot distinguish V3 from V4 — the presence of audio is the tell). |

---

## Package `sei`

### `SeiImuParser`

`object SeiImuParser`

| Member | Signature | Description |
|---|---|---|
| `parse` | `(annexB, base = 0, length = ...): List<SeiImuPayload>` | Decode all Trinet IMU SEI payloads from an access unit. |
| `decodeSei` | `(seiNal: ByteArray): SeiImuPayload?` | Decode a single SEI NAL; null if no Trinet payload. |

### `SeiImuHeader` / `SeiImuPayload`

`data class SeiImuHeader(version, numSamples, accelFs, gyroFs, frameSofTsNs = 0, exposureUs = 0, timingFlags = 0, readoutTimeUs = 0)` ·
`data class SeiImuPayload(header: SeiImuHeader, samples: List<ImuSample>)`.

The v6+ header fields carry the per-frame timing block: `frameSofTsNs` (this
frame's device timestamp — exposure-centre when `isMidExposure`), `exposureUs`,
`timingFlags`, and `readoutTimeUs` (rolling-shutter readout span). Convenience
getters `isMidExposure` / `isFrameCentered` mirror
[`VtsEntry`](#vtsentry). All four are 0 on pre-v6 streams.

### `SeiAudioParser`

`object SeiAudioParser` — decodes the **TRINETAAC** audio SEI (v4 cameras). See
[file formats → in-stream audio SEI](file-formats.md#in-stream-audio-sei-trinetaac).

| Member | Signature | Description |
|---|---|---|
| `parse` | `(annexB, base = 0, length = ...): List<SeiAudioPayload>` | Decode all Trinet audio SEI payloads from an access unit. Empty on pre-v4 streams. |
| `decodeSei` | `(seiNal: ByteArray): SeiAudioPayload?` | Decode a single SEI NAL; null if it isn't a Trinet audio payload. |

`data class SeiAudioPayload(version, sampleRate, channels, frames: List<AacFrame>)` ·
`data class AacFrame(ptsUs: Long, adts: ByteArray)` — `ptsUs` is device
`CLOCK_MONOTONIC` µs (the same clock as the IMU/frame timestamps); `adts` is one
self-describing ADTS AAC-LC frame.

### `SeiConstants`

`object SeiConstants`

| Member | Value | Description |
|---|---|---|
| `TRIMU_UUID` | `ByteArray(16)` | UUID prefixing every Trinet IMU SEI payload. |
| `TRINET_AAC_UUID` | `ByteArray(16)` | UUID prefixing every Trinet AAC audio SEI payload (v4 cameras). |
| `SEI_TYPE_USER_DATA_UNREGISTERED` | `5` | SEI payload type. |
| `SEI_HEADER_SIZE` | `23` | UUID(16) + version(1) + num_samples(2) + accel_fs(2) + gyro_fs(2). |
| `SEI_VERSION_V6` / `SEI_HEADER_SIZE_V6` | `6` / `40` | v6 header appends the per-frame timing block: frame_sof_ts_ns(8) + exposure_us(4) + timing_flags(1) + readout_time_us(4). |
| `AAC_SEI_VERSION` | `1` | Audio SEI wire version this SDK understands. |
| `AAC_SEI_HEADER_SIZE` | `24` | UUID(16) + version(1) + sample_rate(4) + channels(1) + num_frames(2). |
| `TIMING_MID_EXPOSURE` … `TIMING_FRAME_CENTERED` | `0x01/0x02/0x04/0x08` | Per-frame timing flags (v6 IMU SEI / v4 VTS). |
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

## Package `audio`

### `AudioPlayer`

`class AudioPlayer` — live AAC-LC playback for a streaming session. Feed it the
ADTS frames recovered from the TRINETAAC SEI; a background thread decodes via
`MediaCodec` and writes PCM to an `AudioTrack` in streaming mode, so the blocking
write paces playback naturally. If the queue backs up, the oldest frame is dropped
to bound latency. Pre-v4 cameras emit no audio SEI, so it simply stays idle.

| Member | Signature | Description |
|---|---|---|
| `start` | `()` | Start the decode thread. |
| `submit` | `(adts: ByteArray)` | Queue one self-describing ADTS AAC frame. |
| `stop` | `()` | Stop and release the decoder/track. |

For Compose apps, prefer the drop-in [`LiveAudio`](#package-ui) composable, which
manages an `AudioPlayer` tied to the composition lifecycle.

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
| `LiveAudio` | `@Composable (frames: SharedFlow<TrinetSession.Frame>, enabled: Boolean = true)` | Decode + play the TRINETAAC audio in a live session's frames. Drop it alongside `LivePreview` to add sound; `enabled = false` mutes. Silent (no-op) on pre-v4 cameras. |
| `ImuOverlayPanel` | `@Composable (history: ImuHistory, sample: ImuSample?, quatXyzw: FloatArray, modifier)` | Sensor cards + orientation header. |
| `OrientationCube` | `@Composable (quatXyzw: FloatArray, modifier, color)` | Quaternion-driven wireframe cube. |
| `TimeSeriesPlot` | `@Composable (values: FloatArray, modifier, color, minY, maxY, label)` | Single-channel scrolling line plot. |
| `TripleAxisPlot` | `@Composable (x, y, z: FloatArray, modifier, label)` | Three stacked axis plots. |
| `ImuHistory` | `class ImuHistory(capacity = 300)` | Synchronized ring buffer: `add(sample)`, `reset()`, `length`, `epoch`, per-channel `accelX/Y/Z`, `gyroX/Y/Z`, `magX/Y/Z`, `fsyncUs`. |

---

See also: [Getting started](getting-started.md) · [Streaming](streaming.md) ·
[IMU](imu.md) · [Recording](recording.md) · [Playback](playback.md) ·
[File formats](file-formats.md).
