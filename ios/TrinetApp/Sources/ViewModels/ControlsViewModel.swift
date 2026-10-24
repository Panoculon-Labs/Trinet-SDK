// ControlsViewModel.swift — owns the Controls screen state and routes every
// control through the selected TrinetDevice's API. Mirrors the Android app's
// ControlsViewModel: LED, encoder bitrate + rate-control mode, persistent boot
// mode, and calibration read / upload.
//
// Bitrate / rate-control / mode changes are persisted on the camera and cause
// it to restart (mode reboots and re-enumerates), so after one the live
// connection drops and the camera must be rediscovered from Home.

import Foundation
import TrinetSDK

@MainActor
final class ControlsViewModel: ObservableObject {
    @Published var busy = false
    @Published var message: String?

    // LED channels (last set; the hardware has no PWM so these are on/off).
    @Published var ledR = true
    @Published var ledG = true
    @Published var ledB = true

    // Encoder bitrate.
    @Published var bitrateField = ""
    @Published var currentBitrate: Int?

    // Rate-control mode: "cbr" | "avbr" (nil = unknown / not yet read).
    @Published var rcMode: String?

    // Persistent boot mode: "uvc" | "ncm" | "imu" (nil = unknown).
    @Published var currentMode: String?

    // Mic audio: manual gain (dB), mute, auto-gain. Persisted app-side (the camera
    // resets to its default gain on reboot) and pushed on connect.
    @Published var audioGainDb: Double = 6
    @Published var audioMuted = false
    @Published var audioAgc = false
    static let audioGainDbRange: ClosedRange<Double> = 0...24

    // Calibration summary (multi-line) and whether one is stored.
    @Published var calibSummary: String?

    // §5 image controls (live; the camera actuates the ISP immediately).
    @Published var brightness: Double = 128   // 0...255
    @Published var contrast:   Double = 128   // 0...255
    @Published var saturation: Double = 100   // 0...200 % (0 = grayscale)
    @Published var sharpness:  Double = 50    // 0...100
    @Published var gain:       Double = 1     // manual AE gain (honoured in manual mode)
    @Published var wbAuto = true              // auto WB vs manual temperature/component
    @Published var wbTemp:  Double = 5000     // 2800...6500 K (manual WB)
    @Published var wbRGain: Double = 256      // Q8.8, 256 = 1.0
    @Published var wbBGain: Double = 256
    @Published var exposureManual = false     // false = auto AE, true = manual

    // §5 exposure range + mains (persisted; camera reboots to apply).
    @Published var expMinUsField = ""
    @Published var expMaxUsField = ""
    @Published var mainsHz = 50               // 50 | 60

    // §6 encoder / stream controls.
    @Published var gopField = ""              // frames (reboot)
    @Published var imuStreamOn = true         // live
    @Published var calibLocked = false        // live

    // §10 audio sample rate (persisted; camera reboots to apply).
    @Published var audioRateHz = 48000        // 16000 | 44100 | 48000

    // NCM-parity controls.
    @Published var hue: Double = 50           // 0...100 (50 = neutral), live
    /// Manual exposure time in units of 100 µs (5...2500 = 0.5...250 ms), live,
    /// manual exposure mode only.
    @Published var exposureTime: Double = 100
    static let exposureTimeRange: ClosedRange<Double> = 5...2500
    /// Recording thermal limit in °C; nil = firmware default.
    @Published var thermalLimit: Int?
    @Published var thermalLimitRange: ClosedRange<Int> = TrinetDevice.thermalLimitRange
    /// Bluetooth LE status broadcast (applies from the next boot); nil = unknown/unsupported.
    @Published var bleOn: Bool?
    /// AWB tuning table read-out (nil = not read / unsupported).
    @Published var awbTuneSummary: String?
    /// Temporal noise reduction (Pro Stereo GS only).
    @Published var tnrOn = false
    /// Codec of the camera's own SD-card recordings; nil = unknown / not
    /// supported by this firmware (picker hidden).
    @Published var recordingCodec: VideoCodec?
    /// Minutes per card-recording part; 0 = one continuous file. nil = unknown
    /// or firmware without the control.
    @Published var recordingChunkMinutes: Int?
    /// Extra 180-degree rotation for an inverted (cap) mount. nil = unknown.
    @Published var imageFlip: Bool?
    /// Card recording audio format. nil = unknown.
    @Published var recordingAudioFormat: AudioFormat?

