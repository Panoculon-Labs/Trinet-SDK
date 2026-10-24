// LibraryView.swift — lists recordings already on the phone.
//
// Each recording is the triple <name>.mp4 / <name>.imu / <name>.vts under
// Documents/Trinet/. The list collapses those onto one row keyed by the
// base name and surfaces the MP4 file size. Rows can be swiped to delete
// (which removes the whole .mp4/.imu/.vts triple), and the Edit button
// enables multi-delete. Empty (0-byte) MP4s — left behind by an interrupted
// recording — are flagged so they're easy to spot and clear.

import AVKit
import LinkPresentation
import SwiftUI
import TrinetSDK
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @State private var entries: [Entry] = []
    @State private var confirmClearEmpty = false

    struct Entry: Identifiable {
        let id: String          // base name
        let mp4URL: URL
        let imuURL: URL?
        let vtsURL: URL?
        let mp4Size: UInt64
        let modified: Date
        var isEmpty: Bool { mp4Size == 0 }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { e in
                    row(for: e)
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No recordings yet",
                                           systemImage: "tray",
                                           description: Text("Start a recording from the Record tab."))
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                if entries.contains(where: { $0.isEmpty }) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear empty", role: .destructive) { confirmClearEmpty = true }
                    }
                }
            }
            .confirmationDialog("Delete interrupted recordings?",
                                isPresented: $confirmClearEmpty, titleVisibility: .visible) {
                let n = entries.filter(\.isEmpty).count
                Button("Delete \(n) empty recording\(n == 1 ? "" : "s")", role: .destructive,
                       action: deleteEmpties)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These 0-byte recordings can't be played. This can't be undone.")
            }
            .onAppear(perform: reload)
            .refreshable { reload() }
        }
    }

    @ViewBuilder
    private func row(for e: Entry) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(e.id).font(.headline)
                .foregroundColor(e.isEmpty ? .secondary : .primary)
            if e.isEmpty {
                Label("Interrupted recording — can't play. Swipe to delete.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            } else {
                HStack(spacing: 12) {
                    Label(byteString(e.mp4Size), systemImage: "film")
                    if e.imuURL != nil { Label("IMU", systemImage: "waveform") }
                }
                .font(.caption).foregroundColor(.secondary)
            }
            Text(e.modified, style: .date)
                .font(.caption2).foregroundColor(.secondary)
        }

        if e.isEmpty {
            // Nothing to play — show the row but don't navigate into a broken player.
            content
        } else {
            NavigationLink {
                PlayerScreen(url: e.mp4URL, title: e.id)
            } label: { content }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            remove(entries[index])
        }
        reload()
    }

    private func deleteEmpties() {
        for e in entries where e.isEmpty { remove(e) }
        reload()
    }

    /// Remove the whole .mp4 / .imu / .vts triple for one recording.
    private func remove(_ e: Entry) {
        let fm = FileManager.default
        for url in [e.mp4URL, e.imuURL, e.vtsURL].compactMap({ $0 }) {
            try? fm.removeItem(at: url)
        }
    }

    private func reload() {
        let dir = RecordViewModel.recordingsDirectory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                              includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            entries = []
            return
        }
        // group by base name
        var byBase: [String: (mp4: URL?, imu: URL?, vts: URL?, modified: Date)] = [:]
        for url in items {
            let base = url.deletingPathExtension().lastPathComponent
            var slot = byBase[base] ?? (nil, nil, nil, Date.distantPast)
            switch url.pathExtension.lowercased() {
            case "mp4": slot.mp4 = url
            case "imu": slot.imu = url
            case "vts": slot.vts = url
            default: continue
            }
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate),
               date > slot.modified { slot.modified = date }
            byBase[base] = slot
        }

        entries = byBase.compactMap { base, s in
            guard let mp4 = s.mp4 else { return nil }
            let size = (try? mp4.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return Entry(id: base, mp4URL: mp4, imuURL: s.imu, vtsURL: s.vts,
                         mp4Size: UInt64(size), modified: s.modified)
        }.sorted { $0.modified > $1.modified }
    }

    private func byteString(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}

/// Player for a recorded MP4 + its .imu sidecar: video with a fused-orientation
/// cube overlaid top-right, and a scrolling accel/gyro track below — both driven
/// by the video clock. Mirrors the Android SDK's PlaybackScreen.
struct PlayerScreen: View {
    let url: URL          // .mp4
    let title: String

