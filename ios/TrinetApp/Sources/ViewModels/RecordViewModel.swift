// RecordViewModel.swift — owns the live session for preview + IMU plot,
// and drives recording through the session (no separate recorder object).

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
    private var codec: VideoCodec = .h264
    private var recordDir: URL?
    private var wasRecordingBeforeThermal = false
    private var startedAt = Date()

    func openSession(on device: TrinetDevice, codec: VideoCodec) async {
        if session != nil { return }
        self.device = device
        self.codec = codec
        // The live session requests `/live.<codec>`; set it before opening.
        await device.setLocalConfig(DeviceConfig(codec: codec))
        let s = await device.liveSession()
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
                self.thermalTempC = th.temp_c
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
        await stopRecording()
        await session?.stop()       // stop the :8080 stream → camera idles → cools
        session = nil
        sampleStream = nil
        sessionActive = false
        isThermalPaused = true
    }

    private func exitThermalPause() async {
        isThermalPaused = false
        guard let dev = device else { return }
        await openSession(on: dev, codec: codec)   // recreate preview session
        if wasRecordingBeforeThermal, let dir = recordDir {
            wasRecordingBeforeThermal = false
            await startRecording(into: dir)
        }
    }

    func startRecording(into dir: URL) async {
        guard let session else { return }
        lastError = nil
        recordDir = dir
        do {
            let h = try await session.startRecording(in: dir)
            self.currentMp4URL = h.mp4URL
            self.startedAt = Date()
            self.elapsed = 0
            self.bytesRecorded = 0
            self.isRecording = true
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, let s = self.session else { return }
                    let bytes = s.recordingBytes
                    await MainActor.run {
                        self.elapsed = Date().timeIntervalSince(self.startedAt)
                        self.bytesRecorded = bytes
                    }
                }
            }
        } catch {
            lastError = friendlyTrinetError(error)
        }
    }

    func stopRecording() async {
        tickerTask?.cancel(); tickerTask = nil
        session?.stopRecording()   // synchronous, returns immediately
        isRecording = false
    }

    static var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                             in: .userDomainMask)[0]
        return docs.appendingPathComponent("Trinet", isDirectory: true)
    }
}