    /// The currently-selected device; the view keeps this in sync with the
    /// shared DeviceViewModel.
    var device: TrinetDevice?
    /// Model info of the selected device (gates stereo / GS-only controls).
    var info: TrinetDeviceInfo?

    private func run(_ label: String, _ action: @escaping () async throws -> Void) {
        guard device != nil else { message = "No camera connected. Rescan from Home."; return }
        busy = true; message = nil
        Task {
            do { try await action() }
            catch { message = friendlyTrinetError(error) }
            busy = false
        }
    }

    // MARK: LED

    func applyLed() {
        run("led") { [self] in _ = try await device?.setLed(r: ledR, g: ledG, b: ledB) }
    }

    func setAllLed(_ on: Bool) {
        ledR = on; ledG = on; ledB = on
        applyLed()
    }

    // MARK: Bitrate

    func applyBitrate() {
        guard let kbps = Int(bitrateField.trimmingCharacters(in: .whitespaces)) else {
            message = "Enter a whole number of kbps."; return
        }
        guard (256...30000).contains(kbps) else {
            message = "Bitrate must be 256–30000 kbps."; return
        }
        run("bitrate") { [self] in
            try await device?.setBitrate(kbps: kbps)
            message = "Set \(kbps) kbps. The camera restarts (~15 s) to apply — reconnect from Home."
        }
    }

    func readBitrate() {
        run("bitrate") { [self] in currentBitrate = try await device?.bitrate() }
    }

    // MARK: Rate-control mode

    func setRcMode(_ mode: String) {
        run("rcmode") { [self] in
            try await device?.setRateControlMode(mode)
            rcMode = mode
            message = "Set \(mode.uppercased()). The camera restarts (~15 s) to apply — reconnect from Home."
        }
    }

    func readRcMode() {
        run("rcmode") { [self] in rcMode = try await device?.rateControlMode() }
    }

    // MARK: Boot mode

    func setMode(_ mode: String) {
        run("mode") { [self] in
            try await device?.setMode(mode)
            message = mode == "ncm"
                ? "Staying in iPhone (NCM) mode; the camera reboots to apply."
                : "Switching to \(mode.uppercased()). The camera reboots and leaves iPhone mode — it will no longer appear here."
        }
    }

    func readMode() {
        run("mode") { [self] in currentMode = try await device?.currentMode() }
    }

    // MARK: Mic audio

    private static let kGainDb = "trinet.audio.gainDb"
    private static let kMuted  = "trinet.audio.muted"
    private static let kAgc    = "trinet.audio.agc"

    /// Load the persisted audio preference and push it to the camera (the camera
    /// resets to its default gain on reboot, so the app is the source of truth).
    /// Falls back to whatever the camera reports if nothing is stored yet.
    func refreshAudio() {
        guard let device else { return }
        let ud = UserDefaults.standard
        let hasStored = ud.object(forKey: Self.kGainDb) != nil
        if hasStored {
            audioGainDb = ud.double(forKey: Self.kGainDb)
            audioMuted = ud.bool(forKey: Self.kMuted)
            audioAgc = ud.bool(forKey: Self.kAgc)
        }
        Task {
            do {
                if hasStored {
                    try await device.setAudio(gainQ8: trinetAudioGainDbToQ8(audioGainDb),
                                              muted: audioMuted, agc: audioAgc)
                } else if let a = try? await device.audio() {
                    audioGainDb = min(max(a.gainDb, Self.audioGainDbRange.lowerBound),
                                      Self.audioGainDbRange.upperBound)
                    audioMuted = a.isMuted
                    audioAgc = a.isAgc
                }
            } catch { /* pre-v4 camera ignores audio control */ }
        }
    }

    func setAudioGainDb(_ db: Double) {
        audioGainDb = db
        UserDefaults.standard.set(db, forKey: Self.kGainDb)
        applyAudio()
    }

