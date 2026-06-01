// RecordView.swift — live preview + IMU plot + big record button.

import SwiftUI
import TrinetSDK

struct RecordView: View {
    @EnvironmentObject var device: DeviceViewModel
    @StateObject private var vm = RecordViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    previewCard
                    imuCard
                    controlsCard
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
            .task(id: device.selected?.host) {
                // Restart session when the selected device changes (or first appears).
                await vm.closeSession()
                if let dev = device.selected {
                    await vm.openSession(on: dev)
                }
            }
            .onDisappear {
                Task { await vm.closeSession() }
            }
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black)
                .aspectRatio(16.0/9.0, contentMode: .fit)
            if let stream = vm.sampleStream {
                LivePreviewView(stream: stream)
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 6) {
                    if device.selected == nil {
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
