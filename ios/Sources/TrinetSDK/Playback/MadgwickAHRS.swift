// MadgwickAHRS.swift — IMU-only (6-axis: gyro + accel) sensor fusion.
//
// Direct port of the Android SDK's MadgwickAhrs.kt. Produces an orientation
// quaternion from gyroscope + accelerometer. No magnetometer (the ICM-20948's
// mag is disabled in firmware), so yaw drifts slowly but pitch/roll are
// gravity-locked and stable. Sebastian Madgwick's IMU update (2010); beta
// tuned for the ICM-20948 @ 562 Hz.

import Foundation

/// Orientation quaternion, component order (w, x, y, z) == Madgwick (q0..q3).
public struct Quaternion: Sendable, Hashable {
    public var w: Float
    public var x: Float
    public var y: Float
    public var z: Float
    public init(w: Float, x: Float, y: Float, z: Float) {
        self.w = w; self.x = x; self.y = y; self.z = z
    }
    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)
}

public final class MadgwickAHRS {
    public private(set) var q = Quaternion.identity
    private let beta: Float

    public init(beta: Float = 0.1) { self.beta = beta }

    public func reset() { q = .identity }

    /// One fusion step. gyro in rad/s, accel in any consistent unit
    /// (normalized internally), dt in seconds.
    public func update(gx: Float, gy: Float, gz: Float,
                       ax: Float, ay: Float, az: Float, dt: Float) {
        var q0 = q.w, q1 = q.x, q2 = q.y, q3 = q.z

        // Normalise accelerometer measurement.
        var norm = (ax * ax + ay * ay + az * az).squareRoot()
        if norm == 0 { return }
        norm = 1 / norm
        let axn = ax * norm, ayn = ay * norm, azn = az * norm

        // Auxiliary variables.
        let _2q0 = 2 * q0, _2q1 = 2 * q1, _2q2 = 2 * q2, _2q3 = 2 * q3
        let _4q0 = 4 * q0, _4q1 = 4 * q1, _4q2 = 4 * q2
        let _8q1 = 8 * q1, _8q2 = 8 * q2
        let q0q0 = q0 * q0, q1q1 = q1 * q1, q2q2 = q2 * q2, q3q3 = q3 * q3

        // Gradient descent corrective step.
        let s0 = _4q0 * q2q2 + _2q2 * axn + _4q0 * q1q1 - _2q1 * ayn
        let s1 = _4q1 * q3q3 - _2q3 * axn + 4 * q0q0 * q1 - _2q0 * ayn - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * azn
        let s2 = 4 * q0q0 * q2 + _2q0 * axn + _4q2 * q3q3 - _2q3 * ayn - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * azn
        let s3 = 4 * q1q1 * q3 - _2q1 * axn + 4 * q2q2 * q3 - _2q2 * ayn
        norm = (s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3).squareRoot()
        if norm == 0 { return }
        norm = 1 / norm
        let s0n = s0 * norm, s1n = s1 * norm, s2n = s2 * norm, s3n = s3 * norm

        // Rate of change of quaternion from gyroscope, minus the corrective step.
        let qDot0 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz) - beta * s0n
        let qDot1 = 0.5 * (q0 * gx + q2 * gz - q3 * gy) - beta * s1n
        let qDot2 = 0.5 * (q0 * gy - q1 * gz + q3 * gx) - beta * s2n
        let qDot3 = 0.5 * (q0 * gz + q1 * gy - q2 * gx) - beta * s3n

        // Integrate.
        q0 += qDot0 * dt; q1 += qDot1 * dt; q2 += qDot2 * dt; q3 += qDot3 * dt

        // Normalise quaternion.
        norm = (q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3).squareRoot()
        if norm == 0 { return }
        norm = 1 / norm
        q = Quaternion(w: q0 * norm, x: q1 * norm, y: q2 * norm, z: q3 * norm)
    }
}
