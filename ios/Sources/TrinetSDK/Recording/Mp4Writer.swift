// Mp4Writer.swift — turns the device's Annex-B H.264/H.265 byte stream
// into an MP4 file via AVAssetWriter.
//
// AVAssetWriter expects sample buffers, not raw NAL units. We:
//   1. Collect VPS+SPS+PPS at stream start to build a CMVideoFormatDescription
//   2. Convert each picture-slice NAL into a CMSampleBuffer with AVCC framing
//      (length-prefix instead of start code) and the right PTS
//   3. Feed buffers via AVAssetWriterInput.append(_:)
//
// PTS comes from a configured frame rate plus a per-frame counter. If the
// SDK ever switches to a wire protocol that carries per-frame timestamps,
// swap the counter for the real value.

import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

public enum Mp4WriterError: Error {
    case unsupportedCodec
    case missingParameterSets
    case formatDescription(OSStatus)
    case sessionStart(OSStatus)
    case sampleBuffer(OSStatus)
    case writerFailed(any Error)
}

public final class Mp4Writer {
    public let url: URL
    public let codec: VideoCodec
    public let width: Int
    public let height: Int
    public let fps: Double

    private let writer: AVAssetWriter
    // Created lazily once we have the CMVideoFormatDescription — a passthrough
    // input (outputSettings: nil) made WITHOUT a sourceFormatHint never reports
    // isReadyForMoreMediaData=true, so every appended frame is silently
    // dropped (the empty-recording bug). We build it with the format hint in
    // startSessionIfNeeded().
    private var input: AVAssetWriterInput?
    private var formatDesc: CMVideoFormatDescription?
    private var sessionStarted = false
    private var sawKeyframe = false               // gate first sample on an IDR
    private var finished = false                  // set by finish(); blocks late appends
    private var firstSofNs: UInt64?               // device capture time of the 1st written frame
    private var appendedSamples = 0               // diagnostics: samples actually written
    private var droppedNotReady = 0               // diagnostics: dropped (input not ready)
    private var vclSeen = 0                        // diagnostics: VCL NALs reaching appendVCL
    private var frameIndex: Int64 = 0
    private let timeScale: CMTimeScale = 90_000   // standard 90 kHz

    // Serializes append() (video thread) against finish() (teardown task) so
    // the AVAssetWriter's state and our flags are never read across threads
    // mid-mutation. NOT held across the finishWriting() await (we snapshot
    // under the lock, release, then call AVFoundation).
    private let stateLock = NSLock()

    // Parameter set NALs accumulated during stream start. For H.264 we
    // need SPS+PPS; for H.265 we additionally need VPS.
    private var vps: Data?    // h265 only
    private var sps: Data?
    private var pps: Data?

    // Optional AAC audio track. The audio format is learned from the first ADTS
    // frame; the input must be added BEFORE startWriting(), so the session is
    // NOT opened on the first video frame: `gate` holds it closed until either
    // the audio format is known or a short grace window (~0.5 s of video) has
    // passed with no audio at all (camera without a microphone → video-only
    // file). Video frames that arrive while the gate is closed are dropped —
    // the recording simply starts a fraction of a second later, always on a
    // keyframe. Audio frames are buffered (bounded) and flushed once the video
    // clock origin (firstSofNs) is known; `rebaser` places them on the video
    // timeline.
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    /// `auSofNs`: frame time of the video access unit this audio arrived with;
    /// nil until that AU's picture is seen.
    private var pendingAudio: [(adts: Data, ptsUs: Int64, auSofNs: UInt64?)] = []
    private static let maxPendingAudio = 256          // ≈5 s of AAC at 48 kHz
    private var gate = SessionStartGate()
    private var rebaser = AudioRebaser()
    private var appendedAudio = 0
    private var droppedLateAudio = 0                  // audio after a video-only start

    public init(url: URL, codec: VideoCodec, width: Int, height: Int, fps: Double) throws {
        self.url = url
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let fileType: AVFileType = .mp4
        self.writer = try AVAssetWriter(url: url, fileType: fileType)
        // The input is created in startSessionIfNeeded(), once formatDesc
        // exists, so it can be given a sourceFormatHint (see property note).
    }

