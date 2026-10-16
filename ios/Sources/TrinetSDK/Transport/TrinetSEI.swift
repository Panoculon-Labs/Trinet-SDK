// TrinetSEI.swift — parses the Trinet in-stream SEI (IMU + temperature),
// mirroring the Android SDK's SeiImuParser / SeiConstants byte-for-byte.
//
// The NCM firmware embeds IMU, temperature and (v4+) audio data as user_data_
// unregistered SEI NALs inside the H.264/H.265 bitstream — the SEI is the only
// IMU transport, exactly as over UVC. On stereo cameras there is one SEI stream
// for the whole side-by-side canvas. A normal decoder
// ignores these SEIs; we parse them for the live plot, the .imu/.vts sidecars,
// and per-frame Start-of-Frame timing — and we also mux them into the MP4 so
// the recording self-contains IMU exactly like the UVC path.
//
// v6 cameras add a per-frame timing block: the frame timestamp can be stamped
// at mid-exposure (TIMING flag MID_EXPOSURE) and reference either the top row
// or, when FRAME_CENTERED (0x08) is set, the rolling-shutter middle row. Simple
// playback uses the timestamp directly; per-row reconstruction (e.g. for
// calibration) branches on FRAME_CENTERED — see `ImuBatch.rowOffsetNs`.
//
// SEI wire format (Annex-B start code already stripped by the splitter):
//   [NAL header: 1B (h264 type 6) / 2B (h265 type 39)]
//   per message: payload_type (Σ 0xFF + final), payload_size (Σ 0xFF + final)
//   payload_type 5 = user_data_unregistered, dispatched by 16-byte UUID.
// EPB (00 00 03) is removed before parsing.
//
//   IMU  UUID "TRINETIMUSEI\0\1\0\0": version u8, num_samples u16 LE,
//        accel_fs u16 LE, gyro_fs u16 LE, then num_samples × 80-byte ImuSample.
//   TEMP UUID "TRINETTEMP\0\1\0\0\0\0": version u8, temp_mC i32 LE, cpu_kHz u32 LE.

import Foundation

/// One frame's IMU batch (~19 samples at 562 Hz / 30 fps).
public struct ImuBatch: Sendable {
    public let samples: [ImuSample]
    public let accelFs: Int
    public let gyroFs: Int
    /// SEI format version the camera stamped (3/4 = frame-sync delay in the
    /// trailing float; 5 = live magnetometer + mag_age_us; 6 adds the per-frame
    /// timing block below). 0 if the camera predates the version byte.
    public let version: Int
    /// v6+: this frame's timestamp (CLOCK_MONOTONIC ns) — mid-exposure if
    /// `isMidExposure`, else raw Start-of-Frame. References the middle row when
    /// `isFrameCentered`, else the top row. 0 for v<6.
    public let frameSofTsNs: UInt64
    /// v6+: applied integration time (µs), 0 if unknown.
    public let exposureUs: UInt32
    /// v6+: TIMING_* flags. 0x01 MID_EXPOSURE (timestamp centred in time),
    /// 0x02 EXPOSURE_VALID, 0x04 READOUT_VALID, 0x08 FRAME_CENTERED (timestamp
    /// references the middle rolling-shutter row rather than the top row).
    public let timingFlags: UInt8
    /// v6+: rolling-shutter readout span of the frame (µs), 0 if unknown.
    /// Per-row delay = `readoutTimeUs / imageHeight` (the Kalibr line_delay).
    public let readoutTimeUs: UInt32

    public static let timingMidExposure: UInt8 = 0x01
    public static let timingExposureValid: UInt8 = 0x02
    public static let timingReadoutValid: UInt8 = 0x04
    public static let timingFrameCentered: UInt8 = 0x08

    /// True if `frameSofTsNs` is exposure-center (v6 mid-exposure). This is a
    /// *temporal* statement (the timestamp is centred within the exposure), not
    /// a row statement — `isFrameCentered` says which row it references.
    public var isMidExposure: Bool { (timingFlags & Self.timingMidExposure) != 0 }

    /// True if `frameSofTsNs` references the rolling-shutter *middle* row
    /// (`r_ref = imageHeight / 2`) rather than the top row (`r_ref = 0`). When
    /// clear-but-`isMidExposure`, the timestamp references the top row.
    /// Per-row reconstruction must branch on this to pick `r_ref`; use
    /// `rowOffsetNs(row:imageHeight:)`, which already accounts for it.
    public var isFrameCentered: Bool { (timingFlags & Self.timingFrameCentered) != 0 }

    /// Nanosecond offset to add to `frameSofTsNs` to get the capture time of a
    /// given rolling-shutter row: `t_row(r) = frameSofTsNs + rowOffsetNs(r)`.
    /// `line_delay = readoutTimeUs / imageHeight` (the Kalibr line_delay);
    /// `r_ref = imageHeight / 2` if `isFrameCentered`, else 0. Returns 0 when
    /// readout span or image height is unknown (no per-row correction possible).
    public func rowOffsetNs(row: Int, imageHeight: Int) -> Int64 {
        guard readoutTimeUs != 0, imageHeight > 0 else { return 0 }
        let lineDelayNs = Double(readoutTimeUs) * 1000.0 / Double(imageHeight)
        let rRef = isFrameCentered ? Double(imageHeight) / 2.0 : 0.0
        return Int64(((Double(row) - rRef) * lineDelayNs).rounded())
    }

