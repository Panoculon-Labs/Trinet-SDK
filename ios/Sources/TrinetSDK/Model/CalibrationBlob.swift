// CalibrationBlob.swift — camera + IMU calibration, the typed view of the
// 200-byte binary blob the Trinet camera stores and serves.
//
// The byte layout is a cross-platform contract shared with the Android SDK and
// the host calibration tooling; the layouts are kept in lockstep and `version`
// is bumped on any change.
//
// Store & serve: the camera holds this opaque blob and returns it on request;
// it does not interpret the parameters.

import Foundation

public struct CalibrationBlob: Sendable, Equatable {
    public enum Model: UInt8, Sendable { case pinholeRadtan = 0, pinholeEquidistant = 1 }

    public var imageWidth: Int
    public var imageHeight: Int
    public var model: Model
    public var fx: Float, fy: Float, cx: Float, cy: Float
    public var distortion: [Float]          // up to 5 coefficients
    public var rCamImu: [Float]             // 9, row-major (camera↔IMU rotation)
    public var tCamImu: [Float]             // 3, metres
    public var timeshiftCamImuS: Float
    public var accelNoiseDensity: Float
    public var gyroNoiseDensity: Float
    public var accelRandomWalk: Float
    public var gyroRandomWalk: Float
    public var accelBias: [Float]           // 3, m/s^2 (VIO init)
    public var gyroBias: [Float]            // 3, rad/s (VIO init)
    public var reprojectionRmsPx: Float     // camera-calib quality (QA)
    public var gyroResidual: Float          // Kalibr gyro error mean (QA)
    public var accelResidual: Float         // Kalibr accel error mean (QA)
    public var imuRateHz: Float
    public var chipId: [UInt8]              // 16; all-zero = unbound
    public var flags: UInt16

    public static let magic: UInt32 = 0x434C4254   // "TBLC" LE
    public static let version: UInt16 = 1
    public static let blobSize = 200
    public static let maxDistortion = 5
    public static let flagChipIdValid: UInt16 = 0x0001
    public static let flagExtrinsicsValid: UInt16 = 0x0002
    public static let flagTimeshiftValid: UInt16 = 0x0004
    public static let flagBiasValid: UInt16 = 0x0008
    public static let flagQualityValid: UInt16 = 0x0010
    public static let flagTimeshiftSignTimu: UInt16 = 0x0020

    public init(imageWidth: Int, imageHeight: Int, model: Model,
                fx: Float, fy: Float, cx: Float, cy: Float,
                distortion: [Float], rCamImu: [Float], tCamImu: [Float],
                timeshiftCamImuS: Float = 0,
                accelNoiseDensity: Float = 0, gyroNoiseDensity: Float = 0,
                accelRandomWalk: Float = 0, gyroRandomWalk: Float = 0,
                accelBias: [Float] = [0, 0, 0], gyroBias: [Float] = [0, 0, 0],
                reprojectionRmsPx: Float = 0, gyroResidual: Float = 0,
                accelResidual: Float = 0, imuRateHz: Float = 0,
                chipId: [UInt8] = [UInt8](repeating: 0, count: 16),
                flags: UInt16 = 0) {
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.model = model
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.distortion = distortion; self.rCamImu = rCamImu; self.tCamImu = tCamImu
        self.timeshiftCamImuS = timeshiftCamImuS
        self.accelNoiseDensity = accelNoiseDensity; self.gyroNoiseDensity = gyroNoiseDensity
        self.accelRandomWalk = accelRandomWalk; self.gyroRandomWalk = gyroRandomWalk
        self.accelBias = accelBias; self.gyroBias = gyroBias
        self.reprojectionRmsPx = reprojectionRmsPx; self.gyroResidual = gyroResidual
        self.accelResidual = accelResidual; self.imuRateHz = imuRateHz
        self.chipId = chipId; self.flags = flags
    }
}

// MARK: - Binary encoding (200-byte packed little-endian; iOS is LE-native)

