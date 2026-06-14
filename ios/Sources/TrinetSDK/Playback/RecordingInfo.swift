// RecordingInfo.swift — "nerdy stats" about a recording (the Info dialog),
// matching the Android app's RecordingInfo: codec/resolution/fps/bitrate, GOP
// + keyframes, and IMU/VTS sidecar facts. Best-effort: missing/unreadable
// pieces stay nil rather than throwing.

import AVFoundation
import Foundation

public struct RecordingInfo: Sendable {
    // identity
    public var name: String
    public var deviceIdHex: String?
    public var createdAt: Date?

    // video
    public var videoSizeBytes: UInt64?
    public var durationSeconds: Double?
    public var codec: String?            // "HEVC (hvc1)" / "H.264 (avc1)"
    public var width: Int?
    public var height: Int?
    public var fpsMp4: Float?            // nominalFrameRate
    public var fpsVts: Float?            // from .vts header
    public var totalFrames: Int?
    public var keyframeCount: Int?
    public var gopFrames: Int?           // mean keyframe interval
    public var avgBitrateBps: Int64?

    // imu
    public var imuVersion: Int?
    public var imuSampleRateHz: Int?
    public var imuActualRateHz: Float?
    public var imuSampleCount: Int?
    public var accelFsName: String?
    public var gyroFsName: String?
    public var frameSyncEnabled: Bool?
    public var magPresent: Bool?        // v5+: live magnetometer data is present

    // vts
    public var vtsVersion: Int?
    public var vtsFrameCount: Int?

    public init(name: String) { self.name = name }
}

public enum RecordingInfoCollector {
    private static let accelFsNames = ["±2 g", "±4 g", "±8 g", "±16 g"]
    private static let gyroFsNames  = ["±250 dps", "±500 dps", "±1000 dps", "±2000 dps"]

    /// `mp4URL` is the recording's .mp4; .imu/.vts are looked up beside it.
    public static func collect(mp4URL: URL) async -> RecordingInfo {
        var info = RecordingInfo(name: mp4URL.deletingPathExtension().lastPathComponent)
        let fm = FileManager.default
        let imuURL = mp4URL.deletingPathExtension().appendingPathExtension("imu")
        let vtsURL = mp4URL.deletingPathExtension().appendingPathExtension("vts")

        if let attrs = try? fm.attributesOfItem(atPath: mp4URL.path) {
            info.videoSizeBytes = (attrs[.size] as? NSNumber)?.uint64Value
            info.createdAt = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date
        }

        await collectVideo(mp4URL, into: &info)
        collectImu(imuURL, into: &info)
        collectVts(vtsURL, into: &info)
        return info
    }

    // MARK: video

    private static func collectVideo(_ url: URL, into info: inout RecordingInfo) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        if let dur = try? await asset.load(.duration) { info.durationSeconds = dur.seconds }
        if let size = try? await track.load(.naturalSize) {
            info.width = Int(abs(size.width)); info.height = Int(abs(size.height))
        }
        if let fps = try? await track.load(.nominalFrameRate), fps > 0 { info.fpsMp4 = fps }
        if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
            info.avgBitrateBps = Int64(rate)
        }
        if let fmts = try? await track.load(.formatDescriptions), let f = fmts.first {
            info.codec = codecName(CMFormatDescriptionGetMediaSubType(f))
        }
        // Bitrate fallback: file bits / duration.
        if info.avgBitrateBps == nil, let bytes = info.videoSizeBytes,
           let dur = info.durationSeconds, dur > 0 {
            info.avgBitrateBps = Int64(Double(bytes) * 8 / dur)
        }
        // Frame + keyframe count via a passthrough reader (sync-sample flags).
        if let reader = try? AVAssetReader(asset: asset) {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                if reader.startReading() {
                    var frames = 0, keys = 0
                    while let sb = out.copyNextSampleBuffer() {
                        frames += 1
                        if isSyncSample(sb) { keys += 1 }
                    }
                    if frames > 0 {
                        info.totalFrames = frames
                        info.keyframeCount = keys
                        if keys > 0 { info.gopFrames = (frames + keys - 1) / keys }
                    }
                }
            }
        }
    }

    private static func isSyncSample(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false),
              CFArrayGetCount(arr) > 0 else { return true }   // no attachments → sync
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
        let key = Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
        guard let raw = CFDictionaryGetValue(dict, key) else { return true } // not present → sync
        let notSync = unsafeBitCast(raw, to: CFBoolean.self)
        return !CFBooleanGetValue(notSync)
    }

    private static func codecName(_ t: CMVideoCodecType) -> String {
        let c = String(format: "%c%c%c%c",
                       (t >> 24) & 0xff, (t >> 16) & 0xff, (t >> 8) & 0xff, t & 0xff)
        switch c {
        case "hvc1", "hev1": return "HEVC (\(c))"
        case "avc1":         return "H.264 (avc1)"
        default:             return c
        }
    }

    // MARK: imu (TRIMU001 v4/v5, 64-byte header + 80-byte samples)

    private static func collectImu(_ url: URL, into info: inout RecordingInfo) {
        guard let d = try? Data(contentsOf: url), d.count >= 64 else { return }
        d.withUnsafeBytes { raw in
            let b = raw.baseAddress!
            info.imuVersion      = Int(UInt32(littleEndian: b.loadUnaligned(fromByteOffset: 8,  as: UInt32.self)))
            info.imuSampleRateHz = Int(UInt32(littleEndian: b.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            let accelFs = Int(UInt16(littleEndian: b.loadUnaligned(fromByteOffset: 16, as: UInt16.self)))
            let gyroFs  = Int(UInt16(littleEndian: b.loadUnaligned(fromByteOffset: 18, as: UInt16.self)))
            info.accelFsName = accelFsNames.indices.contains(accelFs) ? accelFsNames[accelFs] : "fs=\(accelFs)"
            info.gyroFsName  = gyroFsNames.indices.contains(gyroFs)   ? gyroFsNames[gyroFs]   : "fs=\(gyroFs)"
            let flags = UInt32(littleEndian: b.loadUnaligned(fromByteOffset: 36, as: UInt32.self))
            info.frameSyncEnabled = (flags & 0x01) != 0
            info.magPresent = (flags & 0x02) != 0
            let id = Data(bytes: b.advanced(by: 40), count: 16)
            let hex = id.map { String(format: "%02x", $0) }.joined()
            info.deviceIdHex = hex == String(repeating: "0", count: 32) ? nil : hex
        }
        let n = (d.count - 64) / ImuSample.binarySize
        info.imuSampleCount = n
        if n >= 2,
           let first = ImuSample.decode(from: d, at: 64),
           let last  = ImuSample.decode(from: d, at: 64 + (n - 1) * ImuSample.binarySize) {
            let span = Double(last.timestampNs &- first.timestampNs)
            if span > 0 { info.imuActualRateHz = Float(Double(n - 1) * 1e9 / span) }
        }
    }

    // MARK: vts (TRIVTS01 v2, 32-byte header + 24-byte entries)

    private static func collectVts(_ url: URL, into info: inout RecordingInfo) {
        guard let d = try? Data(contentsOf: url), d.count >= 32 else { return }
        d.withUnsafeBytes { raw in
            let b = raw.baseAddress!
            info.vtsVersion = Int(UInt32(littleEndian: b.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let fpsMilli = UInt32(littleEndian: b.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            if fpsMilli > 0 { info.fpsVts = Float(fpsMilli) / 1000 }
        }
        info.vtsFrameCount = (d.count - 32) / VtsEntry.binarySize
    }
}
