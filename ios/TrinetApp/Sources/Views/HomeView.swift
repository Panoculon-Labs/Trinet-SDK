// HomeView.swift — device list + connection status.

import SwiftUI
import TrinetSDK

struct HomeView: View {
    @EnvironmentObject var device: DeviceViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Connected Trinet") {
                    if device.devices.isEmpty {
                        if device.isScanning {
                            HStack { ProgressView(); Text("Scanning USB interfaces…") }
                        } else {
                            Label("No Trinet found", systemImage: "exclamationmark.triangle")
                                .foregroundColor(.secondary)
                            Text("Plug a Trinet into the USB-C port and tap Rescan. The device shows up as an Ethernet adapter in Settings.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        ForEach(device.devices, id: \.host) { d in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(d.host).font(.headline)
                                    if device.selected?.host == d.host, let info = device.info {
                                        Text(modelLine(info))
                                            .font(.subheadline)
                                    }
                                    if !device.deviceId.isEmpty,
                                       device.selected?.host == d.host {
                                        Text(device.deviceId.prefix(16) + "…")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if device.selected?.host == d.host {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task {
                                    device.selected = d
                                    await device.refreshInfo(for: d)
                                }
                            }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Selects this Trinet")
                        }
                    }
                }

                if let err = device.lastError {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundColor(.secondary)
                        Button {
                            Task { await device.scan() }
                        } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    }
                }
            }
            .navigationTitle("Trinet")
            .refreshable { await device.scan() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await device.scan() }
                    } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Rescan")
                }
            }
        }
    }

    /// e.g. "Trinet Pro Stereo · 0.5.10 · 3840×1080 side-by-side".
    private func modelLine(_ info: TrinetDeviceInfo) -> String {
        var parts = [info.displayName]
        if let fw = info.firmwareVersion { parts.append(info.isDevBuild ? "\(fw) dev" : fw) }
        parts.append("\(info.canvasWidth)×\(info.canvasHeight)\(info.isStereo ? " side-by-side" : "")")
        return parts.joined(separator: " · ")
    }

}
