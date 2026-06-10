// SettingsView.swift — minimal app settings: video encoding.
//
// The only runtime knob is the codec. It selects which `/live.<codec>`
// endpoint the SDK requests; H.264 is the default. Changing it restarts the
// Record screen's live session. The camera must be running firmware that
// actually streams the selected codec.

import SwiftUI
import TrinetSDK

struct SettingsView: View {
    @EnvironmentObject var device: DeviceViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Encoding", selection: $device.codec) {
                        ForEach(VideoCodec.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Video encoding")
                } header: {
                    Text("Video encoding")
                } footer: {
                    Text("H.264 is the default. Switch to H.265 (HEVC) for smaller files at the same quality. The camera must be running firmware that streams the selected codec; changing this restarts the live preview.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
