// TrinetDevice.swift — the customer-facing handle.
//
// One TrinetDevice instance corresponds to one Trinet camera reachable
// over the CDC NCM USB Ethernet link at a known IPv4 address (typically
// 172.32.<X>.70). After `connect()` resolves device_id and storage state,
// the device is ready for streaming, recording, and config changes.

import Foundation
import Network

public actor TrinetDevice {

    // MARK: - Identity / connection

    public nonisolated let host: String
    public nonisolated let interfaceName: String?     // e.g. "en7" — used for
                                                       // per-interface socket
                                                       // binding when multiple
                                                       // Trinets are attached
    private let api: DeviceAPI
    public private(set) var deviceId: String = ""
    public private(set) var deviceIdBytes: Data = Data(count: 16)
    public private(set) var connected: Bool = false

    /// Model / firmware / stream-shape info from /api/device_id, filled by
    /// `connect()`. nil until connected.
    public private(set) var info: TrinetDeviceInfo? = nil

    /// True when the camera streams a side-by-side stereo canvas.
    public var isStereo: Bool { info?.isStereo ?? false }

    /// The camera model (`.unknown` before connect or on unidentifiable firmware).
    public var model: TrinetModel { info?.model ?? .unknown }

    public init(host: String, interfaceName: String? = nil) {
        self.host = host
        self.interfaceName = interfaceName
        self.api = DeviceAPI(host: host)
    }

    // MARK: - Config (codec / bitrate / resolution / fps)

    public private(set) var currentConfig: DeviceConfig = .default

    public func setLocalConfig(_ c: DeviceConfig) { currentConfig = c }

    /// Pushes the given config to the device. v0 of the firmware doesn't
    /// expose a config-write endpoint, so this currently just stores the
    /// values locally — the SDK uses them when constructing the recorder
    /// and live preview, but the device keeps whatever rkncm.ini was at
    /// boot. Wire this up once /api/config lands.
    public func applyConfig(_ c: DeviceConfig) async throws {
        currentConfig = c
        // TODO: when the firmware adds POST /api/config, send it here.
    }

    // MARK: - Sync offset (filled by syncProbe)

    public private(set) var lastHostOffsetNs: Int64? = nil

    @discardableResult
    public func syncProbe(samples: Int = 10) async throws -> SyncCoordinator.Offset {
        let s = SyncCoordinator(host: host, interfaceName: interfaceName)
        let o = try await s.probe(samples: samples)
        lastHostOffsetNs = o.deviceMinusHostNs
        return o
    }

    // MARK: - Connect

    public func connect() async throws {
        let id = try await api.deviceId()
        self.deviceId = id.device_id
        self.deviceIdBytes = Self.hex16(id.device_id)
        self.info = TrinetDeviceInfo(id)
        self.connected = true
        // No eager sync probe: IMU now rides in the video SEI in the same
        // device clock as the frames, so :5557 isn't needed for IMU↔video
        // alignment — and probing a port the firmware may have dropped would
        // block (its receiveMessage has no timeout). syncProbe() stays callable
        // for the future multi-camera host-offset case.
    }

    public func disconnect() async {
        connected = false
    }

    // MARK: - Recording
    //
    // Recording is driven through TrinetLiveSession (preview + record share
    // one video stream). Use `device.liveSession()` → `session.start()` →
    // `session.startRecording(in:)`. The old standalone TrinetRecorder API
    // was removed; it opened a second video stream and used an actor-await
    // chain that hung on stop.

    // MARK: - State helpers

    public func storage() async throws -> DeviceAPI.StorageResponse { try await api.storage() }
    public func state()   async throws -> DeviceAPI.StateResponse   { try await api.state() }
    public func time()    async throws -> DeviceAPI.TimeResponse    { try await api.time() }
    /// Camera internal temperature + a host-pause signal — poll while recording and
    /// pause/resume on `.paused`. See `DeviceAPI.thermal()`.
    public func thermal() async throws -> DeviceAPI.ThermalResponse { try await api.thermal() }

    // MARK: - Device control (calibration / LED / bitrate)

    /// Last calibration set or fetched from the camera.
    public private(set) var calibration: CalibrationBlob? = nil

    /// Upload calibration to the camera; it stores the blob and serves it back.
    public func setCalibration(_ blob: CalibrationBlob) async throws {
        try await api.setCalibration(blob.encode())
        self.calibration = blob
        self.calibrationAny = .mono(blob)
    }

    /// Last calibration (mono or stereo) set or fetched from the camera.
    public private(set) var calibrationAny: TrinetCalibration? = nil

    /// Fetch the camera's stored mono calibration, or nil if none is stored
    /// (or if the stored blob is a stereo one — use `getCalibrationAny()`).
    public func getCalibration() async throws -> CalibrationBlob? {
        let any = try await getCalibrationAny()
        if case .mono(let b)? = any { return b }
        return nil
    }

    /// Fetch the camera's stored calibration, whichever kind it is: a 200-byte
    /// mono blob or a 300-byte stereo blob. nil if none is stored or the
    /// stored bytes are not a structurally valid blob.
    public func getCalibrationAny() async throws -> TrinetCalibration? {
        do {
            let any = TrinetCalibration.decode(from: try await api.getCalibration())
            self.calibrationAny = any
            if case .mono(let b)? = any { self.calibration = b } else { self.calibration = nil }
            return any
        } catch DeviceAPI.APIError.http(404) {
            self.calibration = nil
            self.calibrationAny = nil
            return nil
        }
    }

    /// Upload a stereo (300-byte TBLC v2) calibration.
    public func setStereoCalibration(_ blob: StereoCalibrationBlob) async throws {
        try await api.setCalibration(blob.encode())
        self.calibrationAny = .stereo(blob)
        self.calibration = nil
    }

    /// Upload pre-packed calibration bytes (a host-packed `.bin`). Validated
    /// locally first (size + magic + version + CRC); throws
    /// `CalibrationError.invalidBlob` otherwise.
    public func setCalibrationRaw(_ data: Data) async throws {
        guard let any = TrinetCalibration.decode(from: data) else {
            throw CalibrationError.invalidBlob
        }
        try await api.setCalibration(data)
        self.calibrationAny = any
        if case .mono(let b) = any { self.calibration = b } else { self.calibration = nil }
    }

    /// Set the status LED channels on/off (no brightness — hardware has no PWM).
    public func setLed(r: Bool, g: Bool, b: Bool) async throws {
        try await api.setLed(r: r, g: g, b: b)
    }

    /// Set the encoder bitrate target (kbps). The value is persisted on the
    /// camera and shared with its other streaming mode; the camera restarts
    /// (~15 s) to apply it and re-enumerates, so this handle is briefly
    /// unreachable afterwards. Survives a power cycle. `connected` is cleared
    /// locally — treat as fire-and-reconnect.
    public func setBitrate(kbps: Int) async throws {
        try await api.setBitrate(kbps: kbps)
        self.connected = false
    }

    /// The camera's current encoder bitrate target (kbps).
    public func bitrate() async throws -> Int {
        try await api.bitrate().kbps
    }

    /// Set the rate-control mode ("cbr" | "avbr"). CBR holds image quality;
    /// AVBR clamps the average to the target bitrate. Persisted and shared with
    /// the camera's other streaming mode; the camera restarts to apply it (same
    /// re-enumeration as `setBitrate`). `connected` is cleared locally.
    public func setRateControlMode(_ mode: String) async throws {
        try await api.setRateControlMode(mode)
        self.connected = false
    }

    /// The camera's current rate-control mode ("cbr" | "avbr").
    public func rateControlMode() async throws -> String {
        try await api.rateControlMode().mode
    }

    /// Set the mic gain (Q8, 256 = unity) + mute + auto-gain. Live (no reboot);
    /// the gain is applied on the camera, so it changes the actual recording, not
    /// just playback. When agc is true the camera auto-levels (manual gain ignored).
    public func setAudio(gainQ8: Int, muted: Bool, agc: Bool) async throws {
        try await api.setAudio(gainQ8: gainQ8, muted: muted, agc: agc)
    }

    /// The camera's current mic gain + mute + auto-gain.
    public func audio() async throws -> DeviceAPI.AudioResponse {
        try await api.audio()
    }

    /// The camera's current persistent boot mode ("uvc" | "ncm" | "imu").
    public func currentMode() async throws -> String {
        try await api.mode().mode
    }

    /// Switch the persistent boot mode ("uvc" | "ncm" | "imu"). The camera
    /// persists it and reboots to apply. Since NCM and UVC are different USB
    /// gadgets, after switching away from "ncm" this device handle is no longer
    /// reachable (it re-enumerates in the new mode); treat the call as fire-and-
    /// reconnect. `connected` is cleared locally.
    public func setMode(_ mode: String) async throws {
        try await api.setMode(mode)
        if mode != "ncm" { self.connected = false }
    }

    // MARK: - §5 image controls (live; no reboot)

    /// Brightness 0...255 (128 = neutral).
    public func setBrightness(_ v: Int) async throws { try await api.setBrightness(v) }
    public func brightness() async throws -> Int { try await api.brightness().value }
    /// Contrast 0...255 (128 = neutral).
    public func setContrast(_ v: Int) async throws { try await api.setContrast(v) }
    public func contrast() async throws -> Int { try await api.contrast().value }
    /// Saturation 0...200 % (0 = grayscale, 100 = neutral).
    public func setSaturation(_ v: Int) async throws { try await api.setSaturation(v) }
    public func saturation() async throws -> Int { try await api.saturation().value }
    /// Sharpness 0...100.
    public func setSharpness(_ v: Int) async throws { try await api.setSharpness(v) }
    public func sharpness() async throws -> Int { try await api.sharpness().value }
    /// Manual AE gain multiplier (honoured only when exposure mode is manual).
    public func setGain(_ v: Int) async throws { try await api.setGain(v) }
    public func gain() async throws -> Int { try await api.gain().value }
    /// White-balance auto (AWB) vs manual.
    public func setWhiteBalanceAuto(_ on: Bool) async throws { try await api.setWhiteBalanceAuto(on) }
    public func whiteBalanceAuto() async throws -> Bool { try await api.whiteBalanceAuto().value != 0 }
    /// White-balance colour temperature 2800...6500 K (switches WB to manual).
    public func setWhiteBalanceTemperature(kelvin: Int) async throws { try await api.setWhiteBalanceTemperature(kelvin: kelvin) }
    public func whiteBalanceTemperature() async throws -> Int { try await api.whiteBalanceTemperature().value }
    /// White Balance Component: per-channel Red/Blue gain (Q8.8, 256 = gain 1.0).
    public func setWhiteBalanceComponent(rGain: Int, bGain: Int) async throws { try await api.setWhiteBalanceComponent(rGain: rGain, bGain: bGain) }
    public func whiteBalanceComponent() async throws -> (rGain: Int, bGain: Int) {
        let r = try await api.whiteBalanceComponent(); return (r.r_gain, r.b_gain)
    }
    /// Exposure mode "auto" | "manual".
    public func setExposureMode(_ mode: String) async throws { try await api.setExposureMode(mode) }
    public func exposureMode() async throws -> String { try await api.exposureMode().mode }

    // MARK: - §5 exposure range + mains (persisted; camera reboots to apply)

    /// Auto-exposure min/max in microseconds. The camera restarts to apply;
    /// `connected` is cleared locally (fire-and-reconnect).
    public func setExposureRange(minUs: Int, maxUs: Int) async throws {
        try await api.setExposureRange(minUs: minUs, maxUs: maxUs); self.connected = false
    }
    public func exposureRange() async throws -> (minUs: Int, maxUs: Int) {
        let r = try await api.exposureRange(); return (r.min_us, r.max_us)
    }
    /// Mains/anti-flicker frequency (50 | 60 Hz). Camera restarts to apply.
    public func setMainsFrequency(hz: Int) async throws {
        try await api.setMainsFrequency(hz: hz); self.connected = false
    }
    public func mainsFrequency() async throws -> Int { try await api.mainsFrequency().hz }

    // MARK: - §6 encoder / stream controls

    /// Encoder GOP length (frames, 1...600). Persisted; camera restarts to apply.
    public func setGop(frames: Int) async throws {
        try await api.setGop(frames: frames); self.connected = false
    }
    public func gop() async throws -> Int { try await api.gop().frames }
    // MARK: - Codecs (live stream vs. SD-card recording)

    /// Thrown when the camera reports a codec name this SDK doesn't know.
    public struct UnknownCodecError: Error, LocalizedError {
        public let name: String
        public var errorDescription: String? { "Unknown codec \"\(name)\"" }
    }

    private static func parseCodec(_ name: String) throws -> VideoCodec {
        guard let c = VideoCodec(rawValue: name.lowercased()) else { throw UnknownCodecError(name: name) }
        return c
    }

    /// Record what the live stream carries, so `currentConfig.codec` matches.
    func noteStreamCodec(_ codec: VideoCodec) { currentConfig.codec = codec }

    /// The codec of the live NCM stream. Throws `DeviceAPI.APIError.http(404)`
    /// on firmware without the endpoint — those cameras stream H.264.
    /// `liveSession()` already does this lookup (with that fallback).
    public func streamCodec() async throws -> VideoCodec {
        try Self.parseCodec(try await api.streamCodec().codec)
    }

    /// Switch the live NCM stream's codec. Persisted on the camera. The camera
    /// restarts its stream server to apply: any open `TrinetLiveSession` stops
    /// receiving video, the stream returns in ~5–10 s, and this API stays
    /// reachable throughout. Stop the session first, call this, wait for
    /// `waitUntilReachable()`, then open a new `liveSession()` (its stream
    /// keeps retrying the connection while the server comes back).
    public func setStreamCodec(_ codec: VideoCodec) async throws {
        try await api.setStreamCodec(codec.rawValue)
    }

    /// The codec the camera uses for its own SD-card recordings.
    public func recordingCodec() async throws -> VideoCodec {
        try Self.parseCodec(try await api.recordingCodec().codec)
    }

    /// Set the codec for the camera's own SD-card recordings. Persisted; no
    /// restart. Independent of the live stream codec.
    public func setRecordingCodec(_ codec: VideoCodec) async throws {
        try await api.setRecordingCodec(codec.rawValue)
    }

    /// Poll GET /api/device_id until the camera answers or `timeout` elapses.
    /// Returns true if it answered.
    public func waitUntilReachable(timeout: TimeInterval = 30,
                                   interval: TimeInterval = 0.5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (try? await api.deviceId()) != nil { return true }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while Date() < deadline && !Task.isCancelled
        return false
    }

    /// Enable/disable the in-band IMU SEI stream. Live (no reboot).
    public func setImuStream(_ enabled: Bool) async throws { try await api.setImuStream(enabled) }
    public func imuStream() async throws -> Bool { try await api.imuStream().isEnabled }
    /// Lock/unlock calibration writes. Live + persisted. While locked the camera
    /// rejects calibration uploads (403).
    public func setCalibrationLock(_ locked: Bool) async throws { try await api.setCalibrationLock(locked) }
    public func calibrationLock() async throws -> Bool { try await api.calibrationLock().isLocked }

    // MARK: - §10 audio sample rate (persisted; camera reboots to apply)

    /// Audio capture sample rate (16000 | 44100 | 48000 Hz). Camera restarts to apply.
    public func setAudioRate(hz: Int) async throws {
        try await api.setAudioRate(hz: hz); self.connected = false
    }
    public func audioRate() async throws -> Int { try await api.audioRate().hz }

    // MARK: - LED read-back

    /// The status LED's current channel state (r, g, b on/off).
    public func led() async throws -> (r: Bool, g: Bool, b: Bool) {
        let s = try await api.led(); return (s.red, s.green, s.blue)
    }

    // MARK: - Thermal limit (persisted; applies to the next recording)

    /// Allowed thermal-limit range in °C.
    public static let thermalLimitRange: ClosedRange<Int> = 75...100

    /// The recording thermal limit in °C, or nil when the firmware default
    /// is in effect (the camera reports 0).
    public func thermalLimit() async throws -> Int? {
        let r = try await api.thermalLimit(); return r.isDefault ? nil : r.celsius
    }

    /// Full thermal-limit read-out including the allowed min/max.
    public func thermalLimitInfo() async throws -> DeviceAPI.ThermalLimitResponse {
        try await api.thermalLimit()
    }

    /// Set the recording thermal limit (75...100 °C). Persisted; applies to the
    /// next recording, no reboot.
    public func setThermalLimit(celsius: Int) async throws {
        try await api.setThermalLimit(celsius: celsius)
    }

    // MARK: - Image controls added with NCM parity (live; no reboot)

    /// Hue 0...100 (50 = neutral).
    public func setHue(_ v: Int) async throws { try await api.setHue(v) }
    public func hue() async throws -> Int { try await api.hue().value }

    /// Manual exposure time in units of 100 µs (5...2500 = 0.5...250 ms). Only
    /// valid in manual exposure mode — the camera answers HTTP 409 in auto.
    public func setExposureTime(units100us: Int) async throws { try await api.setExposureTime(units100us) }
    public func exposureTime() async throws -> Int { try await api.exposureTime().value }

    /// The AWB tuning table summary (most recent anchor + anchor count).
    public func awbTune() async throws -> DeviceAPI.AwbTuneResponse { try await api.awbTune() }

    /// Add an AWB tuning anchor; `cct <= 0` clears the table. Returns the new
    /// anchor count (nil if the camera didn't report it).
    @discardableResult
    public func setAwbTune(cct: Int, r: Double, b: Double) async throws -> Int? {
        try await api.setAwbTune(cct: cct, r: r, b: b).anchors
    }

    /// Temporal noise reduction — Pro Stereo GS only (other models answer 404).
    public func setTemporalNoiseReduction(_ on: Bool) async throws { try await api.setTnr(on) }
    public func temporalNoiseReduction() async throws -> Bool { try await api.tnr().value != 0 }

    // MARK: - Bluetooth LE status broadcast (persisted; next boot)

    /// Whether the camera broadcasts its status over Bluetooth LE.
    public func bleBroadcast() async throws -> Bool { try await api.ble().isEnabled }

    /// Turn the Bluetooth LE status broadcast on/off. Saved on the camera and
    /// applied from its next boot.
    public func setBleBroadcast(_ enabled: Bool) async throws {
        try await api.setBle(enabled)
    }

    // MARK: - Card recording + mounting (0.3.2)

    /// How the camera splits its card recordings (`minutes` 0 = one file).
    public func recordingChunk() async throws -> DeviceAPI.RecordingChunkResponse {
        try await api.recordingChunk()
    }

    /// Split card recordings every `minutes` (0 = one continuous file). Applies
    /// to the next recording, no restart.
    public func setRecordingChunk(minutes: Int) async throws {
        try await api.setRecordingChunk(minutes: minutes)
    }

    /// Whether the picture is rotated 180 degrees (upside-down mount).
    public func imageFlip() async throws -> DeviceAPI.ImageFlipResponse {
        try await api.imageFlip()
    }

    /// Rotate the picture 180 degrees. Persisted; the camera restarts its
    /// imaging pipeline to apply, so the stream drops and must be reopened.
    public func setImageFlip(_ on: Bool) async throws {
        try await api.setImageFlip(on)
    }

    /// Card recording audio format ("aac" | "pcm").
    public func recordingAudioFormat() async throws -> DeviceAPI.AudioFormatResponse {
        try await api.recordingAudioFormat()
    }

    /// Set the card recording audio format ("aac" | "pcm"). Card recordings
    /// only — the live stream's audio is always AAC. Persisted; the camera
    /// restarts to apply.
    public func setRecordingAudioFormat(_ format: String) async throws {
        try await api.setRecordingAudioFormat(format)
    }

    // MARK: - Helpers

    private static func hex16(_ hex: String) -> Data {
        var out = Data(); out.reserveCapacity(16)
        var idx = hex.startIndex
        while idx < hex.endIndex, out.count < 16 {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteStr = hex[idx..<next]
            if let b = UInt8(byteStr, radix: 16) { out.append(b) }
            idx = next
        }
        while out.count < 16 { out.append(0) }
        return out
    }
}
