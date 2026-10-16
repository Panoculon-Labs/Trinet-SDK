// ControlsView.swift — device controls (parity with the Android Controls
// screen): camera info, status LED (read back from the camera), microphone,
// image / white balance / exposure, encoder, thermal limit, Bluetooth status
// broadcast, boot mode, and mono or stereo calibration read / upload.
// Model-specific controls (temporal noise reduction on Pro Stereo GS, stereo
// calibration) are shown only for the models that have them.

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

                // Grouped so no single ViewBuilder block has more than 10 children.
                Group {
                    if let info = deviceVM.info { cameraInfoSection(info) }
                    ledSection
                    micAudioSection
                    imageSection
                    whiteBalanceSection
                    exposureSection
                    if deviceVM.info?.isGlobalShutter == true { noiseReductionSection }
                }
                Group {
                    codecSection
                    rateControlSection
                    bitrateSection
                    gopSection
                    streamSection
                    audioRateSection
                    thermalSection
                    bluetoothSection
                    bootModeSection
                    calibrationSection
                }

                if let msg = vm.message {
                    Section { Text(msg).font(.callout).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Controls")
            .toolbar {
                if vm.busy { ToolbarItem(placement: .navigationBarTrailing) { ProgressView() } }
            }
            .disabled(vm.busy)
            .onAppear { syncDevice() }
            .onChange(of: deviceVM.deviceId) { _, _ in syncDevice() }
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

    private func syncDevice() {
        vm.device = deviceVM.selected
        vm.info = deviceVM.info
        vm.refreshAudio()
        vm.refreshImageControls()
        vm.refreshParityControls()
        Task { await deviceVM.refreshStreamCodec() }
    }

    // MARK: Codecs

    /// Live-stream codec (to this iPhone) and the camera's own card-recording
    /// codec. Each row is hidden on firmware that doesn't offer the setting.
    @ViewBuilder
    private var codecSection: some View {
        if deviceVM.streamCodecSupported || vm.recordingCodec != nil {
            Section {
                if deviceVM.streamCodecSupported {
                    Picker("Stream codec (iPhone)", selection: Binding(
                        get: { deviceVM.streamCodec ?? .h264 },
                        set: { c in if c != deviceVM.streamCodec { vm.setStreamCodec(c, via: deviceVM) } })) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265").tag(VideoCodec.h265)
                    }
                    .disabled(deviceVM.streamRestarting)
                    if deviceVM.streamRestarting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Camera restarting stream…").foregroundColor(.secondary)
                        }
                    }
                }
                if let rc = vm.recordingCodec {
                    Picker("Card recording codec", selection: Binding(
                        get: { rc },
                        set: { c in if c != rc { vm.setRecordingCodec(c) } })) {
                        Text("H.264").tag(VideoCodec.h264)
                        Text("H.265").tag(VideoCodec.h265)
                    }
                }
            } header: {
                Text("Encoding")
            } footer: {
                Text("Stream codec is what the camera sends to this iPhone (preview and phone recordings); changing it restarts the camera's stream for ~5–10 s and stops any phone recording in progress. Card recording codec applies to the camera's own SD-card recordings only. Both are saved on the camera.")
            }
            .disabled(!enabled)
        }
    }

    // MARK: Camera info

    private func cameraInfoSection(_ info: TrinetDeviceInfo) -> some View {
        Section {
            LabeledContent("Model", value: info.displayName)
            if let fw = info.firmwareVersion {
                LabeledContent("Firmware", value: info.isDevBuild ? "\(fw) (development)" : fw)
            }
            if let gen = info.generation { LabeledContent("Generation", value: gen) }
            LabeledContent("Video",
                           value: "\(info.canvasWidth)×\(info.canvasHeight)"
                               + (info.isStereo ? " side-by-side (L | R)" : ""))
        } header: {
            Text("Camera")
        } footer: {
            if info.isStereo {
                Text("Both eyes stream as one side-by-side frame and are always recorded together. Pick L / Both / R on the Record tab to choose what the preview shows.")
            }
        }
    }

    // MARK: Temporal noise reduction (Pro Stereo GS)

    private var noiseReductionSection: some View {
        Section {
            Toggle("Temporal noise reduction",
                   isOn: Binding(get: { vm.tnrOn }, set: { vm.setTnr($0) }))
        } header: {
            Text("Noise reduction")
        } footer: {
            Text("Live. Reduces sensor noise across frames; turn off for the crispest motion.")
        }
        .disabled(!enabled)
    }

    // MARK: Thermal limit

    private var thermalSection: some View {
        Section {
            Picker("Limit", selection: Binding(
                get: { vm.thermalLimit ?? 0 },
                set: { vm.setThermalLimit($0 == 0 ? nil : $0) })) {
                Text("Camera default").tag(0)
                ForEach(Array(stride(from: vm.thermalLimitRange.lowerBound,
                                     through: vm.thermalLimitRange.upperBound, by: 5)), id: \.self) { c in
                    Text("\(c) °C").tag(c)
                }
                if let t = vm.thermalLimit, t % 5 != 0 { Text("\(t) °C").tag(t) }
            }
        } header: {
            Text("Thermal limit")
        } footer: {
            Text("The temperature at which the camera pauses recording to cool down. Saved on the camera; applies to the next recording.")
        }
        .disabled(!enabled)
    }

    // MARK: Bluetooth status broadcast

    private var bluetoothSection: some View {
        Section {
            if let on = vm.bleOn {
                Toggle("Broadcast status over Bluetooth",
                       isOn: Binding(get: { on }, set: { vm.setBle($0) }))
            } else {
                Text("Not available on this camera's firmware.")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Bluetooth")
        } footer: {
            Text("Lets nearby phones see recording status without a cable. Saved on the camera; takes effect the next time it boots.")
        }
        .disabled(!enabled)
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

    // MARK: Mic audio

    private var micAudioSection: some View {
        Section {
            Toggle("Mute", isOn: Binding(get: { vm.audioMuted }, set: { vm.setAudioMuted($0) }))
            Toggle("Auto gain", isOn: Binding(get: { vm.audioAgc }, set: { vm.setAudioAgc($0) }))
                .disabled(vm.audioMuted)
            VStack(alignment: .leading) {
                HStack {
                    Text("Gain")
                    Spacer()
                    Text(vm.audioAgc ? "auto" : "+\(Int(vm.audioGainDb.rounded())) dB")
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(get: { vm.audioGainDb }, set: { vm.audioGainDb = $0 }),
                    in: ControlsViewModel.audioGainDbRange, step: 1,
                    onEditingChanged: { editing in if !editing { vm.setAudioGainDb(vm.audioGainDb) } })
                    .disabled(vm.audioAgc || vm.audioMuted)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("The gain is applied on the camera, so it changes the actual recording — not just playback. Auto gain levels the volume automatically; mute records silence.")
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
            Text(deviceVM.isStereo
                 ? "Upload a stereo calibration JSON (cameras: [left, right] plus T_cam0_imu / T_cam1_cam0, parsed on device) or a packed 300-byte stereo .bin blob. The camera stores it and serves it back to any client."
                 : "Upload a calibration.json (parsed on device) or a packed 200-byte .bin blob. The camera stores it and serves it back to any client.")
        }
    }

    // MARK: Image controls

    /// A labelled slider that applies live on release (not on every drag tick).
    private func imageSlider(_ title: String, _ value: Binding<Double>,
                             _ range: ClosedRange<Double>, suffix: String = "",
                             apply: @escaping () -> Void) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)").foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: 1,
                   onEditingChanged: { editing in if !editing { apply() } })
        }
    }

    private var imageSection: some View {
        Section {
            imageSlider("Brightness", $vm.brightness, 0...255) { vm.applyBrightness() }
            imageSlider("Contrast", $vm.contrast, 0...255) { vm.applyContrast() }
            imageSlider("Saturation", $vm.saturation, 0...200, suffix: "%") { vm.applySaturation() }
            imageSlider("Sharpness", $vm.sharpness, 0...100) { vm.applySharpness() }
            imageSlider("Hue", $vm.hue, 0...100) { vm.applyHue() }
        } header: {
            Text("Image")
        } footer: {
            Text("Live — the camera adjusts the picture immediately (no restart). Saturation 0 is grayscale, 100 neutral. Hue 50 is neutral.")
        }
        .disabled(!enabled)
    }

    // MARK: White balance

    private var whiteBalanceSection: some View {
        Section {
            Toggle("Auto white balance", isOn: Binding(get: { vm.wbAuto }, set: { vm.setWbAuto($0) }))
            if !vm.wbAuto {
                imageSlider("Temperature", $vm.wbTemp, 2800...6500, suffix: " K") { vm.applyWbTemp() }
                imageSlider("Red gain", $vm.wbRGain, 0...1024) { vm.applyWbComponent() }
                imageSlider("Blue gain", $vm.wbBGain, 0...1024) { vm.applyWbComponent() }
            }
            HStack {
                Text("AWB tuning")
                Spacer()
                Text(vm.awbTuneSummary ?? "—")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button("Read AWB tuning") { vm.readAwbTune() }
        } header: {
            Text("White balance")
        } footer: {
            Text("Auto runs AWB. Turn it off for manual colour temperature, or per-channel Red/Blue gain (256 = 1.0×).")
        }
        .disabled(!enabled)
    }

    // MARK: Exposure

    private var exposureSection: some View {
        Section {
            Toggle("Manual exposure", isOn: Binding(get: { vm.exposureManual }, set: { vm.setExposureManual($0) }))
            if vm.exposureManual {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Exposure time")
                        Spacer()
                        Text(String(format: "%.1f ms", vm.exposureTime / 10.0)).foregroundColor(.secondary)
                    }
                    Slider(value: $vm.exposureTime, in: ControlsViewModel.exposureTimeRange, step: 5,
                           onEditingChanged: { editing in if !editing { vm.applyExposureTime() } })
                }
                imageSlider("Gain", $vm.gain, 0...64) { vm.applyGain() }
            }
            HStack {
                TextField("min µs", text: $vm.expMinUsField).keyboardType(.numberPad)
                TextField("max µs", text: $vm.expMaxUsField).keyboardType(.numberPad)
                Button("Apply") { vm.applyExposureRange() }
            }
            Picker("Anti-flicker", selection: Binding(get: { vm.mainsHz }, set: { vm.setMains($0) })) {
                Text("50 Hz").tag(50)
                Text("60 Hz").tag(60)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Exposure")
        } footer: {
            Text("Manual mode, exposure time (0.5–250 ms) and gain are live. The exposure µs range and anti-flicker frequency are persisted and the camera restarts to apply — reconnect from Home.")
        }
        .disabled(!enabled)
    }

    // MARK: GOP

    private var gopSection: some View {
        Section {
            HStack {
                TextField("frames (1–600)", text: $vm.gopField).keyboardType(.numberPad)
                Button("Apply") { vm.applyGop() }
            }
        } header: {
            Text("Keyframe interval (GOP)")
        } footer: {
            Text("Frames between keyframes. Persisted; the camera restarts to apply — reconnect from Home.")
        }
        .disabled(!enabled)
    }

    // MARK: Stream toggles

    private var streamSection: some View {
        Section {
            Toggle("Embed IMU in stream", isOn: Binding(get: { vm.imuStreamOn }, set: { vm.setImuStream($0) }))
            Toggle("Lock calibration", isOn: Binding(get: { vm.calibLocked }, set: { vm.setCalibLock($0) }))
        } header: {
            Text("Stream & calibration lock")
        } footer: {
            Text("Live. IMU embedding adds motion samples to the video stream. Locking calibration makes the camera reject calibration uploads until unlocked.")
        }
        .disabled(!enabled)
    }

    // MARK: Audio sample rate

    private var audioRateSection: some View {
        Section {
            Picker("Sample rate", selection: Binding(get: { vm.audioRateHz }, set: { vm.setAudioRate($0) })) {
                Text("16 kHz").tag(16000)
                Text("44.1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Audio sample rate")
        } footer: {
            Text("Persisted; the camera restarts to apply — reconnect from Home.")
        }
        .disabled(!enabled)
    }
}
