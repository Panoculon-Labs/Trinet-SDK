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

    // Calibration summary (multi-line) and whether one is stored.
    @Published var calibSummary: String?

    /// The currently-selected device; the view keeps this in sync with the
    /// shared DeviceViewModel.
    var device: TrinetDevice?

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

    // MARK: Calibration

    func readCalibration() {
        run("calibration") { [self] in
            // device?.getCalibration() is CalibrationBlob?? (optional chain over an
            // optional return) — flatten before binding.
            let blob = (try await device?.getCalibration()) ?? nil
            if let blob {
                calibSummary = Self.summarize(blob)
            } else {
                calibSummary = "No calibration stored on the camera."
            }
        }
    }

    /// Upload a calibration from a picked file: a `calibration.json` (parsed
    /// on-device) or a pre-packed 200-byte `.bin` blob.
    func uploadCalibration(from url: URL) {
        run("calibration") { [self] in
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)

            let blob: CalibrationBlob?
            if url.pathExtension.lowercased() == "json" || Self.looksLikeJson(data) {
                guard let text = String(data: data, encoding: .utf8) else {
                    message = "Couldn't read the file as text."; return
                }
                blob = CalibrationBlob.fromCalibrationJson(text)
                if blob == nil { message = "That JSON has no usable camera intrinsics."; return }
            } else {
                blob = CalibrationBlob.decode(from: data)
                if blob == nil { message = "Not a valid 200-byte calibration blob."; return }
            }
            guard let blob else { return }
            try await device?.setCalibration(blob)
            calibSummary = Self.summarize(blob)
            message = "Calibration uploaded."
        }
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
