// TrinetAudioPlayer.swift — live playback of the embedded AAC audio (v4
// cameras) carried in the TRINETAAC SEI. Decodes nothing itself: it feeds the
// compressed AAC CMSampleBuffers (built by AACSupport) straight into an
// AVSampleBufferAudioRenderer, which decodes + plays them, paced by an
// AVSampleBufferRenderSynchronizer. This mirrors the video preview path, which
// hands compressed-then-decoded buffers to AVSampleBufferDisplayLayer.
//
// Pre-v4 cameras emit no audio SEI, so submit() is simply never called and this
// stays silent — backward compatible and side-effect free.

import AVFoundation
import CoreMedia
import Foundation

public final class TrinetAudioPlayer: @unchecked Sendable {

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "com.panoculon.trinet.audio")

    private var format: CMAudioFormatDescription?
    private var pending: [CMSampleBuffer] = []
    private var nextPts: CMTime = .zero
    private var started = false
    private let frameSamples = 1024
    private let maxPending = 32     // ~0.75 s of AAC frames; drop oldest beyond this

    public init() {
        synchronizer.addRenderer(renderer)
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump() }
    }

    /// Configure the audio session and begin playback. Idempotent. Returns
    /// immediately: the (blocking) session calls run on TrinetAudioSession.queue.
    public func start() {
        #if os(iOS)
        TrinetAudioSession.perform("audioplayer.activate") { session in
            try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try? session.setActive(true)
        }
        #endif
    }

    /// Enqueue one frame's batch of AAC audio for playback.
    public func submit(_ batch: AacBatch) {
        queue.async { [weak self] in self?._submit(batch) }
    }

    private func _submit(_ batch: AacBatch) {
        guard !batch.frames.isEmpty else { return }
        if format == nil { format = AACSupport.formatDescription(from: batch.frames[0].adts) }
        guard let format else { return }

        let scale = CMTimeScale(batch.sampleRate)
        for f in batch.frames {
            // Live playback is paced by a synthetic stream clock (one AAC-LC frame
            // = 1024 samples); the synchronizer drives presentation. The device
            // pts only matters for record-time A/V sync, not live monitoring.
            guard let sb = AACSupport.sampleBuffer(adts: f.adts, format: format, pts: nextPts)
            else { continue }
            pending.append(sb)
            nextPts = CMTimeAdd(nextPts, CMTime(value: CMTimeValue(frameSamples), timescale: scale))
        }
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }
        if !started {
            started = true
            synchronizer.setRate(1.0, time: .zero)
        }
        pump()
    }

    private func pump() {
        while renderer.isReadyForMoreMediaData, !pending.isEmpty {
            renderer.enqueue(pending.removeFirst())
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.synchronizer.setRate(0, time: .zero)
            self.renderer.flush()
            self.pending.removeAll()
            self.nextPts = .zero
            self.started = false
            self.format = nil
            #if os(iOS)
            TrinetAudioSession.perform("audioplayer.deactivate") { session in
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
            #endif
        }
    }
}
