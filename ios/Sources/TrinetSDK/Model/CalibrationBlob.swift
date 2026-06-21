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

// MARK: - calibration.json → blob

extension CalibrationBlob {
    /// Parse a calibration `calibration.json` (as produced by the host
    /// calibration tooling) into a blob, ready to upload via
    /// `TrinetDevice.setCalibration`. Mirrors the Android SDK + Python packer
    /// (same schema, same aliases). Returns nil if the file has no usable camera
    /// intrinsics.
    ///
    /// Accepts the schema variants that have shipped across calibration versions:
    /// intrinsics at top-level `intrinsics{}` (model `fisheye`→equidistant) or
    /// nested under `camera{}`; timeshift as `extrinsics.timeshift_cam_imu_s`
    /// **or** `…_sec` (or top-level); IMU noise directly under `imu{}` **or**
    /// under `imu.noise_model{}`, short (`accel_noise_density`) or long
    /// (`accelerometer_noise_density`) names; biases + sample rate + Kalibr
    /// residuals when present.
    public static func fromCalibrationJson(_ json: String) -> CalibrationBlob? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return fromCalibrationJson(root)
    }

    /// Same as the `String` overload, on an already-parsed JSON object.
    public static func fromCalibrationJson(_ root: [String: Any]) -> CalibrationBlob? {
        func obj(_ d: [String: Any]?, _ k: String) -> [String: Any]? { d?[k] as? [String: Any] }
        func arr(_ d: [String: Any]?, _ k: String) -> [Any]? { d?[k] as? [Any] }
        func num(_ d: [String: Any]?, _ k: String) -> NSNumber? { d?[k] as? NSNumber }
        func dbl(_ d: [String: Any]?, _ k: String) -> Double { num(d, k)?.doubleValue ?? 0 }
        func str(_ d: [String: Any]?, _ k: String, _ def: String = "") -> String { d?[k] as? String ?? def }
        func farr(_ a: [Any]?) -> [Float] { (a ?? []).map { ($0 as? NSNumber)?.floatValue ?? 0 } }
        func iAt(_ a: [Any], _ i: Int, _ def: Int) -> Int { (a[i] as? NSNumber)?.intValue ?? def }
        // R(3x3) + translation column out of a 3x4 / 4x4 nested transform.
        func applyTMat(_ m: [Any], _ r: inout [Float], _ t: inout [Float]) {
            var rf = [Float](repeating: 0, count: 9)
            var tf = [Float](repeating: 0, count: 3)
            for i in 0..<min(3, m.count) {
                let row = (m[i] as? [Any]) ?? []
                for j in 0..<3 where j < row.count { rf[i * 3 + j] = (row[j] as? NSNumber)?.floatValue ?? 0 }
                if row.count >= 4 { tf[i] = (row[3] as? NSNumber)?.floatValue ?? 0 }
            }
            r = rf; t = tf
        }
        func modelCode(_ name: String) -> Int {
            let n = name.lowercased()
            return ["equi", "fisheye", "kannala", "kb"].contains(where: { n.contains($0) }) ? 1 : 0
        }

        var fx = 0.0, fy = 0.0, cx = 0.0, cy = 0.0
        var modelName = "radtan"
        var dist: [Float] = []
        var w = 1920, h = 1080

        let intr = obj(root, "intrinsics")
        if let intr = intr {
            fx = dbl(intr, "fx"); fy = dbl(intr, "fy"); cx = dbl(intr, "cx"); cy = dbl(intr, "cy")
            modelName = str(intr, "model", "radtan")
            dist = farr(arr(intr, "distortion"))
            if let size = arr(intr, "image_size") ?? arr(intr, "resolution"), size.count >= 2 {
                w = iAt(size, 0, w); h = iAt(size, 1, h)
            }
        } else if let cam = obj(root, "camera") {
            let ci = obj(cam, "intrinsics")
            fx = dbl(ci, "fx"); fy = dbl(ci, "fy"); cx = dbl(ci, "cx"); cy = dbl(ci, "cy")
            let d = obj(cam, "distortion")
            modelName = str(d, "model", "radtan")
            dist = farr(arr(d, "coeffs"))
            if let res = arr(cam, "resolution"), res.count >= 2 { w = iAt(res, 0, w); h = iAt(res, 1, h) }
        } else {
            return nil
        }

        var r: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        var t: [Float] = [0, 0, 0]
        var timeshift: Float = 0
        var hasExt = false, hasTs = false

        let ext = obj(root, "extrinsics")
        if let ext = ext {
            if let rr = arr(ext, "R_cam_imu"), let tt = arr(ext, "t_cam_imu_m") {
                var rf = [Float](repeating: 0, count: 9)
                for i in 0..<min(3, rr.count) {
                    let row = (rr[i] as? [Any]) ?? []
                    for j in 0..<3 where j < row.count { rf[i * 3 + j] = (row[j] as? NSNumber)?.floatValue ?? 0 }
                }
                r = rf; t = farr(tt); hasExt = true
            } else if let tmat = arr(ext, "T_cam_imu") {
                applyTMat(tmat, &r, &t); hasExt = true
            }
            for tk in ["timeshift_cam_imu_s", "timeshift_cam_imu_sec"] {
                if let v = num(ext, tk) { timeshift = v.floatValue; hasTs = true; break }
            }
        }
        if !hasExt, let tmat = arr(root, "T_cam_imu") { applyTMat(tmat, &r, &t); hasExt = true }
        if !hasTs {
            for tk in ["timeshift_cam_imu_s", "timeshift_cam_imu_sec"] {
                if let v = num(root, tk) { timeshift = v.floatValue; hasTs = true; break }
            }
        }

        // IMU noise: directly under imu{} OR nested under imu.noise_model{},
        // with short (accel_*) or long (accelerometer_*) names.
        let imu = obj(root, "imu")
        let nm = obj(imu, "noise_model")
        func imuNoise(_ names: [String]) -> Double {
            for src in [nm, imu].compactMap({ $0 }) {
                for key in names { if let v = src[key] as? NSNumber { return v.doubleValue } }
            }
            return 0
        }
        let aNd = imuNoise(["accel_noise_density", "accelerometer_noise_density"])
        let gNd = imuNoise(["gyro_noise_density", "gyroscope_noise_density"])
        let aRw = imuNoise(["accel_random_walk", "accelerometer_random_walk"])
        let gRw = imuNoise(["gyro_random_walk", "gyroscope_random_walk"])

        // IMU biases (VIO init) + sample rate.
        var accelBias: [Float] = [0, 0, 0], gyroBias: [Float] = [0, 0, 0]
        var hasBias = false
        if let ab = arr(imu, "accel_bias_m_s2") ?? arr(imu, "accel_bias"), ab.count >= 3 {
            accelBias = farr(ab); hasBias = true
        }
        if let gb = arr(imu, "gyro_bias_rad_s") ?? arr(imu, "gyro_bias"), gb.count >= 3 {
            gyroBias = farr(gb); hasBias = true
        }
        let imuRate = Float(dbl(imu, "sample_rate_hz"))

        // Calibration-quality residuals (QA).
        var reproj = Float(dbl(intr, "reprojection_rms_px"))
        if reproj == 0 { reproj = Float(dbl(ext, "kalibr_reprojection_error_mean_px")) }
        let gyroResid = Float(dbl(ext, "kalibr_gyro_error_mean"))
        let accelResid = Float(dbl(ext, "kalibr_accel_error_mean"))
        let hasQuality = reproj != 0 || gyroResid != 0 || accelResid != 0
        let signTimu = str(ext, "timeshift_sign_convention").contains("t_imu = t_cam +")

        var fl: UInt16 = 0
        if hasExt { fl |= flagExtrinsicsValid }
        if hasTs { fl |= flagTimeshiftValid }
        if hasBias { fl |= flagBiasValid }
        if hasQuality { fl |= flagQualityValid }
        if signTimu { fl |= flagTimeshiftSignTimu }

        return CalibrationBlob(
            imageWidth: w, imageHeight: h,
            model: modelCode(modelName) == 1 ? .pinholeEquidistant : .pinholeRadtan,
            fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy),
            distortion: dist, rCamImu: r, tCamImu: t, timeshiftCamImuS: timeshift,
            accelNoiseDensity: Float(aNd), gyroNoiseDensity: Float(gNd),
            accelRandomWalk: Float(aRw), gyroRandomWalk: Float(gRw),
            accelBias: accelBias, gyroBias: gyroBias,
            reprojectionRmsPx: reproj, gyroResidual: gyroResid,
            accelResidual: accelResid, imuRateHz: imuRate,
            flags: fl)
    }
}
