# Trinet Camera — IMU ↔ Video Time Synchronization

This document explains how the Trinet camera time-aligns its inertial (IMU) data
with its video frames, what accuracy you can expect, and how to use the
timestamps correctly in your own pipeline (VIO, SLAM, sensor fusion, AR). It is
self-contained: no prior knowledge of the camera internals is assumed.

---

## 1. TL;DR

- Every Trinet recording is a **synchronized triple**: the video, the IMU
  samples, and a per-frame timestamp track. (Over the live USB video/network
  paths the IMU is embedded in the video stream and the SDK reconstructs the
  same triple for you.)
- **All timestamps — IMU samples and video frames — are expressed in one shared
  monotonic camera clock.** Aligning an IMU sample to a video frame is therefore
  a direct timestamp comparison; there is no separate "sync signal" to decode.
- **Each video frame is timestamped at the *middle of its exposure*** (not the
  start of the frame). This is the photometrically correct instant and is what
  visual-inertial algorithms expect.
- **Relative timing precision (jitter) is ≈ 10 µs.** The remaining *systematic*
  offset between the camera and IMU is a small, constant value captured once by
  calibration (`timeshift_cam_imu`). Apply it for best results.
- **Do not use the video container's presentation timestamps (PTS) or
  wall-clock time** for IMU alignment — use the frame timestamps the camera/SDK
  provides.

---

## 2. Two different things: *precision* vs *accuracy*

People often conflate these; keeping them separate makes the rest easy.

| | What it means | Trinet value |
|---|---|---|
| **Precision (jitter)** | How repeatably each timestamp lands relative to the true periodic event. The frame-to-frame "wobble." | **≈ 10 µs (1σ)** |
| **Accuracy (bias)** | A constant offset between the *reported* time and the *true physical* time of the event, the same for every sample. | Removed/absorbed (see §6) |

Precision is set by how the camera captures timestamps; accuracy is handled by a
combination of the camera's mid-exposure timestamping and a one-time calibration
constant. A system can be very precise but biased, or unbiased but jittery — the
Trinet camera is engineered to be both precise *and* unbiased once calibrated.

---

## 3. The shared clock

The camera maintains a single **monotonic clock** (a steadily increasing
nanosecond counter that never jumps backward and is unaffected by wall-clock
changes). Two things are stamped against it:

- **IMU samples** are timestamped **at the moment the sample is acquired** — at
  the sensor's data-ready event, *before* the value is read out. This means the
  timestamp reflects when the motion actually occurred, not when software got
  around to reading it.
- **Video frames** are timestamped at the **middle of their exposure window**
  (see §4).

Because both live on the same clock, **IMU↔frame alignment is just arithmetic**:
find the IMU samples whose timestamps bracket a frame's timestamp and
interpolate. There is no cross-clock conversion and no hardware trigger pulse to
recover.

> Magnetometer note: the magnetometer is sampled on its own (slower) schedule.
> Each IMU sample carries the most recent magnetometer reading plus its age in
> microseconds, so you can recover the exact time the magnetometer value was
> taken if you need it.

---

## 4. Why "middle of exposure"? (the theory)

A camera frame is **not an instant** — it is an integral of light over an
**exposure window** of duration `T_exp`. Every photon collected during that
window contributes to the image. The single instant that best represents the
frame is therefore the **midpoint of the exposure**, because that is the average
time over which the image was formed.

This matters because of **auto-exposure**. In bright light `T_exp` might be a
few milliseconds; in dim light it can grow to tens of milliseconds, and it
changes frame to frame as lighting changes. Consider what happens if a camera
instead timestamped the **start of the frame**:

- The gap between "start of frame" and "middle of exposure" is `T_exp / 2`.
- Since `T_exp` varies with lighting, that gap is **not constant** — it can swing
  from well under a millisecond to ~15 ms.
- A calibration step can only remove a *constant* offset. A *varying* offset
  would leak straight into your motion estimate as a lighting-dependent error.

**The Trinet camera removes this for you**: it reads the exposure actually
applied to each frame and reports that frame's timestamp at the exposure center.
Each frame timestamp also carries the exposure value and a flag indicating that
the mid-exposure correction was applied, so a consumer can verify it.

> Rolling-shutter note: like most compact image sensors, the Trinet uses a
> rolling shutter — rows are exposed and read out sequentially, so different rows
> are centered at slightly different times. The reported timestamp corresponds to
> the frame's reference (center) row. Any small, fixed row-to-row offset is a
> constant and is absorbed by the calibration `timeshift` (§6). For the vast
> majority of VIO/AR use this is negligible; if you do per-row modelling, treat
> the frame timestamp as the center-row mid-exposure time.

---

## 5. Using the timestamps

The SDK exposes, per frame, a **Start-of-Frame timestamp** in the shared clock
(`sofNs` / `sof_timestamp_ns`) — despite the historical name, this value is the
**mid-exposure** time described above. IMU samples expose their own
acquisition timestamp (`timestampNs`).

Typical alignment loop (pseudocode):

```
for each video frame f:
    t_cam = f.sof_timestamp_ns                 # mid-exposure, shared clock
    t_cam += timeshift_cam_imu_ns              # calibration constant (§6)
    # find IMU samples around t_cam and interpolate / integrate
    imu_window = imu.samples where t_cam - dt <= sample.timestampNs <= t_cam + dt
    pose_input = interpolate(imu_window, at=t_cam)
```

Rules of thumb:

1. **Use the frame timestamp the SDK gives you**, not the `.mp4` container PTS
   and not your host's arrival/wall-clock time. Container PTS and host time are
   subject to buffering and USB/network transport jitter of milliseconds.
