// ControlsView.swift — device controls (parity with the Android Controls
// screen): status LED, encoder bitrate, rate-control mode, persistent boot
// mode, and calibration read / upload (calibration.json or a packed .bin blob).

import SwiftUI
import UniformTypeIdentifiers
import TrinetSDK

struct ControlsView: View {
    @EnvironmentObject var deviceVM: DeviceViewModel
    @StateObject private var vm = ControlsViewModel()

    @State private var showImporter = false
    @State private var pendingMode: String?

    private var connected: Bool { deviceVM.selected != nil }
    private var enabled: Bool { connected && !vm.busy }

    var body: some View {
        NavigationStack {
            Form {
                if !connected {
                    Section {
                        Label("No camera connected. Open Home and Rescan.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundColor(.secondary)
                    }
                }

                ledSection
                rateControlSection
                bitrateSection
                bootModeSection
                calibrationSection

                if let msg = vm.message {
                    Section { Text(msg).font(.callout).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Controls")
            .toolbar {
                if vm.busy { ToolbarItem(placement: .navigationBarTrailing) { ProgressView() } }
            }
            .disabled(vm.busy)
            .onAppear { vm.device = deviceVM.selected }
            .onChange(of: deviceVM.deviceId) { _, _ in vm.device = deviceVM.selected }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json, .data],
                          allowsMultipleSelection: false) { result in
                if case let .success(urls) = result, let url = urls.first {
                    vm.uploadCalibration(from: url)
                } else if case let .failure(err) = result {
                    vm.message = err.localizedDescription
                }
            }
        }
    }

    // MARK: LED

    private var ledSection: some View {
        // Custom bindings apply the LED exactly once per user toggle (a plain
        // onChange would also fire when "All on/off" sets the channels).
        Section {
            Toggle("Red", isOn: Binding(get: { vm.ledR }, set: { vm.ledR = $0; vm.applyLed() }))
            Toggle("Green", isOn: Binding(get: { vm.ledG }, set: { vm.ledG = $0; vm.applyLed() }))
            Toggle("Blue", isOn: Binding(get: { vm.ledB }, set: { vm.ledB = $0; vm.applyLed() }))
            HStack {
                Button("All on") { vm.setAllLed(true) }
                Spacer()
                Button("All off") { vm.setAllLed(false) }
            }
            .disabled(!enabled)
        } header: {
            Text("Status LED")
        } footer: {
            Text("Channels are on/off — the LED has no brightness control.")
        }
        .disabled(!enabled)
    }

    // MARK: Rate control

    private var rateControlSection: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { vm.rcMode ?? "" },
                set: { if !$0.isEmpty { vm.setRcMode($0) } })) {
                Text("CBR").tag("cbr")
                Text("AVBR").tag("avbr")
                if vm.rcMode == nil { Text("—").tag("") }
            }
            .pickerStyle(.segmented)
            Button("Read current") { vm.readRcMode() }
        } header: {
            Text("Rate control")
        } footer: {
            Text("CBR holds image quality; AVBR clamps the average to the bitrate target. Persisted; the camera restarts to apply.")
        }
        .disabled(!enabled)
    }

    // MARK: Bitrate

    private var bitrateSection: some View {
        Section {
            HStack {
                TextField("kbps (256–30000)", text: $vm.bitrateField)
                    .keyboardType(.numberPad)
                Button("Apply") { vm.applyBitrate() }
            }
            Button("Read current") { vm.readBitrate() }
            if let kbps = vm.currentBitrate {
                Text("Current: \(kbps) kbps").foregroundColor(.secondary)
            }
        } header: {
            Text("Encoder bitrate")
        } footer: {
            Text("Persisted and shared with the camera's other streaming mode. The camera restarts (~15 s) to apply — reconnect from Home afterwards.")
        }
        .disabled(!enabled)
    }

    // MARK: Boot mode

    private var bootModeSection: some View {
        Section {
            HStack {
                ForEach(["uvc", "ncm", "imu"], id: \.self) { m in
                    Button(m.uppercased()) { pendingMode = m }
                        .buttonStyle(.bordered)
                        .tint(vm.currentMode == m ? .accentColor : .secondary)
                }
            }
            Button("Read current") { vm.readMode() }
            if let m = vm.currentMode {
                Text("Current: \(m.uppercased())").foregroundColor(.secondary)
            }
        } header: {
            Text("Boot mode")
        } footer: {
            Text("Boot mode is how the camera starts up when powered on. NCM streams to this iPhone app; UVC streams to the Android app; IMU records video and motion to an inserted SD card. Switching away from NCM reboots the camera and it leaves iPhone mode, so it will no longer appear here.")
        }
        .disabled(!enabled)
        .confirmationDialog(
            pendingMode.map { "Switch to \($0.uppercased())?" } ?? "",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible) {
            if let m = pendingMode {
                Button("Reboot camera", role: .destructive) { vm.setMode(m); pendingMode = nil }
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: {
            Text(pendingMode == "imu"
                ? "The camera restarts in IMU recording mode and records to an inserted SD card. It leaves iPhone mode, so it won't appear in this app. To return, insert an SD card with Trinet/trinet_mode.conf set to \"mode=ncm\" and power-cycle the camera."
                : "The camera reboots to apply. If you switch away from NCM it will no longer appear in this app.")
        }
    }

    // MARK: Calibration

    private var calibrationSection: some View {
        Section {
            HStack {
                Button("Read") { vm.readCalibration() }
                Spacer()
                Button("Upload from file") { showImporter = true }
            }
            .disabled(!enabled)
            if let summary = vm.calibSummary {
                Text(summary)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } header: {
            Text("Calibration")
        } footer: {
            Text("Upload a calibration.json (parsed on device) or a packed 200-byte .bin blob. The camera stores it and serves it back to any client.")
        }
    }
}
