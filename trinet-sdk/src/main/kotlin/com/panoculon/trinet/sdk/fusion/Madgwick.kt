package com.panoculon.trinet.sdk.fusion

import kotlin.math.sqrt

/**
 * Minimal Kotlin implementation of the Madgwick AHRS filter (S. Madgwick, 2010),
 * used to fuse the device's raw accelerometer + gyroscope streams into an
 * orientation quaternion suitable for rendering.
 *
 * 6-DOF only ([updateIMU]) — yaw will drift without magnetometer correction.
 *
 * Internal quaternion order is wxyz (scalar-first); [asXyzw] converts to
 * scalar-last for scipy/OpenGL-style consumers.
 */
class Madgwick(
    var beta: Float = 0.1f,
) {
    // w, x, y, z
    private var q0: Float = 1f
    private var q1: Float = 0f
    private var q2: Float = 0f
    private var q3: Float = 0f

    fun reset() {
        q0 = 1f; q1 = 0f; q2 = 0f; q3 = 0f
    }

    /** Seed from accelerometer (tilt-only); analogous to ahrs acc2q. */
    fun seedFromAccel(ax: Float, ay: Float, az: Float) {
        val n = sqrt(ax * ax + ay * ay + az * az)
        if (n < 1e-6f) { reset(); return }
        val x = ax / n; val y = ay / n; val z = az / n
        // Rotation from world-down to measured gravity direction.
        val w = sqrt((z + 1f).coerceAtLeast(0f) * 0.5f)
        q0 = w
        if (w > 1e-6f) {
            q1 = -y / (2f * w)
            q2 =  x / (2f * w)
            q3 = 0f
        } else {
            q1 = 1f; q2 = 0f; q3 = 0f
        }
        normalize()
    }

    /** 6-DOF update (accel + gyro), dt in seconds. */
    fun updateIMU(
        gx: Float, gy: Float, gz: Float,
        ax: Float, ay: Float, az: Float,
        dt: Float,
    ) {
        if (dt <= 0f || dt > 0.5f || !dt.isFinite()) return

        var q0 = this.q0; var q1 = this.q1; var q2 = this.q2; var q3 = this.q3

        // Rate of change of quaternion from gyroscope.
        var qDot0 = 0.5f * (-q1 * gx - q2 * gy - q3 * gz)
        var qDot1 = 0.5f * ( q0 * gx + q2 * gz - q3 * gy)
        var qDot2 = 0.5f * ( q0 * gy - q1 * gz + q3 * gx)
        var qDot3 = 0.5f * ( q0 * gz + q1 * gy - q2 * gx)

        val aNorm = sqrt(ax * ax + ay * ay + az * az)
        if (aNorm > 1e-6f) {
            val nax = ax / aNorm; val nay = ay / aNorm; val naz = az / aNorm

            val _2q0 = 2f * q0; val _2q1 = 2f * q1; val _2q2 = 2f * q2; val _2q3 = 2f * q3
            val _4q0 = 4f * q0; val _4q1 = 4f * q1; val _4q2 = 4f * q2
            val _8q1 = 8f * q1; val _8q2 = 8f * q2
            val q0q0 = q0 * q0; val q1q1 = q1 * q1; val q2q2 = q2 * q2; val q3q3 = q3 * q3

            var s0 = _4q0 * q2q2 + _2q2 * nax + _4q0 * q1q1 - _2q1 * nay
            var s1 = _4q1 * q3q3 - _2q3 * nax + 4f * q0q0 * q1 - _2q0 * nay - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * naz
            var s2 = 4f * q0q0 * q2 + _2q0 * nax + _4q2 * q3q3 - _2q3 * nay - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * naz
            var s3 = 4f * q1q1 * q3 - _2q1 * nax + 4f * q2q2 * q3 - _2q2 * nay

            val sn = sqrt(s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3)
            if (sn > 1e-6f) {
                s0 /= sn; s1 /= sn; s2 /= sn; s3 /= sn
                qDot0 -= beta * s0
                qDot1 -= beta * s1
                qDot2 -= beta * s2
                qDot3 -= beta * s3
            }
        }

        q0 += qDot0 * dt
        q1 += qDot1 * dt
        q2 += qDot2 * dt
        q3 += qDot3 * dt

        val qn = sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3)
        if (qn > 1e-6f) {
            this.q0 = q0 / qn; this.q1 = q1 / qn; this.q2 = q2 / qn; this.q3 = q3 / qn
        }
    }

    private fun normalize() {
        val n = sqrt(q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3)
        if (n > 1e-6f) {
            q0 /= n; q1 /= n; q2 /= n; q3 /= n
        }
    }

    /** Copy current quaternion as [x, y, z, w] (scipy / our cube convention). */
    fun asXyzw(out: FloatArray = FloatArray(4)): FloatArray {
        out[0] = q1; out[1] = q2; out[2] = q3; out[3] = q0
        return out
    }
}
