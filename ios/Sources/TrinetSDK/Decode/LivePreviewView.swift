// LivePreviewView.swift — SwiftUI wrapper for AVSampleBufferDisplayLayer.
//
// Caller hands us a stream of CMSampleBuffer (from VideoDecoder) via an
// AsyncStream. We enqueue them onto an AVSampleBufferDisplayLayer hosted
// inside a UIView. Direct video presentation without going through
// AVPlayer's URL machinery — exactly what the Android SDK's TextureView
// + MediaCodec path does, except iOS has the display layer built in.
//
// Stereo: a stereo Trinet streams one side-by-side canvas (left eye in the
// left half, right eye in the right half). `lens` picks what to show:
//   .both   the whole canvas (32:9 on a 3840x1080 stream)
//   .left   only the left half (16:9)
//   .right  only the right half (16:9)
// One eye is shown by laying the display layer out at twice the container's
// width inside a clipping container and offsetting it — no re-decode, no
// cropping copy, instant to switch, and the recording is unaffected (it always
// keeps the full canvas). Size the container to `TrinetDeviceInfo
// .previewAspect(for:)` for a borderless fit. On a single-camera stream (the
// decoded frame isn't wider than ~2.5:1) `lens` is ignored and the whole frame
// is shown.

import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

public struct LivePreviewView: UIViewRepresentable {
    /// Bind the decoder's output to a stream the view consumes.
    public let stream: AsyncStream<CMSampleBuffer>
    /// Which part of a side-by-side stereo canvas to show.
    public let lens: StereoLens

    public init(stream: AsyncStream<CMSampleBuffer>, lens: StereoLens = .both) {
        self.stream = stream
        self.lens = lens
    }

    public func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.lens = lens
        context.coordinator.bind(to: v)
        return v
    }

    public func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // The stream is fed via the coordinator; only the lens is dynamic.
        if uiView.lens != lens { uiView.lens = lens }
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
///
/// The view itself is a clipping container; the display layer lives in a
/// child view so it can be laid out wider than the container to show one eye
/// of a side-by-side stereo canvas.
public final class PreviewUIView: UIView {

    /// Child view whose backing layer is the display layer.
    private final class DisplayLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    private let videoView = DisplayLayerView()
    private var displayLayer: AVSampleBufferDisplayLayer { videoView.displayLayer }

    /// Which part of a side-by-side stereo canvas to show. Ignored (whole
    /// frame shown) when the stream isn't side by side.
    public var lens: StereoLens = .both {
        didSet { if lens != oldValue { setNeedsLayout() } }
    }

    /// True once the decoded stream's frame is wider than ~2.5:1, i.e. a
    /// side-by-side stereo canvas (3840x1080). Derived from the format
    /// description, so it follows the SPS rather than any assumed size.
    public private(set) var streamIsSideBySide = false {
        didSet { if streamIsSideBySide != oldValue { setNeedsLayout() } }
    }

    /// Decoded frame dimensions of the current stream (from the SPS), if known.
    public private(set) var streamDimensions: CMVideoDimensions?

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
        clipsToBounds = true
        videoView.backgroundColor = .black
        videoView.isUserInteractionEnabled = false
        addSubview(videoView)
        displayLayer.videoGravity = .resizeAspect
        // Intentionally no controlTimebase — VideoDecoder emits PTS in a
        // synthetic "stream time" (starts at 0), which makes the layer
        // drop every frame as "in the past" if compared to host time.
        // Without a controlTimebase, the layer presents samples in arrival
        // order at the screen refresh rate. Marginal latency, but always
        // shows frames.
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let effective: StereoLens = streamIsSideBySide ? lens : .both
        let target: CGRect
        switch effective {
        case .both:  target = b
        case .left:  target = CGRect(x: 0, y: 0, width: b.width * 2, height: b.height)
        case .right: target = CGRect(x: -b.width, y: 0, width: b.width * 2, height: b.height)
        }
        // No implicit animation when switching lenses — it's a cut, not a pan.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = target
        CATransaction.commit()
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
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            if streamDimensions?.width != dims.width || streamDimensions?.height != dims.height {
                streamDimensions = dims
                streamIsSideBySide = dims.height > 0
                    && Double(dims.width) / Double(dims.height) > 2.5
            }
        }
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        }
    }
}
