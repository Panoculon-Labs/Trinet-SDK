// PlaybackImuTrackView.swift — scrolling accel + gyro strip that follows the
// player, with a center playhead. Windows on the ABSOLUTE device clock
// (centerDeviceNs) so it stays aligned with the video frame currently on
// screen. Port of the Android SDK's PlaybackImuTrack.

import SwiftUI

public struct PlaybackImuTrackView: View {
    public let data: ImuPlaybackData
    /// Device CLOCK_MONOTONIC ns of the frame currently shown by the player.
    public let centerDeviceNs: UInt64
    public var windowSeconds: Double

    public init(data: ImuPlaybackData,
                centerDeviceNs: UInt64,
                windowSeconds: Double = 4.0) {
        self.data = data
        self.centerDeviceNs = centerDeviceNs
        self.windowSeconds = windowSeconds
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            trace(title: "Accelerometer (m/s²)", range: -12...12) { $0.accel }
            trace(title: "Gyroscope (rad/s)",    range: -3.5...3.5) { $0.gyro }
            if data.hasMag {
                trace(title: "Magnetometer (µT)", range: -100...100) { $0.mag }
            }
            if let s = data.sampleAtDeviceNs(centerDeviceNs) {
                Text("T: \(s.tempC, specifier: "%.1f") °C · \(data.sampleRateHz) Hz")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func trace(title: String,
                       range: ClosedRange<Float>,
                       channel: @escaping (ImuSample) -> SIMD3<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title).font(.caption.bold())
                ForEach(Array(ImuAxis.labels.enumerated()), id: \.offset) { i, label in
                    HStack(spacing: 3) {
                        Capsule().fill(ImuAxis.colors[i]).frame(width: 14, height: 3)
                        Text(label).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            Canvas { ctx, size in
                ctx.draw(Text("\(Int(range.upperBound))").font(.system(size: 8))
                            .foregroundColor(.gray),
                         at: CGPoint(x: 4, y: 8), anchor: .topLeading)
                ctx.draw(Text("\(Int(range.lowerBound))").font(.system(size: 8))
                            .foregroundColor(.gray),
                         at: CGPoint(x: 4, y: size.height - 8), anchor: .bottomLeading)

                let winNs = windowSeconds * 1e9
                let center = Double(centerDeviceNs)
                let startNs = center - winNs / 2
                let endNs = center + winNs / 2
                let lo = data.indexAtDeviceNs(UInt64(max(0, startNs)))
                let hi = min(data.indexAtDeviceNs(UInt64(max(0, endNs))) + 1, data.samples.count)
                let yMid = Double(range.lowerBound + range.upperBound) / 2
                let ySpan = Double(range.upperBound - range.lowerBound)

                func xFor(_ tsNs: UInt64) -> CGFloat {
                    CGFloat((Double(tsNs) - startNs) / winNs) * size.width
                }
                func yFor(_ v: Float) -> CGFloat {
                    size.height / 2 - CGFloat((Double(v) - yMid) / ySpan) * size.height
                }

                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height / 2))
                base.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(base, with: .color(.gray.opacity(0.3)),
                           style: .init(lineWidth: 0.5, dash: [3, 3]))

                if hi > lo + 1 {
                    // Decimate to ~2 points per horizontal pixel — at 562 Hz a
                    // 4 s window is ~2200 samples, far more than the ~360 px
                    // width, and drawing them all 30×/s saturated the main thread.
                    let step = max(1, (hi - lo) / max(1, Int(size.width * 2)))
                    let comps: [KeyPath<SIMD3<Float>, Float>] = [\.x, \.y, \.z]
                    for (idx, kp) in comps.enumerated() {
                        var path = Path()
                        var started = false
                        var i = lo
                        while i < hi {
                            let s = data.samples[i]
                            let p = CGPoint(x: xFor(s.timestampNs),
                                            y: yFor(channel(s)[keyPath: kp]))
                            if !started { path.move(to: p); started = true }
                            else { path.addLine(to: p) }
                            i += step
                        }
                        ctx.stroke(path, with: .color(ImuAxis.colors[idx]),
                                   style: StrokeStyle(lineWidth: 1.3, dash: ImuAxis.dashes[idx]))
                    }
                }

                var ph = Path()
                ph.move(to: CGPoint(x: size.width / 2, y: 0))
                ph.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                ctx.stroke(ph, with: .color(.white.opacity(0.9)), lineWidth: 1)
            }
            .frame(height: 70)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement()
            .accessibilityLabel(title)
        }
    }
}
