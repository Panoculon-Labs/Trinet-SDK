import XCTest
@testable import TrinetSDK

final class RecordingTimelineTests: XCTestCase {

    // MARK: - SessionStartGate

    func testGateOpensOnFirstKeyframeOnceAudioIsKnown() {
        var g = SessionStartGate(audioGraceFrames: 15)
        XCTAssertFalse(g.shouldOpen(isKey: false, audioFormatKnown: true))   // never on a P frame
        XCTAssertTrue(g.shouldOpen(isKey: true, audioFormatKnown: true))
    }

    func testGateWaitsForAudioDuringGraceWindow() {
        var g = SessionStartGate(audioGraceFrames: 15)
        // A keyframe inside the grace window with no audio yet is skipped…
        XCTAssertFalse(g.shouldOpen(isKey: true, audioFormatKnown: false))
        for _ in 0..<5 { XCTAssertFalse(g.shouldOpen(isKey: false, audioFormatKnown: false)) }
        // …and the next keyframe after audio shows up opens it.
        XCTAssertTrue(g.shouldOpen(isKey: true, audioFormatKnown: true))
    }

    func testGateGoesVideoOnlyAfterGraceWindow() {
        var g = SessionStartGate(audioGraceFrames: 15)
        for _ in 0..<15 { XCTAssertFalse(g.shouldOpen(isKey: false, audioFormatKnown: false)) }
        XCTAssertTrue(g.graceExpired)
        XCTAssertFalse(g.shouldOpen(isKey: false, audioFormatKnown: false))  // still needs a keyframe
        XCTAssertTrue(g.shouldOpen(isKey: true, audioFormatKnown: false))
    }

    // MARK: - AudioRebaser

    private let ms: Int64 = 1_000_000

    func testConsistentClockMapsDirectlyAndDropsPreroll() {
        var r = AudioRebaser()
        let base: Int64 = 100_000 * ms
        // Pre-roll: arrived with an AU before the first written frame.
        XCTAssertEqual(r.place(audioNs: base - 40 * ms, auSofNs: base - 33 * ms, videoBaseNs: base), .drop)
        XCTAssertEqual(r.place(audioNs: base + 5 * ms, auSofNs: base, videoBaseNs: base), .write(relNs: 5 * ms))
        XCTAssertEqual(r.place(audioNs: base + 26 * ms, auSofNs: base + 33 * ms, videoBaseNs: base),
                       .write(relNs: 26 * ms))
        XCTAssertFalse(r.rebased)
        XCTAssertEqual(r.offsetNs, 0)
    }

    func testAudioPtsStaysStrictlyIncreasing() {
        var r = AudioRebaser()
        let base: Int64 = 10_000 * ms
        XCTAssertEqual(r.place(audioNs: base + 20 * ms, auSofNs: base, videoBaseNs: base), .write(relNs: 20 * ms))
        XCTAssertEqual(r.place(audioNs: base + 20 * ms, auSofNs: base, videoBaseNs: base), .drop)   // duplicate
        XCTAssertEqual(r.place(audioNs: base + 10 * ms, auSofNs: base, videoBaseNs: base), .drop)   // backwards
        XCTAssertEqual(r.place(audioNs: base + 41 * ms, auSofNs: base, videoBaseNs: base), .write(relNs: 41 * ms))
    }

    func testGrosslySkewedClockIsRebasedOntoVideo() {
        var r = AudioRebaser()
        let base: Int64 = 50_000 * ms
        let audio0: Int64 = 3_000_000 * ms          // unrelated clock, far away
        let first = r.place(audioNs: audio0, auSofNs: base + 33 * ms, videoBaseNs: base)
        XCTAssertTrue(r.rebased)
        XCTAssertTrue(r.didRebaseOnLastCall)
        XCTAssertEqual(first, .write(relNs: 33 * ms))   // aligned to its AU's frame time
        let second = r.place(audioNs: audio0 + 21 * ms, auSofNs: base + 66 * ms, videoBaseNs: base)
        XCTAssertFalse(r.didRebaseOnLastCall)
        XCTAssertEqual(second, .write(relNs: 54 * ms))  // spacing preserved
    }

