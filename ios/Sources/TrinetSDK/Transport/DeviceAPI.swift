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

    // MARK: - Public methods

    public func deviceId() async throws -> DeviceIdResponse { try await get("api/device_id") }
    public func state()    async throws -> StateResponse    { try await get("api/state") }
    public func storage()  async throws -> StorageResponse  { try await get("api/storage") }
    public func time()     async throws -> TimeResponse     { try await get("api/time") }

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
}
