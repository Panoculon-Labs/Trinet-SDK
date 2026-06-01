// VtsFileWriter.swift — writes a TRIVTS01 v2 sidecar of per-frame timestamps.
//
// TRIVTS01 v2 format (shared with the Android SDK and Linux toolchain — see
// ios/docs/PROTOCOLS.md and ios/README.md):
//   Header (32 bytes):
//     magic[8] = "TRIVTS01"
//     version  = uint32 (2)
//     frame_rate_milli = uint32 (fps * 1000)
//     reserved[16]
//   Per-frame entry (24 bytes):
//     frame_number, sof_timestamp_ns, venc_seq, venc_pts_us

import Foundation

public final class VtsFileWriter {
    public let url: URL
    private let handle: FileHandle
    public private(set) var entryCount: Int = 0

    public init(url: URL, fps: Double) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        self.handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: VtsFileWriter.serialize(fps: fps))
    }

    public func append(_ entry: VtsEntry) throws {
        var d = Data(); d.reserveCapacity(VtsEntry.binarySize)
        entry.encode(into: &d)
        try handle.write(contentsOf: d)
        entryCount += 1
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }

    static func serialize(fps: Double) -> Data {
        var d = Data(); d.reserveCapacity(32)
        d.append("TRIVTS01".data(using: .ascii)!)         // 8 bytes
        var ver: UInt32 = 2; withUnsafeBytes(of: &ver) { d.append(contentsOf: $0) }
        var fpsMilli: UInt32 = UInt32(round(fps * 1000))
        withUnsafeBytes(of: &fpsMilli) { d.append(contentsOf: $0) }
        d.append(Data(count: 16))                          // reserved
        precondition(d.count == 32, "TRIVTS01 header must be exactly 32 bytes")
        return d
    }
}
