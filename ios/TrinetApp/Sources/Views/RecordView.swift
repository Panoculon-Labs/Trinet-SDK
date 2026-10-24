// RecordView.swift — live preview + IMU plot + big record button.

import SwiftUI
import TrinetSDK

struct RecordView: View {
    @EnvironmentObject var device: DeviceViewModel
    @StateObject private var vm = RecordViewModel()
    @Environment(\.scenePhase) private var scenePhase
    /// Stereo preview lens (display-only; recordings always keep both eyes).
    @AppStorage("trinet.preview.lens") private var lensRaw: String = StereoLens.left.rawValue

    private var lens: StereoLens { StereoLens(rawValue: lensRaw) ?? .left }

    /// Preview aspect: one eye (16:9) or the full side-by-side canvas (32:9)
    /// on stereo; the plain frame (16:9) on mono.
    private var previewAspect: Double {
        device.info?.previewAspect(for: lens) ?? 16.0 / 9.0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    previewCard
                    if device.isStereo { lensPicker }
                    imuCard
                    controlsCard
                    if vm.isThermalPaused {
                        Label("Camera too hot — recording paused. It resumes automatically once cooled.",
                              systemImage: "thermometer.sun.fill")
                            .font(.caption).foregroundColor(.orange)
                            .padding(.horizontal)
                    }
                    if vm.currentMp4URL != nil && !vm.isRecording {
                        Label("Saved to Library", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                    }
                    if let err = vm.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Record")
            .task(id: "\(device.selected?.host ?? "none")|\(device.streamRestarting)") {
                // Restart the session when the selected device changes, or
                // around a stream-codec change (closed while the camera
                // restarts its stream, reopened afterwards).
                await vm.closeSession()
                if let dev = device.selected, !device.streamRestarting {
                    await vm.openSession(on: dev)
                }
            }
            .onDisappear {
                Task { await vm.closeSession() }
            }
            .onChange(of: scenePhase) { _, phase in
                // While recording the app stays alive in the background (the
                // recording keeps going); otherwise the stream is closed and
                // reopened when the app comes back.
                switch phase {
                case .background: Task { await vm.appDidEnterBackground() }
                case .active:     Task { await vm.appDidBecomeActive() }
                default:          break
                }
            }
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black)
                .aspectRatio(previewAspect, contentMode: .fit)
            if let stream = vm.sampleStream {
                LivePreviewView(stream: stream, lens: device.isStereo ? lens : .both)
                    .aspectRatio(previewAspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 6) {
                    if device.streamRestarting {
                        ProgressView()
                            .tint(.white)
                        Text("Camera restarting stream…")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.caption)
                    } else if vm.isThermalPaused {
                        Image(systemName: "thermometer.sun.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text("Cooling down… \(vm.thermalTempC)°C")
                            .foregroundColor(.white.opacity(0.8))
                            .font(.caption)
                    } else if device.selected == nil {
                        Image(systemName: "video.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.6))
                        Text("No Trinet connected")
                            .foregroundColor(.white.opacity(0.6))
                    } else if !vm.sessionActive {
                        ProgressView()
                            .tint(.white)
                        Text("Opening stream…")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.caption)
                    }
                }
            }
            if vm.isRecording {
                VStack {
                    HStack {
                        Circle().fill(Color.red).frame(width: 10, height: 10)
                        Text("REC \(timeString(vm.elapsed))")
                            .font(.caption.bold().monospacedDigit())
                            .foregroundColor(.white)
                        Spacer()
                        Text(byteString(vm.bytesRecorded))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.45))
                    .clipShape(Capsule())
                    .padding(8)
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
    }

    /// L | Both | R — which eye(s) of the stereo canvas to preview. Display
    /// only: switching is instant and allowed while recording.
    private var lensPicker: some View {
        Picker("Lens", selection: $lensRaw) {
            Text("L").tag(StereoLens.left.rawValue)
            Text("Both").tag(StereoLens.both.rawValue)
            Text("R").tag(StereoLens.right.rawValue)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .accessibilityLabel("Preview lens")
        .accessibilityHint("Recording always keeps both eyes")
    }

    private var imuCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            ImuPlotView(history: vm.imuHistory)
        }
    }

    private var controlsCard: some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    if vm.isRecording {
                        await vm.stopRecording()
                    } else {
                        await vm.startRecording(into: RecordViewModel.recordingsDirectory)
                    }
                }
            } label: {
                ZStack {
                    Circle().stroke(Color.gray, lineWidth: 4)
                        .frame(width: 84, height: 84)
                    if vm.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle().fill(Color.red).frame(width: 68, height: 68)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(device.selected == nil || !vm.sessionActive)
            .accessibilityLabel(vm.isRecording ? "Stop recording" : "Start recording")
            .accessibilityValue(vm.isRecording ? "Recording, \(timeString(vm.elapsed))" : "Idle")
            .accessibilityAddTraits(.isButton)

            Group {
                if device.selected == nil {
                    Text("Connect a Trinet to record")
                } else if !vm.sessionActive {
                    Text("Opening stream…")
                } else {
                    Text(vm.isRecording ? "Tap to stop" : "Tap to record")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.top, 4)
    }

    /// Unified timecode across the app: MM:SS, rolling into H:MM:SS past an hour.
    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    private func byteString(_ b: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
