// TrinetLiveSession — owns the single VideoStream + decoder (preview) +
// IMU subscription, and optionally a RecordSink (recording). Plain
// lock-based class, NOT an actor: the NAL hot path is a synchronous
// callback from VideoStream's receive queue, so there are no actor-await
// chains to tangle with stop() (which was the hang).
//
// Threading model:
//   - VideoStream delivers NALs synchronously on its NWConnection serial
//     queue → onNAL(). That's the only place the decoder is touched, so
//     the decoder needs no lock of its own.
//   - The lock guards the small set of swappable references (decoder,
//     recordSink, videoStream, imuTelemetry) against stop()/startRecording
//     coming from the main thread.
//   - sampleStream / imuStream are AsyncStreams; their continuations are
//     thread-safe to yield from any thread.

import CoreMedia
import Foundation

public final class TrinetLiveSession: @unchecked Sendable {
    public let device: TrinetDevice

    /// The codec the camera is actually streaming. Starts as the value passed
    /// to `init` (normally `TrinetDevice.streamCodec()`), and follows the
    /// stream's HTTP Content-Type if that disagrees.
    public var codec: VideoCodec {
        lock.lock(); defer { lock.unlock() }
        return activeCodec
    }
    private var activeCodec: VideoCodec

    private let lock = NSLock()
    private var videoStream: VideoStream?
    private var decoder: VideoDecoder?
    private var recordSink: RecordSink?
    /// Set by stop(); a recording can't be attached to a stopped session.
    private var stopped = false

    // Latest parameter-set NALs seen on the wire (VPS/SPS/PPS). Cached so a
    // recording started mid-stream can prime its Mp4Writer immediately,
    // instead of waiting up to one GOP (~1s) for the firmware to repeat the
    // headers — which is the window where a quick start→stop produced an
    // uninitialized writer (status .unknown) and an empty/crashing file.
    private var paramVPS: Data?   // h265 only
    private var paramSPS: Data?
    private var paramPPS: Data?

    // IMU arrives in-stream as SEI (there is no separate IMU socket). On a
    // stereo camera there is ONE SEI stream for the whole side-by-side canvas
    // (both eyes are genlocked), handled exactly like mono. Per access unit we
    // accumulate the SEI NALs (to mux into the MP4) and the frame's SoF time
    // (from the IMU samples) until the VCL that closes the AU. Only touched on
    // the single NAL producer thread.
    private var pendingSEINALs: [Data] = []
    private var pendingSofNs: UInt64?

    // Bounded: keep only the newest few decoded frames. If the main-thread
    // display layer falls behind (e.g. while recording adds load), we drop
    // stale frames instead of letting the buffer grow unbounded and flood
    // the main thread — which froze the UI.
    private let sampleStreamMaker =
        AsyncStream<CMSampleBuffer>.makeStream(bufferingPolicy: .bufferingNewest(3))
    public var sampleStream: AsyncStream<CMSampleBuffer> { sampleStreamMaker.stream }
    /// These are COMPRESSED frames: dropping one breaks every frame that
    /// references it (smeared preview until the next keyframe). So after a
    /// drop, stop feeding the preview until the next keyframe. NAL thread only.
    private var previewNeedsKeyframe = false

    private let imuStreamMaker =
        AsyncStream<ImuBatch>.makeStream(bufferingPolicy: .bufferingNewest(8))
    public var imuStream: AsyncStream<ImuBatch> { imuStreamMaker.stream }

    // Embedded AAC audio (v4 cameras), surfaced for SDK consumers that want to
    // play or analyse it live (the demo app keeps its preview silent). Bounded
    // so a slow or absent consumer drops stale frames rather than backing up
    // the NAL thread. Empty on older cameras (no TRINETAAC SEI). Recording does
    // not depend on this stream — audio goes straight to the RecordSink.
    private let audioStreamMaker =
        AsyncStream<AacBatch>.makeStream(bufferingPolicy: .bufferingNewest(16))
    public var audioStream: AsyncStream<AacBatch> { audioStreamMaker.stream }

    public init(device: TrinetDevice, codec: VideoCodec) {
        self.device = device
        self.activeCodec = codec
    }

    // MARK: - Lifecycle

    public func start() async {
        let host = device.host
        let codec = self.codec

        let dec = makeDecoder(codec)
        let vs = VideoStream(host: host, codec: codec, interfaceName: device.interfaceName)

        let alreadyStopped = lock.withLock { () -> Bool in
            if stopped { return true }
            decoder = dec
            videoStream = vs
            return false
        }
        if alreadyStopped { return }

        // Synchronous NAL callback — no await, no actor hop. IMU is parsed out
        // of the SEI here too; there is no separate UDP channel anymore.
        vs.start { [weak self] nal in
            self?.onNAL(nal)
        }
    }