    /// Process one NAL coming off VideoStream. Returns true once the writer
    /// has started consuming picture slices (i.e. headers were collected
    /// and the AVAssetWriter session is open).
    @discardableResult
    public func append(nal: VideoStream.NALUnit, seiPrefix: [Data] = []) throws -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        // Once finalized, never touch the writer again — appending after
        // markAsFinished throws an Obj-C exception that would SIGABRT.
        if finished { return false }
        switch codec {
        case .h264: return try appendH264(nal.payload, timing: nal.timing, seiPrefix: seiPrefix)
        case .h265: return try appendH265(nal.payload, timing: nal.timing, seiPrefix: seiPrefix)
        }
    }

    /// Submit one self-describing ADTS AAC-LC frame with its CLOCK_MONOTONIC
    /// presentation time (µs) — the same clock as the video frames' SoF. Learns
    /// the audio format from the first frame (so the audio track can be added at
    /// session start) and rebases onto the video timeline. Safe no-op once the
    /// session opened video-only (audio arrived too late to add a track).
    public func appendAudio(adts: Data, ptsUs: Int64) {
        stateLock.lock(); defer { stateLock.unlock() }
        if finished { return }
        if audioFormat == nil { audioFormat = AACSupport.formatDescription(from: adts) }
        guard audioFormat != nil else { return }
        // Once started video-only, we can't add a track; drop.
        if sessionStarted && audioInput == nil {
            if droppedLateAudio == 0 {
                NSLog("TrinetSDK Mp4Writer: audio arrived after a video-only start — not recorded")
            }
            droppedLateAudio += 1
            return
        }
        pendingAudio.append((adts, ptsUs, nil))
        if pendingAudio.count > Self.maxPendingAudio {
            pendingAudio.removeFirst(pendingAudio.count - Self.maxPendingAudio)
        }
        drainPendingAudio()
    }

    /// Stamp buffered audio that hasn't been tied to a picture yet with the
    /// frame time of the access unit it arrived with (the audio SEI precedes
    /// that AU's slices). Caller holds stateLock.
    private func anchorPendingAudio(toAccessUnitSof sof: UInt64) {
        for i in pendingAudio.indices.reversed() {
            if pendingAudio[i].auSofNs != nil { break }
            pendingAudio[i].auSofNs = sof
        }
    }

    /// Write buffered audio once the session is open and the video clock origin
    /// (firstSofNs) is known, so audio rebases onto the video timeline. Frames
    /// whose access unit hasn't been seen yet stay buffered. Caller holds
    /// stateLock.
    private func drainPendingAudio() {
        guard sessionStarted, let input = audioInput, let format = audioFormat,
              let base = firstSofNs else { return }
        guard writer.status == .writing else { return }
        var consumed = 0
        for f in pendingAudio {
            guard let auSof = f.auSofNs else { break }       // AU not seen yet
            guard input.isReadyForMoreMediaData else { break }
            consumed += 1
            let decision = rebaser.place(audioNs: f.ptsUs &* 1000,
                                         auSofNs: Int64(bitPattern: auSof),
                                         videoBaseNs: Int64(bitPattern: base))
            if rebaser.didRebaseOnLastCall {
                NSLog("TrinetSDK Mp4Writer: audio clock inconsistent with video (audio \(f.ptsUs) us vs frame \(auSof / 1000) us) — rebasing audio onto the video timeline")
            }
            guard case .write(let rel) = decision else { continue }
            let pts = CMTime(value: CMTimeValue(rel), timescale: 1_000_000_000)
            if let sb = AACSupport.sampleBuffer(adts: f.adts, format: format, pts: pts) {
                input.append(sb)
                appendedAudio += 1
            }
        }
        if consumed > 0 { pendingAudio.removeFirst(consumed) }
    }

    /// Finalize the file. Runs in a detached task. We finalize ONLY via
    /// finishWriting() and ONLY when the snapshotted status is .writing —
    /// never input.markAsFinished(), which raised an uncatchable Obj-C
    /// NSException ("status is 0") on abrupt teardown and SIGABRT'd the app.
    /// finishWriting() marks unfinished inputs as finished itself, so the file
    /// still completes correctly without the throwing call.
    public func finish() async {
        // Snapshot everything under the lock so we act on one coherent view
        // of (finished, status, sessionStarted) — never a half-mutated state
        // straddling the video thread's append().
        stateLock.lock()
        if finished { stateLock.unlock(); return }   // idempotent
        finished = true
        let status = writer.status
        let started = sessionStarted
        // Diagnostic marker so we can confirm THIS build is running and see
        // exactly how many frames the recorder actually wrote.
        let diag = "codec=\(codec.rawValue) status=\(status.rawValue) started=\(started) sawKeyframe=\(sawKeyframe) vclSeen=\(vclSeen) appended=\(appendedSamples) droppedNotReady=\(droppedNotReady) audioTrack=\(audioInput != nil) audio=\(appendedAudio) audioRebased=\(rebaser.rebased) droppedLateAudio=\(droppedLateAudio)"
        stateLock.unlock()

        NSLog("TrinetSDK Mp4Writer.finish \(diag)")

        // Only a writer in .writing with an open session can be finalized.
        guard status == .writing, started else {
            if status == .writing { writer.cancelWriting() }  // started==false → no frames
            if status != .completed { discardEmptyFile() }
            return
        }

        // IMPORTANT: do NOT call input.markAsFinished() here. On abrupt
        // teardown (USB yanked mid-recording) the input's view of the writer
        // status can be torn and markAsFinished raises an Obj-C NSException
        // ("status is 0") that Swift can't catch → SIGABRT. finishWriting()
        // already "marks all unfinished inputs as finished and completes the
        // file", so calling it alone both avoids the throwing call and still
        // produces a valid, playable MP4.
        await writer.finishWriting()
        if writer.status != .completed { discardEmptyFile() }
    }

    private func discardEmptyFile() {
        // Only remove if it's our URL and clearly not a finalized movie
        // (no moov → tiny / unplayable). Safe: we created it this session.
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - H.264

    private func appendH264(_ nal: Data, timing: FrameTiming?, seiPrefix: [Data]) throws -> Bool {
        guard let first = nal.first else { return sessionStarted }
        let nalType = first & 0x1F
        switch nalType {
        case 7: sps = nal     // SPS
        case 8: pps = nal     // PPS
        case 5, 1:            // IDR slice, P/B slice
            if formatDesc == nil { try buildH264Format() }
            if formatDesc == nil { return false }   // no SPS/PPS yet
            try handleVCL(nal, isKey: nalType == 5, timing: timing, seiPrefix: seiPrefix)
        default:
            break
        }
        return sessionStarted
    }

    private func buildH264Format() throws {
        guard let sps, let pps else { throw Mp4WriterError.missingParameterSets }
        // Hold the Data buffers as contiguous byte arrays so the pointers we
        // hand to CoreMedia stay valid for the duration of the call.
        let arrays: [[UInt8]] = [Array(sps), Array(pps)]
        var fmt: CMVideoFormatDescription?
        var st: OSStatus = noErr
        arrays.withUnsafePointers { ptrs, sizes in
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: nil, parameterSetCount: arrays.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        if st != noErr { throw Mp4WriterError.formatDescription(st) }
        self.formatDesc = fmt
    }

    // MARK: - H.265

    private func appendH265(_ nal: Data, timing: FrameTiming?, seiPrefix: [Data]) throws -> Bool {
        guard let first = nal.first else { return sessionStarted }
        let nalType = (first >> 1) & 0x3F
        switch nalType {
        case 32: vps = nal    // VPS_NUT
        case 33: sps = nal    // SPS_NUT
        case 34: pps = nal    // PPS_NUT
        default:
            // Only VCL NAL types 0..31 are pictures. SEI (39) reaches the MP4
            // via seiPrefix (muxed into the VCL sample), never as its own frame.
            guard nalType <= 31 else { break }
            if formatDesc == nil { try buildH265Format() }
            if formatDesc == nil { return false }
            // Key NAL types: 16..23 (BLA_W_LP..RSV_IRAP_VCL23) — IDR is 19/20.
            let isKey = (nalType >= 16 && nalType <= 23)
            try handleVCL(nal, isKey: isKey, timing: timing, seiPrefix: seiPrefix)
        }
        return sessionStarted
    }

    private func buildH265Format() throws {
        guard let vps, let sps, let pps else { throw Mp4WriterError.missingParameterSets }
        let arrays: [[UInt8]] = [Array(vps), Array(sps), Array(pps)]
        var fmt: CMVideoFormatDescription?
        var st: OSStatus = noErr
        arrays.withUnsafePointers { ptrs, sizes in
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: nil, parameterSetCount: arrays.count,
                parameterSetPointers: ptrs, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        if st != noErr { throw Mp4WriterError.formatDescription(st) }
        self.formatDesc = fmt
    }

    // MARK: - Common

    /// One picture slice. Ties buffered audio to this access unit, keeps the
    /// session closed until `gate` allows it (audio format known, or the grace
    /// window passed without audio — and always on a keyframe), then writes.
    private func handleVCL(_ nal: Data, isKey: Bool, timing: FrameTiming?,
                           seiPrefix: [Data]) throws {
        vclSeen += 1
        if let sof = timing?.sofNs, sof != 0 { anchorPendingAudio(toAccessUnitSof: sof) }
        if !sessionStarted {
            guard gate.shouldOpen(isKey: isKey, audioFormatKnown: audioFormat != nil) else {
                return   // dropped: waiting for audio format / grace window / keyframe
            }
            try startSessionIfNeeded()
        }
        try appendVCL(nal, isKey: isKey, timing: timing, seiPrefix: seiPrefix)
    }

    private func startSessionIfNeeded() throws {
        if sessionStarted { return }
        guard let formatDesc else { throw Mp4WriterError.missingParameterSets }

        // Build the passthrough input WITH the format hint now that we have it.
        // Add it before startWriting() so the writer sets up the track and the
        // input becomes ready to accept samples.
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                     sourceFormatHint: formatDesc)
        inp.expectsMediaDataInRealTime = true
        guard writer.canAdd(inp) else { throw Mp4WriterError.sessionStart(-2) }
        writer.add(inp)
        self.input = inp

        // If the audio format is known (the gate waits for it, up to the grace
        // window), add a passthrough AAC track too — this must happen before
        // startWriting(). Otherwise the file is video-only for its lifetime.
        if let audioFormat, audioInput == nil {
            let ainp = AVAssetWriterInput(mediaType: .audio, outputSettings: nil,
                                          sourceFormatHint: audioFormat)
            ainp.expectsMediaDataInRealTime = true
            if writer.canAdd(ainp) { writer.add(ainp); self.audioInput = ainp }
        }

        guard writer.startWriting() else {
            if let e = writer.error { throw Mp4WriterError.writerFailed(e) }
            throw Mp4WriterError.sessionStart(-1)
        }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    private func appendVCL(_ nal: Data, isKey: Bool, timing frameTiming: FrameTiming?,
                           seiPrefix: [Data] = []) throws {
        guard let formatDesc else { throw Mp4WriterError.missingParameterSets }

        // The first sample written MUST be a sync sample (IDR). The live
        // stream usually starts mid-GOP, so drop leading P/B frames until
        // the first keyframe — otherwise AVAssetWriter rejects the leading
        // non-IDR, flips status to .failed, and isReadyForMoreMediaData
        // never recovers (the old code then Thread.sleep-spun forever).
        if !sawKeyframe {
            guard isKey else { return }
            sawKeyframe = true
        }
        // If the writer already failed, drop silently — appending more is
        // futile and must never block.
        guard writer.status == .writing else { return }

        // AVCC framing: 4-byte big-endian length prefix + NAL payload. The
        // Trinet SEI NALs (IMU/temp) for this access unit are written first, so
        // the MP4 sample is [SEI…][VCL] — self-contained IMU, like UVC. The
        // decoder ignores the SEIs.
        var prefixed = Data()
        prefixed.reserveCapacity(nal.count + 4 + seiPrefix.reduce(0) { $0 + $1.count + 4 })
        for sei in seiPrefix {
            var sl = UInt32(sei.count).bigEndian
            withUnsafeBytes(of: &sl) { prefixed.append(contentsOf: $0) }
            prefixed.append(sei)
        }
        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { prefixed.append(contentsOf: $0) }
        prefixed.append(nal)

        // PTS from the device's true capture time (Trinet IMU SEI), zero-based
        // to the first written frame, so the MP4 timeline IS the device capture
        // timeline — and lines up with the .imu/.vts device-clock timestamps to
        // ~1 ms. Falls back to the synthetic frameIndex/fps clock only if the
        // stream carries no SEI (older firmware).
        let pts: CMTime
        let dur: CMTime
        if let sof = frameTiming?.sofNs, sof != 0 {
            if firstSofNs == nil { firstSofNs = sof }
            let rel = sof >= firstSofNs! ? (sof - firstSofNs!) : 0
            pts = CMTime(value: CMTimeValue(rel), timescale: 1_000_000_000)
            dur = CMTime(value: CMTimeValue(1_000_000_000.0 / fps), timescale: 1_000_000_000)
        } else {
            pts = CMTime(value: frameIndex, timescale: timeScale)
            dur = CMTime(value: CMTimeValue(Double(timeScale) / fps), timescale: timeScale)
            frameIndex += CMTimeValue(Double(timeScale) / fps)
        }

        var blockBuf: CMBlockBuffer?
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: prefixed.count)
        prefixed.copyBytes(to: UnsafeMutableBufferPointer(start: bytes, count: prefixed.count))
        let st = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: bytes,
            blockLength: prefixed.count,
            blockAllocator: kCFAllocatorDefault,    // takes ownership
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: prefixed.count,
            flags: 0,
            blockBufferOut: &blockBuf)
        if st != noErr || blockBuf == nil { throw Mp4WriterError.sampleBuffer(st) }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts,
                                        decodeTimeStamp: pts)
        var sampleSize = prefixed.count
        let st2 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard st2 == noErr, let sample else { throw Mp4WriterError.sampleBuffer(st2) }

        if !isKey {
            CMSetAttachment(sample, key: kCMSampleAttachmentKey_NotSync as CFString,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }

        // NEVER block. If the input isn't ready (writer overwhelmed or
        // failed), drop this frame. With expectsMediaDataInRealTime=true on
        // a ~realtime source this is rare; dropping a frame is a transient
        // quality blip, whereas blocking here freezes the whole NAL pipeline
        // (preview + stop included) because this runs on the recorder actor.
        guard let input else { return }
        guard input.isReadyForMoreMediaData else { droppedNotReady += 1; return }
        input.append(sample)
        appendedSamples += 1

        // firstSofNs is now set (above) — flush any audio buffered before the
        // video clock origin existed, and keep the audio track in step.
        drainPendingAudio()
    }
}

// MARK: - Helpers

private extension Array where Element == [UInt8] {
    /// Build parallel arrays of pointers + lengths for CoreMedia parameter-set
    /// APIs. The underlying byte arrays must outlive the closure call —
    /// `Array<UInt8>` values are stored on the heap and stay alive as long as
    /// `self` does, so this is safe as long as the caller keeps a strong
    /// reference to the source array for the duration of `body`.
    func withUnsafePointers(_ body: (UnsafePointer<UnsafePointer<UInt8>>,
                                     UnsafePointer<Int>) -> Void) {
        let count = self.count
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: count)
        let sizes    = UnsafeMutablePointer<Int>.allocate(capacity: count)
        defer { pointers.deallocate(); sizes.deallocate() }

        for (i, a) in self.enumerated() {
            a.withUnsafeBufferPointer { buf in
                pointers[i] = buf.baseAddress!
                sizes[i] = buf.count
            }
        }
        body(UnsafePointer(pointers), UnsafePointer(sizes))
    }
}
