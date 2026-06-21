// SettingsView.swift — minimal app settings: video encoding.
//
// The only runtime knob is the codec. It selects which `/live.<codec>`
// endpoint the SDK requests; H.264 is the default. Changing it restarts the
// Record screen's live session. The camera must be running firmware that
// actually streams the selected codec.

import SwiftUI
import TrinetSDK

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Encoding")
                        Spacer()
                        Text("H.264 (AVC)").foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Video encoding")
                } footer: {
                    Text("Recordings use H.264 (AVC) — hardware-decodable on every phone, and the camera's default. H.265 selection has been removed.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
