import CoreMedia
import XCTest
@testable import TrinetSDK

/// Guards for the 0.3.5 UI-hang fixes: nothing the Record screen calls on the
/// main actor may block, and UI-facing streams must coalesce.
final class MainThreadHygieneTests: XCTestCase {

    // MARK: - ImuHistory throttling

    private func batch(startIndex: Int, count: Int, rateHz: Double = 100) -> [ImuSample] {
        (0..<count).map { k in
            let i = startIndex + k
            return ImuSample(timestampNs: 1_000_000_000 + UInt64(Double(i) / rateHz * 1e9),
                             accel: SIMD3(Float(i), 0, 0), gyro: .zero)
        }
    }

    @MainActor
    func testImuHistoryPublishesAtMostMaxRate() {
        let h = ImuHistory(durationSeconds: 1, sampleRateHz: 100, maxPublishHz: 10)
        // 1 s of stream: 30 batches of 10 samples, one per video frame.
        for f in 0..<30 {
            h.append(batch(startIndex: f * 10, count: 10), now: Double(f) / 30)
        }
        // ~10 publishes in 1 s at 10 Hz (not 30, and nowhere near one per sample).
        XCTAssertGreaterThanOrEqual(h.publishCount, 9)
        XCTAssertLessThanOrEqual(h.publishCount, 11)

        h.flush()
        XCTAssertEqual(h.totalReceived, 300)
        XCTAssertEqual(h.window.accel.count, 100)                 // capped at the window
        XCTAssertEqual(h.window.accel.last?.x, 299)               // newest sample kept
        XCTAssertEqual(h.window.accel.first?.x, 200)
        XCTAssertEqual(h.window.gyro.count, 100)
        XCTAssertEqual(h.window.accel.last?.t ?? 0, 2.99, accuracy: 1e-6)  // zero-based time
    }

    @MainActor
    func testImuHistoryLongRunKeepsExactlyOneWindow() {
        let h = ImuHistory(durationSeconds: 1, sampleRateHz: 100, maxPublishHz: 15)
        for f in 0..<500 {   // well past the 2x trim point many times over
            h.append(batch(startIndex: f * 7, count: 7), now: Double(f) / 30)
        }
        h.flush()
        XCTAssertEqual(h.window.accel.count, 100)
        XCTAssertEqual(h.window.accel.last?.x, Float(500 * 7 - 1))
        XCTAssertEqual(h.window.accel.first?.x, Float(500 * 7 - 100))
        XCTAssertEqual(h.totalReceived, 3500)
    }

    @MainActor
    func testImuHistoryTrailingPublishShowsLastBatch() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let h = ImuHistory(durationSeconds: 1, sampleRateHz: 100, maxPublishHz: 10)
        h.append(batch(startIndex: 0, count: 5), now: now)          // publishes
        h.append(batch(startIndex: 5, count: 5), now: now + 0.01)   // deferred
        XCTAssertEqual(h.window.accel.count, 5)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(h.window.accel.count, 10, "the deferred batch must still be shown")
        XCTAssertEqual(h.totalReceived, 10)
    }

    @MainActor
    func testImuHistoryResetDropsPendingPublish() async throws {
        let now = ProcessInfo.processInfo.systemUptime
        let h = ImuHistory(durationSeconds: 1, sampleRateHz: 100, maxPublishHz: 10)
        h.append(batch(startIndex: 0, count: 5), now: now)
        h.append(batch(startIndex: 5, count: 5), now: now + 0.01)
        h.reset()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(h.window.accel.isEmpty)
        XCTAssertEqual(h.totalReceived, 0)
    }

    // MARK: - BackgroundKeepAlive is non-blocking

    @MainActor
    func testKeepAliveStartStopReturnImmediately() {
        let ka = BackgroundKeepAlive.shared
        var t = CFAbsoluteTimeGetCurrent()
        ka.start()
        let startCost = CFAbsoluteTimeGetCurrent() - t
        XCTAssertTrue(ka.isActive)
        t = CFAbsoluteTimeGetCurrent()
        ka.stop()
        let stopCost = CFAbsoluteTimeGetCurrent() - t
        XCTAssertFalse(ka.isActive)
        // The audio session / engine work happens on the audio queue; the
        // calls themselves only flip a flag and enqueue.
        XCTAssertLessThan(startCost, 0.05)
        XCTAssertLessThan(stopCost, 0.05)
        ka.waitUntilIdle()
        XCTAssertFalse(ka.isActive)
    }

    // MARK: - Recording lifecycle runs off the main actor

    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("trinet-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @MainActor
    func testStartRecordingBuildsRecorderOffMain() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = TrinetLiveSession(device: TrinetDevice(host: "127.0.0.1"), codec: .h264)
        let handle = try await session.startRecording(in: dir)
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(session.recordingBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: handle.imuURL.path))

        // The recorder (files + AVAssetWriter) was created on a background
        // thread even though we called from the main actor.
        let create = ActiveOperations.shared.recentlyFinished().last { $0.name == "recorder.create" }
        XCTAssertNotNil(create)
        XCTAssertEqual(create?.onMain, false)

        session.stopRecording()
        XCTAssertFalse(session.isRecording)
        await session.stop()
    }

    func testStartRecordingAfterStopIsRejected() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = TrinetLiveSession(device: TrinetDevice(host: "127.0.0.1"), codec: .h264)
        await session.stop()
        do {
            _ = try await session.startRecording(in: dir)
            XCTFail("a stopped session must not accept a recording")
        } catch is CancellationError {
            // expected — and the sink it built was finalized, not attached
        }
        XCTAssertFalse(session.isRecording)
    }

    // MARK: - Keyframe detection used by the preview resync

    private func makeSample(notSync: Bool?) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 16,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 16, flags: 0, blockBufferOut: &block), noErr)
        var sb: CMSampleBuffer?
        var size = 16
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: nil,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb), noErr)
        let sample = try XCTUnwrap(sb)
        if let notSync,
           let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(notSync ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
        }
        return sample
    }

    func testKeyframeDetection() throws {
        XCTAssertTrue(try makeSample(notSync: nil).trinetIsKeyframe)
        XCTAssertFalse(try makeSample(notSync: true).trinetIsKeyframe)
        XCTAssertTrue(try makeSample(notSync: false).trinetIsKeyframe)
    }

    // MARK: - Diagnostics

    func testIntervalsAreTrackedAndReported() {
        let iv = TrinetDiagnostics.begin("test.interval")
        let now = TrinetDiagnostics.monotonicNs()
        XCTAssertTrue(ActiveOperations.shared.describeOpen(now: now).contains("test.interval"))
        iv.end()
        XCTAssertFalse(ActiveOperations.shared.describeOpen(now: now).contains("test.interval"))
        let overlap = ActiveOperations.shared.describeOverlapping(from: now, to: now)
        XCTAssertTrue(overlap.contains("test.interval"))
    }

    @MainActor
    func testStallDetectorSeesABlockedMainThread() {
        let detector = MainThreadStallDetector.shared
        let seen = expectation(description: "stall reported")
        seen.assertForOverFulfill = false
        detector.setStallObserver { blockedNs in
            if blockedNs >= 250_000_000 { seen.fulfill() }
        }
        detector.start(thresholdMs: 100)
        defer { detector.stop(); detector.setStallObserver(nil) }
        // Let the watchdog arm, then block the main thread.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let iv = TrinetDiagnostics.begin("test.blockMain")
        Thread.sleep(forTimeInterval: 0.4)
        iv.end()
        wait(for: [seen], timeout: 3)
    }
}
