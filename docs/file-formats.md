# File formats

A Trinet recording is a **triple** sharing one folder: the H.264 video plus two binary
sidecars. The same inertial data also exists *inside* the video bitstream as SEI NAL
units — that's how the IMU travels from camera to host in the first place; the recorder
splits it out into a sidecar. This page documents each format at the level the SDK
readers expose, with field names, sizes, units, and timebases.

All binary fields are **little-endian**.

- [The recording triple](#the-recording-triple)
- [IMU sidecar (`imu.bin`)](#imu-sidecar-imubin)
- [VTS sidecar (`frames.bin`)](#vts-sidecar-framesbin)
- [meta.json](#metajson)
- [In-stream IMU SEI](#in-stream-imu-sei)
- [Timebases and alignment](#timebases-and-alignment)

---

## The recording triple

```
<folder>/
  video.mp4    # H.264/AVC video. The SEI IMU NALs are muxed through into the stream.
  imu.bin      # per-sample inertial data            (magic "TRIMU001")
  frames.bin   # per-frame timestamps for alignment  (magic "TRIVTS01")
  meta.json    # human/tool-readable recording metadata
```

The video is plain H.264 in an MP4 container and plays in any media player; the IMU and
timestamp data live in the sidecars (and redundantly inside the video's SEI). The SDK
readers (`ImuFileReader`, `VtsFileReader`) and the SEI parser (`SeiImuParser`) are the
canonical decoders for these formats.

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

Magic `TRIVTS01`, current version **2**. "VTS" = video timestamp. One entry per recorded
frame; it ties each frame to the inertial timeline and to the video PTS.

### Header (32 bytes)

| Offset | Size | Field | Notes |
|---:|---:|---|---|
| 0 | 8 | `magic` | ASCII `"TRIVTS01"` |
| 8 | 4 | `version` | `2` |
| 12 | 4 | `frame_rate_milli` | fps × 1000 (e.g. `30000`) |
| 16 | 16 | `reserved` | zero |

Exposed by `VtsFileReader` as `version`, `frameRateMilli`, `fps`, `entryCount`.

### Entry (24 bytes, v2)

| Offset | Size | Field | Type | Notes |
|---:|---:|---|---|---|
| 0 | 4 | `frame_number` | uint32 | 0-based frame index |
| 4 | 8 | `sof_timestamp_ns` | uint64 | **start-of-frame** timestamp (ns) — use this to align IMU |
| 12 | 4 | `venc_seq` | uint32 | encoder sequence number |
| 16 | 8 | `venc_pts_us` | uint64 | video presentation timestamp (µs) |

This maps to [`VtsEntry`](api-reference.md#vtsentry). `sof_timestamp_ns` is the
hardware-aligned start-of-frame time used to find the matching IMU sample; `venc_pts_us`
is the MP4 PTS used to seek the decoder.

---

## meta.json

Written at the end of a recording. Permissive/forward-compatible (extra fields may
appear):

```json
{
  "id": "ab12cd34_recording_20260524_143000",
  "created_at_epoch_ms": 1748090000000,
  "device": { "vendor_id": 8711, "product_id": 22, "serial": "ab12cd34..." },
  "video":  { "width": 1920, "height": 1080, "fps": 30, "codec": "h264" },
  "sdk_version": "0.1.6"
}
```

`device.serial` is the camera's public per-unit ID (or `null` for cameras that don't
advertise one).

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
| 1 | `version` | payload version |
| 2 | `num_samples` | count of samples that follow |
| 2 | `accel_fs` | accel full-scale code |
| 2 | `gyro_fs` | gyro full-scale code |
| 80 × N | `samples[]` | each a v3 `ImuSample` (same 80-byte layout as the sidecar) |

The header (UUID + version + counts) is `SeiConstants.SEI_HEADER_SIZE` = 23 bytes. The
parser strips H.264 **emulation-prevention** bytes (`00 00 03` → `00 00`) before reading
the payload, and ignores any SEI NAL that isn't a Trinet IMU payload.

`SeiImuParser.parse` returns `List<SeiImuPayload>`:

```kotlin
data class SeiImuHeader(val version: Int, val numSamples: Int, val accelFs: Int, val gyroFs: Int)
data class SeiImuPayload(val header: SeiImuHeader, val samples: List<ImuSample>)
```

If you need lower-level Annex B handling (start-code scanning, emulation-prevention
add/remove), the `NalParser` object exposes `splitNalUnits`, `removeEmulationPrevention`,
and `addEmulationPrevention`.

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

In short: to correlate inertial data with a video frame, always go through
`sof_timestamp_ns` (see [aligning IMU to frames](playback.md#aligning-imu-to-frames)).

---

Next: [API reference →](api-reference.md)
