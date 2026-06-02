# IMU

The Trinet camera embeds inertial samples directly in the H.264 bitstream: every video
frame carries an SEI NAL with the IMU samples captured alongside it. The SDK decodes
these for you, both live (off the stream) and from a recording. This guide covers the
sample model, getting samples live, and the orientation-fusion + visualization helpers.

- [The IMU sample](#the-imu-sample)
- [Sample rate](#sample-rate)
- [Getting IMU samples live](#getting-imu-samples-live)
- [Orientation fusion (Madgwick)](#orientation-fusion-madgwick)
- [UI helpers](#ui-helpers)

---

## The IMU sample

`com.panoculon.trinet.sdk.model.ImuSample` is the unit of inertial data everywhere in
the SDK — live SEI, the on-disk sidecar, and playback all decode to this type.

```kotlin
data class ImuSample(
    val timestampNs: Long,      // capture time, nanoseconds (device monotonic clock)
    val accel: FloatArray,      // [x, y, z] m/s²  (includes gravity)
    val gyro: FloatArray,       // [x, y, z] rad/s
    val mag: FloatArray,        // [x, y, z] µT
    val tempC: Float,           // °C
    val quatXyzw: FloatArray,   // [x, y, z, w] — reserved; compute orientation yourself
    val linAccel: FloatArray,   // [x, y, z] — reserved
    val fsyncDelayUs: Float,    // µs between the frame-sync pulse and this sample
)
```

| Field | Unit | Notes |
|---|---|---|
| `timestampNs` | ns | Device monotonic capture time. Use this for IMU↔IMU spacing and IMU↔frame alignment. |
| `accel` | m/s² | 3-axis, **gravity included** (so a stationary device reads ≈9.81 along the up axis). |
| `gyro` | rad/s | 3-axis angular rate. |
| `mag` | µT | 3-axis magnetometer. |
| `tempC` | °C | Sensor die temperature. |
| `quatXyzw` | — | **Reserved.** Don't rely on it; compute orientation with [Madgwick](#orientation-fusion-madgwick). |
| `linAccel` | — | **Reserved.** |
| `fsyncDelayUs` | µs | Time from the hardware frame-sync pulse to this sample. Used to derive the frame's start-of-frame timestamp for video alignment. |

The camera emits **raw** accelerometer, gyroscope, and magnetometer only —
`quatXyzw`/`linAccel` are reserved fields that read as identity/zero. Compute orientation
from the raw streams with the Madgwick helper.

---

## Sample rate

The camera produces inertial samples at roughly **500–562 Hz**. Each video frame's SEI
NAL carries the batch of samples captured since the previous frame (so at 30 fps you'll
see ~17–19 samples per frame). The exact rate is recorded in the IMU
sidecar header (see [file formats](file-formats.md)); the typical value is
562 Hz.

---

## Getting IMU samples live

The samples ride inside the SEI NALs of the frame flow. Decode them with `SeiImuParser`:

```kotlin
import com.panoculon.trinet.sdk.sei.SeiImuParser

session.frames
    .onEach { frame ->
        val payloads = SeiImuParser.parse(frame.annexB)   // List<SeiImuPayload>
        for (payload in payloads) {
            // payload.header: version, numSamples, accelFs, gyroFs (full-scale codes)
            for (sample in payload.samples) {
                // sample.accel, sample.gyro, sample.mag, sample.timestampNs, ...
            }
        }
    }
    .launchIn(scope)
```

`SeiImuParser.parse` scans the Annex B access unit, finds every Trinet IMU SEI NAL
(identified by the TRIMU UUID), strips emulation-prevention bytes, and decodes the
header + samples. NALs that aren't Trinet IMU SEI are ignored, so you can pass the whole
access unit. See the format details in [file formats](file-formats.md#in-stream-imu-sei).

---

## Orientation fusion (Madgwick)

The SDK includes a 6-DOF Madgwick AHRS filter to fuse accelerometer + gyroscope into an
orientation quaternion (6-DOF means yaw will drift slowly without a magnetometer term).

```kotlin
import com.panoculon.trinet.sdk.fusion.Madgwick

val madgwick = Madgwick(beta = 0.1f)
var lastNs = 0L

fun onSample(s: ImuSample) {
    if (lastNs == 0L) {
        // Seed attitude from the first accelerometer reading (tilt only).
        madgwick.seedFromAccel(s.accel[0], s.accel[1], s.accel[2])
    } else {
        val dt = (s.timestampNs - lastNs).coerceAtLeast(0L) / 1e9f   // seconds
        madgwick.updateIMU(
            gx = s.gyro[0], gy = s.gyro[1], gz = s.gyro[2],
            ax = s.accel[0], ay = s.accel[1], az = s.accel[2],
            dt = dt,
        )
    }
    lastNs = s.timestampNs
    val quat: FloatArray = madgwick.asXyzw()   // [x, y, z, w], scalar-last
}
```

Notes:

- `beta` is the filter gain (default `0.1f`). Higher trusts the accelerometer more
  (faster correction, more jitter); lower trusts the gyro integration more.
- `updateIMU` ignores non-finite or out-of-range `dt` (`dt <= 0` or `dt > 0.5 s`), so a
  stale timestamp won't blow up the estimate.
- `asXyzw()` returns a **scalar-last** `[x, y, z, w]` quaternion (the convention the
  `OrientationCube` widget and scipy/OpenGL expect). Internally the filter is
  scalar-first.
- Call `reset()` to return to identity (e.g. on a seek during playback). After a reset,
  re-seed from accel before the first `updateIMU`.

---

## UI helpers

The `ui` package (requires the Compose dependencies) ships drop-in widgets.

### `ImuOverlayPanel`

A scrollable sidebar with three sensor cards (accel/gyro/mag — numeric X/Y/Z/magnitude
readouts plus stacked per-axis sparklines), a temperature + frame-sync readout, and the
orientation cube. You supply a rolling history buffer, the current sample, and the fused
quaternion:

```kotlin
import com.panoculon.trinet.sdk.ui.ImuOverlayPanel
import com.panoculon.trinet.sdk.ui.ImuHistory

val history = remember { ImuHistory(capacity = 300) }

ImuOverlayPanel(
    history  = history,
    sample   = currentSample,    // ImuSample?
    quatXyzw = quat,             // FloatArray [x,y,z,w] from Madgwick.asXyzw()
)
```

`ImuHistory` is a synchronized fixed-capacity ring buffer of recent samples. Call
`add(sample)` as samples arrive and `reset()` when you seek; it's safe to mutate from a
background thread and read from Compose.

### `OrientationCube`

A lightweight quaternion-driven wireframe cube rendered in pure Compose `Canvas` (no
GLES). Pass it the scalar-last quaternion:

```kotlin
import com.panoculon.trinet.sdk.ui.OrientationCube

OrientationCube(quatXyzw = quat, modifier = Modifier.size(88.dp))
```

### `TimeSeriesPlot` / `TripleAxisPlot`

Scrolling line plots for a single channel or a 3-axis channel. Pass a window of values
(oldest → newest):

```kotlin
import com.panoculon.trinet.sdk.ui.TimeSeriesPlot
import com.panoculon.trinet.sdk.ui.TripleAxisPlot

TimeSeriesPlot(values = history.accelX(), modifier = Modifier.fillMaxWidth().height(40.dp))

TripleAxisPlot(
    x = history.gyroX(), y = history.gyroY(), z = history.gyroZ(),
    label = "Gyroscope",
)
```

`ImuHistory` exposes per-channel snapshot accessors: `accelX/Y/Z`, `gyroX/Y/Z`,
`magX/Y/Z`, and `fsyncUs`.

---

Next: [Recording →](recording.md)
