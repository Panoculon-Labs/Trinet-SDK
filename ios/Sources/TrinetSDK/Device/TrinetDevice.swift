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
