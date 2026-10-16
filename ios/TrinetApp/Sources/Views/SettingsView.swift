// SettingsView.swift — minimal app settings: video encoding.
//
// The live-stream codec is a camera setting, not an app setting: the SDK asks
// the camera what it streams (and confirms it from the stream itself). It is
// changed from Controls → Encoding, alongside the card-recording codec.

import SwiftUI
import TrinetSDK

struct SettingsView: View {
    @EnvironmentObject var device: DeviceViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Live stream")
                        Spacer()
                        Text(device.selected == nil ? "—" : device.codec.displayName)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Video encoding")
                } footer: {
                    Text(device.streamCodecSupported
                         ? "The camera decides the stream codec. Change it in Controls → Encoding (the camera restarts its stream for a few seconds)."
                         : "This camera streams H.264 (AVC). Newer firmware lets you choose H.265 in Controls → Encoding.")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
