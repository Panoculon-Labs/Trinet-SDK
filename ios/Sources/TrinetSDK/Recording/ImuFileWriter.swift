// ImuFileWriter.swift — writes a TRIMU001 sidecar (v4 by default; upgraded to
// v5 in place once a v5 stream is observed — see `note(version:)`).
//
// TRIMU001 format (shared with the Android SDK and Linux toolchain — see
// ios/docs/PROTOCOLS.md and ios/README.md). Header:
//   magic[8] = "TRIMU001"
//   version  = uint32 (4 or 5)
//   sample_rate_hz = uint32
//   accel_fs, gyro_fs = uint16 each
//   start_time_ns, video_start_ns = uint64 each
//   flags = uint32 (bit 0 = frame-sync enabled, bit 1 = magnetometer present)
//   reserved[24]:
//     bytes 0..15  : device id (16 opaque bytes)
//     bytes 16..23 : ios_host_offset_ns (int64 LE)
// Then a contiguous run of 80-byte ImuSample structs. The sample layout is
// identical across v3/v4/v5; only the trailing float's meaning differs
// (frame-sync delay on v3/v4, magnetometer-sample age on v5).

import Foundation

public final class ImuFileWriter {
    public let url: URL
    private let handle: FileHandle
    public private(set) var sampleCount: Int = 0
    public let header: Header

    public struct Header: Sendable {
        public var sampleRateHz: UInt32
        public var accelFs: UInt16
        public var gyroFs:  UInt16
        public var startTimeNs: UInt64
        public var videoStartNs: UInt64
        public var fsyncEnabled: Bool
        public var deviceId: Data           // 16 bytes; pad with zeros if shorter
        public var iosHostOffsetNs: Int64   // host CMHostClock offset vs device monotonic
        // Initial format version + magnetometer flag. Default to v4/no-mag; the
        // writer upgrades the on-disk header in place via note(version:) once it
        // sees what the live stream actually carries.
        public var version: UInt32 = 4
        public var magPresent: Bool = false
    }

    // What the stream turned out to be — backpatched into the header on close()
    // so a v5 camera produces a correctly-labelled v5 sidecar (and an older
    // camera keeps its v4/frame-sync labelling).
    private var observedVersion: UInt32
    private var observedFsync: Bool
    private var observedMag: Bool

    public init(url: URL, header: Header) throws {
        self.url = url
        self.header = header
        self.observedVersion = header.version
        self.observedFsync = header.fsyncEnabled
        self.observedMag = header.magPresent
        // Truncate / create. We re-patch start_time_ns on close.
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        self.handle = try FileHandle(forWritingTo: url)

        // Write 64-byte header up front. start_time_ns / video_start_ns get
        // backpatched on close if they were zero.
        let blob = ImuFileWriter.serialize(header: header)
        try handle.write(contentsOf: blob)
    }

    public func append(samples: [ImuSample]) throws {
        if samples.isEmpty { return }
        var blob = Data(); blob.reserveCapacity(samples.count * ImuSample.binarySize)
        for s in samples { s.encode(into: &blob) }
        try handle.write(contentsOf: blob)
        sampleCount += samples.count
    }

    /// Record the TRIMU version the live stream is using so close() can stamp
    /// the right header. v5 means live magnetometer data and no frame-sync
    /// delay (the trailing float is mag_age_us), so clear the frame-sync flag
    /// and set the magnetometer flag.
    public func note(version: Int) {
        guard version > 0 else { return }
        if UInt32(version) > observedVersion { observedVersion = UInt32(version) }
        if version >= 5 {
            observedMag = true
            observedFsync = false
        }
    }

    public func close() throws {
        // Backpatch version (offset 8) + flags (offset 36) with what the stream
        // actually carried. The 80-byte sample layout is version-independent, so
        // only these two header fields need correcting.
        let flags: UInt32 = (observedFsync ? 1 : 0) | (observedMag ? 2 : 0)
        var ver = observedVersion.littleEndian
        var fl  = flags.littleEndian
        try? handle.seek(toOffset: 8)
        try? handle.write(contentsOf: Data(bytes: &ver, count: 4))
        try? handle.seek(toOffset: 36)
        try? handle.write(contentsOf: Data(bytes: &fl, count: 4))
        try handle.synchronize()
        try handle.close()
    }

    static func serialize(header h: Header) -> Data {
        var d = Data(); d.reserveCapacity(64)

        // magic
        d.append("TRIMU001".data(using: .ascii)!)        // 8 bytes
        // version (4 or 5)
        var ver: UInt32 = h.version; withUnsafeBytes(of: &ver) { d.append(contentsOf: $0) }
        var rate = h.sampleRateHz; withUnsafeBytes(of: &rate) { d.append(contentsOf: $0) }
        var afs = h.accelFs; withUnsafeBytes(of: &afs) { d.append(contentsOf: $0) }
        var gfs = h.gyroFs;  withUnsafeBytes(of: &gfs) { d.append(contentsOf: $0) }
        var st  = h.startTimeNs; withUnsafeBytes(of: &st) { d.append(contentsOf: $0) }
        var vs  = h.videoStartNs; withUnsafeBytes(of: &vs) { d.append(contentsOf: $0) }
        // flags: bit 0 = frame-sync enabled, bit 1 = magnetometer present
        var fl: UInt32 = (h.fsyncEnabled ? 1 : 0) | (h.magPresent ? 2 : 0)
        withUnsafeBytes(of: &fl) { d.append(contentsOf: $0) }

        // reserved[24]
        var rsv = Data(count: 24)
        let didLen = min(16, h.deviceId.count)
        if didLen > 0 {
            rsv.replaceSubrange(0..<didLen, with: h.deviceId.prefix(didLen))
        }
        var off = h.iosHostOffsetNs.littleEndian
        withUnsafeBytes(of: &off) { rsv.replaceSubrange(16..<24, with: $0) }
        d.append(rsv)

        precondition(d.count == 64, "TRIMU001 header must be exactly 64 bytes")
        return d
    }
}
