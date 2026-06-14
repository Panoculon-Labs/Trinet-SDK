import XCTest
@testable import TrinetSDK

final class ImuFormatTests: XCTestCase {

    func testImuSampleRoundtrip() throws {
        let s = ImuSample(
            timestampNs: 0x0123_4567_89AB_CDEF,
            accel: SIMD3<Float>(1.0, -2.0, 9.81),
            gyro:  SIMD3<Float>(0.1, 0.2, 0.3),
            mag:   SIMD3<Float>(40, -20, 60),
            tempC: 25.5,
            quat:  SIMD4<Float>(0, 0, 0, 1),
            linAccel: SIMD3<Float>(0, 0, 0),
            fsyncDelayUs: 123.4)
        var bytes = Data()
        s.encode(into: &bytes)
        XCTAssertEqual(bytes.count, ImuSample.binarySize)

        let decoded = ImuSample.decode(from: bytes)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.timestampNs, s.timestampNs)
        XCTAssertEqual(decoded?.accel.z, s.accel.z, accuracy: 1e-5)
        XCTAssertEqual(decoded?.tempC,  s.tempC,  accuracy: 1e-5)
        XCTAssertEqual(decoded?.fsyncDelayUs, s.fsyncDelayUs, accuracy: 1e-3)
    }

    func testImuFileHeaderLayout() throws {
        // The on-disk header must be exactly 64 bytes with the v4 fields
        // landing at the right offsets.
        let h = ImuFileWriter.Header(
            sampleRateHz: 562,
            accelFs: 2, gyroFs: 3,
            startTimeNs: 1_000_000_000,
            videoStartNs: 2_000_000_000,
            fsyncEnabled: true,
            deviceId: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10]),
            iosHostOffsetNs: -987_654_321)
        let blob = ImuFileWriter.serialize(header: h)
        XCTAssertEqual(blob.count, 64)
        // magic
        XCTAssertEqual(blob[0..<8], "TRIMU001".data(using: .ascii))
        // version = 4
        XCTAssertEqual(blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }, 4)
        // device_id at reserved[0..15] (offset 40..55)
        XCTAssertEqual(blob[40..<56].first, 0x01)
        XCTAssertEqual(blob[40..<56].last,  0x10)
        // ios_host_offset_ns at reserved[16..23] (offset 56..63)
        let off = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 56, as: Int64.self) }
        XCTAssertEqual(off, -987_654_321)
    }

    func testImuV5HeaderAndMagAge() throws {
        // A v5 sidecar header: version byte = 5, flags has the magnetometer bit
        // (0x02) set and the frame-sync bit (0x01) clear.
        let h = ImuFileWriter.Header(
            sampleRateHz: 400,
            accelFs: 2, gyroFs: 3,
            startTimeNs: 0, videoStartNs: 0,
            fsyncEnabled: false,
            deviceId: Data(count: 16),
            iosHostOffsetNs: 0,
            version: 5,
            magPresent: true)
        let blob = ImuFileWriter.serialize(header: h)
        XCTAssertEqual(blob.count, 64)
        XCTAssertEqual(blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }, 5)
        let flags = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self) }
        XCTAssertEqual(flags & 0x02, 0x02)   // magnetometer present
        XCTAssertEqual(flags & 0x01, 0x00)   // no frame-sync delay on v5

        // On v5, the trailing float reads back as mag_age_us (same slot as the
        // v3/v4 frame-sync delay).
        let s = ImuSample(timestampNs: 100, accel: .init(0, 0, 9.81), gyro: .zero,
                          mag: .init(40, -20, 60), fsyncDelayUs: 1800)
        var bytes = Data(); s.encode(into: &bytes)
        let decoded = ImuSample.decode(from: bytes)
        XCTAssertEqual(decoded?.magAgeUs, 1800, accuracy: 1e-3)
    }

    func testDeriveSofIsVersionAware() throws {
        // v4: SoF = timestamp - frame-sync delay. v5: never subtract (the
        // trailing float is mag_age_us, not a frame-sync delay).
        let s = ImuSample(timestampNs: 10_000_000, accel: .zero, gyro: .zero,
                          fsyncDelayUs: 2000)   // 2000 µs = 2_000_000 ns
        XCTAssertEqual(TrinetSEI.deriveSofNs(s, version: 4), 8_000_000)
        XCTAssertEqual(TrinetSEI.deriveSofNs(s, version: 5), 10_000_000)
    }

    func testImuTelemetryDecode() throws {
        // Synthesize the same packet shape the firmware emits.
        var d = Data()
        // Header (big-endian)
        d.append(contentsOf: [0x54, 0x52, 0x49, 0x4D]) // "TRIM"
        d.append(0x01)                                  // version
        d.append(0x00)                                  // flags
        d.append(contentsOf: [0x00, 0x02])              // sample_count = 2
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x00,
                              0x00, 0x00, 0x00, 0x2A])  // seq = 42
        d.append(contentsOf: [0x00, 0x00, 0x02, 0x32])  // rate = 562
        d.append(contentsOf: [0x00, 0x50])              // sample_size = 80
        d.append(contentsOf: [0x00, 0x00])              // reserved
        // Two samples
        let s1 = ImuSample(timestampNs: 1, accel: .init(0,0,9.81), gyro: .zero)
        let s2 = ImuSample(timestampNs: 2, accel: .init(1,0,9.81), gyro: .zero)
        s1.encode(into: &d); s2.encode(into: &d)

        guard let pkt = ImuTelemetry.decode(data: d) else {
            XCTFail("decode failed")
            return
        }
        XCTAssertEqual(pkt.seq, 42)
        XCTAssertEqual(pkt.sampleRateHz, 562)
        XCTAssertEqual(pkt.samples.count, 2)
        XCTAssertEqual(pkt.samples[1].timestampNs, 2)
        XCTAssertEqual(pkt.samples[1].accel.x, 1.0, accuracy: 1e-5)
    }
}