    @State private var player: AVPlayer?
    @State private var imuData: ImuPlaybackData?
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    /// Device-clock ns of the first recorded video frame (from .vts). Maps the
    /// player's 0-based position to the device clock the IMU is stamped in.
    @State private var videoOriginNs: UInt64?
    @State private var showInfo = false
    @State private var showFullscreen = false
    @State private var loadFailed = false

    // Transport state for the custom (Android-style) control bar.
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false
    @State private var endObserver: NSObjectProtocol?
    private let fps: Double = 30

    private var imuURL: URL { url.deletingPathExtension().appendingPathExtension("imu") }
    private var vtsURL: URL { url.deletingPathExtension().appendingPathExtension("vts") }

    /// Absolute device CLOCK_MONOTONIC ns for the current player position.
    private var currentDeviceNs: UInt64 {
        let origin = videoOriginNs ?? imuData?.t0Ns ?? 0
        return origin &+ UInt64(max(0, currentTime) * 1e9)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    if loadFailed {
                        Color.black.aspectRatio(16.0/9.0, contentMode: .fit)
                            .overlay {
                                ContentUnavailableView("Can't play this recording",
                                    systemImage: "exclamationmark.triangle",
                                    description: Text("The file may be incomplete."))
                                    .foregroundStyle(.white)
                            }
                    } else if let player {
                        VideoLayerView(player: player)
                            .aspectRatio(16.0/9.0, contentMode: .fit)
                    } else {
                        Color.black.aspectRatio(16.0/9.0, contentMode: .fit)
                            .overlay { ProgressView().tint(.white) }
                    }
                    if imuData?.isEmpty == false,
                       let q = imuData?.orientationAtDeviceNs(currentDeviceNs) {
                        OrientationCubeView(quaternion: q)
                            .frame(width: 84, height: 84)
                            .background(Color.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    }
                }

                controlBar(showFullscreenButton: true)

                if let imuData, !imuData.isEmpty {
                    PlaybackImuTrackView(data: imuData, centerDeviceNs: currentDeviceNs)
                } else {
                    Text("No .imu sidecar for this recording")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Recording info")
                // The .mp4 self-contains video + IMU (muxed SEI) + frame timing,
                // so a single file is all you need to share. Pause the player
                // first, then present the share sheet with a PROMISED file (see
                // ShareSheet) so nothing opens or probes the large movie until
                // an activity is actually chosen.
                Button {
                    player?.pause(); isPlaying = false
                    ShareSheet.present(url: url, title: title)
                } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
            }
        }
        .sheet(isPresented: $showInfo) {
            RecordingInfoView(mp4URL: url)
        }
        .fullScreenCover(isPresented: $showFullscreen) {
            // Shares the SAME AVPlayer (a second player was the old hang).
            if let player {
                FullscreenPlayerView(player: player, controls: { controlBar(showFullscreenButton: false) })
            }
        }
        .onAppear(perform: setup)
        .onDisappear(perform: teardown)
    }

    // MARK: - Custom transport controls (Android-style)

    @ViewBuilder
    private func controlBar(showFullscreenButton: Bool) -> some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(max(currentTime, 0), max(duration, 0.001)) },
                    set: { v in
                        currentTime = v             // cube + track follow the thumb live
                        seek(to: v, exact: false)   // fast scrub of the video
                    }),
                in: 0...max(duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        isScrubbing = true
                        wasPlayingBeforeScrub = isPlaying
                        player?.pause(); isPlaying = false
                    } else {
                        seek(to: currentTime, exact: true)
                        isScrubbing = false
                        if wasPlayingBeforeScrub { player?.play(); isPlaying = true }
                    }
                })
            HStack(spacing: 12) {
                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 44, height: 44)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                Text("\(timecode(currentTime)) / \(timecode(duration))")
                    .font(.callout.monospacedDigit())
                Spacer()
                Text("frame \(Int(currentTime * fps))")
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                if showFullscreenButton {
                    Button { showFullscreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.title3).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Full screen")
                }
            }
        }
        .padding(.horizontal)
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause(); isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0, exact: true); currentTime = 0
            }
            player.play(); isPlaying = true
        }
    }

    private func seek(to t: Double, exact: Bool) {
        guard let player else { return }
        let cm = CMTime(seconds: max(0, t), preferredTimescale: 600)
        if exact {
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            let tol = CMTime(seconds: 0.08, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: tol, toleranceAfter: tol)
        }
    }

    private func timecode(_ s: Double) -> String {
        let t = Int(max(0, s)); let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private func setup() {
        let iv = TrinetDiagnostics.begin("player.setup")
        defer { iv.end() }
        // Recordings carry an AAC track; play it even with the ringer switch on
        // silent (the live preview used to set this category; it is silent now).
        // These calls block on the audio server (100 ms – 1 s+), so they run on
        // the SDK's audio-session queue, never on the main thread.
        TrinetAudioSession.perform("player.audioSession") { session in
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
        let p = AVPlayer(url: url)
        // Load + fuse the IMU track off the main thread; it's a quick parse but
        // a long recording has many samples.
        let imuFileURL = imuURL
        let vtsFileURL = vtsURL
        let mp4FileURL = url
        Task.detached(priority: .userInitiated) {
            // Prefer the .imu sidecar (fast); fall back to extracting the IMU
            // from the MP4's in-stream SEI so a shared-only .mp4 still replays
            // with the cube + IMU track.
            if FileManager.default.fileExists(atPath: imuFileURL.path) {
                let data = ImuPlaybackData.load(url: imuFileURL)
                let origin = ImuPlaybackData.firstVideoSofNs(vtsURL: vtsFileURL)
                await MainActor.run { self.imuData = data; self.videoOriginNs = origin }
            } else {
                let (data, origin) = await ImuPlaybackData.loadFromMp4(url: mp4FileURL)
                await MainActor.run { self.imuData = data; self.videoOriginNs = origin }
            }
        }
        // Drive currentTime from the video clock at 30 Hz so the orientation
        // cube is smooth (the sample plot is decimated, so this stays cheap).
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { t in
            guard !isScrubbing else { return }
            let s = t.seconds.isFinite ? t.seconds : 0
            if abs(s - currentTime) > 0.005 { currentTime = s }
        }
        // Duration (async) for the seek bar + timecode.
        Task {
            if let d = try? await p.currentItem?.asset.load(.duration), d.seconds.isFinite {
                duration = d.seconds
            }
        }
        // End of playback → flip the button back to ▶.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            isPlaying = false
        }
        // Surface a load failure instead of an infinite spinner.
        Task {
            for _ in 0..<25 {
                switch p.currentItem?.status {
                case .failed: loadFailed = true; return
                case .readyToPlay: return
                default: try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        player = p
        p.play()
        isPlaying = true
    }

    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
    }
}

/// Bare AVPlayerLayer host — just renders the video, no controls (our custom
/// control bar drives it). One AVPlayer can back several of these layers, so
/// inline + fullscreen share a single decode pipeline.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerLayerUIView {
        let v = PlayerLayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: PlayerLayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Full-screen replay sharing the parent's AVPlayer + reusing the same control
/// bar. Tap toggles the controls; the × button (or swipe-down) exits.
struct FullscreenPlayerView<Controls: View>: View {
    let player: AVPlayer
    @ViewBuilder let controls: () -> Controls
    @Environment(\.dismiss) private var dismiss
    @State private var controlsVisible = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VideoLayerView(player: player)
                .ignoresSafeArea()
                .onTapGesture { withAnimation { controlsVisible.toggle() } }
            if controlsVisible {
                controls()
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            // Always visible so there's never a "how do I get out" moment.
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.85)).padding()
            }
            .accessibilityLabel("Close full screen")
        }
    }
}

