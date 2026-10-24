// BackgroundKeepAlive.swift — keep the app running while it is backgrounded or
// the phone is locked, so a phone-side recording of the camera stream doesn't
// stop.
//
// iOS suspends a backgrounded app within seconds, which drops the camera's
// stream socket. There is no background mode for a USB-Ethernet camera, so —
// like a field recorder app — the app keeps an audio session playing while a
// recording runs: an inaudible looped buffer through AVAudioEngine, mixed with
// other audio (music keeps playing, no ducking). Requires the app to declare
// `UIBackgroundModes: [audio]`.
//
// Use it only while a recording is running: start() when recording starts,
// stop() when it ends. It survives audio interruptions (a phone call, Siri) by
// restarting once the interruption ends, and media-services resets.
//
// Threading: start() and stop() only record what is wanted and return at once
// — safe (and cheap) on the main thread. The audio session and engine are
// driven on `TrinetAudioSession.queue`, which converges on the latest wanted
// state; a quick start → stop therefore costs at most one activation.
// (Doing that work synchronously on the main actor froze the UI for up to a
// second or more on every Record tap and again on stop.)
//
// Note for App Store distribution: background audio that plays silence can be
// questioned in review; TestFlight / ad-hoc / enterprise builds are unaffected.

import AVFoundation
import Foundation

public final class BackgroundKeepAlive: @unchecked Sendable {
    public static let shared = BackgroundKeepAlive()

    private let lock = NSLock()
    private var wanted = false                  // guarded by lock

    // Audio-queue only.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var sessionActive = false
    private var observing = false
    private var queue: DispatchQueue { TrinetAudioSession.queue }

    private init() {}

    /// True while the keep-alive audio is (meant to be) running.
    public var isActive: Bool {
        lock.withLock { wanted }
    }

    /// Start keeping the app alive in the background. Idempotent; returns
    /// immediately (the audio session is activated on the audio queue).
    public func start() {
        let changed = lock.withLock { () -> Bool in
            if wanted { return false }
            wanted = true
            return true
        }
        guard changed else { return }
        queue.async { [self] in reconcile() }
    }

    /// Stop keeping the app alive; iOS may suspend it in the background again.
    /// Returns immediately (deactivation happens on the audio queue).
    public func stop() {
        let changed = lock.withLock { () -> Bool in
            guard wanted else { return false }
            wanted = false
            return true
        }
        guard changed else { return }
        queue.async { [self] in reconcile() }
    }

    /// Block until queued audio work has run. Tests only.
    func waitUntilIdle() { TrinetAudioSession.waitUntilIdle() }

    /// Bring the engine/session in line with `wanted`. Audio queue only.
    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(queue))
        if isActive {
            if engine == nil {
                observeSessionIfNeeded()
                startEngine()
            }
        } else if engine != nil || sessionActive {
            let iv = TrinetDiagnostics.begin("keepalive.deactivate")
            defer { iv.end() }
            stopEngine()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionActive = false
        }
    }

    // MARK: - Engine (audio queue only)

    private func startEngine() {
        let iv = TrinetDiagnostics.begin("keepalive.activate")
        defer { iv.end() }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionActive = true
        } catch {
            NSLog("TrinetSDK BackgroundKeepAlive: audio session failed: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // 0.5 s of zeros, looped: inaudible, but the session is "playing".
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
        silence.frameLength = silence.frameCapacity   // buffers are zero-filled
        do {
            try engine.start()
        } catch {
            NSLog("TrinetSDK BackgroundKeepAlive: engine start failed: \(error)")
            return
        }
        player.scheduleBuffer(silence, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
    }

    private func stopEngine() {
        let e = engine, p = player
        engine = nil; player = nil
        p?.stop()
        e?.stop()
    }

    private func restartIfWanted() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isActive else { return }
        stopEngine()
        startEngine()
    }

    // MARK: - Interruptions

    /// Registered once, on first start, and kept for the app's lifetime (this is
    /// a singleton); every handler re-checks `wanted` on the audio queue.
    private func observeSessionIfNeeded() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        _ = nc.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw),
                  type == .ended, let self else { return }
            self.queue.async { self.restartIfWanted() }
        }
        _ = nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.restartIfWanted() }
        }
        // Route / hardware change stops the engine; only react to our own.
        _ = nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                           object: nil, queue: nil) { [weak self] note in
            guard let self, let changed = note.object as AnyObject? else { return }
            let changedID = ObjectIdentifier(changed)
            self.queue.async {
                if let e = self.engine, ObjectIdentifier(e) == changedID { self.restartIfWanted() }
            }
        }
    }
}
