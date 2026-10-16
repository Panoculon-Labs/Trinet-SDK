// TrinetDeviceInfo.swift — which Trinet is on the other end of the link, and
// the shape of the video it streams.
//
// Populated from GET /api/device_id on `TrinetDevice.connect()`. Current
// firmware reports `model`, `cameras`, `layout` and `canvas` directly; older
// firmware reports only `generation` (or nothing), so every derived property
// falls back: v4 = Pro Mono, v5 = Pro Stereo, v6 = Pro Stereo GS.
//
// Stereo cameras stream ONE H.264 stream: a side-by-side canvas (3840x1080)
// with the physically left eye in x 0..<1920 and the right eye in
// x 1920..<3840, both genlocked, with a single SEI stream (IMU / temperature /
// audio) for the whole canvas. Recording keeps the full canvas; showing one
// eye is a display-only choice (see `StereoLens` / `LivePreviewView`).

import Foundation

/// Trinet camera model.
public enum TrinetModel: String, Sendable, Codable, CaseIterable {
    case proMono      = "pro-mono"
    case proStereo    = "pro-stereo"
    case proStereoGS  = "pro-stereo-gs"
    case mini         = "mini"
    case unknown      = "unknown"

    /// Human-readable product name.
    public var displayName: String {
        switch self {
        case .proMono:     "Trinet Pro Mono"
        case .proStereo:   "Trinet Pro Stereo"
        case .proStereoGS: "Trinet Pro Stereo GS"
        case .mini:        "Trinet Mini"
        case .unknown:     "Trinet"
        }
    }

    /// True for the two-camera boards.
    public var isStereo: Bool { self == .proStereo || self == .proStereoGS }

    /// True for the global-shutter board.
    public var isGlobalShutter: Bool { self == .proStereoGS }

    /// Parse the `model` string from /api/device_id (case-insensitive).
    public init(wireValue: String?) {
        guard let v = wireValue?.lowercased() else { self = .unknown; return }
        self = TrinetModel(rawValue: v) ?? .unknown
    }

    /// Fallback for firmware that doesn't report `model`: infer from the
    /// hardware generation string ("v4", "v5", "v6", …).
    public init(generation: String?) {
        switch generation?.lowercased() {
        case "v4": self = .proMono
        case "v5": self = .proStereo
        case "v6": self = .proStereoGS
        default:   self = .unknown
        }
    }
}

/// How the encoded frame is laid out.
public enum TrinetVideoLayout: String, Sendable, Codable {
    /// One camera fills the frame.
    case single
    /// Two cameras side by side: left eye = left half, right eye = right half.
    case sideBySide = "side_by_side"
}

/// Which part of a side-by-side stereo canvas to show in the live preview.
/// On a single-camera stream every value shows the whole frame.
public enum StereoLens: String, Sendable, Codable, CaseIterable {
    case left
    case both
    case right
}

/// Identity + capabilities of a connected Trinet, derived from /api/device_id.
public struct TrinetDeviceInfo: Sendable, Equatable {
    public let deviceId: String
    public let product: String
    /// Current transport mode reported by the camera ("ncm" over this link).
    public let mode: String
    public let generation: String?
    public let model: TrinetModel
    /// Firmware version, nil if not reported (or reported as "unknown").
    public let firmwareVersion: String?
    /// "shipping" | "dev", nil if not reported.
    public let build: String?
    public let cameraCount: Int
    public let layout: TrinetVideoLayout
    /// Encoded frame size (full canvas — both eyes on stereo boards).
    public let canvasWidth: Int
    public let canvasHeight: Int

    /// Default canvas sizes when the firmware doesn't report one.
    public static let monoCanvas = (width: 1920, height: 1080)
    public static let stereoCanvas = (width: 3840, height: 1080)

    public init(_ r: DeviceAPI.DeviceIdResponse) {
        deviceId = r.device_id
        product = r.product
        mode = r.mode
        generation = r.generation

        var m = TrinetModel(wireValue: r.model)
        if m == .unknown { m = TrinetModel(generation: r.generation) }
        model = m

        if let fw = r.firmware, !fw.isEmpty, fw.lowercased() != "unknown" {
            firmwareVersion = fw
        } else {
            firmwareVersion = nil
        }
        build = r.build

        // Explicit fields win; otherwise derive from the model.
        let stereoFallback = m.isStereo
        let cams = r.cameras ?? (stereoFallback ? 2 : 1)
        cameraCount = max(1, cams)

        if let l = r.layout, let parsed = TrinetVideoLayout(rawValue: l.lowercased()) {
            layout = parsed
        } else {
            layout = cameraCount >= 2 ? .sideBySide : .single
        }

        if let c = r.canvas, c.width > 0, c.height > 0 {
            canvasWidth = c.width; canvasHeight = c.height
        } else if layout == .sideBySide {
            canvasWidth = Self.stereoCanvas.width; canvasHeight = Self.stereoCanvas.height
        } else {
            canvasWidth = Self.monoCanvas.width; canvasHeight = Self.monoCanvas.height
        }
    }

    /// True when the stream carries two eyes side by side.
    public var isStereo: Bool { layout == .sideBySide || cameraCount >= 2 }

    /// True for the global-shutter stereo board.
    public var isGlobalShutter: Bool { model.isGlobalShutter }

    /// True on development firmware builds.
    public var isDevBuild: Bool { build?.lowercased() == "dev" }

    /// Width of one eye (half the canvas on stereo; the whole canvas on mono).
    public var eyeWidth: Int { isStereo ? canvasWidth / 2 : canvasWidth }

    /// Aspect ratio (w/h) of the full canvas — 32:9 on stereo, 16:9 on mono.
    public var canvasAspect: Double {
        canvasHeight > 0 ? Double(canvasWidth) / Double(canvasHeight) : 16.0 / 9.0
    }

    /// Aspect ratio (w/h) of one eye.
    public var eyeAspect: Double {
        canvasHeight > 0 ? Double(eyeWidth) / Double(canvasHeight) : 16.0 / 9.0
    }

    /// Aspect ratio of the preview for a given lens selection.
    public func previewAspect(for lens: StereoLens) -> Double {
        (isStereo && lens != .both) ? eyeAspect : canvasAspect
    }

    /// Nominal IMU sample rate (Hz) used for sidecar headers and plots: the
    /// stereo boards run the IMU at 400 Hz, the mono boards at 562 Hz.
    public var nominalImuRateHz: Int { isStereo ? 400 : 562 }

    /// Display name, e.g. "Trinet Pro Stereo GS".
    public var displayName: String { model.displayName }
}
