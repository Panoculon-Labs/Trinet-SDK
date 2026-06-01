// ImuSample.swift — one IMU reading from the ICM-20948.
//
// Layout matches the on-disk TRIMU001 v4 sample struct (80 bytes packed,
// little-endian) so a writer can blit them straight into a .imu file
// without per-field conversion. The same layout is shared with the Android
// SDK and the Linux toolchain; see ios/docs/PROTOCOLS.md and ios/README.md
// (File formats) for the field-by-field spec.

import Foundation

public struct ImuSample: Sendable, Hashable {
    /// CLOCK_MONOTONIC nanoseconds on the Trinet at sample time. Same
    /// clock domain as the per-frame `sof_timestamp_ns` in TRIVTS01.
    public var timestampNs: UInt64

    /// Accelerometer in m/s², includes gravity. XYZ.
    public var accel: SIMD3<Float>

    /// Gyroscope in rad/s. XYZ.
    public var gyro: SIMD3<Float>

    /// Magnetometer in µT. XYZ. Zero if magnetometer is disabled.
    public var mag: SIMD3<Float>

    /// IMU die temperature in °C.
    public var tempC: Float

    /// Fused orientation quaternion (XYZW). Unused by current firmware
    /// (all-zero); kept for forward compat with the on-disk layout.
    public var quat: SIMD4<Float>

    /// Gravity-removed linear acceleration in m/s². Unused by current
    /// firmware; same forward-compat story as `quat`.
    public var linAccel: SIMD3<Float>

    /// FSYNC pulse delay in microseconds since the last camera frame
    /// trigger. Zero if no pulse was captured in this sample window.
    public var fsyncDelayUs: Float

    public init(timestampNs: UInt64,
                accel: SIMD3<Float>,
                gyro: SIMD3<Float>,
                mag: SIMD3<Float> = .zero,
                tempC: Float = 0,
                quat: SIMD4<Float> = .zero,
                linAccel: SIMD3<Float> = .zero,
                fsyncDelayUs: Float = 0) {
        self.timestampNs = timestampNs
        self.accel = accel
        self.gyro = gyro
        self.mag = mag
        self.tempC = tempC
        self.quat = quat
        self.linAccel = linAccel
        self.fsyncDelayUs = fsyncDelayUs
    }
}

// MARK: - Binary encoding (matches TRIMU001 v4 sample struct, 80 bytes LE)

extension ImuSample {
    /// On-disk size of a single sample (TRIMU001 v3/v4).
    public static let binarySize: Int = 80

    /// Decode one 80-byte sample from `data` at `offset`. Returns nil if
    /// the offset would read past the end of the buffer.
    public static func decode(from data: Data, at offset: Int = 0) -> ImuSample? {
        guard offset + binarySize <= data.count else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ImuSample in
            let base = raw.baseAddress!.advanced(by: offset)
            func load<T>(_ off: Int, _ type: T.Type) -> T {
                base.advanced(by: off).loadUnaligned(as: type)
            }
            return ImuSample(
                timestampNs: load(0,  UInt64.self),
                accel:    SIMD3<Float>(load(8,  Float.self), load(12, Float.self), load(16, Float.self)),
                gyro:     SIMD3<Float>(load(20, Float.self), load(24, Float.self), load(28, Float.self)),
                mag:      SIMD3<Float>(load(32, Float.self), load(36, Float.self), load(40, Float.self)),
                tempC:    load(44, Float.self),
                quat:     SIMD4<Float>(load(48, Float.self), load(52, Float.self),
                                      load(56, Float.self), load(60, Float.self)),
                linAccel: SIMD3<Float>(load(64, Float.self), load(68, Float.self), load(72, Float.self)),
                fsyncDelayUs: load(76, Float.self))
        }
    }

    /// Encode this sample into 80 little-endian bytes appended to `out`.
    public func encode(into out: inout Data) {
        var ts = timestampNs.littleEndian
        out.append(Data(bytes: &ts, count: 8))
        for v in [accel.x, accel.y, accel.z,
                  gyro.x,  gyro.y,  gyro.z,
                  mag.x,   mag.y,   mag.z,
                  tempC,
                  quat.x,  quat.y,  quat.z, quat.w,
                  linAccel.x, linAccel.y, linAccel.z,
                  fsyncDelayUs] {
            var copy = v
            out.append(Data(bytes: &copy, count: 4))
        }
    }
}
