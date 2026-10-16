// StereoCalibrationBlob.swift — a stereo camera's calibration: one block per
// eye plus the rigid transform between them. The typed view of the 300-byte
// TBLC v2 blob.
//
// Byte layout (little-endian, packed) — identical to the Android SDK's
// `StereoCalibrationData` / `CalibrationData.packStereoJsonV2` and the host
// Python packer (`pack_v2`); keep them in lockstep:
//
//   head (28 B)
//     0  u32  magic "TBLC" (0x434C4254)
//     4  u16  version = 2
//     6  u16  flags (same bits as v1)
//     8  u8[16] device binding id (all-zero = unbound)
//    24  u8   num_cams (1..2)
//    25  u8[3] reserved
//   camera blocks (2 x 52 B, cam0 at 28, cam1 at 80; an absent cam is zeros)
//    +0  u16 width   +2 u16 height   +4 u8 model   +5 u8 num_dist  +6 u8[2] rsv
//    +8  f32 fx, fy, cx, cy
//   +24  f32 distortion[5]
//   +44  f32 timeshift_cam_imu_s
//   +48  f32 reprojection_rms_px
//   tail
//   132  f32 R_cam0_imu[9] (row-major), 168 f32 t_cam0_imu[3] (m)
//   180  f32 R_cam1_cam0[9],            216 f32 t_cam1_cam0[3] (m)
//   228  f32 accel_noise_density, gyro_noise_density,
//            accel_random_walk, gyro_random_walk
//   244  f32 accel_bias[3], 256 f32 gyro_bias[3]
//   268  f32 gyro_residual, 272 f32 accel_residual, 276 f32 imu_rate_hz
//   280  u8[16] reserved
//   296  u32 CRC-32/IEEE over bytes 0..<296
//
// cameras[0] is the PHYSICALLY LEFT eye, which is also the left half
// (x 0..<1920) of the side-by-side video canvas.
//
// Deliberately a separate type from `CalibrationBlob`: a mono record encodes
// back into 200 bytes, so letting a stereo blob masquerade as one would make
// any read-modify-write silently drop the second eye and the baseline.

import Foundation

public struct StereoCalibrationBlob: Sendable, Equatable {

    /// One eye's intrinsics and its own camera↔IMU time offset.
    public struct CameraBlock: Sendable, Equatable {
        public var imageWidth: Int
        public var imageHeight: Int
        public var model: CalibrationBlob.Model
        public var fx: Float, fy: Float, cx: Float, cy: Float
        public var distortion: [Float]          // up to 5 coefficients
        public var timeshiftCamImuS: Float
        public var reprojectionRmsPx: Float

        public init(imageWidth: Int, imageHeight: Int, model: CalibrationBlob.Model,
                    fx: Float, fy: Float, cx: Float, cy: Float,
                    distortion: [Float], timeshiftCamImuS: Float = 0,
                    reprojectionRmsPx: Float = 0) {
            self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.model = model
            self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
            self.distortion = distortion
            self.timeshiftCamImuS = timeshiftCamImuS
            self.reprojectionRmsPx = reprojectionRmsPx
        }
    }

    /// 1 or 2 blocks; [0] = physically left eye.
    public var cameras: [CameraBlock]
    /// Camera 0 ← IMU. Rotation row-major (9), translation in metres (3).
    public var rCam0Imu: [Float]
    public var tCam0Imu: [Float]
    /// Camera 1 ← camera 0: the stereo baseline transform.
    public var rCam1Cam0: [Float]
    public var tCam1Cam0: [Float]
    public var accelNoiseDensity: Float
    public var gyroNoiseDensity: Float
    public var accelRandomWalk: Float
    public var gyroRandomWalk: Float
    public var accelBias: [Float]
    public var gyroBias: [Float]
    public var gyroResidual: Float
    public var accelResidual: Float
    public var imuRateHz: Float
    public var chipId: [UInt8]              // 16; all-zero = unbound
    public var flags: UInt16

    public static let version: UInt16 = 2
    public static let blobSize = 300
    static let camBlockBytes = 52
    static let headBytes = 28