/// "Info" sheet — recording stats (codec, bitrate, GOP, fps, IMU rate, …),
/// matching the Android app's InfoDialog.
struct RecordingInfoView: View {
    let mp4URL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var info: RecordingInfo?

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section("Identity") {
                        row("Name", info.name)
                        row("Device ID", info.deviceIdHex ?? "(pre-v4)")
                        if let d = info.createdAt { row("Created", d.formatted(date: .abbreviated, time: .standard)) }
                    }
                    Section("Video") {
                        row("File size", info.videoSizeBytes.map(byteString) ?? "-")
                        row("Duration", info.durationSeconds.map(durString) ?? "-")
                        row("Codec", info.codec ?? "-")
                        row("Resolution", (info.width != nil && info.height != nil) ? "\(info.width!) × \(info.height!)" : "-")
                        row("FPS (mp4)", info.fpsMp4.map { String(format: "%.2f", $0) } ?? "-")
                        row("FPS (vts)", info.fpsVts.map { String(format: "%.2f", $0) } ?? "-")
                        row("Total frames", info.totalFrames.map(String.init) ?? "-")
                        row("Keyframes", info.keyframeCount.map(String.init) ?? "-")
                        row("Mean GOP", info.gopFrames.map { "\($0) frames" } ?? "-")
                        row("Avg bitrate", info.avgBitrateBps.map(bitrateString) ?? "-")
                    }
                    Section("Inertial sensor") {
                        row("Format", info.imuVersion.map { "TRIMU001 v\($0)" } ?? "-")
                        row("Nominal rate", info.imuSampleRateHz.map { "\($0) Hz" } ?? "-")
                        row("Actual rate", info.imuActualRateHz.map { String(format: "%.1f Hz", $0) } ?? "-")
                        row("Samples", info.imuSampleCount.map(String.init) ?? "-")
                        row("Accel range", info.accelFsName ?? "-")
                        row("Gyro range", info.gyroFsName ?? "-")
                        row("Frame-sync", info.frameSyncEnabled.map { $0 ? "on" : "off" } ?? "-")
                    }
                    Section("Frame timestamps (vts)") {
                        row("Format", info.vtsVersion.map { "TRIVTS01 v\($0)" } ?? "-")
                        row("Frame count", info.vtsFrameCount.map(String.init) ?? "-")
                    }
                } else {
                    HStack { ProgressView(); Text("Reading…").foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Recording info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
        .task {
            // collect() runs an AVAssetReader over every frame — keep it OFF
            // the main actor so opening the sheet doesn't freeze the UI.
            let u = mp4URL
            info = await Task.detached(priority: .userInitiated) {
                await RecordingInfoCollector.collect(mp4URL: u)
            }.value
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit()).multilineTextAlignment(.trailing)
        }
    }

    private func byteString(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
    private func durString(_ s: Double) -> String {
        let total = Int(s); let ms = Int((s - Double(total)) * 1000)
        return String(format: "%02d:%02d.%03d", total / 60, total % 60, ms)
    }
    private func bitrateString(_ bps: Int64) -> String {
        bps >= 1_000_000 ? String(format: "%.2f Mbps", Double(bps) / 1e6)
                         : String(format: "%.0f kbps", Double(bps) / 1e3)
    }
}