    public func stop() async {
        // Mark stopped and detach any active recording in ONE critical section,
        // so a startRecording() finishing concurrently can't attach a sink
        // after we looked.
        let (vs, sink) = lock.withLock { () -> (VideoStream?, RecordSink?) in
            stopped = true
            let vs = videoStream;  videoStream = nil
            decoder = nil
            let s = recordSink;    recordSink = nil
            return (vs, s)
        }
        // Finalize off this thread (see stopRecording()).
        if let sink { Task.detached(priority: .utility) { sink.finish() } }

        vs?.stop()
        sampleStreamMaker.continuation.finish()
        imuStreamMaker.continuation.finish()
        audioStreamMaker.continuation.finish()
    }

    private func makeDecoder(_ codec: VideoCodec) -> VideoDecoder {
        VideoDecoder(codec: codec) { [weak self] sb in
            self?.deliverPreview(sb)
        }
    }

    /// Hand one compressed frame to the preview stream. Runs on the NAL thread
    /// (the decoder emits synchronously from onNAL).
    private func deliverPreview(_ sb: CMSampleBuffer) {
        if previewNeedsKeyframe {
            guard sb.trinetIsKeyframe else { return }
            previewNeedsKeyframe = false
        }
        if case .dropped = sampleStreamMaker.continuation.yield(sb) {
            // The consumer fell behind and the oldest buffered frame was
            // discarded; resync on the next keyframe rather than smear.
            previewNeedsKeyframe = true
        }
    }

    /// The stream turned out to carry a different codec than expected (its
    /// Content-Type is authoritative). Rebuild everything keyed on the codec.
    /// Runs on the NAL producer thread, before the first NAL of that codec.
    private func switchCodec(to newCodec: VideoCodec) {
        lock.lock()
        let old = activeCodec
        activeCodec = newCodec
        decoder = decoder == nil ? nil : makeDecoder(newCodec)
        paramVPS = nil; paramSPS = nil; paramPPS = nil
        var staleSink: RecordSink?
        if let s = recordSink, s.codec != newCodec { staleSink = s; recordSink = nil }
        lock.unlock()
        pendingSEINALs.removeAll(); pendingSofNs = nil
        NSLog("TrinetSDK live session: stream codec \(old.rawValue) → \(newCodec.rawValue)")
        staleSink?.finish()
    }

    // MARK: - NAL hot path (synchronous, single producer thread)

    private func onNAL(_ nal: VideoStream.NALUnit) {
        guard let first = nal.payload.first else { return }
        if nal.codec != self.codec { switchCodec(to: nal.codec) }
        let codec = nal.codec
        let isSEI: Bool, isVCL: Bool
        switch codec {
        case .h265:
            let t = Int((first >> 1) & 0x3F)
            isSEI = (t == 39); isVCL = (t <= 31)
        case .h264:
            let t = Int(first & 0x1F)
            isSEI = (t == 6); isVCL = (t >= 1 && t <= 5)
        }

        // Trinet SEI carries the IMU + temperature in-stream. Parse it for the
        // live plot, the .imu sidecar, and the frame's SoF time — but never feed
        // it to the decoder. Buffer the raw SEI NAL so we can mux it into the
        // MP4 frame (so the recording self-contains IMU like the UVC path).
        if isSEI {
            var isAudioSEI = false
            if let payload = TrinetSEI.parse(nalPayload: nal.payload, codec: codec) {
                switch payload {
                case .imu(let batch):
                    imuStreamMaker.continuation.yield(batch)        // → UI plot
                    lock.lock(); let sink = recordSink; lock.unlock()
                    sink?.writeIMU(batch.samples, version: batch.version)  // → .imu file
                    if pendingSofNs == nil {
                        pendingSofNs = TrinetSEI.frameTimeNs(of: batch)
                    }
                case .temp:
                    break   // thermal trace — surfaced later if needed
                case .audio(let batch):
                    isAudioSEI = true
                    audioStreamMaker.continuation.yield(batch)      // → optional SDK consumers
                    lock.lock(); let sink = recordSink; lock.unlock()
                    sink?.writeAudio(batch.frames)                  // → MP4 AAC track
                }
            }
            // IMU/temp SEIs are muxed verbatim into the MP4's video samples so the
            // recording self-contains them. The audio SEI is NOT — its payload
            // goes into a real AAC track instead, so don't also bloat the video.
            if !isAudioSEI { pendingSEINALs.append(nal.payload) }
            return
        }

        var unit = nal
        if isVCL {
            let sof = pendingSofNs ?? nal.hostReceivedNs
            unit.timing = FrameTiming(sofNs: sof, vencPtsUs: sof / 1000,
                                      vencSeq: 0, isKey: Self.isKeyframe(unit))
        }
        let seiPrefix = isVCL ? pendingSEINALs : []
        if isVCL { pendingSEINALs.removeAll(keepingCapacity: true); pendingSofNs = nil }

        lock.lock()
        let dec = decoder
        let sink = recordSink
        cacheParamSet(unit)     // cheap; under lock
        lock.unlock()
        // Strong refs snapshotted; safe to use off-lock. decoder's internal
        // state is only ever touched here (one serial queue), so concurrent
        // stop() (which only drops the reference) can't corrupt it.
        dec?.decode(unit)                              // preview
        sink?.writeVideo(unit, seiPrefix: seiPrefix)   // recording (muxes SEI)
    }