    public init(cameras: [CameraBlock],
                rCam0Imu: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1], tCam0Imu: [Float] = [0, 0, 0],
                rCam1Cam0: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1], tCam1Cam0: [Float] = [0, 0, 0],
                accelNoiseDensity: Float = 0, gyroNoiseDensity: Float = 0,
                accelRandomWalk: Float = 0, gyroRandomWalk: Float = 0,
                accelBias: [Float] = [0, 0, 0], gyroBias: [Float] = [0, 0, 0],
                gyroResidual: Float = 0, accelResidual: Float = 0, imuRateHz: Float = 0,
                chipId: [UInt8] = [UInt8](repeating: 0, count: 16),
                flags: UInt16 = 0) {
        self.cameras = cameras
        self.rCam0Imu = rCam0Imu; self.tCam0Imu = tCam0Imu
        self.rCam1Cam0 = rCam1Cam0; self.tCam1Cam0 = tCam1Cam0
        self.accelNoiseDensity = accelNoiseDensity; self.gyroNoiseDensity = gyroNoiseDensity
        self.accelRandomWalk = accelRandomWalk; self.gyroRandomWalk = gyroRandomWalk
        self.accelBias = accelBias; self.gyroBias = gyroBias
        self.gyroResidual = gyroResidual; self.accelResidual = accelResidual
        self.imuRateHz = imuRateHz
        self.chipId = chipId; self.flags = flags
    }

    /// Distance between the eyes in metres — the headline stereo number.
    public var baselineM: Float {
        let t = tCam1Cam0 + [0, 0, 0]
        return (t[0] * t[0] + t[1] * t[1] + t[2] * t[2]).squareRoot()
    }

    /// The left eye projected into the mono `CalibrationBlob` shape, so
    /// single-camera consumers work unchanged on a stereo camera. Only camera 0
    /// is offered: its extrinsics are exactly the stored T_cam0_imu. Camera 1's
    /// camera↔IMU transform would need composing with T_cam1_cam0, whose
    /// convention can't be verified from the blob alone — use `cameras[1]` with
    /// `rCam1Cam0`/`tCam1Cam0` for right-eye work.
    public func leftEyeAsMono() -> CalibrationBlob? {
        guard let c = cameras.first else { return nil }
        return CalibrationBlob(
            imageWidth: c.imageWidth, imageHeight: c.imageHeight, model: c.model,
            fx: c.fx, fy: c.fy, cx: c.cx, cy: c.cy,
            distortion: c.distortion, rCamImu: rCam0Imu, tCamImu: tCam0Imu,
            timeshiftCamImuS: c.timeshiftCamImuS,
            accelNoiseDensity: accelNoiseDensity, gyroNoiseDensity: gyroNoiseDensity,
            accelRandomWalk: accelRandomWalk, gyroRandomWalk: gyroRandomWalk,
            accelBias: accelBias, gyroBias: gyroBias,
            reprojectionRmsPx: c.reprojectionRmsPx, gyroResidual: gyroResidual,
            accelResidual: accelResidual, imuRateHz: imuRateHz,
            chipId: chipId, flags: flags)
    }
}

// MARK: - Binary encoding (300-byte packed little-endian; iOS is LE-native)

extension StereoCalibrationBlob {
    public func encode() -> Data {
        var out = Data(); out.reserveCapacity(Self.blobSize)
        func put<T>(_ v: T) { var x = v; withUnsafeBytes(of: &x) { out.append(contentsOf: $0) } }
        func pad(_ a: [Float], _ n: Int) -> [Float] {
            Array(a.prefix(n)) + Array(repeating: Float(0), count: max(0, n - a.count))
        }

        var fl = flags
        if chipId.contains(where: { $0 != 0 }) { fl |= CalibrationBlob.flagChipIdValid }
        var chip = Array(chipId.prefix(16))
        chip += Array(repeating: 0, count: max(0, 16 - chip.count))
        let numCams = min(cameras.count, 2)

        // head (28 B)
        put(CalibrationBlob.magic)
        put(Self.version)
        put(fl)
        out.append(contentsOf: chip)
        put(UInt8(numCams))
        out.append(Data(count: 3))

        // camera blocks (2 x 52 B; absent cam = zeros)
        for i in 0..<2 {
            guard i < numCams else { out.append(Data(count: Self.camBlockBytes)); continue }
            let c = cameras[i]
            put(UInt16(truncatingIfNeeded: c.imageWidth))
            put(UInt16(truncatingIfNeeded: c.imageHeight))
            put(c.model.rawValue)
            put(UInt8(min(c.distortion.count, CalibrationBlob.maxDistortion)))
            put(UInt16(0))                                   // reserved
            for v in [c.fx, c.fy, c.cx, c.cy] { put(v) }
            for v in pad(c.distortion, CalibrationBlob.maxDistortion) { put(v) }
            put(c.timeshiftCamImuS)
            put(c.reprojectionRmsPx)
        }

        // tail
        for v in pad(rCam0Imu, 9) { put(v) }
        for v in pad(tCam0Imu, 3) { put(v) }
        for v in pad(rCam1Cam0, 9) { put(v) }
        for v in pad(tCam1Cam0, 3) { put(v) }
        put(accelNoiseDensity); put(gyroNoiseDensity)
        put(accelRandomWalk); put(gyroRandomWalk)
        for v in pad(accelBias, 3) { put(v) }
        for v in pad(gyroBias, 3) { put(v) }
        put(gyroResidual); put(accelResidual); put(imuRateHz)
        out.append(Data(count: 16))                          // reserved
        put(crc32ieee(out))                                  // over the first 296 bytes
        return out
    }