/// Presents the share sheet for a recording.
///
/// The recording is handed over as a PROMISED file: an NSItemProvider that
/// only declares "an MPEG-4 movie named <title>" and produces the file URL when
/// the chosen activity asks for it. With a plain file-URL item, UIKit and the
/// share sheet inspect the file while building the sheet — type sniffing,
/// collaboration / "default share mode" lookups (the `-10814` log lines), the
/// Save Video compatibility check, a QuickLook thumbnail — against a
/// multi-hundred-MB 3840x1080 movie. That work is UIKit's, so it can't be moved
/// off the main thread; a promise leaves nothing to inspect up front. The
/// preview is a stock icon and a title, so presenting costs the same for any
/// file. The "share.present" interval (TrinetDiagnostics) runs from the tap
/// until the sheet is on screen, so a slow presentation shows in the perf log.
enum ShareSheet {
    @MainActor
    static func present(url: URL, title: String) {
        let iv = TrinetDiagnostics.begin("share.present")
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              var top = window.rootViewController else { iv.end(); return }
        while let presented = top.presentedViewController { top = presented }

        let av = UIActivityViewController(
            activityItemsConfiguration: RecordingShareItem.configuration(url: url, title: title))
        av.completionWithItemsHandler = { activity, completed, _, error in
            let detail = "\(activity?.rawValue ?? "dismissed") completed=\(completed)"
                + (error.map { " error=\($0.localizedDescription)" } ?? "")
            TrinetDiagnostics.event("share.done", detail)
        }
        if let pop = av.popoverPresentationController {   // iPad
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 1,
                                    width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(av, animated: true) { iv.end() }
    }
}

private enum RecordingShareItem {
    @MainActor
    static func configuration(url: URL, title: String) -> UIActivityItemsConfiguration {
        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        // Lazily supplied: called only once an activity needs the bytes, off
        // the main thread. Not open-in-place, so the receiver gets its own copy
        // (an APFS clone on the same volume).
        provider.registerFileRepresentation(forTypeIdentifier: UTType.mpeg4Movie.identifier,
                                            fileOptions: [], visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        let config = UIActivityItemsConfiguration(itemProviders: [provider])
        config.perItemMetadataProvider = { _, key in
            switch key {
            case .title:
                return title
            case .linkPresentationMetadata:
                // Title + stock icon; no originalURL / imageProvider, so nothing
                // tries to thumbnail the movie.
                let md = LPLinkMetadata()
                md.title = title
                md.iconProvider = iconProvider()
                return md
            default:
                return nil
            }
        }
        config.previewProvider = { _, _, _ in iconProvider() }
        return config
    }

    private static func iconProvider() -> NSItemProvider? {
        UIImage(systemName: "film").map { NSItemProvider(object: $0) }
    }
}