2. **Apply the calibration `timeshift`** (§6) when you have it.
3. **Stay in the camera clock** for IMU↔frame work. Only convert to host time at
   the very end, if you must, and expect that conversion to be the least precise
   step.

---

## 6. The calibration time-shift (`timeshift_cam_imu`)

Even with a perfect shared clock and mid-exposure timestamps, the *reported*
times are not the *true physical* times, because of fixed **signal-path delays**
that have nothing to do with the clock:

- **On the camera side:** light must be converted, read out, and processed
  before a frame exists. The timestamp is anchored to the exposure center, but
  there are small, fixed processing latencies around it.
- **On the IMU side:** the motion sensor applies an internal low-pass filter to
  reduce noise. Any such filter has **group delay** — the reported sample lags
  the true motion by a fixed amount.

These two constants do not cancel, so the camera and the IMU effectively "see"
the same physical event at timestamps that differ by a small **fixed offset**.
That offset is the **`timeshift_cam_imu`**.

Key properties:

- It is **constant** for a given camera (it depends on the sensors and their
  configuration, not on lighting or motion).
- It is **measured once, by calibration**, and stored in `calibration.json`
  (field `extrinsics.timeshift_cam_imu_s`, in seconds). The calibration toolchain
  estimates it alongside the camera intrinsics and the camera↔IMU pose.
- You **apply it** by shifting the camera timestamp onto the IMU timeline:
  `t_on_imu_timeline = t_frame + timeshift_cam_imu`. The exact sign and magnitude
  come from the calibration result; use the value as produced.

**How mid-exposure and `timeshift` divide the work:** mid-exposure timestamping
removes the *lighting-dependent* part of the offset (the `T_exp/2` term) inside
the camera, in real time. Whatever remains is *constant* — exactly the kind of
offset a single calibrated `timeshift` is designed to absorb. Together they make
the IMU↔video alignment stable regardless of the scene's brightness.

---

## 7. Worked example

All numbers below are representative of real recordings.

**Frame timeline / precision.** At 30 fps the ideal frame interval is 33.3333 ms.
Two consecutive frame timestamps from a real recording:

```
frame 0 : sof = 338.397280527 s
frame 1 : sof = 338.430606527 s
interval = 33.326 ms          (ideal 33.3333 ms)
jitter   = -7.3 µs            (this pair's deviation from the ideal period)
```

Across the clip the deviation stays within roughly ±10 µs (1σ ≈ 10 µs). That is
the **precision**: the spacing of frame timestamps is rock-steady to ~10 µs.

**Mid-exposure correction (lighting dependence).** Two clips of the same scene
under different lighting:

| Scene | Exposure `T_exp` | Mid-exposure shift applied (`T_exp/2`) |
|---|---|---|
| Bright | 3 ms | 1.5 ms |
| Dim | 30 ms | 15 ms |

In both cases the camera moves the frame timestamp to the exposure center
automatically. A camera that timestamped frame-start instead would mis-align the
IMU by **1.5 ms in bright light and 15 ms in dim light** — and that error would
appear and disappear as the lighting changed. Here it is removed before you ever
see the data.

**Aligning an IMU sample to a frame.** Suppose frame 0 above has `sof =
338.397280527 s`, the calibration reports `timeshift_cam_imu = +0.0007 s` (0.7
ms), and you want the device's angular velocity at that frame:

```
t_query = 338.397280527 + 0.000700 = 338.397980527 s
# pick the IMU samples bracketing t_query (IMU runs ~400 Hz → ~2.5 ms spacing)
# linearly interpolate gyro between them at t_query
```

Because everything is in the same clock, that is the entire procedure.

---

## 8. What accuracy should I quote / expect?

For a single Trinet camera, after applying the calibration `timeshift`:

- **Relative timing precision:** ≈ **10 µs** (1σ) frame-to-IMU.
- **Residual systematic offset:** bounded by the calibration quality; the
  lighting-dependent component is removed on-device, leaving only the constant
  `timeshift` (typically sub-millisecond after calibration).
- **Sampling rates:** video at the configured frame rate (e.g. 30 fps); IMU at
  its configured rate (typically a few hundred Hz); magnetometer slower, with
  per-sample age provided.

Practical guidance for a datasheet / customer statement:

> "IMU and video samples share a common monotonic camera clock. Frame timestamps
> are reported at mid-exposure, so the camera–IMU offset is independent of
> exposure/lighting. Relative timing precision is on the order of 10 µs; the
> residual constant camera–IMU offset is characterized per unit by calibration
> (`timeshift_cam_imu`) and is sub-millisecond after calibration."

---

## 9. Common pitfalls

- **Using `.mp4` PTS or host arrival time for IMU alignment.** These carry
  transport/buffering jitter of milliseconds. Use the SDK frame timestamp.
- **Assuming a fixed frame-start-to-exposure offset.** It is not fixed — it
  scales with exposure. The camera already accounts for this; don't re-add it.
- **Forgetting the calibration `timeshift`.** Without it you keep a small,
  constant bias. With it, alignment is unbiased.
- **Mixing clocks.** Keep IMU↔frame math in the camera clock; convert to
  host/world time only as a final, separate step.

---

## 10. Glossary

- **Exposure (`T_exp`)** — the time the image sensor integrates light for one
  frame. Set by auto-exposure based on scene brightness.
- **Mid-exposure timestamp** — the instant at the center of the exposure window;
  the photometrically correct time for a frame.
- **Jitter (precision)** — random variation of a timestamp around its ideal time.
- **`timeshift_cam_imu`** — the constant residual time offset between the camera
  and IMU signal paths, measured by calibration and applied at fusion time.
- **Monotonic clock** — a counter that only increases and is immune to wall-clock
  adjustments; the common time base for all on-camera timestamps.