    func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        UserDefaults.standard.set(muted, forKey: Self.kMuted)
        applyAudio()
    }

    func setAudioAgc(_ agc: Bool) {
        audioAgc = agc
        UserDefaults.standard.set(agc, forKey: Self.kAgc)
        applyAudio()
    }

    private func applyAudio() {
        guard let device else { return }
        let q8 = trinetAudioGainDbToQ8(audioGainDb)
        let muted = audioMuted, agc = audioAgc
        Task { try? await device.setAudio(gainQ8: q8, muted: muted, agc: agc) }
    }

    // MARK: §5 image controls (live)

    /// Read all live image-control values from the camera into the sliders.
    /// Best-effort: a pre-parity camera 404s these and we just keep the defaults.
    func refreshImageControls() {
        guard let device else { return }
        Task {
            if let v = try? await device.brightness() { brightness = Double(v) }
            if let v = try? await device.contrast()   { contrast   = Double(v) }
            if let v = try? await device.saturation() { saturation = Double(v) }
            if let v = try? await device.sharpness()  { sharpness  = Double(v) }
            if let v = try? await device.gain()       { gain       = Double(v) }
            if let v = try? await device.whiteBalanceAuto() { wbAuto = v }
            if let v = try? await device.whiteBalanceTemperature() { wbTemp = Double(v) }
            if let v = try? await device.whiteBalanceComponent() { wbRGain = Double(v.rGain); wbBGain = Double(v.bGain) }
            if let v = try? await device.exposureMode() { exposureManual = (v == "manual") }
            if let v = try? await device.imuStream() { imuStreamOn = v }
            if let v = try? await device.calibrationLock() { calibLocked = v }
        }
    }

    /// Read the NCM-parity controls (LED state, hue, exposure time, thermal
    /// limit, BLE, AWB tune, TNR on GS). Best-effort: older firmware 404s
    /// these and the defaults stay.
    func refreshParityControls() {
        guard let device else { return }
        let isGS = info?.isGlobalShutter ?? false
        Task {
            if let l = try? await device.led() { ledR = l.r; ledG = l.g; ledB = l.b }
            if let v = try? await device.hue() { hue = Double(v) }
            if let v = try? await device.exposureTime() { exposureTime = Double(v) }
            if let t = try? await device.thermalLimitInfo() {
                thermalLimit = t.isDefault ? nil : t.celsius
                if let lo = t.min, let hi = t.max, lo <= hi { thermalLimitRange = lo...hi }
            }
            bleOn = try? await device.bleBroadcast()
            recordingCodec = try? await device.recordingCodec()
            if let c = try? await device.recordingChunk() { recordingChunkMinutes = c.minutes }
            if let f = try? await device.imageFlip() { imageFlip = f.isOn }
            if let a = try? await device.recordingAudioFormat() {
                recordingAudioFormat = AudioFormat(rawValue: a.format)
            }
            readAwbTuneQuietly()
            if isGS, let v = try? await device.temporalNoiseReduction() { tnrOn = v }
        }
    }

    // MARK: NCM-parity controls

    func applyHue() { run("hue") { [self] in try await device?.setHue(Int(hue)) } }

    func applyExposureTime() {
        guard exposureManual else {
            message = "Switch exposure to manual first — exposure time only applies in manual mode."; return
        }
        let units = Int(exposureTime)
        run("exposure_time") { [self] in
            do { try await device?.setExposureTime(units100us: units) }
            catch DeviceAPI.APIError.http(409) {
                message = "The camera is in auto exposure — switch to manual first."
            }
        }
    }

    /// nil = firmware default (sends 0).
    func setThermalLimit(_ celsius: Int?) {
        thermalLimit = celsius
        run("thermal_limit") { [self] in
            try await device?.setThermalLimit(celsius: celsius ?? 0)
            message = celsius.map { "Thermal limit \($0) °C — applies to the next recording." }
                ?? "Thermal limit reset to the camera default — applies to the next recording."
        }
    }

    func setBle(_ on: Bool) {
        bleOn = on
        run("ble") { [self] in
            try await device?.setBleBroadcast(on)
            message = "Bluetooth status broadcast \(on ? "on" : "off") — takes effect the next time the camera boots."
        }
    }

    // MARK: Codecs

    /// Card (SD) recording codec — persisted on the camera, no restart.
    /// Split card recordings every `minutes` (0 = one continuous file).
    /// Applies to the camera's next recording; no restart.
    func setRecordingChunk(minutes: Int) {
        let previous = recordingChunkMinutes
        recordingChunkMinutes = minutes
        run("recording_chunk") { [self] in
            do {
                try await device?.setRecordingChunk(minutes: minutes)
                message = minutes > 0
                    ? "Card recordings will be split every \(minutes) min — from the next recording."
                    : "Card recordings will be one continuous file — from the next recording."
            } catch {
                recordingChunkMinutes = previous
                throw error
            }
        }
    }

    /// Rotate the picture 180 degrees for an inverted mount. The camera
    /// restarts, so this connection drops and comes back.
    func setImageFlip(_ on: Bool) {
        let previous = imageFlip
        imageFlip = on
        run("image_flip") { [self] in
            do {
                try await device?.setImageFlip(on)
                message = on
                    ? "Picture rotated 180° — the camera is restarting."
                    : "Picture back to normal — the camera is restarting."
            } catch {
                imageFlip = previous
                throw error
            }
        }
    }

    /// Card recording audio format. The camera restarts to apply.
    func setRecordingAudioFormat(_ format: AudioFormat) {
        let previous = recordingAudioFormat
        recordingAudioFormat = format
        run("recording_audio_format") { [self] in
            do {
                try await device?.setRecordingAudioFormat(format.rawValue)
                message = format == .pcm
                    ? "Card recordings will also get an uncompressed .wav — the camera is restarting."
                    : "Card recordings will have AAC audio only — the camera is restarting."
            } catch {
                recordingAudioFormat = previous
                throw error
            }
        }
    }

    func setRecordingCodec(_ codec: VideoCodec) {
        let previous = recordingCodec
        recordingCodec = codec
        run("recording_codec") { [self] in
            do {
                try await device?.setRecordingCodec(codec)
                message = "Card recordings will use \(codec.displayName)."
            } catch {
                recordingCodec = previous
                throw error
            }
        }
    }

    /// Live-stream codec. The camera restarts its stream (~5–10 s); the shared
    /// DeviceViewModel closes and reopens the Record screen's session.
    func setStreamCodec(_ codec: VideoCodec, via deviceVM: DeviceViewModel) {
        guard device != nil else { message = "No camera connected. Rescan from Home."; return }
        busy = true
        message = "Camera restarting stream…"
        Task {
            let err = await deviceVM.changeStreamCodec(codec)
            message = err ?? "Live stream now uses \(codec.displayName)."
            busy = false
        }
    }

    func setTnr(_ on: Bool) {
        tnrOn = on
        run("tnr") { [self] in try await device?.setTemporalNoiseReduction(on) }
    }

    func readAwbTune() {
        run("awb_tune") { [self] in
            guard let t = try await device?.awbTune() else { return }
            awbTuneSummary = Self.summarize(t)
        }
    }

    private func readAwbTuneQuietly() {
        guard let device else { return }
        Task {
            if let t = try? await device.awbTune() { awbTuneSummary = Self.summarize(t) }
        }
    }

    private static func summarize(_ t: DeviceAPI.AwbTuneResponse) -> String {
        if t.anchors == 0 { return "Untuned (camera defaults)" }
        let plural = t.anchors == 1 ? "" : "s"
        return "\(t.anchors) anchor\(plural) · last "
            + String(format: "%.0f K  r %.3f  b %.3f", t.cct, t.r, t.b)
    }

    func applyBrightness() { run("brightness") { [self] in try await device?.setBrightness(Int(brightness)) } }
    func applyContrast()   { run("contrast")   { [self] in try await device?.setContrast(Int(contrast)) } }
    func applySaturation() { run("saturation") { [self] in try await device?.setSaturation(Int(saturation)) } }
    func applySharpness()  { run("sharpness")  { [self] in try await device?.setSharpness(Int(sharpness)) } }
    func applyGain()       { run("gain")       { [self] in try await device?.setGain(Int(gain)) } }
    func applyWbTemp()     { run("wb")         { [self] in try await device?.setWhiteBalanceTemperature(kelvin: Int(wbTemp)) } }
    func applyWbComponent(){ run("wb")         { [self] in try await device?.setWhiteBalanceComponent(rGain: Int(wbRGain), bGain: Int(wbBGain)) } }

    func setWbAuto(_ on: Bool) {
        wbAuto = on
        run("wb") { [self] in try await device?.setWhiteBalanceAuto(on) }
    }

    func setExposureManual(_ manual: Bool) {
        exposureManual = manual
        run("exposure_mode") { [self] in try await device?.setExposureMode(manual ? "manual" : "auto") }
    }

    // MARK: §5 exposure range + mains (reboot)

    func applyExposureRange() {
        guard let lo = Int(expMinUsField.trimmingCharacters(in: .whitespaces)),
              let hi = Int(expMaxUsField.trimmingCharacters(in: .whitespaces)), lo > 0, hi >= lo else {
            message = "Enter min/max exposure in microseconds (max ≥ min)."; return
        }
        run("exposure") { [self] in
            try await device?.setExposureRange(minUs: lo, maxUs: hi)
            message = "Set exposure \(lo)–\(hi) µs. The camera restarts to apply — reconnect from Home."
        }
    }

    func setMains(_ hz: Int) {
        mainsHz = hz
        run("power_line") { [self] in
            try await device?.setMainsFrequency(hz: hz)
            message = "Set \(hz) Hz anti-flicker. The camera restarts to apply — reconnect from Home."
        }
    }

    // MARK: §6 encoder / stream controls

    func applyGop() {
        guard let frames = Int(gopField.trimmingCharacters(in: .whitespaces)), (1...600).contains(frames) else {
            message = "GOP must be 1–600 frames."; return
        }
        run("gop") { [self] in
            try await device?.setGop(frames: frames)
            message = "Set GOP \(frames). The camera restarts to apply — reconnect from Home."
        }
    }

    func setImuStream(_ on: Bool) {
        imuStreamOn = on
        run("imu_stream") { [self] in try await device?.setImuStream(on) }
    }

    func setCalibLock(_ on: Bool) {
        calibLocked = on
        run("calibration_lock") { [self] in try await device?.setCalibrationLock(on) }
    }

    // MARK: §10 audio sample rate (reboot)

    func setAudioRate(_ hz: Int) {
        audioRateHz = hz
        run("audio_rate") { [self] in
            try await device?.setAudioRate(hz: hz)
            message = "Set \(hz) Hz audio. The camera restarts to apply — reconnect from Home."
        }
    }

    // MARK: Calibration

    func readCalibration() {
        run("calibration") { [self] in
            // device?.getCalibrationAny() is TrinetCalibration?? (optional chain
            // over an optional return) — flatten before binding.
            let any = (try await device?.getCalibrationAny()) ?? nil
            if let any {
                calibSummary = Self.summarize(any)
            } else {
                calibSummary = "No calibration stored on the camera."
            }
        }
    }

    /// Upload a calibration from a picked file: a mono `calibration.json` or a
    /// stereo calibration JSON (`cameras`: [left, right]) — both parsed
    /// on-device — or a pre-packed `.bin` blob (200-byte mono / 300-byte stereo).
    func uploadCalibration(from url: URL) {
        run("calibration") { [self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)

            let cal: TrinetCalibration
            if url.pathExtension.lowercased() == "json" || Self.looksLikeJson(data) {
                guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    message = "Couldn't read the file as JSON."; return
                }
                if StereoCalibrationBlob.isStereoCalibrationJson(root) {
                    guard let s = StereoCalibrationBlob.fromStereoCalibrationJson(root) else {
                        message = "That stereo JSON couldn't be parsed (check T_cam0_imu / T_cam1_cam0)."; return
                    }
                    cal = .stereo(s)
                } else {
                    guard let m = CalibrationBlob.fromCalibrationJson(root) else {
                        message = "That JSON has no usable camera intrinsics."; return
                    }
                    cal = .mono(m)
                }
            } else {
                guard let decoded = TrinetCalibration.decode(from: data) else {
                    message = "Not a valid calibration blob (200-byte mono or 300-byte stereo)."; return
                }
                cal = decoded
            }

            // Refuse an obvious mismatch when the camera's model is known.
            if let info, info.model != .unknown, info.isStereo != cal.isStereo {
                message = info.isStereo
                    ? "This is a stereo camera — upload a stereo (two-camera) calibration."
                    : "This is a single-camera Trinet — upload a mono calibration."
                return
            }

            switch cal {
            case .mono(let m):   try await device?.setCalibration(m)
            case .stereo(let s): try await device?.setStereoCalibration(s)
            }
            calibSummary = Self.summarize(cal)
            message = "Calibration uploaded."
        }
    }

    private static func summarize(_ cal: TrinetCalibration) -> String {
        switch cal {
        case .mono(let b):   return summarize(b)
        case .stereo(let s): return summarize(s)
        }
    }

    private static func summarize(_ s: StereoCalibrationBlob) -> String {
        func f(_ v: Float, _ p: Int = 4) -> String { String(format: "%.\(p)f", v) }
        func vec(_ a: [Float], _ p: Int = 4) -> String { a.map { f($0, p) }.joined(separator: ", ") }
        var out = "Stereo · baseline \(f(s.baselineM * 1000, 1)) mm"
        for (i, c) in s.cameras.enumerated() {
            let model = c.model == .pinholeEquidistant ? "pinhole-equidistant" : "pinhole-radtan"
            out += "\n\(i == 0 ? "Left" : "Right") (cam\(i)): \(model)   Res: \(c.imageWidth)×\(c.imageHeight)"
            out += "\n  fx fy cx cy: \(f(c.fx,2)) \(f(c.fy,2)) \(f(c.cx,2)) \(f(c.cy,2))"
            out += "\n  Distortion: [\(vec(c.distortion))]"
            if c.reprojectionRmsPx > 0 { out += "\n  reproj RMS: \(f(c.reprojectionRmsPx,3)) px" }
            if s.flags & CalibrationBlob.flagTimeshiftValid != 0 {
                out += "\n  timeshift_cam_imu: \(f(c.timeshiftCamImuS,6)) s"
            }
        }
        out += "\nt_cam1_cam0 (m): [\(vec(s.tCam1Cam0))]"
        if s.flags & CalibrationBlob.flagExtrinsicsValid != 0 {
            out += "\nt_cam0_imu (m): [\(vec(s.tCam0Imu))]"
        }
        out += "\nnoise nd a/g: \(f(s.accelNoiseDensity,6)) / \(f(s.gyroNoiseDensity,6))"
        out += "\nnoise rw a/g: \(f(s.accelRandomWalk,7)) / \(f(s.gyroRandomWalk,7))"
        if s.imuRateHz > 0 { out += "\nIMU rate: \(f(s.imuRateHz,1)) Hz" }
        return out
    }

    private static func looksLikeJson(_ data: Data) -> Bool {
        guard let first = data.first(where: { !($0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d) })
        else { return false }
        return first == UInt8(ascii: "{")
    }

    private static func summarize(_ b: CalibrationBlob) -> String {
        func f(_ v: Float, _ p: Int = 4) -> String { String(format: "%.\(p)f", v) }
        func vec(_ a: [Float], _ p: Int = 4) -> String { a.map { f($0, p) }.joined(separator: ", ") }
        let model = b.model == .pinholeEquidistant ? "pinhole-equidistant" : "pinhole-radtan"
        var s = """
        Model: \(model)   Res: \(b.imageWidth)×\(b.imageHeight)
        fx fy cx cy: \(f(b.fx,2)) \(f(b.fy,2)) \(f(b.cx,2)) \(f(b.cy,2))
        Distortion: [\(vec(b.distortion))]
        """
        if b.flags & CalibrationBlob.flagExtrinsicsValid != 0 {
            s += "\nt_cam_imu (m): [\(vec(b.tCamImu))]"
            s += "\nR_cam_imu:"
            for row in 0..<3 {
                s += "\n  [\(vec(Array(b.rCamImu[row*3..<row*3+3])))]"
            }
        }
        if b.flags & CalibrationBlob.flagTimeshiftValid != 0 {
            let sign = b.flags & CalibrationBlob.flagTimeshiftSignTimu != 0 ? " (t_imu = t_cam + shift)" : ""
            s += "\ntimeshift_cam_imu: \(f(b.timeshiftCamImuS,6)) s\(sign)"
        }
        if b.flags & CalibrationBlob.flagBiasValid != 0 {
            s += "\naccel_bias (m/s²): [\(vec(b.accelBias,5))]"
            s += "\ngyro_bias (rad/s): [\(vec(b.gyroBias,6))]"
        }
        s += "\nnoise nd a/g: \(f(b.accelNoiseDensity,6)) / \(f(b.gyroNoiseDensity,6))"
        s += "\nnoise rw a/g: \(f(b.accelRandomWalk,7)) / \(f(b.gyroRandomWalk,7))"
        if b.imuRateHz > 0 { s += "\nIMU rate: \(f(b.imuRateHz,1)) Hz" }
        if b.flags & CalibrationBlob.flagQualityValid != 0 {
            s += "\nreproj RMS: \(f(b.reprojectionRmsPx,3)) px   resid g/a: \(f(b.gyroResidual,5)) / \(f(b.accelResidual,5))"
        }
        return s
    }
}
