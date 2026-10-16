import XCTest
@testable import TrinetSDK

/// Byte parity of the Swift stereo (TBLC v2) packer with the Android SDK and
/// the host packer: goldenHex is the reference 300-byte blob for goldenJson
/// (generic, no chip binding). Any layout drift fails here.
final class StereoCalibrationTests: XCTestCase {

    static let goldenHex =
        "54424c43020026000000000000000000000000000000000002000000800738040104000069f312445d0b1444214660445be0164423840e3e4eec803d11369bbd3f87813c00000000a441223c6666b63f80073804010400000f881344a678144421355b44e7c408447a5c143e3ac9633d126f97bd59e2823c000000000d16123cc976be3f482620bcb0fc7fbf7f611a3b7cfc7f3ffe0320bc9f94623bb30f61bb5b961c3b6dff7f3fe61f243da7c737bc0d2636bcb8fe7f3f718f8d3be83394bbc84b8fbbd6fa7f3ff6ce40bc7386923bf320413ccbfa7f3faafc8fbd60e3e73921e24e3ae71d273c3480373b9c50083a30621f380000000000000000000000000000000000000000000000002079673b3719153d0000c8430000000000000000000000000000000044c35b9c"

    static let goldenJson = """
    {"format": "trinet-stereo-calibration/1", "take": "golden", \
    "cameras": [{"intrinsics": {"image_size": [1920, 1080], "model": "equidistant", "fx": 587.8032908623302, "fy": 592.1775259326888, "cx": 897.0957454868687, "cy": 603.5055522313785, "distortion": [0.13917593365221084, 0.06295071332722706, -0.07578671780960758, 0.015811561453694934]}, "timeshift_cam_imu_s": 0.009903345339565866, "reprojection_rms_px": 1.425}, \
    {"intrinsics": {"image_size": [1920, 1080], "model": "equidistant", "fx": 590.1259104153468, "fy": 593.8851411520443, "cx": 876.8301343189879, "cy": 547.0766102414295, "distortion": [0.14488401331432657, 0.05561182471465249, -0.07394231952193518, 0.01597707097234926]}, "timeshift_cam_imu_s": 0.008916390015628672, "reprojection_rms_px": 1.488}], \
    "T_cam0_imu": [[-0.009774751743442112, -0.9999494512585319, 0.00235566468644064, 0.04006948495978225], [0.9999463289354942, -0.009766576465372712, 0.003457344728905065, -0.011217034147671778], [-0.003434163185193297, 0.002389332941825845, 0.9999912487673631, -0.011117470528002401], [0.0, 0.0, 0.0, 1.0]], \
    "T_cam1_cam0": [[0.9999804404596276, 0.004320077963680088, -0.004522789466242284, -0.07030613897643688], [-0.004373047644475919, 0.9999211911167168, -0.011768092879661263, 0.000442291611646366], [0.0044715939515311606, 0.011787641074995294, 0.9999205250245735, 0.0007891972051451546], [0.0, 0.0, 0.0, 1.0]], \
    "imu": {"model": "imu", "rate_hz": 400, "gyro_noise_density": 0.0028, "gyro_random_walk": 3.8e-05, "accel_noise_density": 0.0102, "accel_random_walk": 0.00052}, \
    "timeshift_sign_convention": "t_imu = t_cam + timeshift_cam_imu_s", "kalibr_gyro_error_mean": 0.003532, "kalibr_accel_error_mean": 0.036401}
    """

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testStereoJsonPacksByteIdenticalToReference() throws {
        let blob = try XCTUnwrap(StereoCalibrationBlob.fromStereoCalibrationJson(Self.goldenJson))
        let bytes = blob.encode()
        XCTAssertEqual(bytes.count, StereoCalibrationBlob.blobSize)
        XCTAssertEqual(TrinetCalibration.blobVersion(bytes), 2)
        XCTAssertEqual(hex(bytes), Self.goldenHex)
    }

    func testDecodeRoundTrip() throws {
        let bytes = try XCTUnwrap(StereoCalibrationBlob.fromStereoCalibrationJson(Self.goldenJson)).encode()
        let s = try XCTUnwrap(StereoCalibrationBlob.decode(from: bytes))
        XCTAssertEqual(s.cameras.count, 2)
        XCTAssertEqual(s.cameras[0].imageWidth, 1920)
        XCTAssertEqual(s.cameras[0].model, .pinholeEquidistant)
        XCTAssertEqual(s.cameras[0].distortion.count, 4)
        XCTAssertEqual(s.cameras[0].fx, 587.80, accuracy: 0.01)
        XCTAssertEqual(s.cameras[1].fx, 590.13, accuracy: 0.01)
        XCTAssertEqual(s.baselineM, 0.0703, accuracy: 0.0005)
        XCTAssertEqual(s.imuRateHz, 400, accuracy: 0.5)
        XCTAssertEqual(s.encode(), bytes)
    }

    func testStereoBlobIsNeverMono() throws {
        let bytes = try XCTUnwrap(StereoCalibrationBlob.fromStereoCalibrationJson(Self.goldenJson)).encode()
        XCTAssertNil(CalibrationBlob.decode(from: bytes))
        guard case .stereo? = TrinetCalibration.decode(from: bytes) else {
            return XCTFail("expected stereo")
        }
    }

    func testMonoJsonIsNotStereo() {
        XCTAssertNil(StereoCalibrationBlob.fromStereoCalibrationJson(#"{"intrinsics": {"fx": 500.0}}"#))
    }

    func testDeviceInfoFallsBackToGeneration() {
        let old = DeviceAPI.DeviceIdResponse(device_id: "00", product: "trinet", mode: "ncm", generation: "v6")
        let info = TrinetDeviceInfo(old)
        XCTAssertEqual(info.model, .proStereoGS)
        XCTAssertTrue(info.isStereo)
        XCTAssertEqual(info.canvasWidth, 3840)
        XCTAssertEqual(info.eyeWidth, 1920)

        let mono = TrinetDeviceInfo(DeviceAPI.DeviceIdResponse(device_id: "00", product: "trinet", mode: "ncm"))
        XCTAssertFalse(mono.isStereo)
        XCTAssertEqual(mono.canvasWidth, 1920)
    }

    func testDeviceIdDecodesNewFields() throws {
        let json = #"{"device_id":"0123456789abcdef0123456789abcdef","product":"trinet","mode":"ncm","generation":"v5","model":"pro-stereo","firmware":"0.5.10","build":"shipping","cameras":2,"layout":"side_by_side","canvas":{"width":3840,"height":1080}}"#
        let r = try JSONDecoder().decode(DeviceAPI.DeviceIdResponse.self, from: Data(json.utf8))
        let info = TrinetDeviceInfo(r)
        XCTAssertEqual(info.model, .proStereo)
        XCTAssertEqual(info.layout, .sideBySide)
        XCTAssertEqual(info.firmwareVersion, "0.5.10")
        XCTAssertEqual(info.canvasAspect, 32.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(info.previewAspect(for: .left), 16.0 / 9.0, accuracy: 1e-6)
    }
}
