// ImuPlaybackData.swift — loads a .imu sidecar (TRIMU001 v4) and exposes the
// raw samples plus a precomputed Madgwick orientation track, with helpers to
// look up the sample/orientation nearest a playback time.
//
// Port of the Android SDK's ImuPlaybackData.kt. The .imu timestamps are device
// CLOCK_MONOTONIC ns; we zero-base them to the first sample so 0-based playback
// seconds map directly.

import AVFoundation
import CoreMedia
import Foundation

public struct ImuPlaybackData: Sendable {
    public let samples: [ImuSample]
    public let orientations: [Quaternion]   // one per sample
    public let t0Ns: UInt64
    public let sampleRateHz: Int

    public var isEmpty: Bool { samples.isEmpty }

    public var durationSeconds: Double {
        guard let last = samples.last else { return 0 }
        return Double(last.timestampNs - t0Ns) / 1e9
    }

    /// 0-based playback seconds for a sample.
    public func seconds(of s: ImuSample) -> Double {
        Double(s.timestampNs - t0Ns) / 1e9
    }

    /// Index of the sample nearest `tSeconds` (binary search).
    public func indexAt(_ tSeconds: Double) -> Int {
        if samples.isEmpty { return 0 }
        let targetNs = t0Ns &+ UInt64(max(0, tSeconds) * 1e9)
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].timestampNs < targetNs { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func orientationAt(_ tSeconds: Double) -> Quaternion {
        if orientations.isEmpty { return .identity }
        return orientations[min(max(0, indexAt(tSeconds)), orientations.count - 1)]
    }

    public func sampleAt(_ tSeconds: Double) -> ImuSample? {
        let i = indexAt(tSeconds)
        return samples.indices.contains(i) ? samples[i] : nil
    }

    // MARK: - Absolute device-clock lookups (for video↔IMU alignment)
    //
    // .imu sample timestamps and .vts sof_timestamp_ns are the SAME device
    // CLOCK_MONOTONIC clock. Given a video position, the player computes an
    // absolute device ns = (first .vts sof) + playbackSeconds and looks the IMU
    // up by that absolute timestamp — so frame N lines up with the IMU samples
    // captured at the same instant.

    public func indexAtDeviceNs(_ ns: UInt64) -> Int {
        if samples.isEmpty { return 0 }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].timestampNs < ns { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    public func orientationAtDeviceNs(_ ns: UInt64) -> Quaternion {
        if orientations.isEmpty { return .identity }
        return orientations[min(indexAtDeviceNs(ns), orientations.count - 1)]
    }

    public func sampleAtDeviceNs(_ ns: UInt64) -> ImuSample? {
        let i = indexAtDeviceNs(ns)
        return samples.indices.contains(i) ? samples[i] : nil
    }

    /// First frame's device Start-of-Frame ns from a TRIVTS01 sidecar — the
    /// origin that maps video position 0 to the device clock. Header is 32
    /// bytes; each entry is frame_number u32 + sof_timestamp_ns u64 + …
    public static func firstVideoSofNs(vtsURL: URL) -> UInt64? {
        guard let d = try? Data(contentsOf: vtsURL), d.count >= 32 + 24 else { return nil }
        let sof: UInt64 = d.withUnsafeBytes { raw in
            UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 32 + 4, as: UInt64.self))
        }
        return sof == 0 ? nil : sof
    }

    /// Load + precompute. Returns empty data if the file is missing/too short.
    public static func load(url: URL) -> ImuPlaybackData {
        guard let bytes = try? Data(contentsOf: url) else {
            return ImuPlaybackData(samples: [], orientations: [], t0Ns: 0, sampleRateHz: 562)
        }
        let headerSize = 64
        let sampleSize = ImuSample.binarySize   // 80
        guard bytes.count >= headerSize else {
            return ImuPlaybackData(samples: [], orientations: [], t0Ns: 0, sampleRateHz: 562)
        }
        // header: magic[8], version u32 @8, sample_rate_hz u32 @12 (LE)
        let rate: Int = bytes.withUnsafeBytes { raw in
            let r = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            return r <= 0 ? 562 : r
        }

        let n = (bytes.count - headerSize) / sampleSize
        var samples = [ImuSample](); samples.reserveCapacity(n)
        for i in 0..<n {
            guard let s = ImuSample.decode(from: bytes, at: headerSize + i * sampleSize) else { break }
            samples.append(s)
        }
        return build(samples: samples, rate: rate)
    }

    /// Build playback data (samples + precomputed Madgwick orientation track).
    public static func build(samples: [ImuSample], rate: Int) -> ImuPlaybackData {
        var orientations = [Quaternion](); orientations.reserveCapacity(samples.count)
        let ahrs = MadgwickAHRS()
        var prevTsNs: UInt64 = 0
        for (i, s) in samples.enumerated() {
            let dt: Float = (i == 0)
                ? 1 / Float(max(1, rate))
                : max(1e-6, Float(Double(s.timestampNs &- prevTsNs) / 1e9))
            prevTsNs = s.timestampNs
            ahrs.update(gx: s.gyro.x, gy: s.gyro.y, gz: s.gyro.z,
                        ax: s.accel.x, ay: s.accel.y, az: s.accel.z, dt: dt)
            orientations.append(ahrs.q)
        }
        let t0 = samples.first?.timestampNs ?? 0
        return ImuPlaybackData(samples: samples, orientations: orientations,
                               t0Ns: t0, sampleRateHz: max(1, rate))
    }

    /// Extract IMU from an MP4's in-stream Trinet SEI (when there's no .imu
    /// sidecar — e.g. a shared-only file). Returns the playback data and the
    /// video origin (first frame's SoF) for device-clock alignment.
    public static func loadFromMp4(url: URL) async -> (data: ImuPlaybackData, originNs: UInt64?) {
        let empty = ImuPlaybackData(samples: [], orientations: [], t0Ns: 0, sampleRateHz: 562)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return (empty, nil)
        }
        var codec: VideoCodec = .h265
        if let fmts = try? await track.load(.formatDescriptions), let f = fmts.first {
            codec = (CMFormatDescriptionGetMediaSubType(f) == kCMVideoCodecType_HEVC) ? .h265 : .h264
        }
        guard let reader = try? AVAssetReader(asset: asset) else { return (empty, nil) }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return (empty, nil) }
        reader.add(out)
        guard reader.startReading() else { return (empty, nil) }

        var samples = [ImuSample]()
        var originNs: UInt64?
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var total = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &total, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            let b = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
            // AVCC: 4-byte big-endian length + NAL, repeated.
            var off = 0
            while off + 4 <= total {
                let len = (Int(b[off]) << 24) | (Int(b[off+1]) << 16) | (Int(b[off+2]) << 8) | Int(b[off+3])
                off += 4
                guard len > 0, off + len <= total else { break }
                let first = b[off]
                let isSEI = (codec == .h265) ? (((first >> 1) & 0x3F) == 39) : ((first & 0x1F) == 6)
                if isSEI {
                    let nal = Data(bytes: b + off, count: len)
                    if case .imu(let batch)? = TrinetSEI.parse(nalPayload: nal, codec: codec) {
                        if originNs == nil, let s0 = batch.samples.first {
                            originNs = TrinetSEI.deriveSofNs(s0, version: batch.version)
                        }
                        samples.append(contentsOf: batch.samples)
                    }
                }
                off += len
            }
        }
        return (build(samples: samples, rate: 562), originNs)
    }
}