    public init(samples: [ImuSample], accelFs: Int, gyroFs: Int, version: Int,
                frameSofTsNs: UInt64 = 0, exposureUs: UInt32 = 0, timingFlags: UInt8 = 0,
                readoutTimeUs: UInt32 = 0) {
        self.samples = samples; self.accelFs = accelFs; self.gyroFs = gyroFs
        self.version = version
        self.frameSofTsNs = frameSofTsNs; self.exposureUs = exposureUs
        self.timingFlags = timingFlags; self.readoutTimeUs = readoutTimeUs
    }
}

/// Camera thermal reading (~1 Hz). Non-critical.
public struct TempReading: Sendable {
    public let milliC: Int32
    public let cpuKHz: UInt32
}

/// One AAC-LC frame recovered from a TRINETAAC SEI.
public struct AacFrame: Sendable {
    /// CLOCK_MONOTONIC microseconds — the same clock as `ImuBatch.frameSofTsNs`,
    /// so audio aligns to video directly.
    public let ptsUs: Int64
    /// A single self-describing ADTS AAC-LC frame (header + payload).
    public let adts: Data
    public init(ptsUs: Int64, adts: Data) { self.ptsUs = ptsUs; self.adts = adts }
}

/// One frame's batch of embedded AAC audio (v4 cameras). Empty/absent on older
/// cameras, which never emit the TRINETAAC SEI — so audio is feature-detected.
public struct AacBatch: Sendable {
    public let version: Int
    public let sampleRate: Int
    public let channels: Int
    public let frames: [AacFrame]
    public init(version: Int, sampleRate: Int, channels: Int, frames: [AacFrame]) {
        self.version = version; self.sampleRate = sampleRate
        self.channels = channels; self.frames = frames
    }
}

enum TrinetSEIPayload {
    case imu(ImuBatch)
    case temp(TempReading)
    case audio(AacBatch)
}

/// Per-frame capture timing derived from the IMU SEI.
public struct FrameTiming: Sendable, Hashable {
    public let sofNs: UInt64        // device CLOCK_MONOTONIC Start-of-Frame
    public let vencPtsUs: UInt64
    public let vencSeq: UInt32
    public let isKey: Bool
}

