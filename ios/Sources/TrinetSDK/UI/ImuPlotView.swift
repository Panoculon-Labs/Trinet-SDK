// ImuPlotView.swift — scrolling 3-axis accel + gyro plot.
// Mirrors what the Android SDK's PlotComposable renders, sized to fit in
// a card on the Record screen.

import SwiftUI

/// Shared x/y/z styling — colorblind-safe (Okabe–Ito) colors PLUS a distinct
/// dash per axis, so the traces are distinguishable without relying on hue.
public enum ImuAxis {
    public static let colors: [Color] = [
        Color(red: 0.00,  green: 0.447, blue: 0.698),   // x — blue
        Color(red: 0.902, green: 0.624, blue: 0.00),    // y — orange
        Color(red: 0.00,  green: 0.620, blue: 0.451),   // z — green
    ]
    public static let dashes: [[CGFloat]] = [[], [5, 3], [1, 3]]   // x solid, y dashed, z dotted
    public static let labels = ["x", "y", "z"]
}

@MainActor
public final class ImuHistory: ObservableObject {
    public struct Window {
        public var accel: [(t: Double, x: Float, y: Float, z: Float)] = []
        public var gyro:  [(t: Double, x: Float, y: Float, z: Float)] = []
        public var temp: Float = 0
    }

    @Published public private(set) var window = Window()
    /// Total samples received this session (keeps counting; not capped).
    @Published public private(set) var totalReceived: Int = 0
    /// Live sample rate (Hz), updated each batch.
    @Published public private(set) var rateHz: Double = 0

    public let durationSeconds: Double
    private let capacity: Int          // rolling-window size for the plot
    private var t0Ns: UInt64? = nil    // stable across the whole session
    private var lastBatchTs: UInt64? = nil

    public init(durationSeconds: Double = 4.0, sampleRateHz: Int = 562) {
        self.durationSeconds = durationSeconds
        self.capacity = Int(durationSeconds * Double(sampleRateHz))
    }

    public func append(_ samples: [ImuSample]) {
        guard !samples.isEmpty else { return }
        if t0Ns == nil { t0Ns = samples.first!.timestampNs }
        let t0 = Double(t0Ns!) * 1e-9
        for s in samples {
            let t = Double(s.timestampNs) * 1e-9 - t0
            window.accel.append((t, s.accel.x, s.accel.y, s.accel.z))
            window.gyro .append((t, s.gyro.x,  s.gyro.y,  s.gyro.z))
        }
        window.temp = samples.last!.tempC

        // Running total (not capped — this is the number users want to see
        // climb, vs the rolling-window count which plateaus at capacity).
        totalReceived += samples.count

        // Live rate from the span of this batch.
        if let prev = lastBatchTs {
            let dt = Double(samples.last!.timestampNs &- prev) * 1e-9
            if dt > 0 { rateHz = Double(samples.count) / dt }
        }
        lastBatchTs = samples.last!.timestampNs

        if window.accel.count > capacity {
            window.accel.removeFirst(window.accel.count - capacity)
        }
        if window.gyro.count > capacity {
            window.gyro.removeFirst(window.gyro.count - capacity)
        }
    }

    public func reset() {
        window = Window()
        totalReceived = 0
        rateHz = 0
        t0Ns = nil
        lastBatchTs = nil
    }
}

public struct ImuPlotView: View {
    @ObservedObject public var history: ImuHistory

    public init(history: ImuHistory) { self.history = history }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sensorPlot(title: "Accelerometer (m/s²)",
                       samples: history.window.accel,
                       range: -12...12,
                       colors: ImuAxis.colors,
                       labels: ImuAxis.labels)
            sensorPlot(title: "Gyroscope (rad/s)",
                       samples: history.window.gyro,
                       range: -3.5...3.5,
                       colors: ImuAxis.colors,
                       labels: ImuAxis.labels)
            HStack {
                Text("T: \(history.window.temp, specifier: "%.1f") °C")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(history.rateHz, specifier: "%.0f") Hz")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
                Text("· \(history.totalReceived) total")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func sensorPlot(title: String,
                            samples: [(t: Double, x: Float, y: Float, z: Float)],
                            range: ClosedRange<Float>,
                            colors: [Color],
                            labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title).font(.caption.bold())
                ForEach(0..<3, id: \.self) { i in
                    HStack(spacing: 3) {
                        Capsule().fill(colors[i]).frame(width: 14, height: 3)
                        Text(labels[i]).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            Canvas { ctx, size in
                // y-axis scale ticks so a spike that clips reads differently
                // from one that saturates.
                ctx.draw(Text("\(Int(range.upperBound))").font(.system(size: 8))
                            .foregroundColor(.gray),
                         at: CGPoint(x: 4, y: 8), anchor: .topLeading)
                ctx.draw(Text("\(Int(range.lowerBound))").font(.system(size: 8))
                            .foregroundColor(.gray),
                         at: CGPoint(x: 4, y: size.height - 8), anchor: .bottomLeading)

                guard samples.count >= 2 else { return }
                let xMin = samples.first!.t
                let xMax = samples.last!.t
                let xSpan = max(xMax - xMin, 0.001)
                let yMid = (Double(range.lowerBound) + Double(range.upperBound)) / 2
                let ySpan = Double(range.upperBound - range.lowerBound)

                // Zero baseline
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height / 2))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                ctx.stroke(baseline, with: .color(.gray.opacity(0.3)),
                           style: .init(lineWidth: 0.5, dash: [3, 3]))

                let chans: [KeyPath<(t: Double, x: Float, y: Float, z: Float), Float>] =
                    [\.x, \.y, \.z]
                // Decimate to ~2 points per pixel. The rolling window holds
                // ~2200 samples (4 s @ 562 Hz); drawing them all ×6 lines, 30×/s
                // on the main thread froze the recording screen.
                let step = max(1, samples.count / max(1, Int(size.width * 2)))
                for (idx, ch) in chans.enumerated() {
                    var path = Path()
                    var started = false
                    var i = 0
                    while i < samples.count {
                        let s = samples[i]
                        let nx = CGFloat((s.t - xMin) / xSpan) * size.width
                        let ny = size.height / 2 -
                                 CGFloat((Double(s[keyPath: ch]) - yMid) / ySpan) * size.height
                        if !started { path.move(to: CGPoint(x: nx, y: ny)); started = true }
                        else        { path.addLine(to: CGPoint(x: nx, y: ny)) }
                        i += step
                    }
                    ctx.stroke(path, with: .color(colors[idx]),
                               style: StrokeStyle(lineWidth: 1.3, dash: ImuAxis.dashes[idx]))
                }
            }
            .frame(height: 70)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue(samples))
        }
    }

    private func accessibilityValue(_ samples: [(t: Double, x: Float, y: Float, z: Float)]) -> String {
        guard let s = samples.last else { return "no data" }
        return String(format: "x %.1f, y %.1f, z %.1f", s.x, s.y, s.z)
    }
}
