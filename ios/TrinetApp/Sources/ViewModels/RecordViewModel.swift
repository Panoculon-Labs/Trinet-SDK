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

    // For the live preview view.
    var sampleStream: AsyncStream<CMSampleBuffer>?

    // For the IMU plot.
    let imuHistory = ImuHistory()

    private var session: TrinetLiveSession?
    private var imuTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var startedAt = Date()

    func openSession(on device: TrinetDevice) async {
        if session != nil { return }
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
    }

    func closeSession() async {
        await stopRecording()
        imuTask?.cancel(); imuTask = nil
        await session?.stop()
        session = nil
        sampleStream = nil
        sessionActive = false
        imuHistory.reset()
    }

    func startRecording(into dir: URL) async {
        guard let session else { return }
        lastError = nil
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
