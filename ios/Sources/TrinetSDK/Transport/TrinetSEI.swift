// TrinetSEI.swift — parses the Trinet in-stream SEI (IMU + temperature),
// mirroring the Android SDK's SeiImuParser / SeiConstants byte-for-byte.
//
// The NCM firmware now embeds IMU and SoC-temperature data as user_data_
// unregistered SEI NALs inside the H.264/H.265 bitstream (the legacy UDP :5555
// IMU channel and the TRINETVSYNC timestamp SEI are gone). A normal decoder
// ignores these SEIs; we parse them for the live plot, the .imu/.vts sidecars,
// and per-frame Start-of-Frame timing — and we also mux them into the MP4 so
// the recording self-contains IMU exactly like the UVC path.
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
}

/// SoC thermal reading (~1 Hz). Non-critical.
public struct TempReading: Sendable {
    public let milliC: Int32
    public let cpuKHz: UInt32
}

enum TrinetSEIPayload {
    case imu(ImuBatch)
    case temp(TempReading)
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
    static let headerSize = 16 + 1 + 2 + 2 + 2   // UUID+ver+count+afs+gfs = 23

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
            }
            pos += psize
        }
        return nil
    }

    /// SoF time from a sample (Trinet wire contract): timestamp minus the
    /// hardware frame↔IMU latch delay. Matches Android's deriveSofNs.
    static func deriveSofNs(_ s: ImuSample) -> UInt64 {
        let delay = UInt64(max(0, s.fsyncDelayUs) * 1000)
        return s.timestampNs >= delay ? s.timestampNs - delay : s.timestampNs
    }

    // MARK: - Payload decoders

    private static func decodeImu(_ payload: [UInt8]) -> TrinetSEIPayload? {
        guard payload.count >= headerSize else { return nil }
        // version = payload[16]; ignored
        let n      = Int(u16le(payload, 17))
        let accel  = Int(u16le(payload, 19))
        let gyro   = Int(u16le(payload, 21))
        let data = Data(payload)
        var samples = [ImuSample](); samples.reserveCapacity(n)
        var i = 0
        while i < n, headerSize + (i + 1) * ImuSample.binarySize <= payload.count {
            if let s = ImuSample.decode(from: data, at: headerSize + i * ImuSample.binarySize) {
                samples.append(s)
            }
            i += 1
        }
        return .imu(ImuBatch(samples: samples, accelFs: accel, gyroFs: gyro))
    }

    private static func decodeTemp(_ payload: [UInt8]) -> TrinetSEIPayload? {
        guard payload.count >= 16 + 1 + 4 + 4 else { return nil }
        let mC  = Int32(bitPattern: u32le(payload, 17))
        let khz = u32le(payload, 21)
        return .temp(TempReading(milliC: mC, cpuKHz: khz))
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
}