    private static func isKeyframe(_ nal: VideoStream.NALUnit) -> Bool {
        guard let first = nal.payload.first else { return false }
        switch nal.codec {
        case .h264: return (first & 0x1F) == 5
        case .h265: let t = (first >> 1) & 0x3F; return t >= 16 && t <= 23
        }
    }

    /// Cache the latest VPS/SPS/PPS. Caller holds `lock`.
    private func cacheParamSet(_ nal: VideoStream.NALUnit) {
        guard let first = nal.payload.first else { return }
        switch nal.codec {
        case .h264:
            switch first & 0x1F {
            case 7: paramSPS = nal.payload
            case 8: paramPPS = nal.payload
            default: break
            }
        case .h265:
            switch (first >> 1) & 0x3F {
            case 32: paramVPS = nal.payload
            case 33: paramSPS = nal.payload
            case 34: paramPPS = nal.payload
            default: break
            }
        }
    }

    /// Snapshot the cached parameter sets as raw NAL payloads (caller will
    /// re-wrap them). Order: VPS, SPS, PPS.
    private func snapshotParamSets() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var out: [Data] = []
        if let v = paramVPS { out.append(v) }
        if let s = paramSPS { out.append(s) }
        if let p = paramPPS { out.append(p) }
        return out
    }

    // MARK: - Recording control

    /// Start recording the live stream. Stereo cameras record the full
    /// side-by-side canvas (both eyes) regardless of the preview's lens
    /// selection — showing one eye is display-only.
    ///
    /// Runs off the caller's actor (this is a nonisolated async method): the
    /// file creation and AVAssetWriter setup never touch the main thread.
    /// Throws `CancellationError` if the session was stopped meanwhile.
    @discardableResult
    public func startRecording(in directory: URL,
                               baseName: String? = nil) async throws -> RecordingHandle {
        let iv = TrinetDiagnostics.begin("session.startRecording")
        defer { iv.end() }
        let cfg    = await device.currentConfig
        let devId  = await device.deviceIdBytes
        let offset = await device.lastHostOffsetNs ?? 0
        let info   = await device.info
        let params = snapshotParamSets()   // prime the writer immediately
        let codec  = self.codec
        let sink = try TrinetDiagnostics.measure("recorder.create") {
            try RecordSink(codec: codec, config: cfg,
                           deviceId: devId, iosOffsetNs: offset,
                           paramSets: params,
                           in: directory, baseName: baseName,
                           canvasWidth: info?.canvasWidth,
                           canvasHeight: info?.canvasHeight,
                           imuRateHz: info?.nominalImuRateHz ?? 562)
        }
        // Install it — unless stop() ran while we were setting up, or another
        // recording was started meanwhile; a sink nobody finishes would leave an
        // unfinalized MP4 behind.
        let (installed, replaced) = lock.withLock { () -> (Bool, RecordSink?) in
            if stopped { return (false, nil) }
            let old = recordSink
            recordSink = sink
            return (true, old)
        }
        if let replaced { Task.detached(priority: .utility) { replaced.finish() } }
        guard installed else {
            sink.finish()
            throw CancellationError()
        }
        return sink.handle
    }

    public func stopRecording() {
        lock.lock()
        let s = recordSink
        recordSink = nil
        lock.unlock()
        // Finalize OFF the calling thread. stopRecording is invoked from the
        // @MainActor view model, so doing RecordSink.finish()'s lock.lock()
        // here would block the main thread against writeVideo (which holds
        // that lock per-NAL on the busy video thread) → UI hang. Hand it to
        // a background task; finish() itself is non-blocking + detaches the
        // actual finishWriting.
        guard let s else { return }
        Task.detached(priority: .utility) {
            s.finish()
        }
    }

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return recordSink != nil
    }

    public var recordingBytes: Int {
        lock.lock()
        let s = recordSink
        lock.unlock()
        return s?.bytesWritten ?? 0
    }
}

extension TrinetDevice {
    /// Open a live session for preview + IMU telemetry + recording. The codec
    /// is whatever the camera actually streams: asked via `streamCodec()`
    /// (firmware without that endpoint streams H.264), then confirmed against
    /// the stream's Content-Type once it opens.
    public func liveSession() async -> TrinetLiveSession {
        let iv = TrinetDiagnostics.begin("device.streamCodec")
        let codec = (try? await streamCodec()) ?? .h264
        iv.end()
        noteStreamCodec(codec)
        return TrinetLiveSession(device: self, codec: codec)
    }
}
