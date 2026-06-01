// SyncCoordinator.swift — SNTP-style probe of the device sync responder.
//
// Wire format (matches firmware sync_endpoint.c):
//   Request  (8 bytes, big-endian):
//     u32 magic = "TRSY" (0x54525359)
//     u32 client_seq
//   Response (24 bytes, big-endian):
//     u32 magic
//     u32 client_seq (echo)
//     u64 server_recv_mono_ns
//     u64 server_send_mono_ns
//
// Cristian offset = ((t1-t0) + (t2-t3)) / 2; delay = (t3-t0) - (t2-t1).
// We pick the lowest-delay probe out of N — that's the one with the least
// queuing noise. iOS-side timestamps are CLOCK_MONOTONIC ns
// (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`), which is what CMHostClock
// is built on, so the SDK can carry the offset forward without conversion.

import Foundation
import Network
import Darwin

public actor SyncCoordinator {
    public struct Offset: Sendable {
        public let deviceMinusHostNs: Int64   // add to host monotonic ns to get device monotonic ns
        public let roundTripNs: Int64
        public let probes: Int
    }

    public let host: String
    public let port: UInt16
    public let interfaceName: String?     // USB interface to pin to (e.g. "en5")
    private static let magic: UInt32 = 0x54525359

    public init(host: String, port: UInt16 = 5557, interfaceName: String? = nil) {
        self.host = host
        self.port = port
        self.interfaceName = interfaceName
    }

    public func probe(samples: Int = 10, spacingMs: Int = 50) async throws -> Offset {
        let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!,
                                using: InterfacePinning.udp(boundTo: interfaceName))
        conn.start(queue: .global(qos: .userInitiated))
        defer { conn.cancel() }

        // wait briefly for ready
        for _ in 0..<20 {
            if case .ready = conn.state { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        var bestDelay = Int64.max
        var bestOffset: Int64 = 0
        var done = 0

        for seq in 0..<UInt32(samples) {
            do {
                let (offset, delay) = try await singleProbe(conn: conn, seq: seq)
                done += 1
                if delay < bestDelay {
                    bestDelay  = delay
                    bestOffset = offset
                }
            } catch {
                // single drop is fine; keep trying
            }
            try? await Task.sleep(nanoseconds: UInt64(spacingMs) * 1_000_000)
        }
        if done == 0 {
            throw NSError(domain: "SyncCoordinator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no probes succeeded"])
        }
        return Offset(deviceMinusHostNs: bestOffset, roundTripNs: bestDelay, probes: done)
    }

    private func singleProbe(conn: NWConnection, seq: UInt32) async throws -> (offset: Int64, delay: Int64) {
        // Build request.
        var req = Data()
        let m: UInt32 = Self.magic.bigEndian
        withUnsafeBytes(of: m)              { req.append(contentsOf: $0) }
        var s = seq.bigEndian
        withUnsafeBytes(of: &s)             { req.append(contentsOf: $0) }

        let t0 = Self.monotonicNs()
        return try await withCheckedThrowingContinuation { cont in
            conn.send(content: req, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                    return
                }
                conn.receiveMessage { data, _, _, recvErr in
                    let t3 = Self.monotonicNs()
                    if let err = recvErr {
                        cont.resume(throwing: err)
                        return
                    }
                    guard let data, data.count >= 24 else {
                        cont.resume(throwing: NSError(domain: "SyncCoordinator", code: -2))
                        return
                    }
                    let (mag, rseq, t1, t2): (UInt32, UInt32, UInt64, UInt64) = data.withUnsafeBytes { raw in
                        let base = raw.baseAddress!
                        return (
                            UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 0,  as: UInt32.self)),
                            UInt32(bigEndian: base.loadUnaligned(fromByteOffset: 4,  as: UInt32.self)),
                            UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 8,  as: UInt64.self)),
                            UInt64(bigEndian: base.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
                        )
                    }
                    guard mag == Self.magic, rseq == seq else {
                        cont.resume(throwing: NSError(domain: "SyncCoordinator", code: -3))
                        return
                    }
                    let offset = (Int64(t1) - Int64(t0) + Int64(t2) - Int64(t3)) / 2
                    let delay  = (Int64(t3) - Int64(t0)) - (Int64(t2) - Int64(t1))
                    cont.resume(returning: (offset, delay))
                }
            })
        }
    }

    /// CLOCK_MONOTONIC ns on iOS. mach_continuous_time would sleep through
    /// suspend, mach_absolute_time stops during sleep — we want
    /// CLOCK_UPTIME_RAW which matches CMHostClock's underlying source.
    static func monotonicNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }
}
