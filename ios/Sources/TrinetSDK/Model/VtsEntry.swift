// VtsEntry.swift — one entry in a TRIVTS01 v2 sidecar.

import Foundation

public struct VtsEntry: Sendable, Hashable {
    /// 0-based encoded-frame index in the MP4.
    public var frameNumber: UInt32
    /// CLOCK_MONOTONIC ns at the ISP Start-of-Frame callback. Same domain
    /// as `ImuSample.timestampNs`. Zero if unavailable (host-side recording
    /// with no SoF source).
    public var sofTimestampNs: UInt64
    /// VENC sequence number for the encoded packet.
    public var vencSeq: UInt32
    /// VENC PTS in microseconds (Rockchip-derived CLOCK_MONOTONIC).
    public var vencPtsUs: UInt64

    public init(frameNumber: UInt32, sofTimestampNs: UInt64,
                vencSeq: UInt32, vencPtsUs: UInt64) {
        self.frameNumber = frameNumber
        self.sofTimestampNs = sofTimestampNs
        self.vencSeq = vencSeq
        self.vencPtsUs = vencPtsUs
    }

    public static let binarySize: Int = 24

    public func encode(into out: inout Data) {
        var fn = frameNumber.littleEndian; out.append(Data(bytes: &fn, count: 4))
        var sof = sofTimestampNs.littleEndian; out.append(Data(bytes: &sof, count: 8))
        var seq = vencSeq.littleEndian; out.append(Data(bytes: &seq, count: 4))
        var pts = vencPtsUs.littleEndian; out.append(Data(bytes: &pts, count: 8))
    }
}
