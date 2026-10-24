// DeviceAPI.swift — HTTP JSON client for the device API on :8081.
//
// The full endpoint table lives in docs/PROTOCOLS.md. Groups:
//   identity / state   GET /api/device_id, /api/state, /api/storage, /api/time,
//                      /api/thermal, /api/thermal/limit
//   control            /api/led, /api/mode, /api/ble, /api/calibration(/lock),
//                      /api/audio(/rate), /api/imu/stream
//   video              /api/video/* (bitrate, rcmode, gop, image controls,
//                      white balance, exposure, hue, awb_tune, tnr)
// Errors come back as 4xx/5xx with a {"error":"..."} body; this client
// surfaces the status code as `APIError.http(status)`. Endpoints a given
// firmware/model doesn't implement answer 404 — feature-detect on that.

import Foundation

/// Clamp a linear Q8 gain to the wire's u16 range.
func gain_q8Clamped(_ q8: Int) -> Int { min(max(q8, 0), 0xFFFF) }

/// Convert a dB gain to linear Q8 (256 = 0 dB). The app's gain slider is in dB.
public func trinetAudioGainDbToQ8(_ db: Double) -> Int {
    gain_q8Clamped(Int((256.0 * pow(10.0, db / 20.0)).rounded()))
}

public actor DeviceAPI {
    public let baseURL: URL
    private let session: URLSession

    public init(host: String, port: Int = 8081) {
        // 172.32.<X>.70:8081 by default. We always pass IPv4 dotted-quad,
        // never a DNS name — there's no resolver on the USB-Ethernet link.
        self.baseURL = URL(string: "http://\(host):\(port)")!

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 3
        cfg.timeoutIntervalForResource = 5
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy   = .reloadIgnoringLocalCacheData
        // The Trinet is a point-to-point USB link with no proxy. Disabling
        // proxy resolution stops URLSession's PAC evaluation (the noisy
        // `nw_proxy_resolver … -1009` log spam) and shaves connection latency.
        cfg.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Decoded payloads

    /// GET /api/device_id. Older firmware returns only `device_id`, `product`,
    /// `mode` (and sometimes `generation`), so every other field is optional.
    /// Use `TrinetDeviceInfo(response)` for the typed, fallback-aware view.
    public struct DeviceIdResponse: Sendable, Codable, Equatable {
        public struct Canvas: Sendable, Codable, Equatable {
            public let width: Int
            public let height: Int
            public init(width: Int, height: Int) { self.width = width; self.height = height }
        }
        public let device_id: String
        public let product: String
        public let mode: String
        /// Hardware generation, e.g. "v4" (Pro Mono), "v5" (Pro Stereo), "v6" (Pro Stereo GS).
        public let generation: String?
        /// "pro-mono" | "pro-stereo" | "pro-stereo-gs" | "mini".
        public let model: String?
        /// Firmware version string, e.g. "0.5.10", or "unknown".
        public let firmware: String?
        /// "shipping" | "dev".
        public let build: String?
        /// Number of image sensors (1 or 2).
        public let cameras: Int?
        /// "single" | "side_by_side".
        public let layout: String?
        /// Size of the encoded video frame (3840x1080 on stereo boards).
        public let canvas: Canvas?

        public init(device_id: String, product: String, mode: String,
                    generation: String? = nil, model: String? = nil,
                    firmware: String? = nil, build: String? = nil,
                    cameras: Int? = nil, layout: String? = nil, canvas: Canvas? = nil) {
            self.device_id = device_id; self.product = product; self.mode = mode
            self.generation = generation; self.model = model
            self.firmware = firmware; self.build = build
            self.cameras = cameras; self.layout = layout; self.canvas = canvas
        }
    }

    public struct StateResponse: Sendable, Codable {
        public let mode: String
        public let recording: Bool
        public let ready: Bool
        public let note: String?
    }

    public struct StorageResponse: Sendable, Codable {
        public let mount: String
        public let present: Bool
        public let total_bytes: UInt64?
        public let available_bytes: UInt64?
    }

    public struct TimeResponse: Sendable, Codable {
        public let clock_monotonic_ns: UInt64
        public let clock_realtime_ns:  UInt64
    }

    public struct ThermalResponse: Sendable, Codable {
        public let state: String        // "cool" | "warm" | "hot" | "critical"
        public let temp_c: Int
        public let paused: Bool          // latched: stop recording while true, resume when false
    }

    // MARK: - Public methods

    public func deviceId() async throws -> DeviceIdResponse { try await get("api/device_id") }
    public func state()    async throws -> StateResponse    { try await get("api/state") }
    public func storage()  async throws -> StorageResponse  { try await get("api/storage") }
    public func time()     async throws -> TimeResponse     { try await get("api/time") }
    /// Camera temperature + a host-pause signal. Poll ~1 Hz while recording:
    /// when `.paused` is true the camera is too hot — stop recording (and preview)
    /// and resume when it clears. The streaming analogue of SD pause_resume.
    public func thermal()  async throws -> ThermalResponse  { try await get("api/thermal") }

    // MARK: - Internals

    public enum APIError: Error, LocalizedError {
        case http(Int)
        case decode(any Error)
        case transport(any Error)
        public var errorDescription: String? {
            switch self {
            case .http(let s):     "HTTP \(s)"
            case .decode(let e):   "decode: \(e)"
            case .transport(let e): "transport: \(e)"
            }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { throw APIError.http(0) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw APIError.decode(error) }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }

    // MARK: - Device control (UVC-XU parity over the NCM HTTP API)

    public struct LedCommand: Sendable, Codable {
        public let r: Int
        public let g: Int
        public let b: Int
        public init(r: Bool, g: Bool, b: Bool) {
            self.r = r ? 1 : 0; self.g = g ? 1 : 0; self.b = b ? 1 : 0
        }
    }

    public struct BitrateCommand: Sendable, Codable {
        public let kbps: Int
        public init(kbps: Int) { self.kbps = kbps }
    }

    public struct BitrateResponse: Sendable, Codable {
        public let kbps: Int
    }

    public struct RcModeCommand: Sendable, Codable {
        public let mode: String   // "cbr" | "avbr"
        public init(mode: String) { self.mode = mode }
    }

    public struct RcModeResponse: Sendable, Codable {
        public let mode: String   // "cbr" | "avbr"
    }

    public struct ModeCommand: Sendable, Codable {
        public let mode: String   // "uvc" | "ncm" | "imu"
        public init(mode: String) { self.mode = mode }
    }

    public struct ModeResponse: Sendable, Codable {
        public let mode: String
    }

    /// Mic audio control. gain_q8 is linear Q8 (256 = 0 dB / unity); muted/agc
    /// are 0/1. The camera applies the gain to the recording/stream itself.
    public struct AudioCommand: Sendable, Codable {
        public let gain_q8: Int
        public let muted: Int
        public let agc: Int
        public init(gainQ8: Int, muted: Bool, agc: Bool) {
            self.gain_q8 = gain_q8Clamped(gainQ8); self.muted = muted ? 1 : 0; self.agc = agc ? 1 : 0
        }
    }

    public struct AudioResponse: Sendable, Codable {
        public let gain_q8: Int
        public let muted: Int
        public let agc: Int
        /// Gain in decibels (20·log10(gain_q8/256)); 0 dB at unity.
        public var gainDb: Double { 20.0 * log10(Double(max(1, gain_q8)) / 256.0) }
        public var isMuted: Bool { muted != 0 }
        public var isAgc: Bool { agc != 0 }
    }

    /// Upload a raw calibration blob — POST /api/calibration (octet-stream).
    /// 200 bytes for a mono camera (TBLC v1), 300 bytes for a stereo camera
    /// (TBLC v2). The camera stores it opaquely and serves it back.
    public func setCalibration(_ blob: Data) async throws {
        try await post("api/calibration", contentType: "application/octet-stream", body: blob)
    }

    /// Download the stored calibration blob — GET /api/calibration.
    /// Throws `APIError.http(404)` if the camera has no calibration stored.
    public func getCalibration() async throws -> Data {
        try await getData("api/calibration")
    }

    /// Set the status LED channels on/off — POST /api/led. (No brightness:
    /// the hardware LED has no PWM.)
    public func setLed(r: Bool, g: Bool, b: Bool) async throws {
        try await post("api/led", contentType: "application/json",
                       body: try JSONEncoder().encode(LedCommand(r: r, g: g, b: b)))
    }

    /// Set the encoder bitrate target (kbps, 256...30000) — POST /api/video/bitrate.
    /// The value is persisted on the camera and applied on the next stream: the
    /// camera restarts (~15 s) to apply it and re-enumerates, so this endpoint
    /// won't answer again until it's back. Survives a power cycle, and is shared
    /// with the camera's other streaming mode.
    public func setBitrate(kbps: Int) async throws {
        try await post("api/video/bitrate", contentType: "application/json",
                       body: try JSONEncoder().encode(BitrateCommand(kbps: kbps)))
    }

    /// Current encoder bitrate target (kbps) — GET /api/video/bitrate.
    public func bitrate() async throws -> BitrateResponse { try await get("api/video/bitrate") }

    /// Set the rate-control mode ("cbr" | "avbr") — POST /api/video/rcmode. CBR
    /// holds image quality; AVBR clamps the average to the target bitrate.
    /// Persisted; the camera restarts to apply it (same re-enumeration as
    /// `setBitrate`).
    public func setRateControlMode(_ mode: String) async throws {
        try await post("api/video/rcmode", contentType: "application/json",
                       body: try JSONEncoder().encode(RcModeCommand(mode: mode)))
    }

    /// Current rate-control mode ("cbr" | "avbr") — GET /api/video/rcmode.
    public func rateControlMode() async throws -> RcModeResponse { try await get("api/video/rcmode") }

    /// Current persistent boot mode — GET /api/mode ("uvc" | "ncm" | "imu").
    public func mode() async throws -> ModeResponse { try await get("api/mode") }

    /// Set the persistent boot mode — POST /api/mode. The camera persists it and
    /// reboots to apply; UVC and NCM are different USB gadgets, so the device
    /// re-enumerates in the new mode and this NCM endpoint won't answer again if
    /// switched away from ncm. The reboot is deferred ~1s so this call returns
    /// its acknowledgement first.
    public func setMode(_ mode: String) async throws {
        try await post("api/mode", contentType: "application/json",
                       body: try JSONEncoder().encode(ModeCommand(mode: mode)))
    }

    /// Set mic gain (Q8, 256 = unity) + mute + auto-gain — POST /api/audio. Live
    /// (no reboot); the gain is applied on the camera so it changes the actual
    /// recording, not just playback. When agc is true the camera auto-levels and
    /// the manual gain is ignored.
    public func setAudio(gainQ8: Int, muted: Bool, agc: Bool) async throws {
        try await post("api/audio", contentType: "application/json",
                       body: try JSONEncoder().encode(AudioCommand(gainQ8: gainQ8, muted: muted, agc: agc)))
    }

    /// Current mic gain + mute + auto-gain — GET /api/audio.
    public func audio() async throws -> AudioResponse { try await get("api/audio") }

    // MARK: - Camera settings (full UVC/Android parity)

    // Shared payloads.
    public struct ValueCommand: Sendable, Codable { public let value: Int; public init(value: Int) { self.value = value } }
    public struct ValueResponse: Sendable, Codable { public let value: Int }
    public struct HzCommand: Sendable, Codable { public let hz: Int; public init(hz: Int) { self.hz = hz } }
    public struct HzResponse: Sendable, Codable { public let hz: Int }
    public struct FramesCommand: Sendable, Codable { public let frames: Int; public init(frames: Int) { self.frames = frames } }
    public struct FramesResponse: Sendable, Codable { public let frames: Int }
    public struct EnabledCommand: Sendable, Codable { public let enabled: Int; public init(_ on: Bool) { self.enabled = on ? 1 : 0 } }
    public struct EnabledResponse: Sendable, Codable { public let enabled: Int; public var isEnabled: Bool { enabled != 0 } }
    public struct LockedCommand: Sendable, Codable { public let locked: Int; public init(_ on: Bool) { self.locked = on ? 1 : 0 } }
    public struct LockedResponse: Sendable, Codable { public let locked: Int; public var isLocked: Bool { locked != 0 } }
    public struct ExposureRangeCommand: Sendable, Codable { public let min_us: Int; public let max_us: Int; public init(minUs: Int, maxUs: Int) { self.min_us = minUs; self.max_us = maxUs } }
    public struct ExposureRangeResponse: Sendable, Codable { public let min_us: Int; public let max_us: Int }
    public struct WbComponentCommand: Sendable, Codable { public let r_gain: Int; public let b_gain: Int; public init(rGain: Int, bGain: Int) { self.r_gain = rGain; self.b_gain = bGain } }
    public struct WbComponentResponse: Sendable, Codable { public let r_gain: Int; public let b_gain: Int }
    public struct ExposureModeCommand: Sendable, Codable { public let mode: String; public init(mode: String) { self.mode = mode } }
    public struct ExposureModeResponse: Sendable, Codable { public let mode: String }

    private func postJSON<T: Encodable>(_ path: String, _ body: T) async throws {
        try await post(path, contentType: "application/json", body: try JSONEncoder().encode(body))
    }

    // §5 image controls — LIVE (no reboot, no stream gap); the camera actuates
    // the ISP immediately. Units match the UVC Processing-Unit host scale.

    /// Brightness 0...255 (128 = neutral) — POST /api/video/brightness.
    public func setBrightness(_ v: Int) async throws { try await postJSON("api/video/brightness", ValueCommand(value: v)) }
    public func brightness() async throws -> ValueResponse { try await get("api/video/brightness") }

    /// Contrast 0...255 (128 = neutral) — POST /api/video/contrast.
    public func setContrast(_ v: Int) async throws { try await postJSON("api/video/contrast", ValueCommand(value: v)) }
    public func contrast() async throws -> ValueResponse { try await get("api/video/contrast") }

    /// Saturation 0...200 % (0 = grayscale, 100 = neutral) — POST /api/video/saturation.
    public func setSaturation(_ v: Int) async throws { try await postJSON("api/video/saturation", ValueCommand(value: v)) }
    public func saturation() async throws -> ValueResponse { try await get("api/video/saturation") }

    /// Sharpness 0...100 — POST /api/video/sharpness.
    public func setSharpness(_ v: Int) async throws { try await postJSON("api/video/sharpness", ValueCommand(value: v)) }
    public func sharpness() async throws -> ValueResponse { try await get("api/video/sharpness") }

    /// Manual AE gain multiplier (only honoured when exposure mode is manual) — POST /api/video/gain.
    public func setGain(_ v: Int) async throws { try await postJSON("api/video/gain", ValueCommand(value: v)) }
    public func gain() async throws -> ValueResponse { try await get("api/video/gain") }

    /// White-balance auto (1) vs manual (0) — POST /api/video/white_balance_auto.
    public func setWhiteBalanceAuto(_ on: Bool) async throws { try await postJSON("api/video/white_balance_auto", ValueCommand(value: on ? 1 : 0)) }
    public func whiteBalanceAuto() async throws -> ValueResponse { try await get("api/video/white_balance_auto") }

    /// White-balance colour temperature 2800...6500 K (switches WB to manual) — POST /api/video/white_balance_temperature.
    public func setWhiteBalanceTemperature(kelvin: Int) async throws { try await postJSON("api/video/white_balance_temperature", ValueCommand(value: kelvin)) }
    public func whiteBalanceTemperature() async throws -> ValueResponse { try await get("api/video/white_balance_temperature") }

    /// White Balance Component: per-channel Red/Blue gain (Q8.8, 256 = gain 1.0) — POST /api/video/white_balance_component.
    public func setWhiteBalanceComponent(rGain: Int, bGain: Int) async throws { try await postJSON("api/video/white_balance_component", WbComponentCommand(rGain: rGain, bGain: bGain)) }
    public func whiteBalanceComponent() async throws -> WbComponentResponse { try await get("api/video/white_balance_component") }

    /// Exposure mode "auto" | "manual" — POST /api/video/exposure_mode.
    public func setExposureMode(_ mode: String) async throws { try await postJSON("api/video/exposure_mode", ExposureModeCommand(mode: mode)) }
    public func exposureMode() async throws -> ExposureModeResponse { try await get("api/video/exposure_mode") }

    // §5 exposure range + mains frequency — PERSISTED; the camera reboots to
    // apply (re-enumerates, won't answer again until back), like setBitrate.

    /// Auto-exposure min/max in microseconds — POST /api/video/exposure.
    public func setExposureRange(minUs: Int, maxUs: Int) async throws { try await postJSON("api/video/exposure", ExposureRangeCommand(minUs: minUs, maxUs: maxUs)) }
    public func exposureRange() async throws -> ExposureRangeResponse { try await get("api/video/exposure") }

    /// Mains/anti-flicker frequency (50 | 60 Hz) — POST /api/video/power_line.
    public func setMainsFrequency(hz: Int) async throws { try await postJSON("api/video/power_line", HzCommand(hz: hz)) }
    public func mainsFrequency() async throws -> HzResponse { try await get("api/video/power_line") }

    // §6 encoder/stream controls.

    /// Encoder GOP length in frames (1...600) — POST /api/video/gop. Persisted;
    /// the camera reboots to apply (like setBitrate).
    public func setGop(frames: Int) async throws { try await postJSON("api/video/gop", FramesCommand(frames: frames)) }
    public func gop() async throws -> FramesResponse { try await get("api/video/gop") }

    // Codecs. Two independent settings:
    //   /api/video/stream_codec — the live NCM stream (:8080). Changing it
    //     restarts the camera's stream server: :8080 drops and returns in
    //     ~5–10 s; the USB link and this API stay up. Older firmware: 404
    //     (the stream is H.264).
    //   /api/video/codec — the camera's own SD-card recordings. No restart.

    public struct CodecCommand: Sendable, Codable {
        public let codec: String   // "h264" | "h265"
        public init(codec: String) { self.codec = codec }
    }
    /// GET /api/video/stream_codec and GET /api/video/codec.
    public struct RecordingChunkCommand: Sendable, Codable {
        /// Minutes per part, 0...240. 0 = one continuous file.
        public let minutes: Int
        public init(minutes: Int) { self.minutes = minutes }
    }

    public struct RecordingChunkResponse: Sendable, Codable, Equatable {
        public let minutes: Int
        /// "host" (set by a client) | "default" (firmware default).
        public let source: String?
    }

    public struct ImageFlipCommand: Sendable, Codable {
        public let flip: Int
        public init(_ on: Bool) { self.flip = on ? 1 : 0 }
    }

    public struct ImageFlipResponse: Sendable, Codable, Equatable {
        public let flip: Int
        public var isOn: Bool { flip != 0 }
    }

    public struct AudioFormatCommand: Sendable, Codable {
        public let format: String   // "aac" | "pcm"
        public init(format: String) { self.format = format }
    }

    public struct AudioFormatResponse: Sendable, Codable, Equatable {
        public let format: String
    }

    public struct CodecResponse: Sendable, Codable, Equatable {
        public let codec: String
        /// "host" (set by a client) | "default" (firmware default).
        public let source: String?
    }
    /// POST /api/video/stream_codec acknowledgement.
    public struct StreamCodecSetResponse: Sendable, Codable, Equatable {
        public let status: String?
        public let codec: String?
        /// true: the stream server restarts to apply.
        public let restart: Bool?
    }
    /// POST /api/video/codec acknowledgement.
    public struct RecordingCodecSetResponse: Sendable, Codable, Equatable {
        public let status: String?
        public let codec: String?
        public let reboot: Bool?
    }

    /// Live-stream codec — GET /api/video/stream_codec. 404 on older firmware.
    public func streamCodec() async throws -> CodecResponse { try await get("api/video/stream_codec") }

    /// Set the live-stream codec — POST /api/video/stream_codec. Persisted; the
    /// camera restarts its stream server (the :8080 stream drops for ~5–10 s;
    /// the API stays up). Cleared by a settings reset.
    @discardableResult
    public func setStreamCodec(_ codec: String) async throws -> StreamCodecSetResponse {
        try await postDecoding("api/video/stream_codec", CodecCommand(codec: codec))
    }

    /// SD-card recording codec — GET /api/video/codec.
    public func recordingCodec() async throws -> CodecResponse { try await get("api/video/codec") }

    /// Set the SD-card recording codec — POST /api/video/codec. Persisted; no restart.
    @discardableResult
    public func setRecordingCodec(_ codec: String) async throws -> RecordingCodecSetResponse {
        try await postDecoding("api/video/codec", CodecCommand(codec: codec))
    }

    /// How card recordings are split — GET /api/recording/chunk. `minutes` is
    /// 0 for one continuous file.
    public func recordingChunk() async throws -> RecordingChunkResponse {
        try await get("api/recording/chunk")
    }

    /// Split card recordings into parts of `minutes` each — POST
    /// /api/recording/chunk. 0...240, where 0 means one continuous file (the
    /// default). Parts are written into a folder named after the recording as
    /// `partNNN.*` and each one plays on its own, so a power loss costs the
    /// last part rather than the whole take. Persisted; applies to the
    /// camera's next recording with NO restart, and a recording already
    /// running is unaffected. A config file on the memory card still outranks
    /// it.
    public func setRecordingChunk(minutes: Int) async throws {
        try await post("api/recording/chunk", contentType: "application/json",
                       body: try JSONEncoder().encode(RecordingChunkCommand(minutes: minutes)))
    }

    /// Whether the picture is rotated 180 degrees — GET /api/video/flip.
    public func imageFlip() async throws -> ImageFlipResponse {
        try await get("api/video/flip")
    }

    /// Rotate the picture 180 degrees — POST /api/video/flip. For a camera
    /// worn upside-down, a cap mount for instance: this is an EXTRA half-turn
    /// on top of however the camera is built, so with it on an inverted camera
    /// records and previews upright.
    ///
    /// On a stereo camera the two eyes swap with it (the file that was `_L`
    /// becomes `_R`, the side-by-side stream swaps halves) and the calibration
    /// the camera serves from `/api/calibration` is rotated to match, so a
    /// flipped camera does not have to be recalibrated.
    ///
    /// Persisted, and the camera RESTARTS to apply (~15 s, same
    /// re-enumeration as `setBitrate`) because the rotation is programmed into
    /// the sensor when the imaging pipeline starts. Kept by a settings reset:
    /// it describes how the camera is mounted, not a picture preference.
    public func setImageFlip(_ on: Bool) async throws {
        try await post("api/video/flip", contentType: "application/json",
                       body: try JSONEncoder().encode(ImageFlipCommand(on)))
    }

    /// Card recording audio format — GET /api/audio/format ("aac" | "pcm").
    public func recordingAudioFormat() async throws -> AudioFormatResponse {
        try await get("api/audio/format")
    }

    /// Also write the original uncompressed samples to the card, as a `.wav`
    /// beside each recording — POST /api/audio/format, "aac" | "pcm".
    ///
    /// Additive, not a swap: the MP4 keeps exactly the same AAC track, and the
    /// `.wav` is sample-aligned to it so it drops in with no offset. Raw PCM
    /// cannot go inside an MP4 (see `AudioFormat`), which is why it arrives as
    /// a sidecar. Costs about twelve times AAC's audio bitrate on the card.
    ///
    /// Card recordings only — the audio inside the live stream is always AAC.
    /// Persisted; the camera restarts to apply.
    public func setRecordingAudioFormat(_ format: String) async throws {
        try await post("api/audio/format", contentType: "application/json",
                       body: try JSONEncoder().encode(AudioFormatCommand(format: format)))
    }

    /// Enable/disable the in-band IMU SEI stream — POST /api/imu/stream. Live.
    public func setImuStream(_ enabled: Bool) async throws { try await postJSON("api/imu/stream", EnabledCommand(enabled)) }
    public func imuStream() async throws -> EnabledResponse { try await get("api/imu/stream") }

    /// Lock/unlock calibration writes — POST /api/calibration/lock. Live + persisted.
    /// While locked the camera rejects calibration uploads (403).
    public func setCalibrationLock(_ locked: Bool) async throws { try await postJSON("api/calibration/lock", LockedCommand(locked)) }
    public func calibrationLock() async throws -> LockedResponse { try await get("api/calibration/lock") }

    // §10 audio sample rate.

    /// Audio capture sample rate (16000 | 44100 | 48000 Hz) — POST /api/audio/rate.
    /// Persisted; the camera reboots to apply (the AAC encoder is configured at
    /// capture start).
    public func setAudioRate(hz: Int) async throws { try await postJSON("api/audio/rate", HzCommand(hz: hz)) }
    public func audioRate() async throws -> HzResponse { try await get("api/audio/rate") }

    // MARK: - LED read-back, thermal limit, AWB tune, hue, exposure time,
    //         BLE broadcast, TNR

    /// Status LED channel state (0/1 each) — GET /api/led.
    public struct LedState: Sendable, Codable, Equatable {
        public let r: Int
        public let g: Int
        public let b: Int
        public var red: Bool { r != 0 }
        public var green: Bool { g != 0 }
        public var blue: Bool { b != 0 }
    }

    /// GET /api/thermal/limit. `celsius == 0` means "firmware default".
    public struct ThermalLimitResponse: Sendable, Codable, Equatable {
        public let celsius: Int
        public let min: Int?
        public let max: Int?
        public var isDefault: Bool { celsius == 0 }
    }
    public struct CelsiusCommand: Sendable, Codable { public let celsius: Int; public init(celsius: Int) { self.celsius = celsius } }
    /// POST /api/thermal/limit acknowledgement.
    public struct ThermalLimitSetResponse: Sendable, Codable, Equatable {
        public let status: String?
        public let celsius: Int?
        public let reboot: Bool?
    }

    /// GET /api/video/awb_tune — the user AWB tuning anchor table.
    public struct AwbTuneResponse: Sendable, Codable, Equatable {
        /// Colour temperature (K) of the most recent anchor.
        public let cct: Double
        /// Red / blue gain of that anchor.
        public let r: Double
        public let b: Double
        /// Number of anchors in the table (0 = untuned, firmware defaults).
        public let anchors: Int
    }
    public struct AwbTuneCommand: Sendable, Codable {
        public let cct: Int
        public let r: Double
        public let b: Double
        public init(cct: Int, r: Double, b: Double) { self.cct = cct; self.r = r; self.b = b }
    }
    public struct AwbTuneSetResponse: Sendable, Codable, Equatable {
        public let status: String?
        public let anchors: Int?
    }

    /// POST /api/ble acknowledgement (`next_boot`: applied from the next boot).
    public struct BleSetResponse: Sendable, Codable, Equatable {
        public let status: String?
        public let enabled: Int?
        public let next_boot: Bool?
    }


    /// Read back the status LED channels — GET /api/led.
    public func led() async throws -> LedState { try await get("api/led") }

    /// Recording thermal limit — GET /api/thermal/limit.
    public func thermalLimit() async throws -> ThermalLimitResponse { try await get("api/thermal/limit") }

    /// Set the recording thermal limit (75...100 °C) — POST /api/thermal/limit.
    /// Persisted; applies to the next recording, no reboot.
    @discardableResult
    public func setThermalLimit(celsius: Int) async throws -> ThermalLimitSetResponse {
        try await postDecoding("api/thermal/limit", CelsiusCommand(celsius: celsius))
    }

    /// AWB tuning table summary — GET /api/video/awb_tune.
    public func awbTune() async throws -> AwbTuneResponse { try await get("api/video/awb_tune") }

    /// Add an AWB tuning anchor (cct K, r/b gains) — POST /api/video/awb_tune.
    /// `cct <= 0` clears the table back to firmware defaults.
    @discardableResult
    public func setAwbTune(cct: Int, r: Double, b: Double) async throws -> AwbTuneSetResponse {
        try await postDecoding("api/video/awb_tune", AwbTuneCommand(cct: cct, r: r, b: b))
    }

    /// Hue 0...100 (50 = neutral) — POST /api/video/hue. Live.
    public func setHue(_ v: Int) async throws { try await postJSON("api/video/hue", ValueCommand(value: v)) }
    public func hue() async throws -> ValueResponse { try await get("api/video/hue") }

    /// Manual exposure time in units of 100 µs (5...2500 → 0.5 ms...250 ms) —
    /// POST /api/video/exposure_time. Live. Answers 409 while exposure mode is
    /// "auto"; switch to manual first.
    public func setExposureTime(_ units100us: Int) async throws {
        try await postJSON("api/video/exposure_time", ValueCommand(value: units100us))
    }
    public func exposureTime() async throws -> ValueResponse { try await get("api/video/exposure_time") }

    /// Bluetooth LE status broadcast on/off — GET /api/ble.
    public func ble() async throws -> EnabledResponse { try await get("api/ble") }

    /// Turn the Bluetooth LE status broadcast on/off — POST /api/ble. Persisted;
    /// takes effect from the next boot (`next_boot: true`).
    @discardableResult
    public func setBle(_ enabled: Bool) async throws -> BleSetResponse {
        try await postDecoding("api/ble", EnabledCommand(enabled))
    }

    /// Temporal noise reduction (Pro Stereo GS only; 404 elsewhere) — GET /api/video/tnr.
    public func tnr() async throws -> ValueResponse { try await get("api/video/tnr") }
    /// Enable/disable temporal noise reduction — POST /api/video/tnr {"value":0|1}.
    public func setTnr(_ on: Bool) async throws { try await postJSON("api/video/tnr", ValueCommand(value: on ? 1 : 0)) }



    private func postDecoding<B: Encodable, T: Decodable>(_ path: String, _ body: B) async throws -> T {
        let data = try await postData(path, contentType: "application/json",
                                      body: try JSONEncoder().encode(body))
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.decode(error) }
    }

    private func post(_ path: String, contentType: String, body: Data) async throws {
        _ = try await postData(path, contentType: contentType, body: body)
    }

    private func postData(_ path: String, contentType: String, body: Data) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.http(0) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            return data
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }

    private func getData(_ path: String) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        do {
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse else { throw APIError.http(0) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
            return data
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.transport(error)
        }
    }
}
