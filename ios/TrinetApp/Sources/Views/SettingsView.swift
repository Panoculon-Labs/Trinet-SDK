// SettingsView.swift — codec / bitrate controls.
//
// Resolution and frame rate are fixed: the Trinet always streams 1080p @ 30 fps
// over NCM, so only the encoder (codec) and bitrate are user-adjustable.
// Hitting "Apply" pushes the config to the SDK (currently a local-only effect;
// firmware-side /api/config wiring is the next firmware task).

import SwiftUI
import TrinetSDK

struct SettingsView: View {
    @EnvironmentObject var device: DeviceViewModel

    @State private var codec: VideoCodec = .h265
    @State private var bitrateKbps: Int = 15000
    @State private var selectedPreset: String? = nil
    @State private var statusText: String?

    // Fixed format — 1080p30 over NCM.
    private let fixedResolution: VideoResolution = .res1080p
    private let fixedFps = 30

    // Only the FHD presets (codec/bitrate combos); resolution/fps are fixed.
    private var presets: [(label: String, config: DeviceConfig)] {
        DeviceConfig.presets.filter { $0.config.resolution == .res1080p }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Codec") {
                    Picker("Encoder", selection: $codec) {
                        ForEach(VideoCodec.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Format") {
                    HStack {
                        Text("Resolution / frame rate")
                        Spacer()
                        Text("1080p · 30 fps").foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }

                Section("Bitrate (\(bitrateKbps) kbps)") {
                    Slider(value: Binding(
                        get: { Double(bitrateKbps) },
                        set: { bitrateKbps = Int($0 / 500) * 500 }),
                        in: 1_000...30_000, step: 500)
                    Text("Higher = better quality, more bandwidth.")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("Presets") {
                    ForEach(presets, id: \.label) { p in
                        Button(action: { apply(preset: p.config); selectedPreset = p.label }) {
                            HStack {
                                Text(p.label)
                                Spacer()
                                if selectedPreset == p.label {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

                Section(footer: Text("Codec and bitrate are saved on this phone and used for local recording. Pushing them to the Trinet needs a firmware update (coming soon); until then the camera keeps its boot settings.")) {
                    Button {
                        Task { await applyToDevice() }
                    } label: {
                        if device.selected == nil {
                            Text("Connect a Trinet first").foregroundColor(.secondary)
                        } else {
                            Text("Save preference").bold()
                        }
                    }
                    .disabled(device.selected == nil)
                    if let s = statusText {
                        Text(s).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { snapshotCurrent() }
        }
    }

    private func snapshotCurrent() {
        let c = device.config
        codec = c.codec
        bitrateKbps = c.bitrateKbps
    }

    private func apply(preset c: DeviceConfig) {
        codec = c.codec
        bitrateKbps = c.bitrateKbps
    }

    private func applyToDevice() async {
        let c = DeviceConfig(codec: codec, resolution: fixedResolution,
                             fps: fixedFps, bitrateKbps: bitrateKbps)
        await device.apply(config: c)
        statusText = "Saved."
    }
}
