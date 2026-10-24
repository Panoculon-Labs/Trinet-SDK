// LivePreviewView.swift — SwiftUI wrapper for AVSampleBufferDisplayLayer.
//
// Caller hands us a stream of CMSampleBuffer (from VideoDecoder) via an
// AsyncStream. We enqueue them onto an AVSampleBufferDisplayLayer hosted
// inside a UIView. Direct video presentation without going through
// AVPlayer's URL machinery — exactly what the Android SDK's TextureView
// + MediaCodec path does, except iOS has the display layer built in.
//
// Threading: frames are enqueued OFF the main thread, through the layer's
// `sampleBufferRenderer` (iOS 17+), which is documented as safe to feed from a
// background thread. The old path hopped every 3840x1080 frame onto the main
// actor (30/s): any UI work stalled the preview, and the preview competed with
// the UI for the main thread. Only a change of frame size touches the main
// thread now.
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

        init(stream: AsyncStream<CMSampleBuffer>) {
            self.stream = stream
        }

        func bind(to view: PreviewUIView) {
            task?.cancel()
            let sink = view.sink
            let source = UncheckedSendableBox(stream)
            // One consumer, off the main actor: frames go straight to the
            // renderer in stream order.
            task = Task.detached(priority: .userInitiated) {
                for await sb in source.value {
                    sink.enqueue(sb)
                }
            }
        }

        deinit { task?.cancel() }
    }
}

/// Carries a non-Sendable value into a detached task that becomes its only user.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Feeds an AVSampleBufferVideoRenderer from one background consumer. Holds
/// the presentation state (backgrounded / waiting for a keyframe) that the
/// main thread's lifecycle observers flip.
final class PreviewRenderSink: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var inBackground = false        // guarded by lock
    // Start on a keyframe: a mid-GOP first frame can't be decoded anyway.
    private var awaitingKeyframe = true     // guarded by lock
    private var needsFlush = false          // guarded by lock
    private var lastWidth: Int32 = -1       // consumer only
    private var lastHeight: Int32 = -1      // consumer only
    /// The view to tell about frame-size changes. Set once on the main thread
    /// before any frame is enqueued; weak loads are thread-safe.
    weak var view: PreviewUIView?

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    /// iOS gives a backgrounded app no hardware video decode: the renderer
    /// fails with "operation interrupted" and frames enqueued meanwhile are
    /// lost. Pause presentation instead; on return flush and resume at the next
    /// keyframe — a clean picture within one GOP rather than smeared P-frames.
    /// The flush itself is done by the consumer, so the renderer is only ever
    /// driven from one thread.
    func setInBackground(_ bg: Bool) {
        lock.withLock {
            inBackground = bg
            if !bg { needsFlush = true; awaitingKeyframe = true }
        }
    }

    /// Enqueue one compressed frame. Call from a single thread/queue at a time.
    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            if dims.width != lastWidth || dims.height != lastHeight {
                lastWidth = dims.width; lastHeight = dims.height
                // Rare (stream start / resolution change): the only main hop.
                Task { @MainActor [weak view = self.view] in view?.noteDimensions(dims) }
            }
        }
        let isKey = sampleBuffer.trinetIsKeyframe
        let (skip, flush) = lock.withLock { () -> (Bool, Bool) in
            if inBackground { return (true, false) }
            let f = needsFlush
            needsFlush = false
            if awaitingKeyframe {
                guard isKey else { return (true, f) }
                awaitingKeyframe = false
            }
            return (false, f)
        }
        if flush { renderer.flush() }
        if skip { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            // A flushed renderer can only start decoding again from a keyframe.
            if !isKey { lock.withLock { awaitingKeyframe = true }; return }
        }
        if renderer.isReadyForMoreMediaData {
            renderer.enqueue(sampleBuffer)
        } else {
            // Dropping a compressed frame breaks every frame that references
            // it; resync at the next keyframe instead of smearing.
            lock.withLock { awaitingKeyframe = true }
        }
    }
}

/// UIView host for the sample-buffer display layer. The layer auto-handles
/// presentation timing from the CMSampleBuffer PTS we provide.
///
/// The view itself is a clipping container; the display layer lives in a
/// child view so it can be laid out wider than the container to show one eye
/// of a side-by-side stereo canvas.
public final class PreviewUIView: UIView {

    /// A sample is a keyframe unless it carries the NotSync attachment
    /// (VideoDecoder marks every non-key frame).
    static func isKeyframe(_ sb: CMSampleBuffer) -> Bool { sb.trinetIsKeyframe }

    /// Child view whose backing layer is the display layer.
    private final class DisplayLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    private let videoView: DisplayLayerView
    private var displayLayer: AVSampleBufferDisplayLayer { videoView.displayLayer }
    /// Background-thread feeder for the display layer's renderer.
    let sink: PreviewRenderSink

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

    private var lifecycleObservers: [NSObjectProtocol] = []

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public override init(frame: CGRect) {
        let v = DisplayLayerView()
        videoView = v
        sink = PreviewRenderSink(renderer: v.displayLayer.sampleBufferRenderer)
        super.init(frame: frame)
        configure()
    }
    public required init?(coder: NSCoder) {
        let v = DisplayLayerView()
        videoView = v
        sink = PreviewRenderSink(renderer: v.displayLayer.sampleBufferRenderer)
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        sink.view = self
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

        let nc = NotificationCenter.default
        let sink = self.sink
        lifecycleObservers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            sink.setInBackground(true)
        })
        lifecycleObservers.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            sink.setInBackground(false)
        })
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

    /// Enqueue one decoded-stream sample. May be called from any thread, but
    /// from one at a time (LivePreviewView's coordinator does this for you).
    public func enqueue(_ sampleBuffer: CMSampleBuffer) {
        sink.enqueue(sampleBuffer)
    }

    /// Main thread: the stream's frame size changed.
    fileprivate func noteDimensions(_ dims: CMVideoDimensions) {
        if streamDimensions?.width != dims.width || streamDimensions?.height != dims.height {
            streamDimensions = dims
            streamIsSideBySide = dims.height > 0
                && Double(dims.width) / Double(dims.height) > 2.5
        }
    }
}
