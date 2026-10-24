// DeviceViewModel.swift — discovered + selected Trinet, plus connection
// status used by every screen.

import Foundation
import TrinetSDK

/// Turn SDK/transport errors into a short, human, recovery-oriented message —
/// never raw `Domain=… Code=…` / enum-case text.
func friendlyTrinetError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        return "Couldn't reach the Trinet. Check the USB cable, then tap Rescan."
    }
    if let local = error as? LocalizedError, let d = local.errorDescription,
       !d.isEmpty, !d.contains("Domain="), !d.hasPrefix("HTTP "),
       !d.hasPrefix("transport"), !d.hasPrefix("decode") {
        return d
    }
    return "Couldn't reach the Trinet. Check the USB cable, then tap Rescan."
}

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published var devices: [TrinetDevice] = []
    @Published var selected: TrinetDevice?
    @Published var deviceId: String = ""
    @Published var isScanning: Bool = false
    @Published var lastError: String?
    /// Model / firmware / stream shape of the selected camera (nil until connected).
    @Published var info: TrinetDeviceInfo?

    /// True when the selected camera streams a side-by-side stereo canvas.
    var isStereo: Bool { info?.isStereo ?? false }

    /// The camera's live-stream codec as last read from it (nil = not read yet,
    /// or firmware without the stream-codec setting — it streams H.264). The
    /// live session asks the camera itself; this drives the Controls picker.
    @Published var streamCodec: VideoCodec?
    /// False on firmware without GET /api/video/stream_codec (picker hidden).
    @Published var streamCodecSupported = false
    /// True while the camera restarts its stream after a codec change. The
    /// Record screen closes its session and shows a "restarting" state, then
    /// reopens when this clears.
    @Published var streamRestarting = false

    /// What the live stream carries (H.264 unless the camera says otherwise).
    var codec: VideoCodec { streamCodec ?? .h264 }

    private let discovery = TrinetDiscovery()

    /// Read the live-stream codec from the selected camera. 404 = older
    /// firmware: H.264 only, no picker.
    func refreshStreamCodec() async {
        guard let dev = selected else { streamCodec = nil; streamCodecSupported = false; return }
        do {
            streamCodec = try await dev.streamCodec()
            streamCodecSupported = true
        } catch DeviceAPI.APIError.http(404) {
            streamCodec = .h264
            streamCodecSupported = false
        } catch {
            // Unreachable / transient: keep what we had.
        }
    }

    /// Switch the camera's live-stream codec: the camera restarts its stream
    /// server (~5–10 s). The Record screen's session is closed (any phone-side
    /// recording is stopped and saved) while `streamRestarting` is set, and is
    /// reopened once the camera's API answers again. Returns an error message,
    /// or nil on success.
    func changeStreamCodec(_ codec: VideoCodec) async -> String? {
        guard let dev = selected else { return "No camera connected. Rescan from Home." }
        guard !streamRestarting else { return nil }
        streamRestarting = true
        defer { streamRestarting = false }
        do {
            try await dev.setStreamCodec(codec)
        } catch {
            return friendlyTrinetError(error)
        }
        streamCodec = codec
        // The stream drops right after the acknowledgement; the API stays up.
        // Give the server a moment to go down, then wait until the camera
        // answers. The new live session keeps retrying :8080 until the stream
        // is back.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard await dev.waitUntilReachable(timeout: 30) else {
            return "The camera didn't come back after the codec change. Check the cable, then Rescan from Home."
        }
        await refreshStreamCodec()
        return nil
    }

    func scan() async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }
        let found = await discovery.scan(timeout: 1.5)
        self.devices = found
        if selected == nil { self.selected = found.first }
        if let dev = selected {
            await refreshInfo(for: dev)
        }
    }

    func refreshInfo(for dev: TrinetDevice) async {
        // info first: views key off deviceId changes and read info then.
        self.info = await dev.info
        self.deviceId = await dev.deviceId
        await refreshStreamCodec()
    }
}