    func testPersistentNegativeAudioTriggersRebase() {
        var r = AudioRebaser()
        let base: Int64 = 50_000 * ms
        // Audio 1.9 s behind (inside the 2 s skew tolerance) → every frame would
        // be dropped as before t = 0.
        let lag: Int64 = 1_900 * ms
        var t: Int64 = 0
        var wrote = false
        for i in 0..<AudioRebaser.maxConsecutiveNegative {
            let au = base + Int64(i) * 33 * ms
            let d = r.place(audioNs: au - lag, auSofNs: au, videoBaseNs: base)
            if case .write = d { wrote = true }
            t = au
        }
        XCTAssertTrue(wrote, "after the threshold audio must be re-anchored and written")
        XCTAssertTrue(r.rebased)
        // Subsequent frames continue on the new anchor.
        if case .write(let rel) = r.place(audioNs: t - lag + 21 * ms, auSofNs: t + 33 * ms, videoBaseNs: base) {
            XCTAssertEqual(rel, t - base + 21 * ms)
        } else {
            XCTFail("expected write")
        }
    }

    // MARK: - Frame time (SEI v6)

    func testFrameTimeUsesV6FrameTimestamp() {
        let s = ImuSample(timestampNs: 5_000_000, accel: .zero, gyro: .zero, mag: .zero,
                          tempC: 0, quat: SIMD4<Float>(0, 0, 0, 1), linAccel: .zero,
                          fsyncDelayUs: 100)
        let v6 = ImuBatch(samples: [s], accelFs: 2, gyroFs: 3, version: 6, frameSofTsNs: 7_777_000)
        XCTAssertEqual(TrinetSEI.frameTimeNs(of: v6), 7_777_000)
        let v6zero = ImuBatch(samples: [s], accelFs: 2, gyroFs: 3, version: 6, frameSofTsNs: 0)
        XCTAssertEqual(TrinetSEI.frameTimeNs(of: v6zero), 5_000_000)          // v5+ rule: as-is
        let v4 = ImuBatch(samples: [s], accelFs: 2, gyroFs: 3, version: 4)
        XCTAssertEqual(TrinetSEI.frameTimeNs(of: v4), 5_000_000 - 100_000)    // minus fsync delay
        XCTAssertNil(TrinetSEI.frameTimeNs(of: ImuBatch(samples: [], accelFs: 2, gyroFs: 3, version: 5)))
    }

    // MARK: - H.265 SEI (2-byte NAL header)

    func testParsesImuSeiFromH265Nal() throws {
        var payload: [UInt8] = TrinetSEI.imuUUID
        payload += [6]                          // version
        payload += [0, 0]                       // num_samples
        payload += [2, 0, 3, 0]                 // accel_fs, gyro_fs
        payload += [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01]   // frame_sof_ts_ns
        payload += [0xE8, 0x03, 0x00, 0x00]     // exposure_us = 1000
        payload += [0x01]                       // flags: MID_EXPOSURE
        payload += [0x10, 0x27, 0x00, 0x00]     // readout_time_us = 10000
        XCTAssertEqual(payload.count, TrinetSEI.headerSizeV6)
        // HEVC prefix SEI: nal_unit_type 39 → header 0x4E 0x01.
        let nal = Data([0x4E, 0x01, 5, UInt8(payload.count)] + payload + [0x80])
        guard case .imu(let b)? = TrinetSEI.parse(nalPayload: nal, codec: .h265) else {
            return XCTFail("H.265 IMU SEI not parsed")
        }
        XCTAssertEqual(b.version, 6)
        XCTAssertEqual(b.frameSofTsNs, 0x0102_0304_0506_0708)
        XCTAssertEqual(b.exposureUs, 1000)
        XCTAssertEqual(b.readoutTimeUs, 10000)
    }

    // MARK: - Stream Content-Type

    func testContentTypeDecidesCodec() {
        let h265 = "HTTP/1.1 200 OK\r\nContent-Type: video/H265\r\nConnection: close"
        XCTAssertEqual(VideoStream.codec(fromHTTPHeader: h265), .h265)
        XCTAssertEqual(VideoStream.statusCode(fromHTTPHeader: h265), 200)
        XCTAssertEqual(VideoStream.codec(fromHTTPHeader: "HTTP/1.1 200 OK\r\ncontent-type: video/h264"), .h264)
        XCTAssertEqual(VideoStream.codec(fromHTTPHeader: "HTTP/1.0 200 OK\r\nContent-Type:video/HEVC"), .h265)
        XCTAssertNil(VideoStream.codec(fromHTTPHeader: "HTTP/1.1 200 OK\r\nServer: x"))
        XCTAssertEqual(VideoStream.statusCode(fromHTTPHeader: "HTTP/1.1 503 Service Unavailable\r\n"), 503)
    }
}
