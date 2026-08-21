# File formats

A Trinet recording is a **triple** sharing one folder: the H.264 video plus two binary
sidecars. The same inertial data also exists *inside* the video bitstream as SEI NAL
units — that's how the IMU travels from camera to host in the first place; the recorder
splits it out into a sidecar. v4 cameras additionally embed **stereo AAC audio** as a
second SEI stream ([TRINETAAC](#in-stream-audio-sei-trinetaac)), which the recorder
muxes into the MP4 as a normal audio track. This page documents each format at the
level the SDK readers expose, with field names, sizes, units, and timebases.

All binary fields are **little-endian**.

- [The recording triple](#the-recording-triple)
- [IMU sidecar (`imu.bin`)](#imu-sidecar-imubin)
- [VTS sidecar (`frames.bin`)](#vts-sidecar-framesbin)
- [meta.json](#metajson)
- [TMF metadata in the MP4](#tmf-metadata-in-the-mp4)
- [In-stream IMU SEI](#in-stream-imu-sei)
- [In-stream audio SEI (TRINETAAC)](#in-stream-audio-sei-trinetaac)
- [Timebases and alignment](#timebases-and-alignment)

---

## The recording triple

```
<folder>/
  video.mp4    # H.264/AVC video. The SEI IMU NALs are muxed through into the stream.
               # v4 cameras: plus a second (AAC-LC) audio track, muxed from the
               # in-stream TRINETAAC SEI at record time.
               # Also carries TMF metadata (camera identity + calibration) in
               # moov/udta — see "TMF metadata in the MP4" below.
  imu.bin      # per-sample inertial data            (magic "TRIMU001")
  frames.bin   # per-frame timestamps for alignment  (magic "TRIVTS01")
  meta.json    # human/tool-readable recording metadata
```

The video is plain H.264 in an MP4 container and plays in any media player; the IMU and
timestamp data live in the sidecars (and redundantly inside the video's SEI). The SDK
readers (`ImuFileReader`, `VtsFileReader`) and the SEI parser (`SeiImuParser`) are the
canonical decoders for these formats.

Since **0.4.1** the `video.mp4` also carries the camera's identity and stored
calibration in `moov/udta`, so a clip that gets separated from its folder is
still attributable and still usable for undistortion.

---

## IMU sidecar (`imu.bin`)

Magic `TRIMU001`, current version **5**. A 64-byte header followed by fixed-size samples.

> **Version history (all layout-compatible — a reader for any version parses the others):**
> - **v3** — base 80-byte sample (the trailing float is a frame-sync delay).
> - **v4** — repurposes 8 of the reserved header bytes for an iOS host-clock offset.
> - **v5** — cameras with a magnetometer: `mag[3]` carries live data and the trailing
>   float becomes `mag_age_us` (the frame-sync delay is unused — `flags` bit 0 is clear,
>   bit 1 is set). Header and sample byte layouts are identical to v3/v4, so older
>   recordings keep parsing unchanged and a v5-aware reader handles every version.

### Header (64 bytes)

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 8 | `magic` | ASCII `"TRIMU001"` |
| 8 | 4 | `version` | `3`, `4`, or `5` |
| 12 | 4 | `sample_rate_hz` | configured IMU rate |
| 16 | 2 | `accel_fs` | accelerometer full-scale code |
| 18 | 2 | `gyro_fs` | gyroscope full-scale code |
| 20 | 8 | `start_time_ns` | timestamp of the first sample (ns) |
| 28 | 8 | `video_start_ns` | `0` when unused (reader infers) |
| 36 | 4 | `flags` | bit 0 (`0x01`) = frame-sync alignment present; bit 1 (`0x02`) = magnetometer present (v5) |
| 40 | 24 | `reserved` | first 16 bytes = public device id (zero if unknown); rest zero |

Exposed by `ImuFileReader` as `version`, `sampleRateHz`, `accelFs`, `gyroFs`,
`startTimeNs`, `videoStartNs`, `flags`, `deviceId` (16 bytes) / `deviceIdHex`,
`sampleCount`, `sampleSize`.

### Sample (80 bytes, v3/v4/v5 — identical layout)

| Offset | Size | Field | Type | Unit |
|---:|---:|---|---|---|
| 0 | 8 | `timestamp_ns` | uint64 | ns |
| 8 | 12 | `accel[3]` | float32×3 | m/s² (gravity included) |
| 20 | 12 | `gyro[3]` | float32×3 | rad/s |
| 32 | 12 | `mag[3]` | float32×3 | µT (live on v5; zero otherwise) |
| 44 | 4 | `temp_c` | float32 | °C |
| 48 | 16 | `quat_xyzw[4]` | float32×4 | reserved |
| 64 | 12 | `lin_accel[3]` | float32×3 | reserved |
| 76 | 4 | `fsync_delay_us` / `mag_age_us` | float32 | µs |

The trailing float at offset 76 is `fsync_delay_us` on v3/v4 and `mag_age_us` on v5
(µs from this sample's timestamp back to the magnetometer reading; absolute mag time =
`timestamp_ns − mag_age_us × 1000`). It's the same 4 bytes — the header `version` (and
`flags` bit 1) tells you which it is. Exposed on [`ImuSample`](imu.md#the-imu-sample) as
both `fsyncDelayUs` and `magAgeUs` (a typed view of the same slot).

`quat_xyzw` and `lin_accel` are reserved (identity/zero) — compute orientation with the
[Madgwick helper](imu.md#orientation-fusion-madgwick).

> **Older versions:** `ImuFileReader` also reads v1 (44-byte samples) and v2 (76-byte
> samples), promoting them into the `ImuSample` shape with the missing fields set to
> zero/identity. v3/v4 carry `fsync_delay_us`; v5 carries `mag_age_us` + live `mag`.

---

## VTS sidecar (`frames.bin`)

Magic `TRIVTS01`, current version **4**. "VTS" = video timestamp. One entry per recorded
frame; it ties each frame to the inertial timeline and to the video PTS. The SDK writer
emits v4 entries; the reader decodes v2 and v4.

### Header (32 bytes)

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 8 | `magic` | ASCII `"TRIVTS01"` |
| 8 | 4 | `version` | `2` or `4` (selects the entry size) |
| 12 | 4 | `frame_rate_milli` | fps × 1000 (e.g. `30000`) |
| 16 | 16 | `reserved` | zero |

Exposed by `VtsFileReader` as `version`, `frameRateMilli`, `fps`, `entryCount`.

### Entry (24 bytes v2 · 36 bytes v4)

| Offset | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 4 | `frame_number` | uint32 | 0-based frame index |
| 4 | 8 | `sof_timestamp_ns` | uint64 | frame timestamp (ns) — use this to align IMU. Start-of-frame, or exposure-centre when the `MID_EXPOSURE` flag is set |
| 12 | 4 | `venc_seq` | uint32 | encoder sequence number |
| 16 | 8 | `venc_pts_us` | uint64 | video presentation timestamp (µs) |
| 24 | 4 | `exposure_us` | uint32 | **v4+** applied integration time (µs); 0 if unknown |
| 28 | 4 | `timing_flags` | uint32 | **v4+** `0x01` MID_EXPOSURE (timestamp is exposure-centre) · `0x02` EXPOSURE_VALID · `0x04` READOUT_VALID · `0x08` FRAME_CENTERED (timestamp references the middle row of the rolling-shutter frame, not the top row) |
| 32 | 4 | `readout_time_us` | uint32 | **v4+** rolling-shutter readout span (first row → last row, µs); per-row delay = `readout_time_us / image_height` |

This maps to [`VtsEntry`](api-reference.md#vtsentry), which also provides the
`isMidExposure` / `isFrameCentered` flag getters and `rowOffsetNs(row, imageHeight)`
for per-row rolling-shutter reconstruction. `sof_timestamp_ns` is the
hardware-aligned frame time used to find the matching IMU sample; `venc_pts_us`
is the MP4 PTS used to seek the decoder.

---

## meta.json

Written at the end of a recording. Permissive/forward-compatible (extra fields may
appear):

```json
{
  "id": "ab12cd34_recording_20260524_143000",
  "created_at_epoch_ms": 1748090000000,
  "device": {
    "vendor_id": 8711, "product_id": 22, "serial": "ab12cd34...",
    "firmware_version": "0.5.2", "generation": "v4"
  },
  "video":  { "width": 1920, "height": 1080, "fps": 30, "codec": "h264" },
  "sdk_version": "0.4.1",
  "has_embedded_calibration": true
}
```

`device.serial` is the camera's public per-unit ID (or `null` for cameras that don't
advertise one). `firmware_version` and `generation` appear only when the camera
answered at record time; older firmware omits them rather than guessing.
`has_embedded_calibration` is a convenience flag — the authoritative copy is the
`tmfc` box in the MP4, and this just saves a reader from opening the video to
find out whether it is there.

---

## TMF metadata in the MP4

Two boxes are folded into the MP4's `moov/udta` when the recording is finalised.
The camera writes the same two boxes into its own on-device recordings, with the
same names and the same schema, so one reader handles both sources.

| box | contents |
|---|---|
| `tmfm` | UTF-8 JSON — take metadata (schema 2) |
| `tmfc` | the camera's stored calibration blob, byte-for-byte (magic `TBLC`) |

```json
{
  "tmf_schema": 2,
  "source": "uvc",
  "device_id": "ab12cd34…",
  "fw_version": "0.5.2",
  "hw_generation": "v4",
  "codec": "h264",
  "imu_version": 5,
  "vts_version": 4,
  "recorder": "trinet-sdk/0.4.1",
  "drops": { "recorded": 1800, "rejected": 0 }
}
```

- `source` is `uvc` for a recording made by this SDK, `sd` for one the camera
  wrote itself.
- `imu_version` is the version the live stream actually turned out to be, so it
  always agrees with the `imu.bin` header. The two matter: they select opposite
  meanings for the sample's trailing float (`fsync_delay_us` vs `mag_age_us`).
- Keys are **omitted when unknown rather than guessed** — a camera on older
  firmware that does not report its version simply has no `fw_version`, and a
  camera with no calibration stored produces no `tmfc` box at all. Treat every
  key as optional.
- `tmfc` is the same blob `getCalibrationBlob()` returns; decode it with the
  calibration tooling, or read it back through `CalibrationData`.

Players ignore both boxes and `ffprobe` does not list them, which is the point —
the file stays an ordinary MP4. **Anything that re-encodes or re-muxes the file
drops them**, the same way it drops GoPro's GPMF, so the sidecar files remain the
recovery path for a processed clip.

---

## In-stream IMU SEI

The IMU also rides inside the H.264 bitstream as **SEI** (Supplemental Enhancement
Information) NAL units, so it's available live off `session.frames` and survives as long
as the video does. Each video frame's access unit can carry one Trinet IMU SEI NAL.

Decode it with `SeiImuParser.parse(annexB)`. The relevant constants live in
`SeiConstants`:

- NAL unit type for SEI: **6** (`h264_nal_type` = header byte `& 0x1F`).
- SEI `payload_type` = **5** (`user_data_unregistered`).
- A Trinet payload is identified by the 16-byte **TRIMU UUID**
  (`SeiConstants.TRIMU_UUID`).

### SEI payload layout

After the standard SEI `payload_type`/`payload_size` varints (each a series of `0xFF`
bytes terminated by a final byte), a Trinet `user_data_unregistered` payload is:

| Size | Field | Notes |
|---:|---|---|
| 16 | `uuid` | must equal `TRIMU_UUID` |
| 1 | `version` | payload version (v5: live mag; **v6**: adds the timing block below) |
| 2 | `num_samples` | count of samples that follow |
| 2 | `accel_fs` | accel full-scale code |
| 2 | `gyro_fs` | gyro full-scale code |
| 8 | `frame_sof_ts_ns` | **v6+** this frame's device timestamp (ns) — exposure-centre when the `MID_EXPOSURE` flag is set, else raw start-of-frame |
| 4 | `exposure_us` | **v6+** applied integration time (µs); 0 if unknown |
| 1 | `timing_flags` | **v6+** same flag bits as the [VTS entry](#vts-sidecar-framesbin) (`0x01` MID_EXPOSURE · `0x02` EXPOSURE_VALID · `0x04` READOUT_VALID · `0x08` FRAME_CENTERED) |
| 4 | `readout_time_us` | **v6+** rolling-shutter readout span (µs) |
| 80 × N | `samples[]` | each an `ImuSample` (same 80-byte layout as the sidecar; v5+ trailing float is `mag_age_us`) |

The header is `SeiConstants.SEI_HEADER_SIZE` = 23 bytes through v5, or
`SEI_HEADER_SIZE_V6` = 40 bytes with the v6 timing block. The parser strips H.264
**emulation-prevention** bytes (`00 00 03` → `00 00`) before reading the payload, and
ignores any SEI NAL that isn't a Trinet IMU payload.

`SeiImuParser.parse` returns `List<SeiImuPayload>`:

```kotlin
data class SeiImuHeader(
    val version: Int, val numSamples: Int, val accelFs: Int, val gyroFs: Int,
    // v6+ per-frame timing block (0 on older streams):
    val frameSofTsNs: Long, val exposureUs: Long, val timingFlags: Int, val readoutTimeUs: Long,
)
data class SeiImuPayload(val header: SeiImuHeader, val samples: List<ImuSample>)
```

If you need lower-level Annex B handling (start-code scanning, emulation-prevention
add/remove), the `NalParser` object exposes `splitNalUnits`, `removeEmulationPrevention`,
and `addEmulationPrevention`.

---

## In-stream audio SEI (TRINETAAC)

**v4 cameras** embed stereo **AAC-LC audio** in the same H.264 bitstream, as a second
`user_data_unregistered` SEI stream identified by the 16-byte
`SeiConstants.TRINET_AAC_UUID` ("TRINETAAC"). Older cameras never emit it, and consumers
that don't recognise the UUID skip it — the scheme is fully backward compatible.

Payload layout (after the UUID):

| Size | Field | Notes |
|---:|---|---|
| 1 | `version` | `1` |
| 4 | `sample_rate` | Hz (e.g. `44100`; configurable 16000/44100/48000) |
| 1 | `channels` | e.g. `2` |
| 2 | `num_frames` | AAC frames that follow |
| per frame: | | |
| 8 | `pts_us` | device `CLOCK_MONOTONIC` µs — **the same clock** as the IMU sample timestamps and `frame_sof_ts_ns`, so audio aligns to video/IMU directly |
| 2 | `len` | ADTS frame length |
| len | `adts` | one self-describing ADTS AAC-LC frame |

Decode with `SeiAudioParser.parse(annexB)` → `List<SeiAudioPayload>` (each with
`List<AacFrame>`). Consumers:

- **Live**: feed `AacFrame.adts` to `AudioPlayer` (or just drop the `LiveAudio`
  composable next to `LivePreview`).
- **Recording**: `TrinetRecorder` extracts these frames automatically and muxes a
  second AAC track into `video.mp4` — recordings play with sound in any player, no
  separate muxing step.

---

## Timebases and alignment

- **`timestamp_ns`** (per IMU sample) and **`sof_timestamp_ns`** (per frame) share the
  same device monotonic clock — that's why aligning IMU to a frame is a nearest-by-
  timestamp lookup against the frame's `sof_timestamp_ns`.
- **`fsync_delay_us`** (v3/v4 recordings) is the offset between the hardware frame-sync
  pulse and the sample; the recorder derives a frame's `sof_timestamp_ns` from the SEI
  sample's timestamp minus this delay. On **v5** recordings the trailing float is
  `mag_age_us` instead (there is no frame-sync delay), so `sof_timestamp_ns` is taken
  directly from the SEI sample timestamp / `venc_pts_us` — never subtract `mag_age_us`.
- **`venc_pts_us`** is the MP4 presentation timestamp — use it to *seek the video
  decoder*, not to align IMU. The decoder paces on PTS; IMU alignment uses
  `sof_timestamp_ns`.

- **`pts_us`** (per AAC audio frame, v4 cameras) is on the **same device monotonic
  clock** as the IMU timestamps — audio, video, and IMU all share one timebase.

In short: to correlate inertial data with a video frame, always go through
`sof_timestamp_ns` (see [aligning IMU to frames](playback.md#aligning-imu-to-frames)).

---

Next: [API reference →](api-reference.md)