    /// Decode a 300-byte TBLC v2 blob. nil unless size, magic, version and CRC
    /// all check out.
    public static func decode(from data: Data) -> StereoCalibrationBlob? {
        guard TrinetCalibration.blobVersion(data) == Int(version) else { return nil }
        let bytes = Data(data)   // re-base so offsets start at 0
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> StereoCalibrationBlob? in
            let base = raw.baseAddress!
            func u8(_ o: Int) -> UInt8 { base.advanced(by: o).loadUnaligned(as: UInt8.self) }
            func u16(_ o: Int) -> UInt16 { base.advanced(by: o).loadUnaligned(as: UInt16.self) }
            func f(_ o: Int) -> Float { base.advanced(by: o).loadUnaligned(as: Float.self) }
            func fa(_ o: Int, _ n: Int) -> [Float] { (0..<n).map { f(o + $0 * 4) } }

            let flags = u16(6)
            let chip = (0..<16).map { u8(8 + $0) }
            let numCams = Int(u8(24))

            var cams: [CameraBlock] = []
            for i in 0..<min(numCams, 2) {
                let o = headBytes + i * camBlockBytes
                let nDist = min(Int(u8(o + 5)), CalibrationBlob.maxDistortion)
                cams.append(CameraBlock(
                    imageWidth: Int(u16(o)), imageHeight: Int(u16(o + 2)),
                    model: u8(o + 4) == 1 ? .pinholeEquidistant : .pinholeRadtan,
                    fx: f(o + 8), fy: f(o + 12), cx: f(o + 16), cy: f(o + 20),
                    distortion: Array(fa(o + 24, CalibrationBlob.maxDistortion).prefix(nDist)),
                    timeshiftCamImuS: f(o + 44),
                    reprojectionRmsPx: f(o + 48)))
            }

            return StereoCalibrationBlob(
                cameras: cams,
                rCam0Imu: fa(132, 9), tCam0Imu: fa(168, 3),
                rCam1Cam0: fa(180, 9), tCam1Cam0: fa(216, 3),
                accelNoiseDensity: f(228), gyroNoiseDensity: f(232),
                accelRandomWalk: f(236), gyroRandomWalk: f(240),
                accelBias: fa(244, 3), gyroBias: fa(256, 3),
                gyroResidual: f(268), accelResidual: f(272), imuRateHz: f(276),
                chipId: chip, flags: flags)
        }
    }
}

// MARK: - stereo calibration JSON → blob

