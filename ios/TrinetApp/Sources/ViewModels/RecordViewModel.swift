// RecordViewModel.swift — owns the live session for preview + IMU plot,
// and drives recording through the session (no separate recorder object).
//
// Main-actor discipline: every method here runs on the main actor, so nothing
// in them may block. The slow parts live elsewhere — the camera API and the
// recorder setup are awaited (they run off the main actor), and the background
// keep-alive's audio-session work runs on TrinetAudioSession.queue
// (start()/stop() return immediately). Each step is a named interval
// (TrinetDiagnostics), so a DEBUG build's stall detector can name whatever is
// running if the main thread ever does stall.

import AVFoundation
import CoreMedia
import Foundation
import SwiftUI
import TrinetSDK

@MainActor
final class RecordViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var bytesRecorded: Int = 0
    @Published var sessionActive = false
    @Published var lastError: String?
    @Published var currentMp4URL: URL?
    /// True while the camera is too hot: recording + preview are paused; both
    /// resume automatically once it cools. The streaming analogue of SD pause_resume.
    @Published var isThermalPaused = false
    @Published var thermalTempC: Int = 0

    // For the live preview view. Published so the preview reattaches when the
    // session is recreated after a thermal-pause cooldown.
    @Published var sampleStream: AsyncStream<CMSampleBuffer>?

    // For the IMU plot.
    let imuHistory = ImuHistory()

    private var session: TrinetLiveSession?
    private var imuTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var thermalTask: Task<Void, Never>?
    private var device: TrinetDevice?
    private var recordDir: URL?
    private var wasRecordingBeforeThermal = false
    private var startedAt = Date()
    /// Set while the app is backgrounded with no recording running: the
    /// session was closed so iOS can suspend the app, and is reopened on return.
    private var closedForBackground = false
    /// Bumped by every open and close. An openSession() whose await outlived a
    /// close (or a newer open) sees a different value and discards its session
    /// instead of starting a second stream that nothing would ever stop.
    private var sessionGeneration = 0
    /// True while a start is in flight, so a double tap can't start two
    /// recordings (the first would never be finalized).
    private var startingRecording = false

    /// The live preview is deliberately SILENT: the session's audio is not
    /// played here. It still reaches recordings (the SDK muxes it into the MP4's
    /// AAC track), and Library playback plays that track.
    func openSession(on device: TrinetDevice) async {
        if session != nil { return }
        let iv = TrinetDiagnostics.begin("record.openSession")
        defer { iv.end() }
        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.device = device
        // The SDK asks the camera which codec it streams (and confirms it from
        // the stream itself) — no app-side codec assumption. Off the main
        // actor; can take up to the API timeout if the camera is slow.
        let s = await device.liveSession()
        // Closed, or superseded by another open, while we waited: drop this
        // one. It was never started, so there is nothing to stop.
        guard generation == sessionGeneration, session == nil else { return }
        self.session = s
        self.sampleStream = s.sampleStream
        self.sessionActive = true

        let imuStream = s.imuStream
        imuTask = Task { [weak self] in
            for await pkt in imuStream {
                self?.imuHistory.append(pkt.samples)
            }
        }

        await s.start()
        startThermalWatch()
    }

    func closeSession() async {
        let iv = TrinetDiagnostics.begin("record.closeSession")
        defer { iv.end() }
        sessionGeneration &+= 1          // invalidates an open still in flight
        thermalTask?.cancel(); thermalTask = nil
        await stopRecording()
        imuTask?.cancel(); imuTask = nil
        await session?.stop()
        session = nil
        sampleStream = nil
        sessionActive = false
        device = nil
        isThermalPaused = false
        imuHistory.reset()
    }

    /// Poll the camera's thermal status ~1 Hz over the device API (independent of
    /// the video stream). When it latches "paused" (too hot), stop recording
    /// + idle the preview so the device cools; when it clears, recreate the
    /// session (preview) and resume recording. No-op on firmware without /api/thermal.
    private func startThermalWatch() {
        if thermalTask != nil { return }
        thermalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let dev = self.device else { continue }
                guard let th = try? await dev.thermal() else { continue }
                // Publish only on change: every assignment re-renders the
                // whole Record screen.
                if self.thermalTempC != th.temp_c { self.thermalTempC = th.temp_c }
                if th.paused && !self.isThermalPaused {
                    await self.enterThermalPause()
                } else if !th.paused && self.isThermalPaused {
                    await self.exitThermalPause()
                }
            }
        }
    }

    private func enterThermalPause() async {
        wasRecordingBeforeThermal = isRecording
        // Pause, don't end: the background keep-alive stays on so a recording
        // paused while the phone is locked can still resume after cooling.
        await stopRecording(endKeepAlive: false)
        await session?.stop()       // stop the :8080 stream → camera idles → cools
        session = nil
        sampleStream = nil
        sessionActive = false
        isThermalPaused = true
    }

    private func exitThermalPause() async {
        isThermalPaused = false
        guard let dev = device else { return }
        await openSession(on: dev)   // recreate preview session
        if wasRecordingBeforeThermal, let dir = recordDir {
            wasRecordingBeforeThermal = false
            await startRecording(into: dir)
        }
        if !isRecording { BackgroundKeepAlive.shared.stop() }
    }

    func startRecording(into dir: URL) async {
        guard let session, !isRecording, !startingRecording else { return }
        let iv = TrinetDiagnostics.begin("record.start")
        defer { iv.end() }
        startingRecording = true
        defer { startingRecording = false }
        lastError = nil
        recordDir = dir
        do {
            // File + AVAssetWriter setup — runs off the main actor.
            let h = try await session.startRecording(in: dir)
            // The session was closed / replaced while the recorder was being
            // set up (the SDK already finalized that sink).
            guard self.session === session else { return }
            self.currentMp4URL = h.mp4URL
            self.startedAt = Date()
            self.elapsed = 0
            self.bytesRecorded = 0
            self.isRecording = true
            // Keep running if the app is backgrounded or the phone locks, so
            // the recording continues (like Android). Recording-only by design.
            // Non-blocking: the audio session is activated on the audio queue
            // (doing it here, on the main actor, was the Record-tap freeze).
            BackgroundKeepAlive.shared.start()
            setLed(false)   // no visible capture indicator while recording
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, let s = self.session else { return }
                    // O(1) and lock-free w.r.t. the video thread (its own
                    // counter lock), so this main-actor poll never waits on
                    // an MP4 append.
                    let bytes = s.recordingBytes
                    self.elapsed = Date().timeIntervalSince(self.startedAt)
                    if self.bytesRecorded != bytes { self.bytesRecorded = bytes }
                }
            }
        } catch is CancellationError {
            // Session stopped while starting (screen left / thermal pause).
        } catch {
            lastError = friendlyTrinetError(error)
        }
    }

    func stopRecording(endKeepAlive: Bool = true) async {
        let iv = TrinetDiagnostics.begin("record.stop")
        defer { iv.end() }
        tickerTask?.cancel(); tickerTask = nil
        let wasRecording = isRecording
        session?.stopRecording()   // returns immediately; finalizes off-main
        if isRecording { isRecording = false }
        // Non-blocking: deactivation runs on the audio queue.
        if endKeepAlive { BackgroundKeepAlive.shared.stop() }
        if wasRecording { setLed(true) }   // restore the LED now that capture stopped
    }

    // MARK: - Background / foreground

    /// App went to the background (or the phone locked). While recording, the
    /// keep-alive keeps the stream and the recording running; otherwise close
    /// the session cleanly so iOS can suspend the app, and reopen on return.
    func appDidEnterBackground() async {
        guard !isRecording, !isThermalPaused, !wasRecordingBeforeThermal, session != nil else { return }
        let dev = device
        await closeSession()
        device = dev
        closedForBackground = true
    }

    /// App is active again: reopen the preview session if it was closed for
    /// the background.
    func appDidBecomeActive() async {
        guard closedForBackground else { return }
        closedForBackground = false
        guard let dev = device else { return }
        device = nil
        await openSession(on: dev)
    }

    /// Set all LED channels on/off over the shared device connection, best-effort
    /// and non-blocking so it never gates record start/stop. The camera's LED is
    /// turned off while recording (no visible capture indicator) and restored
    /// when recording stops — matching the Android app.
    private func setLed(_ on: Bool) {
        guard let dev = device else { return }
        Task { try? await dev.setLed(r: on, g: on, b: on) }
    }

    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask)[0]
        return docs.appendingPathComponent("Trinet", isDirectory: true)
    }
}
