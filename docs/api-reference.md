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
- [Package `wireless`](#package-wireless)
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
| `getGeneration` | `(): String?` | Camera generation code as the camera reports it (`"v2"` … `"v6"`), or `null` on older firmware — treat `null` as `"v2"`. Map it with [`TrinetGeneration.fromCode`](#trinetgeneration), minding the caveat there about codes newer than this SDK. |
| `getFirmwareVersion` | `(): String?` | Camera firmware version (e.g. `"0.5.2"`), or `null` when the camera doesn't answer. Uses the shared connection, so it is safe to call while streaming. |
| `resetSettings` | `(): Boolean` | Clear every host-set override and restart the camera on its shipped defaults: bitrate, GOP, rate control, mic gain/mute/AGC/sample-rate, the IMU-stream toggle, image controls, exposure range and mains frequency. Deliberately **kept**: the stored calibration and its lock, the boot mode, and the USB transport — resetting those could leave the camera somewhere the app can no longer reach it, which is not what "restore defaults" should mean. The camera disappears for ~15 s. `false` on older firmware. |
| `setExposureRange` | `(minMs: Float, maxMs: Float): Boolean` | Set the auto-exposure time range (ms). The minimum holds the flicker-free floor; the maximum caps motion blur. Saved on the camera and applied across all modes on the next start (the camera restarts). |
| `getExposureRange` | `(): Pair<Float, Float>?` | Current min/max exposure (ms), or null. |
| `setMainsFrequency` | `(hz: Int): Boolean` | Set the mains / anti-flicker frequency (50 or 60). Pick by region — 60 in the Americas, 50 in Europe/Asia — to remove flicker banding from indoor lighting. Saved + applied across all modes on restart. |
| `getMainsFrequency` | `(): Int` | Current mains frequency (50 or 60 Hz), or -1. |
| `setCalibration` / `getCalibration` | `(CalibrationData): Boolean` / `(): CalibrationData?` | Store / read the camera+IMU calibration on the device (intrinsics, distortion, extrinsics, time-shift). |
| `setCalibrationBlob` / `getCalibrationBlob` | `(ByteArray): Boolean` / `(): ByteArray?` | The same calibration as raw bytes, unparsed. This is what the recorder embeds verbatim as the MP4's `tmfc` box, so a round-trip through it is byte-exact. Accepts both the 200-byte mono and the 300-byte stereo blob. |
| `getCalibrationAny` | `(): Calibration?` | The stored calibration whichever kind it is: `Calibration.Mono` or `Calibration.Stereo` (per-eye intrinsics + baseline). Use this when a stereo camera may be attached — `getCalibration()` only decodes the mono blob. See [`Calibration`](#calibration--stereocalibrationdata). |
| `setCalibrationLock` / `getCalibrationLock` | `(locked: Boolean): Boolean` / `(): Boolean?` | Protect the stored calibration: while locked, `setCalibration` is rejected by the camera. Getter is `null` on older firmware. |
| `getThermal` | `(): ThermalStatus?` | Camera die temperature + a latched `paused` flag. Poll ~1 Hz while recording; when `paused` is true the camera is too hot — stop recording (and preview) and resume when it clears. `null` on older firmware. |
| `setGop` / `getGop` | `(frames: Int): Boolean` / `(): Int` | Keyframe interval (GOP length) in frames. Saved on the camera; the camera restarts to apply. Getter returns -1 on older firmware. |
| `setImuStream` / `getImuStream` | `(enabled: Boolean): Boolean` / `(): Boolean?` | Enable/disable the in-band IMU SEI. Applies live and persists across power cycles. |
| `setAudio` | `(gainQ8: Int, muted: Boolean, agc: Boolean): Boolean` | Live microphone control (v4 cameras): linear Q8 gain (256 = 0 dB; pass ≤0 to leave the gain unchanged), mute (embedded audio emits silence), and auto-gain (while on, the manual gain is ignored). Takes effect on the next audio frame. |
| `getAudio` | `(): AudioStatus?` | Current mic state as `AudioStatus(gainQ8, muted, agc)`, or `null` (pre-v4 firmware). |
| `setAudioRate` / `getAudioRate` | `(hz: Int): Boolean` / `(): Int` | Audio sample rate: 16000, 44100, or 48000 Hz. Saved; the camera restarts to apply. Getter returns -1 when unavailable. |
| `setVideoCodec` / `getVideoCodec` | `(codec: VideoCodec): Boolean` / `(): VideoCodec?` | Codec for the recordings the camera writes to **its own memory card** ([`VideoCodec`](#videocodec) `H264` / `H265`). Saved; read when a recording starts, so it applies from the next take with no restart. The USB stream stays H.264. Firmware 0.5.7+; older firmware: getter `null`, setter `false`. |
| `setWirelessBroadcast` / `getWirelessBroadcast` | `(enabled: Boolean): Boolean` / `(): Boolean?` | Turn the [wireless status](wireless-status.md) broadcast on or off. Saved on the camera and applied **from its next boot**; on by default (Pro Mono, Pro Stereo and Pro Stereo GS on firmware 0.5.9+). Getter `null` on firmware without the control. |

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
`setCalibration(...)`. For a stereo camera, `CalibrationData.packStereoJsonV2(json)`
packs a two-eye calibration JSON (a `cameras` array, `cam0` = left eye) into the
300-byte blob for `setCalibrationBlob(...)`; it returns `null` for a file that is not a
stereo calibration. `CalibrationData.blobVersion(bytes)` tells a ready `.bin` apart:
`1` (mono), `2` (stereo) or `0` (not a valid blob). (The demo app's file picker accepts
either a `calibration.json` or a ready `.bin` blob, for both kinds of camera.)

**`DeviceControls`.** `object DeviceControls` offers a subset of these controls as
one-shot calls on a `UsbDevice` you have not opened as a `TrinetDevice`, each opening
and closing its own connection — e.g. `getCalibrationAny(context, device)` and
`setWirelessBroadcast(context, device, enabled)` / `getWirelessBroadcast(context, device)`.
Blocking — call from `Dispatchers.IO`. Because it opens a second connection, don't use
it while a `TrinetDevice` holds the camera; use the `TrinetDevice` methods then.

**Thermal pause.** `getThermal()` returns `ThermalStatus(tempC, state, paused)`.
The demo Record screen polls it while recording and auto-pauses/resumes recording
on `paused` (showing a "cooling down" banner) — mirroring the SD recorder's
pause/cool/resume on the streaming path.

---

## Package `session`

### `SessionConfig`

`data class SessionConfig(width: Int = 1920, height: Int = 1080, fps: Int = 30, maxFrameBytes: Int = 1 shl 20, fallbackWidth: Int = 0, fallbackHeight: Int = 0)`

Requested stream format. The device must advertise a matching combination.
`fallbackWidth`/`fallbackHeight` (0 = none) name a second resolution tried quietly
when the first is not advertised — ask for `3840×1080` with a `1920×1080` fallback to
open stereo and mono cameras alike. `maxFrameBytes` is the per-frame size budget at
1080p (oversize frames are dropped whole; ≤ 0 disables it); the session scales it by
the negotiated pixel area.

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
| `negotiatedWidth` / `negotiatedHeight` | `Int` | The frame size the device actually delivers — the fallback size if it was used. Kept across `stop()`. |
| `effectiveMaxFrameBytes` | `Int` | The frame budget in force, scaled from `SessionConfig.maxFrameBytes`. |
| `layout` | `StreamLayout` | How the eyes sit in the negotiated frames. |
| `isSideBySide` | `Boolean` | True while streaming a side-by-side stereo pair. |
| `Frame` | `data class Frame(annexB: ByteArray, ptsUs: Long)` | One access unit (Annex B) + capture PTS (µs). |

### `StreamLayout`

`enum class StreamLayout { MONO, SIDE_BY_SIDE }` — how a camera's eyes are arranged in
one video frame. `SIDE_BY_SIDE`: both eyes, left eye in the left half.

| Member | Signature | Description |
|---|---|---|
| `metaTag` | `String?` | The `meta.json` `video.layout` value: `"sbs"`, or `null` for `MONO` (key omitted). |
| `Companion.of` | `(width, height): StreamLayout` | Classify a frame size: `SIDE_BY_SIDE` when `width >= 3 × height`. |

Detect stereo from the stream, never from the USB product id — a stereo camera shares
the mono camera's product id. See [stereo cameras](streaming.md#stereo-cameras).

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

`data class RecordingMeta(id, createdAtEpochMs, deviceVendorId, deviceProductId, deviceSerial, width, height, fps, codec, sdkVersion, firmwareVersion = null, generation = null, hasCalibration = false, layout = null, shutter = null)` and `object MetaWriter { fun write(file, meta) }` — write `meta.json`. Normally driven by `TrinetRecorder`, which fills `layout` (`"sbs"` for a side-by-side frame) from the frame shape and `shutter` (`"global"` / `"rolling"`) from the stream's timing SEI; both keys are omitted when `null`.

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

`enum class TrinetGeneration { LEGACY, V3, V4, V5, V6 }` — camera generation, with
`label` for UI display. `V4` = Pro Mono, `V5` = Pro Stereo, `V6` = Pro Stereo GS
(global shutter).

> **Forward-compatibility caveat.** `fromCode` maps anything it does not
> recognise — including a generation code newer than this SDK — to `LEGACY`, and
> `LEGACY` means "the per-sample trailing float is `fsyncDelayUs`". On a camera
> newer than this SDK that float is `magAgeUs`, so trusting `hasLiveMag` there would
> read a magnetometer age as a frame-sync offset.
>
> This is only reachable if you pair this SDK with a camera generation released
> after it. If you need to be safe against that, branch on the **format version**
> (`SeiImuHeader.version >= 5` ⇒ live magnetometer) rather than on the enum, or
> pin the SDK version alongside the camera. `deriveSofNs(sample, version)` already
> does the right thing from the format version and is unaffected.

| Member | Type / Signature | Description |
|---|---|---|
| `hasLiveMag` | `Boolean` | V3 and later: the per-sample trailing float is `magAgeUs` (live magnetometer) rather than `fsyncDelayUs`. |
| `hasAudio` | `Boolean` | V4, V5, V6: the camera embeds audio (recordings gain a second AAC track). |
| `nominalImuRateHz` | `Int` | Nominal IMU rate for a recording header: 400 from V3 on, 562 for `LEGACY`. Use it instead of a hand-kept list of generations. |
| `isStereo` | `Boolean` | V5, V6. A label and cross-check only — detect stereo from [`TrinetSession.layout`](#trinetsession). |
| `isGlobalShutter` | `Boolean` | V6. Advisory like `isStereo`; the authoritative signal is [`SeiImuHeader.shutter`](#seiimuheader--seiimupayload). |
| `Companion.fromCode` | `(code: String?): TrinetGeneration` | Map the device-reported code (`"v2"` … `"v6"`, from [`getGeneration`](#trinetdevice)) — the authoritative source. Unknown/null → `LEGACY`. |
| `Companion.fromFormatVersion` | `(version: Int?): TrinetGeneration` | Recording-time fallback from the IMU SEI/sidecar format version (≥5 → at least V3; cannot distinguish V3 from V4 — the presence of audio is the tell). |

### `VideoCodec`

`enum class VideoCodec(wire: Int, label: String) { H264, H265 }` — codec of the
camera's own memory-card recordings, for [`setVideoCodec`](#trinetdevice). `label` is
`"H.264"` / `"H.265"`; `Companion.fromWire(v): VideoCodec?`.

### `ShutterType`

`enum class ShutterType(metaTag: String) { GLOBAL, ROLLING }` — the sensor's shutter as
the stream declares it; `metaTag` is the `meta.json` `video.shutter` value
(`"global"` / `"rolling"`).

### `Calibration` / `StereoCalibrationData`

`sealed interface Calibration` — a camera's calibration, whichever kind it has:
`Calibration.Mono(data: CalibrationData)` or `Calibration.Stereo(data: StereoCalibrationData)`.
`Calibration.decodeAny(blob: ByteArray?): Calibration?` decodes a 200-byte mono or
300-byte stereo blob (null when absent or invalid); `TrinetDevice.getCalibrationAny()`
is the shortcut.

`data class StereoCalibrationData(cameras, rCam0Imu, tCam0Imu, rCam1Cam0, tCam1Cam0, accelNoiseDensity, gyroNoiseDensity, accelRandomWalk, gyroRandomWalk, accelBias, gyroBias, gyroResidual, accelResidual, imuRateHz, …)`

| Member | Type / Signature | Description |
|---|---|---|
| `cameras` | `List<CameraBlock>` | Per eye, `cam0` = left: `imageWidth`, `imageHeight`, `model`, `fx`, `fy`, `cx`, `cy`, `distortion`, `timeshiftCamImuS`, `reprojectionRmsPx`. |
| `rCam0Imu` / `tCam0Imu` | `FloatArray` | IMU → left-eye extrinsics (3×3 row-major rotation, translation in m). |
| `rCam1Cam0` / `tCam1Cam0` | `FloatArray` | Left eye → right eye extrinsics. |
| `baselineM` | `Float` | Stereo baseline, metres (length of `tCam1Cam0`). |
| `leftEyeAsMono` | `(): CalibrationData?` | The left eye + IMU as a mono calibration, for code that only handles one camera. |
| `Companion.decode` | `(blob): StereoCalibrationData?` | Decode a 300-byte stereo blob. |

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

`SeiImuHeader.shutter: ShutterType?` — the shutter this frame declares: `ROLLING` for a
non-zero readout, `GLOBAL` for a *valid zero* readout (`TIMING_READOUT_VALID` set,
`readoutTimeUs == 0` — the Pro Stereo GS), `null` when the frame does not say (pre-v6
streams, or readout not marked valid).

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

## Package `wireless`

Follow cameras recording to their own memory card over the Bluetooth LE status
broadcast — the phone only listens. Guide: [Wireless status](wireless-status.md).
Needs camera firmware 0.5.9+ and the app-declared Bluetooth permissions.

### `WirelessCameraMonitor`

`class WirelessCameraMonitor(context: Context, config: WirelessMonitorConfig)`; also
`WirelessCameraMonitor(context)` with the default config. Use one per process; call
`start`/`stop`/`setScanMode` on the main thread.

| Member | Type / Signature | Description |
|---|---|---|
| `start` / `stop` | `()` | Start / stop the one long-lived scan. `start` is idempotent — call again after a permission grant. `stop` keeps camera state and history. |
| `state` | `StateFlow<WirelessMonitorState>` | `Stopped`, `Scanning`, or `Error(reason, message)` with `reason` `NO_BLUETOOTH` / `BLUETOOTH_OFF` / `PERMISSION_DENIED` / `SCAN_FAILED`. |
| `cameras` | `StateFlow<List<WirelessCamera>>` | Every camera heard, by unit id; updated at most `CAMERAS_MAX_HZ` (4) times a second. |
| `events` | `SharedFlow<WirelessEvent>` | Recording start/stop edges as detected (not replayed). |
| `eventHistory` | `List<WirelessEvent>` | Events since construction, oldest first (last 2000). |
| `history` | `WirelessHistory?` | The stored history; `null` when persistence is disabled. |
| `setScanMode` | `(mode: WirelessScanMode)` | Change the scan duty cycle; applied at most once every 10 s. |
| `exportTo` | `(out: OutputStream, scope: WirelessExportScope = ALL, gzip: Boolean = true): WirelessExportSummary` | Write the wireless status log (format v2) for the desktop sync tool. Blocking. Throws `IllegalStateException` when persistence is disabled. |
| `toUtcMillis` | `(unitId: String, deviceMs: Long): Long?` | UTC for a camera time on that camera's current boot. |
| `hasScanPermission` | `(): Boolean` | The permission the scan needs on this Android version is granted. |
| `Companion.requiredPermissions` | `(): Array<String>` | `BLUETOOTH_SCAN` (Android 12+) or `ACCESS_FINE_LOCATION` (11 and older). |
| `exportLog` | `(): JSONObject` | **Deprecated** — format v1, live fits only. Use `exportTo`. |

### `WirelessMonitorConfig` / `WirelessPersistence` / `WirelessScanMode`

| Type | Description |
|---|---|
| `data class WirelessMonitorConfig(persistence = WirelessPersistence(), scanMode = WirelessScanMode.LOW_LATENCY)` | Monitor configuration. |
| `data class WirelessPersistence(enabled = true, retentionDays = 30, maxBytes = 256 MB, sntpServer: String? = "time.google.com", sntpIntervalMs = 10 min, fileName)` | History settings. `WirelessPersistence.Disabled` keeps live state only; `sntpServer = null` turns the internet time check off (it also needs `INTERNET`). |
| `enum class WirelessScanMode { LOW_LATENCY, BALANCED, LOW_POWER }` | Continuous (screen on) / duty-cycled (background logging) / lowest power. |

### `WirelessCamera`

`data class WirelessCamera` — live state of one camera.

| Member | Type | Description |
|---|---|---|
| `unitId` | `String` | 8 lowercase hex: the first 8 of the camera's device id (USB serial). |
| `address` | `String` | Advertiser address. |
| `recording` / `finalizing` / `sdOk` | `Boolean` | Recording / closing a take / memory card present. |
| `takeNumber` / `recordingCount` | `Int` | Current or last take (0 = none) / recordings on the card. |
| `groupId` / `groupLow` / `role` | `Int` / `Int` / `WirelessRole` | Full 16-bit kit id (0 = none) / its low byte / `UNPAIRED`, `MASTER`, `SLAVE`, `UNKNOWN`. |
| `rssi` / `rssiAvg` | `Int?` / `Double?` | Last and ~3 s-smoothed signal strength, dBm. Not a distance. |
| `lastSeenElapsedNanos` | `Long` | Last heard, on `SystemClock.elapsedRealtimeNanos()`. `secondsSinceSeen(nowElapsedNanos)` helps. |
| `lastEdgeDeviceMs` / `lastEdgeUtcMillis` | `Long?` | Last start/stop this camera boot. |
| `fit` | `DeviceClockFit.Quality` | Clock-fit quality: `samples`, `buckets`, `residualMs`, `skewPpm`, `ready`, `skewEstimated`. |
| `identity` / `identityIsCurrent` | `WirelessIdentity?` / `Boolean` | Model and firmware; current = sent in the camera's present boot. |
| `advert` | `WirelessAdvert` | The last raw status advert. |

### `WirelessEvent`

`sealed class WirelessEvent` — `Started`, `Stopped`, `AbnormalStop` (adds
`cameraRestarted: Boolean`). Common members: `unitId`, `takeNumber`, `deviceMs`,
`utcMillis: Long?` (null while no clock fit exists), `eventSeq`, `bootNonce`,
`missedEdges` (edges collapsed while out of range), `detectedElapsedNanos`, and
`kind` (`"started"` / `"stopped"` / `"abnormal_stop"`).

### `WirelessIdentity` / `WirelessBoard`

`data class WirelessIdentity` — a camera's identity broadcast: `board`, `boardWire`,
`boardName`, `generation` (`"v6"` or null), `hwGenerationNumber`, `fwVersion`
(`"0.5.9"` or null), `fwMajor`/`fwMinor`/`fwPatch`, `shipping` (false = development
build), `versionKnown`, `bootNonce`, `shutter`. `Companion.parse(bytes): WirelessIdentity?`.

`enum class WirelessBoard { UNKNOWN, MONO, STEREO, STEREO_GS }` with `displayName`
("Pro Stereo GS"), `shortName` ("Stereo GS"), `productName` ("Trinet Pro Stereo GS"),
`exportName`, and `shutter: WirelessShutter` (`GLOBAL` for `STEREO_GS`, else `ROLLING`).

### `WirelessAdvert`

`data class WirelessAdvert` — one decoded status broadcast (`flags`, `bootNonce`,
`eventSeq`, `takeNumber`, `recordingCount`, `nowMs`, `edgeMs`, `groupLow`, and the
decoded `recording`, `finalizing`, `sdOk`, `role`, `timebaseIsMaster`, `linkUp`,
`abnormalStop`). For apps with their own scanner: `Companion.parse(bytes)`,
`unitIdFromAddress(address)`, `groupIdFromAddress(address, groupLow)`, `COMPANY_ID`.

### `DeviceClockFit`

The camera-clock → phone-clock fit behind `toUtcMillis` (lower envelope of arrival
delays, offset + skew, per camera boot). Exposed mainly for its `Quality`
(`WirelessCamera.fit`).

### Package `wireless.log` — `WirelessHistory`

`class WirelessHistory` — the stored history. From `monitor.history`, or
`WirelessHistory.open(context, persistence = WirelessPersistence())` without a
running monitor. Queries are `suspend` (on `Dispatchers.IO`); exports block.

| Member | Signature | Description |
|---|---|---|
| `units` | `suspend (range = WirelessTimeRange.ALL, query: String? = null): List<WirelessUnitSummary>` | Cameras heard, newest first. `query` matches unit id, names, kit id, model or firmware. |
| `unit` | `suspend (unitId): WirelessUnitSummary?` | One camera, with its last stored `identity`. |
| `kits` | `suspend (): List<WirelessKitSummary>` | Kits and their members. |
| `takes` | `suspend (unitId, limit = 50, offset = 0): List<WirelessTake>` | A camera's takes, newest first, UTC refined with its latest clock fit. |
| `kitTakes` | `suspend (groupId, limit = 50): List<WirelessKitTake>` | Members' takes starting within `KIT_TAKE_WINDOW_MS` (2 s) = one kit take. |
| `segments` | `suspend (unitId, limit = 20): List<WirelessSegmentInfo>` | Clock fits per camera boot (sync quality). |
| `sightings` / `seenRanges` | `suspend (unitId, sinceUtcMillis)` | Minute-by-minute reception / merged in-range periods. |
| `setLabel` / `setKitLabel` / `labels` / `kitLabels` | `suspend` | Name cameras and kits; names survive deletion. |
| `stats` / `estimate` | `suspend (): WirelessHistoryStats` / `suspend (scope): WirelessExportEstimate` | Store size / rough size of an export. |
| `deleteBefore` / `clear` | `suspend (utcMillis)` / `suspend ()` | Delete history (names are kept). |
| `observe` | `(query: suspend WirelessHistory.() -> T): Flow<T>` | Re-run a query whenever the history changes. |
| `changes` | `StateFlow<Long>` | Increments on every change. |
| `exportTo` | `(out, scope = WirelessExportScope.ALL, gzip = true): WirelessExportSummary` | Wireless status log, format v2 (JSON Lines, gzip by default). Does not close `out`. |
| `exportTakesCsv` | `(out, scope = WirelessExportScope.ALL)` | Takes as CSV (UTF-8, ISO-8601 UTC). |

Supporting types (package `com.panoculon.trinet.sdk.wireless.log`):
`WirelessTimeRange(fromUtcMillis?, toUtcMillis?)` (`ALL`);
`WirelessExportScope(units?, groups?, fromUtcMillis?, toUtcMillis?)` with `ALL`,
`unit(unitId, from, to)`, `kit(groupId, from, to)`;
`WirelessExportSummary(records, units, segments, buckets, events, takes, sightings, bytes)`;
`WirelessTake` (`pairing: WirelessTakePairing` `EXACT` / `MISSED_EDGES` / `START_ONLY` /
`STOP_ONLY`, `stopKind: WirelessStopKind?` `STOPPED` / `ABNORMAL_STOP` / `REBOOT`,
`startUtcMillis`, `stopUtcMillis`, `durationMs`, `endedAbnormally`, …);
`WirelessKitTake`; `WirelessUnitSummary` (`identity: WirelessUnitIdentity?` with
`board`, `hwGeneration`, `fwVersion`, `shipping`); `WirelessKitSummary`;
`WirelessSegmentInfo`; `WirelessSighting`; `WirelessSeenRange`;
`WirelessHistoryStats`; `WirelessExportEstimate`.

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
| `LivePreview` | `@Composable (frames: SharedFlow<TrinetSession.Frame>, width, height, modifier, cropEye: Int? = null, onFocusScore: ((Float) -> Unit)? = null)` | Decode + display a live session. `cropEye` shows one eye of a side-by-side stereo frame (`0` left, `1` right; the decoder still gets both). `onFocusScore` receives a smoothed focus score of the displayed image ~8×/s for manual focusing. |
| `FocusAssist` | `object` | Focus scoring behind `onFocusScore` (variance of the Laplacian over a centre ROI): `scoreBitmap(bitmap, cropEye)`, `scoreArgb(px, w, h)`, `ema(prev, raw)`, `roiOf(w, h, cropEye)`, `ROI_FRAC`. `FocusAssist.run(...)` was removed in 0.5.0. |
| `LiveAudio` | `@Composable (frames: SharedFlow<TrinetSession.Frame>, enabled: Boolean = true)` | Decode + play the TRINETAAC audio in a live session's frames. Drop it alongside `LivePreview` to add sound; `enabled = false` mutes. Silent (no-op) on pre-v4 cameras. |
| `ImuOverlayPanel` | `@Composable (history: ImuHistory, sample: ImuSample?, quatXyzw: FloatArray, modifier)` | Sensor cards + orientation header. |
| `OrientationCube` | `@Composable (quatXyzw: FloatArray, modifier, color)` | Quaternion-driven wireframe cube. |
| `TimeSeriesPlot` | `@Composable (values: FloatArray, modifier, color, minY, maxY, label)` | Single-channel scrolling line plot. |
| `TripleAxisPlot` | `@Composable (x, y, z: FloatArray, modifier, label)` | Three stacked axis plots. |
| `ImuHistory` | `class ImuHistory(capacity = 300)` | Synchronized ring buffer: `add(sample)`, `reset()`, `length`, `epoch`, per-channel `accelX/Y/Z`, `gyroX/Y/Z`, `magX/Y/Z`, `fsyncUs`. |

---

See also: [Getting started](getting-started.md) · [Streaming](streaming.md) ·
[IMU](imu.md) · [Recording](recording.md) · [Playback](playback.md) ·
[File formats](file-formats.md) · [Wireless status](wireless-status.md).