extension StereoCalibrationBlob {
    /// Parse a stereo `trinet-stereo-calibration/1` JSON (`cameras`: [cam0,
    /// cam1], cam0 = the physically LEFT eye) — same schema and defaults as the
    /// Android SDK and the host packer. Returns nil when the JSON has no
    /// `cameras` array (not a stereo JSON — try `CalibrationBlob.fromCalibrationJson`)
    /// or a present `T_cam0_imu` / `T_cam1_cam0` isn't a 3x4 / 4x4 matrix.
    /// The result is generic (binding id zero, unbound) unless `chipId` is given.
    public static func fromStereoCalibrationJson(
        _ json: String,
        chipId: [UInt8] = [UInt8](repeating: 0, count: 16)
    ) -> StereoCalibrationBlob? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return fromStereoCalibrationJson(root, chipId: chipId)
    }

    /// True if a parsed JSON object looks like a stereo calibration (has a
    /// non-empty `cameras` array).
    public static func isStereoCalibrationJson(_ root: [String: Any]) -> Bool {
        ((root["cameras"] as? [Any])?.isEmpty == false)
    }

    /// Same as the `String` overload, on an already-parsed JSON object.
    public static func fromStereoCalibrationJson(
        _ root: [String: Any],
        chipId: [UInt8] = [UInt8](repeating: 0, count: 16)
    ) -> StereoCalibrationBlob? {
        guard let camsJson = root["cameras"] as? [Any], !camsJson.isEmpty else { return nil }
        func num(_ d: [String: Any]?, _ k: String) -> NSNumber? { d?[k] as? NSNumber }
        func dbl(_ d: [String: Any]?, _ k: String) -> Double { num(d, k)?.doubleValue ?? 0 }
        func farr(_ a: Any?) -> [Float] { ((a as? [Any]) ?? []).map { ($0 as? NSNumber)?.floatValue ?? 0 } }
        func modelCode(_ name: String) -> CalibrationBlob.Model {
            let n = name.lowercased()
            return ["equi", "fisheye", "kannala", "kb"].contains(where: { n.contains($0) })
                ? .pinholeEquidistant : .pinholeRadtan
        }
        /// R (row-major 9) + t (3) from a 3x4 / 4x4 nested matrix. Identity/zero
        /// when the key is absent; nil (whole parse fails) when malformed.
        func rt(_ key: String) -> (r: [Float], t: [Float])? {
            guard let m = root[key] else { return ([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]) }
            guard let rows = m as? [Any], rows.count >= 3 else { return nil }
            var r = [Float](repeating: 0, count: 9), t = [Float](repeating: 0, count: 3)
            for i in 0..<3 {
                guard let row = rows[i] as? [Any], row.count >= 4 else { return nil }
                for j in 0..<3 { r[i * 3 + j] = (row[j] as? NSNumber)?.floatValue ?? 0 }
                t[i] = (row[3] as? NSNumber)?.floatValue ?? 0
            }
            return (r, t)
        }

        let numCams = min(camsJson.count, 2)
        var cams: [CameraBlock] = []
        var anyTs = false
        for i in 0..<numCams {
            let cj = (camsJson[i] as? [String: Any]) ?? [:]
            let intr = (cj["intrinsics"] as? [String: Any]) ?? cj
            var w = 1920, h = 1080
            if let size = (intr["image_size"] as? [Any]) ?? (intr["resolution"] as? [Any]), size.count >= 2 {
                w = (size[0] as? NSNumber)?.intValue ?? w
                h = (size[1] as? NSNumber)?.intValue ?? h
            }
            let ts = Float(dbl(cj, "timeshift_cam_imu_s"))
            if ts != 0 { anyTs = true }
            let reproj = num(cj, "reprojection_rms_px")?.floatValue
                ?? Float(dbl(intr, "reprojection_rms_px"))
            cams.append(CameraBlock(
                imageWidth: w, imageHeight: h,
                model: modelCode(intr["model"] as? String ?? "radtan"),
                fx: Float(dbl(intr, "fx")), fy: Float(dbl(intr, "fy")),
                cx: Float(dbl(intr, "cx")), cy: Float(dbl(intr, "cy")),
                distortion: Array(farr(intr["distortion"]).prefix(CalibrationBlob.maxDistortion)),
                timeshiftCamImuS: ts, reprojectionRmsPx: reproj))
        }

        guard let t0 = rt("T_cam0_imu"), let t10 = rt("T_cam1_cam0") else { return nil }

        // IMU noise / bias / rate — same normalizer as the mono path.
        let imu = root["imu"] as? [String: Any]
        let nm = imu?["noise_model"] as? [String: Any]
        func imuNoise(_ names: [String]) -> Float {
            for src in [nm, imu].compactMap({ $0 }) {
                for key in names { if let v = src[key] as? NSNumber { return v.floatValue } }
            }
            return 0
        }
        var accelBias: [Float] = [0, 0, 0], gyroBias: [Float] = [0, 0, 0]
        var hasBias = false
        if let ab = (imu?["accel_bias_m_s2"] as? [Any]) ?? (imu?["accel_bias"] as? [Any]), ab.count >= 3 {
            accelBias = Array(farr(ab).prefix(3)); hasBias = true
        }
        if let gb = (imu?["gyro_bias_rad_s"] as? [Any]) ?? (imu?["gyro_bias"] as? [Any]), gb.count >= 3 {
            gyroBias = Array(farr(gb).prefix(3)); hasBias = true
        }
        var imuRate: Float = 0
        for key in ["sample_rate_hz", "rate_hz"] {
            if let v = num(imu, key) { imuRate = v.floatValue; break }
        }

        var fl: UInt16 = 0
        if chipId.contains(where: { $0 != 0 }) { fl |= CalibrationBlob.flagChipIdValid }
        if root["T_cam0_imu"] != nil { fl |= CalibrationBlob.flagExtrinsicsValid }
        if anyTs { fl |= CalibrationBlob.flagTimeshiftValid }
        if hasBias { fl |= CalibrationBlob.flagBiasValid }
        if ((root["timeshift_sign_convention"] as? String) ?? "").contains("t_imu = t_cam +") {
            fl |= CalibrationBlob.flagTimeshiftSignTimu
        }

        return StereoCalibrationBlob(
            cameras: cams,
            rCam0Imu: t0.r, tCam0Imu: t0.t,
            rCam1Cam0: t10.r, tCam1Cam0: t10.t,
            accelNoiseDensity: imuNoise(["accel_noise_density", "accelerometer_noise_density"]),
            gyroNoiseDensity: imuNoise(["gyro_noise_density", "gyroscope_noise_density"]),
            accelRandomWalk: imuNoise(["accel_random_walk", "accelerometer_random_walk"]),
            gyroRandomWalk: imuNoise(["gyro_random_walk", "gyroscope_random_walk"]),
            accelBias: accelBias, gyroBias: gyroBias,
            gyroResidual: Float(dbl(root, "kalibr_gyro_error_mean")),
            accelResidual: Float(dbl(root, "kalibr_accel_error_mean")),
            imuRateHz: imuRate,
            chipId: Array((chipId + [UInt8](repeating: 0, count: 16)).prefix(16)),
            flags: fl)
    }
}

