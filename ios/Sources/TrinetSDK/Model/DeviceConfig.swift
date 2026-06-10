// DeviceConfig.swift — encoder + stream knobs the iOS app can change at
// runtime. These map onto rkncm.ini values that get applied when the
// firmware (re)starts the VENC pipeline.

import Foundation

public enum VideoCodec: String, Sendable, Codable, CaseIterable, Identifiable {
    case h264
    case h265
    public var id: String { rawValue }
    public var displayName: String { self == .h265 ? "H.265 (HEVC)" : "H.264 (AVC)" }
}

public enum VideoResolution: String, Sendable, Codable, CaseIterable, Identifiable {
    case res1080p = "1920x1080"
    case res720p  = "1280x720"
    case res480p  = "640x480"

    public var id: String { rawValue }
    public var width: Int  { switch self { case .res1080p: 1920; case .res720p: 1280; case .res480p: 640 } }
    public var height: Int { switch self { case .res1080p: 1080; case .res720p: 720;  case .res480p: 480 } }
}

public struct DeviceConfig: Sendable, Codable, Equatable {
    public var codec: VideoCodec
    public var resolution: VideoResolution
    public var fps: Int
    public var bitrateKbps: Int
    public var gopSeconds: Int

    public init(codec: VideoCodec = .h264,
                resolution: VideoResolution = .res1080p,
                fps: Int = 30,
                bitrateKbps: Int = 15000,
                gopSeconds: Int = 1) {
        self.codec = codec
        self.resolution = resolution
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.gopSeconds = gopSeconds
    }

    /// Matches the firmware's compiled defaults (rkncm.ini ships these too,
    /// so a fresh device that's never been configured looks like this).
    public static let `default` = DeviceConfig()

    /// Reasonable presets SDK consumers can apply via `TrinetDevice.applyConfig`.
    /// (The demo app's Settings tab exposes only the codec — H.264 default,
    /// switchable to H.265 — and otherwise streams the firmware's defaults.)
    public static let presets: [(label: String, config: DeviceConfig)] = [
        ("1080p H.264 @ 15 Mbps", DeviceConfig(codec: .h264, resolution: .res1080p, fps: 30, bitrateKbps: 15000)),
        ("1080p H.265 @ 15 Mbps", DeviceConfig(codec: .h265, resolution: .res1080p, fps: 30, bitrateKbps: 15000)),
        ("1080p H.264 @ 8 Mbps",  DeviceConfig(codec: .h264, resolution: .res1080p, fps: 30, bitrateKbps: 8000)),
        ("720p H.264 @ 6 Mbps",   DeviceConfig(codec: .h264, resolution: .res720p,  fps: 30, bitrateKbps: 6000)),
        ("720p H.265 @ 4 Mbps",   DeviceConfig(codec: .h265, resolution: .res720p,  fps: 30, bitrateKbps: 4000)),
    ]
}
