// LivePreviewView.swift — SwiftUI wrapper for AVSampleBufferDisplayLayer.
//
// Caller hands us a stream of CMSampleBuffer (from VideoDecoder) via an
// AsyncStream. We enqueue them onto an AVSampleBufferDisplayLayer hosted
// inside a UIView. Direct video presentation without going through
// AVPlayer's URL machinery — exactly what the Android SDK's TextureView
// + MediaCodec path does, except iOS has the display layer built in.

import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

public struct LivePreviewView: UIViewRepresentable {
    /// Bind the decoder's output to a stream the view consumes.
    public let stream: AsyncStream<CMSampleBuffer>

    public init(stream: AsyncStream<CMSampleBuffer>) {
        self.stream = stream
    }

    public func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        context.coordinator.bind(to: v)
        return v
    }

    public func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // nothing dynamic — the stream is fed via the coordinator
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(stream: stream)
    }

    public final class Coordinator {
        let stream: AsyncStream<CMSampleBuffer>
        private var task: Task<Void, Never>?
        weak var view: PreviewUIView?

        init(stream: AsyncStream<CMSampleBuffer>) {
            self.stream = stream
        }

        func bind(to view: PreviewUIView) {
            self.view = view
            task?.cancel()
            task = Task { [weak self] in
                guard let self else { return }
                for await sb in self.stream {
                    await MainActor.run { [weak self] in
                        self?.view?.enqueue(sb)
                    }
                }
            }
        }

        deinit { task?.cancel() }
    }
}

/// UIView host for the sample-buffer display layer. The layer auto-handles
/// presentation timing from the CMSampleBuffer PTS we provide.
public final class PreviewUIView: UIView {
    public override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        // Intentionally no controlTimebase — VideoDecoder emits PTS in a
        // synthetic "stream time" (starts at 0), which makes the layer
        // drop every frame as "in the past" if compared to host time.
        // Without a controlTimebase, the layer presents samples in arrival
        // order at the screen refresh rate. Marginal latency, but always
        // shows frames.
    }

    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        // Always run on main thread — AVSampleBufferDisplayLayer requires it.
        if Thread.isMainThread {
            _enqueue(sampleBuffer)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?._enqueue(sampleBuffer)
            }
        }
    }

    private func _enqueue(_ sampleBuffer: CMSampleBuffer) {
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}
