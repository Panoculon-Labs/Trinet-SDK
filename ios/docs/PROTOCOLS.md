# Trinet wire protocols — iOS / CDC NCM

This document describes the Trinet camera's **CDC NCM (USB-Ethernet)** wire
protocol as used by the iOS SDK, so a consumer can implement a client from
scratch. The `TrinetSDK` Swift package is the canonical client — if you find
yourself opening raw sockets, prefer adding a method to the SDK instead.

> Android uses a different transport (UVC over USB). For the why and the
> side-by-side comparison see [`../../docs/TRANSPORT.md`](../../docs/TRANSPORT.md);
> for the Android wire details see the Android SDK docs
> ([streaming](../../docs/streaming.md), [IMU](../../docs/imu.md)).

## Addressing

Over NCM the camera presents a USB-Ethernet interface; iOS shows it under
**Settings → Ethernet**. The iPhone receives a DHCP lease from the device on a
`172.32.<X>.0/24` subnet, where `<X>` is derived per-unit from the device id.
The camera answers on its own address on that subnet (the interface's gateway /
router IP). All endpoints below listen on that camera IP.

The SDK pins its `NWConnection`s to the specific USB-Ethernet interface
(`NWParameters.requiredInterface`) so traffic never leaks onto Wi-Fi/cellular —
see `InterfacePinning.swift`.

## Endpoints

| Port | Proto | Endpoint                | Direction        | Purpose |
|------|-------|-------------------------|------------------|---------|
| 8080 | HTTP  | `GET /live.h264`        | server → client  | Raw H.264 Annex-B bytes (IMU embedded as SEI) |
| 8080 | HTTP  | `GET /live.h265`        | server → client  | Raw H.265 Annex-B bytes (IMU embedded as SEI) |
| 8081 | HTTP  | `GET /api/device_id`    | request/response | `{device_id, product, mode}` |
| 8081 | HTTP  | `GET /api/state`        | request/response | `{mode, recording, ready, note}` |
| 8081 | HTTP  | `GET /api/storage`      | request/response | `{mount, present, total_bytes?, available_bytes?}` |
| 8081 | HTTP  | `GET /api/time`         | request/response | `{clock_monotonic_ns, clock_realtime_ns}` |
| 5557 | UDP   | sync probe / response   | bidir            | Clock-offset measurement (see below) |

> **Note on IMU:** earlier firmware shipped IMU as a separate UDP telemetry
> channel on port 5555. That channel is **removed** — IMU is now embedded
> **in-stream** as SEI NAL units inside the H.264/H.265 bitstream (next
> section). There is no separate IMU socket to open.

## Live video (port 8080)

The server emits Annex-B bytes (3- or 4-byte start codes + NAL payload). The
first bytes after a connection always include the parameter sets
(SPS/PPS, plus VPS for H.265) so a decoder can start without waiting for the
next GOP boundary.

iOS-side parsing (`VideoStream.swift`):
1. Split on Annex-B start codes (`AnnexBSplitter`).
2. For **H.264**, classify by `nal[0] & 0x1F`: 7 = SPS, 8 = PPS, 5 = IDR slice,
   1 = non-IDR slice, 6 = SEI.
3. For **H.265**, classify by `(nal[0] >> 1) & 0x3F`: 32 = VPS, 33 = SPS,
   34 = PPS, 16…21 = IRAP/key, 39 = prefix SEI.
4. Build a `CMVideoFormatDescription` from the parameter sets, wrap each
   picture-slice NAL with a 4-byte big-endian length prefix (AVCC framing),
   and feed it to the decoder / `AVAssetWriterInput`.
5. SEI NALs are routed to the SEI parser (below) for IMU + timing, and are
   also muxed verbatim into the recorded MP4 so the file self-contains IMU.

## In-stream IMU + temperature (SEI)

IMU and SoC-temperature data ride inside the video bitstream as
`user_data_unregistered` SEI messages (`payload_type = 5`), dispatched by a
16-byte UUID. A standard decoder ignores them. Reference: `TrinetSEI.swift`.

