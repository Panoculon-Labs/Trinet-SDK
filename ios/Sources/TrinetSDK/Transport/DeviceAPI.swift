// DeviceAPI.swift — HTTP JSON client for the device API on :8081.
//
// Endpoint surface is documented in ios/docs/PROTOCOLS.md. Live endpoints today:
//   GET  /api/device_id
//   GET  /api/state
//   GET  /api/storage
//   GET  /api/time
// Stub endpoints (return 501 — feature-detect via this client):
//   POST /api/time, GET/POST /api/recording, /api/recording/start_at,
//   /api/sessions, /api/files, /api/logs

import Foundation

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

    public struct DeviceIdResponse: Sendable, Codable {
        public let device_id: String
        public let product: String
        public let mode: String
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
    /// Camera internal temperature + a host-pause signal. Poll ~1 Hz while recording:
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

    /// Upload a calibration blob (raw 200 bytes) — POST /api/calibration.
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

    private func post(_ path: String, contentType: String, body: Data) async throws {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        do {
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError.http(0) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
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
