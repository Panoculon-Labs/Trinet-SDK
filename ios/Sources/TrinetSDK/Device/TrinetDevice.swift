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
    }

    /// Fetch the camera's stored calibration, or nil if none is stored.
    public func getCalibration() async throws -> CalibrationBlob? {
        do {
            let blob = CalibrationBlob.decode(from: try await api.getCalibration())
            self.calibration = blob
            return blob
        } catch DeviceAPI.APIError.http(404) {
            self.calibration = nil
            return nil
        }
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