SEI message layout (Annex-B start code already stripped; emulation-prevention
bytes `00 00 03` removed before parsing):

```
[ NAL header: 1 byte (H.264 type 6) / 2 bytes (H.265 type 39) ]
per message:
  payload_type   (Σ 0xFF bytes + final byte)      # = 5
  payload_size   (Σ 0xFF bytes + final byte)
  payload[payload_size]                            # first 16 bytes = UUID
```

### IMU message — UUID `54 52 49 4E 45 54 49 4D 55 53 45 49 00 01 00 00` (`"TRINETIMUSEI\0\1\0\0"`)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 16     | UUID            | as above |
| 16 | 1      | version         | currently 1 |
| 17 | 2      | num_samples (N) | little-endian |
| 19 | 2      | accel_fs        | little-endian, accel full-scale (g) |
| 21 | 2      | gyro_fs         | little-endian, gyro full-scale (°/s) |
| 23 | 80 × N | samples         | N × 80-byte `ImuSample` (little-endian, identical to the on-disk TRIMU001 v4 sample struct) |

At 562 Hz IMU / 30 fps video that's ~19 samples per frame.

### Temperature message — UUID `54 52 49 4E 45 54 54 45 4D 50 00 01 00 00 00 00` (`"TRINETTEMP\0\1\0\0\0\0"`)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0  | 16 | UUID    | as above |
| 16 | 1  | version | currently 1 |
| 17 | 4  | temp_mC | int32 LE, milli-Celsius |
| 21 | 4  | cpu_kHz | uint32 LE |

### Video↔IMU sync

Each `ImuSample` carries `timestamp_ns` (device `CLOCK_MONOTONIC`) and a
`fsync_delay_us` hardware latch delay. The **Start-of-Frame** time for the
video frame the SEI is attached to is:

```
sof_ns = sample.timestamp_ns − fsync_delay_us × 1000
```

This is what the SDK uses to PTS-align the MP4 and to write the `.vts` per-frame
timing sidecar, yielding ~1 ms video↔IMU alignment on the device clock.

## Sync probe (port 5557 UDP)

A lightweight Cristian's-algorithm probe to measure the device-vs-host clock
offset (`SyncCoordinator.swift`).

> **Optional — not used for video↔IMU sync.** Each frame's IMU SEI already
> carries the device Start-of-Frame timestamp on the same clock as the frames,
> so alignment needs no UDP probe. This endpoint exists only for a future
> multi-camera host-offset case; the SDK does not call it during normal
> streaming or recording.

### Request (8 bytes, big-endian)
| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic = `"TRSY"` (0x54525359) |
| 4 | 4 | client_seq |

### Response (24 bytes, big-endian)
| Offset | Size | Field |
|--------|------|-------|
| 0  | 4 | magic |
| 4  | 4 | client_seq (echoed) |
| 8  | 8 | server_recv_mono_ns (`CLOCK_MONOTONIC` at server `recvfrom`) |
| 16 | 8 | server_send_mono_ns (`CLOCK_MONOTONIC` at server `sendto`) |

The client records `t0 = send`, `t3 = recv` on its own clock; with the device's
`t1 = server_recv`, `t2 = server_send`:

```
offset = ((t1 − t0) + (t2 − t3)) / 2     # device clock − host clock, ns
delay  = (t3 − t0) − (t2 − t1)           # round trip, ns
```

The SDK runs ~10 probes and keeps the lowest-delay sample. On a quiet USB-
Ethernet link delay is typically < 2 ms.

## On-disk sidecar formats

A recording is `<base>.mp4` (with IMU SEI muxed in) plus two binary sidecars:
`<base>.imu` (TRIMU001 v4) and `<base>.vts` (TRIVTS01 v2). These match the
Android SDK and the Linux toolchain byte-for-byte. See
[`../README.md`](../README.md#file-formats) for the full layout.
