// RecordSink — lock-based recording target. Receives video NALs (from the
// VideoStream receive queue, via TrinetLiveSession.onNAL) and IMU samples
// (from the IMU telemetry task), writes mp4 + .imu + .vts.
//
// Why a lock-based class and not an actor: the previous actor-based
// recorder created an await chain (VideoStream → session → recorder) that
// tangled with stop() and hung. A plain class with one NSLock has no
// await, no reentrancy, no deadlock. The lock is held only for the
// duration of a fast, non-blocking append; stop() does a pointer swap
// under the lock, then finalizes the snapshot off-lock.

import AVFoundation
import Foundation

public struct RecordingHandle: Sendable {
    public let baseURL: URL
    public let mp4URL: URL
    public let imuURL: URL
    public let vtsURL: URL
    public let startedAtHostNs: UInt64
}

final class RecordSink: @unchecked Sendable {
    let handle: RecordingHandle

    private let lock = NSLock()
    private var mp4: Mp4Writer?
    private var vts: VtsFileWriter?
    private var imu: ImuFileWriter?
    private var frameNumber: UInt32 = 0
    private var sawKeyframe: Bool = false
    private var bytes: Int = 0
    private let codec: VideoCodec

    init(codec: VideoCodec,
         config: DeviceConfig,
         deviceId: Data,
         iosOffsetNs: Int64,
         paramSets: [Data],
         in directory: URL,
         baseName: String?) throws {
        self.codec = codec

        let name = baseName ?? RecordSink.nextName(in: directory)
        let base = directory.appendingPathComponent(name)
        let mp4URL = base.appendingPathExtension("mp4")
        let imuURL = base.appendingPathExtension("imu")
        let vtsURL = base.appendingPathExtension("vts")

        let header = ImuFileWriter.Header(
            sampleRateHz: 562, accelFs: 2, gyroFs: 3,
            startTimeNs: 0, videoStartNs: 0,
            fsyncEnabled: true,
            deviceId: deviceId,
            iosHostOffsetNs: iosOffsetNs)

        self.imu = try ImuFileWriter(url: imuURL, header: header)
        self.vts = try VtsFileWriter(url: vtsURL, fps: Double(config.fps))
        let writer = try Mp4Writer(url: mp4URL, codec: codec,
                                   width: config.resolution.width,
                                   height: config.resolution.height,
                                   fps: Double(config.fps))
        // Prime the writer with the cached VPS/SPS/PPS so its
        // CMVideoFormatDescription is ready before the first live VCL —
        // recording then starts at the very next keyframe instead of
        // waiting (up to a GOP) for the firmware to repeat the headers.
        for ps in paramSets {
            let unit = VideoStream.NALUnit(codec: codec, payload: ps, hostReceivedNs: 0)
            _ = try? writer.append(nal: unit)
        }
        self.mp4 = writer
        self.handle = RecordingHandle(baseURL: base, mp4URL: mp4URL,
                                      imuURL: imuURL, vtsURL: vtsURL,
                                      startedAtHostNs: SyncCoordinator.monotonicNs())
    }

    var bytesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    /// Called synchronously from the video receive queue. `seiPrefix` is the
    /// access unit's Trinet SEI NALs (IMU/temp), muxed into the MP4 frame so the
    /// recording self-contains IMU like the UVC path.
    func writeVideo(_ nal: VideoStream.NALUnit, seiPrefix: [Data] = []) {
        lock.lock(); defer { lock.unlock() }
        guard let mp4 else { return }
        let active = (try? mp4.append(nal: nal, seiPrefix: seiPrefix)) ?? false
        guard active else { return }
        bytes += nal.payload.count + 4
        guard Self.isVCL(nal) else { return }
        // Mirror Mp4Writer's keyframe gate so .vts frame N == MP4 frame N.
        if !sawKeyframe {
            guard Self.isKeyframe(nal) else { return }
            sawKeyframe = true
        }
        // Real device-clock timing from the TRINETVSYNC SEI (falls back to host
        // arrival time only if the stream carried no SEI). .imu already stores
        // device CLOCK_MONOTONIC sample times, so .vts and .imu share one clock.
        let sof  = nal.timing?.sofNs ?? nal.hostReceivedNs
        let vpts = nal.timing?.vencPtsUs ?? (nal.hostReceivedNs / 1000)
        let seq  = nal.timing?.vencSeq ?? frameNumber
        try? vts?.append(VtsEntry(frameNumber: frameNumber,
                                  sofTimestampNs: sof, vencSeq: seq, vencPtsUs: vpts))
        frameNumber += 1
    }

    /// Called from the IMU telemetry task. `version` is the TRIMU format the
    /// live stream is carrying (from the SEI), so the sidecar header is stamped
    /// v5/magnetometer rather than v4/frame-sync when recording a v5 camera.
    func writeIMU(_ samples: [ImuSample], version: Int = 4) {
        lock.lock(); defer { lock.unlock() }
        imu?.note(version: version)
        try? imu?.append(samples: samples)
    }

    /// Swap writers out under the lock, then finalize the snapshot off-lock
    /// in a detached task. Returns immediately — never blocks the caller.
    func finish() {
        lock.lock()
        let m = mp4; let v = vts; let i = imu
        mp4 = nil; vts = nil; imu = nil
        lock.unlock()

        Task.detached(priority: .utility) {
            if let m { await m.finish() }   // finish() is non-throwing + status-guarded
            try? v?.close()
            try? i?.close()
        }
    }

    private static func isVCL(_ nal: VideoStream.NALUnit) -> Bool {
        guard let first = nal.payload.first else { return false }
        switch nal.codec {
        case .h264: let t = first & 0x1F;        return t >= 1 && t <= 5
        case .h265: let t = (first >> 1) & 0x3F; return t <= 31
        }
    }

    private static func isKeyframe(_ nal: VideoStream.NALUnit) -> Bool {
        guard let first = nal.payload.first else { return false }
        switch nal.codec {
        case .h264: return (first & 0x1F) == 5
        case .h265: let t = (first >> 1) & 0x3F; return t >= 16 && t <= 23
        }
    }

    private static func nextName(in dir: URL) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 1
        while fm.fileExists(atPath: dir.appendingPathComponent("recording\(n).mp4").path) {
            n += 1
        }
        return "recording\(n)"
    }
}