// MARK: - Mono-or-stereo entry point

/// Errors raised by calibration helpers.
public enum CalibrationError: Error, LocalizedError {
    case invalidBlob
    public var errorDescription: String? {
        switch self {
        case .invalidBlob: "Not a valid calibration blob (expected 200-byte mono or 300-byte stereo)."
        }
    }
}

/// A camera's calibration, whichever kind it has — the entry point when you
/// don't know in advance whether a mono or a stereo camera is attached.
public enum TrinetCalibration: Sendable, Equatable {
    case mono(CalibrationBlob)
    case stereo(StereoCalibrationBlob)

    public var isStereo: Bool { if case .stereo = self { return true }; return false }

    /// Structural validity of a raw TBLC blob: size + magic + version + CRC.
    /// Returns the blob version (1 = mono, 2 = stereo) or 0 when invalid.
    public static func blobVersion(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        guard bytes.count == CalibrationBlob.blobSize || bytes.count == StereoCalibrationBlob.blobSize
        else { return 0 }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> UInt32 {
            UInt32(bytes[o]) | (UInt32(bytes[o + 1]) << 8) | (UInt32(bytes[o + 2]) << 16) | (UInt32(bytes[o + 3]) << 24)
        }
        guard u32(0) == CalibrationBlob.magic else { return 0 }
        let v = Int(u16(4))
        let sizeOk = (v == Int(CalibrationBlob.version) && bytes.count == CalibrationBlob.blobSize)
            || (v == Int(StereoCalibrationBlob.version) && bytes.count == StereoCalibrationBlob.blobSize)
        guard sizeOk else { return 0 }
        let n = bytes.count
        return crc32ieee(bytes[0..<(n - 4)]) == u32(n - 4) ? v : 0
    }

    /// Decode any valid TBLC blob: 200-byte mono or 300-byte stereo. nil when
    /// structurally invalid.
    public static func decode(from data: Data) -> TrinetCalibration? {
        switch blobVersion(data) {
        case Int(CalibrationBlob.version):
            return CalibrationBlob.decode(from: Data(data)).map { .mono($0) }
        case Int(StereoCalibrationBlob.version):
            return StereoCalibrationBlob.decode(from: data).map { .stereo($0) }
        default:
            return nil
        }
    }
}