enum TrinetSEI {
    static let imuUUID: [UInt8] = [
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x49, 0x4D,
        0x55, 0x53, 0x45, 0x49, 0x00, 0x01, 0x00, 0x00,
    ]
    static let tempUUID: [UInt8] = [
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x54, 0x45,
        0x4D, 0x50, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
    ]
    // "TRINETAAC" — v4 cameras embed stereo AAC-LC audio. Layout after the UUID:
    //   version u8 · sample_rate u32 LE · channels u8 · num_frames u16 LE ·
    //   per frame: pts_us i64 LE (CLOCK_MONOTONIC µs) · len u16 LE · adts[len].
    static let aacUUID: [UInt8] = [
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x41, 0x41,
        0x43, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    static let aacHeaderSize = 16 + 1 + 4 + 1 + 2   // UUID+ver+rate+channels+count = 24
    static let headerSize = 16 + 1 + 2 + 2 + 2   // UUID+ver+count+afs+gfs = 23
    // v6 adds frame_sof_ts_ns(8) + exposure_us(4) + timing_flags(1) +
    // readout_time_us(4) before the samples. timing_flags bit 0x08
    // FRAME_CENTERED means frame_sof_ts_ns references the middle row, else top.
    static let headerSizeV6 = headerSize + 8 + 4 + 1 + 4   // 40

    /// `nalPayload` is one SEI NAL with the Annex-B start code removed.
    static func parse(nalPayload: Data, codec: VideoCodec) -> TrinetSEIPayload? {
        let raw = deEmulate(nalPayload)
        var pos = (codec == .h265) ? 2 : 1   // skip the NAL header
        while pos < raw.count - 1 {
            var ptype = 0
            while pos < raw.count, raw[pos] == 0xFF { ptype += 255; pos += 1 }
            guard pos < raw.count else { return nil }
            ptype += Int(raw[pos]); pos += 1

            var psize = 0
            while pos < raw.count, raw[pos] == 0xFF { psize += 255; pos += 1 }
            guard pos < raw.count else { return nil }
            psize += Int(raw[pos]); pos += 1

            guard pos + psize <= raw.count else { return nil }
            if ptype == 5, psize >= 16 {
                let payload = Array(raw[pos ..< pos + psize])
                if matches(payload, imuUUID)  { return decodeImu(payload) }
                if matches(payload, tempUUID) { return decodeTemp(payload) }
                if matches(payload, aacUUID)  { return decodeAudio(payload) }
            }
            pos += psize
        }
        return nil
    }

    /// SoF time from a sample (Trinet wire contract): on v3/v4 cameras the
    /// trailing float is the hardware frame↔IMU latch delay, so the
    /// Start-of-Frame time is the sample timestamp minus that delay. v5 cameras
    /// have no such delay (the trailing float is mag_age_us), so the sample
    /// timestamp is used as-is — never subtract mag_age. Matches Android's
    /// deriveSofNs. Pass the batch's `version`.
    static func deriveSofNs(_ s: ImuSample, version: Int) -> UInt64 {
        guard version < 5 else { return s.timestampNs }
        let delay = UInt64(max(0, s.fsyncDelayUs) * 1000)
        return s.timestampNs >= delay ? s.timestampNs - delay : s.timestampNs
    }

    /// The frame time to use for a video access unit, from its IMU batch.
    /// v6+: the camera's own per-frame timestamp (`frameSofTsNs`) — the same
    /// mapping the camera applies to its audio timestamps, so audio and video
    /// share one timeline. Older cameras (or a zero field): derived from the
    /// first IMU sample via `deriveSofNs`. nil if neither is available.
    static func frameTimeNs(of batch: ImuBatch) -> UInt64? {
        if batch.version >= 6, batch.frameSofTsNs != 0 { return batch.frameSofTsNs }
        guard let s0 = batch.samples.first else { return nil }
        return deriveSofNs(s0, version: batch.version)
    }

    // MARK: - Payload decoders

    private static func decodeImu(_ payload: [UInt8]) -> TrinetSEIPayload? {
        guard payload.count >= headerSize else { return nil }
        let version = Int(payload[16])
        let n      = Int(u16le(payload, 17))
        let accel  = Int(u16le(payload, 19))
        let gyro   = Int(u16le(payload, 21))

        // v6 adds the per-frame timing block (frame SoF + exposure + flags +
        // readout_time_us) before the samples.
        var frameSof: UInt64 = 0
        var exposure: UInt32 = 0
        var flags: UInt8 = 0
        var readout: UInt32 = 0
        let sampleBase: Int
        if version >= 6, payload.count >= headerSizeV6 {
            frameSof = u64le(payload, 23)
            exposure = u32le(payload, 31)
            flags = payload[35]
            readout = u32le(payload, 36)
            sampleBase = headerSizeV6
        } else {
            sampleBase = headerSize
        }

        let data = Data(payload)
        var samples = [ImuSample](); samples.reserveCapacity(n)
        var i = 0
        while i < n, sampleBase + (i + 1) * ImuSample.binarySize <= payload.count {
            if let s = ImuSample.decode(from: data, at: sampleBase + i * ImuSample.binarySize) {
                samples.append(s)
            }
            i += 1
        }
        return .imu(ImuBatch(samples: samples, accelFs: accel, gyroFs: gyro,
                             version: version, frameSofTsNs: frameSof,
                             exposureUs: exposure, timingFlags: flags,
                             readoutTimeUs: readout))
    }

    private static func decodeTemp(_ payload: [UInt8]) -> TrinetSEIPayload? {
        guard payload.count >= 16 + 1 + 4 + 4 else { return nil }
        let mC  = Int32(bitPattern: u32le(payload, 17))
        let khz = u32le(payload, 21)
        return .temp(TempReading(milliC: mC, cpuKHz: khz))
    }

    private static func decodeAudio(_ payload: [UInt8]) -> TrinetSEIPayload? {
        guard payload.count >= aacHeaderSize else { return nil }
        let version = Int(payload[16])
        let rate    = Int(u32le(payload, 17))
        let chans   = Int(payload[21])
        let n       = Int(u16le(payload, 22))

        var frames = [AacFrame](); frames.reserveCapacity(n)
        var pos = aacHeaderSize
        var i = 0
        while i < n, pos + 10 <= payload.count {
            let pts = Int64(bitPattern: u64le(payload, pos)); pos += 8
            let len = Int(u16le(payload, pos)); pos += 2
            guard len > 0, pos + len <= payload.count else { break }
            frames.append(AacFrame(ptsUs: pts, adts: Data(payload[pos ..< pos + len])))
            pos += len; i += 1
        }
        return .audio(AacBatch(version: version, sampleRate: rate, channels: chans, frames: frames))
    }

    // MARK: - Helpers

    private static func matches(_ payload: [UInt8], _ uuid: [UInt8]) -> Bool {
        guard payload.count >= uuid.count else { return false }
        for i in uuid.indices where payload[i] != uuid[i] { return false }
        return true
    }

    private static func deEmulate(_ d: Data) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(d.count)
        var zeros = 0
        for b in d {
            if zeros >= 2 && b == 0x03 { zeros = 0; continue }
            out.append(b)
            zeros = (b == 0) ? zeros + 1 : 0
        }
        return out
    }

    private static func u16le(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }
    private static func u32le(_ b: [UInt8], _ o: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[o + k]) << (8 * k) }
        return v
    }
    private static func u64le(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * k) }
        return v
    }
}