extension CalibrationBlob {
    public func encode() -> Data {
        var out = Data(); out.reserveCapacity(Self.blobSize)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func pad(_ a: [Float], _ n: Int) -> [Float] {
            Array(a.prefix(n)) + Array(repeating: Float(0), count: max(0, n - a.count))
        }

        var fl = flags
        if chipId.contains(where: { $0 != 0 }) { fl |= Self.flagChipIdValid }
        var chip = Array(chipId.prefix(16))
        chip += Array(repeating: 0, count: max(0, 16 - chip.count))

        put(Self.magic)
        put(Self.version)
        put(fl)
        out.append(contentsOf: chip)
        put(UInt16(truncatingIfNeeded: imageWidth))
        put(UInt16(truncatingIfNeeded: imageHeight))
        put(model.rawValue)
        put(UInt8(min(distortion.count, Self.maxDistortion)))
        put(UInt16(0))                                   // _rsv0
        for v in [fx, fy, cx, cy] { put(v) }
        for v in pad(distortion, Self.maxDistortion) { put(v) }
        for v in pad(rCamImu, 9) { put(v) }
        for v in pad(tCamImu, 3) { put(v) }
        put(timeshiftCamImuS)
        put(accelNoiseDensity); put(gyroNoiseDensity)
        put(accelRandomWalk); put(gyroRandomWalk)
        for v in pad(accelBias, 3) { put(v) }
        for v in pad(gyroBias, 3) { put(v) }
        put(reprojectionRmsPx); put(gyroResidual)
        put(accelResidual); put(imuRateHz)
        out.append(Data(count: 20))                      // _rsv2
        put(crc32ieee(out))                              // over the first 196 bytes
        return out
    }

    public static func decode(from data: Data) -> CalibrationBlob? {
        guard data.count == blobSize else { return nil }
        let crcCalc = crc32ieee(data.prefix(blobSize - 4))
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> CalibrationBlob? in
            let base = raw.baseAddress!
            func u8(_ o: Int) -> UInt8 { base.advanced(by: o).loadUnaligned(as: UInt8.self) }
            func u16(_ o: Int) -> UInt16 { base.advanced(by: o).loadUnaligned(as: UInt16.self) }
            func u32(_ o: Int) -> UInt32 { base.advanced(by: o).loadUnaligned(as: UInt32.self) }
            func f(_ o: Int) -> Float { base.advanced(by: o).loadUnaligned(as: Float.self) }

            guard u32(0) == magic, u16(4) == version else { return nil }
            guard u32(196) == crcCalc else { return nil }
            let flags = u16(6)
            var chip = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { chip[i] = u8(8 + i) }
            let numDist = min(Int(u8(29)), maxDistortion)
            let dist = (0..<maxDistortion).map { f(32 + 16 + $0 * 4) }
            return CalibrationBlob(
                imageWidth: Int(u16(24)), imageHeight: Int(u16(26)),
                model: Model(rawValue: u8(28)) ?? .pinholeRadtan,
                fx: f(32), fy: f(36), cx: f(40), cy: f(44),
                distortion: Array(dist.prefix(numDist)),
                rCamImu: (0..<9).map { f(68 + $0 * 4) },
                tCamImu: (0..<3).map { f(104 + $0 * 4) },
                timeshiftCamImuS: f(116),
                accelNoiseDensity: f(120), gyroNoiseDensity: f(124),
                accelRandomWalk: f(128), gyroRandomWalk: f(132),
                accelBias: (0..<3).map { f(136 + $0 * 4) },
                gyroBias: (0..<3).map { f(148 + $0 * 4) },
                reprojectionRmsPx: f(160), gyroResidual: f(164),
                accelResidual: f(168), imuRateHz: f(172),
                chipId: chip, flags: flags)
        }
    }
}

/// CRC-32/IEEE 802.3 (reflected, poly 0xEDB88320) — matches zlib.crc32,
/// java.util.zip.CRC32, and the firmware implementation.
private func crc32ieee<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
    }
    return ~crc
}
