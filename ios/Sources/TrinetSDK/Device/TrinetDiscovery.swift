// TrinetDiscovery.swift — finds Trinet cameras reachable over the host's
// active USB Ethernet interfaces.
//
// Strategy: iterate every Ethernet-class interface on iOS, look for ones
// with a 172.32.0.0/12 address (the firmware's NCM subnet), and probe
// device_id at the .70 end of each /24. Anything that responds within
// the timeout becomes a TrinetDevice.
//
// Per-interface routing matters: iOS won't necessarily send our HTTP
// requests out the right interface when multiple are up. The Network
// framework's `requiredInterface` on NWParameters would let us pin it,
// but URLSession doesn't expose that knob — for v0 we accept that single
// Trinet is the common case and rely on iOS picking the right default
// route. Multi-Trinet support (the original customer ask) needs a small
// extension here that builds raw NWConnections per interface.

import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

public actor TrinetDiscovery {
    public init() {}

    public struct Candidate: Sendable {
        public let host: String              // 172.32.<X>.70
        public let interfaceName: String     // e.g. en7
    }

    /// Enumerate IPv4 addresses on every active interface and infer the
    /// device address. Trinet firmware always serves on `.70` of a /24 in
    /// the 172.32.<X>.0/24 range; the host gets the .71 side via udhcpd.
    public func enumerateCandidates() -> [Candidate] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var out: [Candidate] = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let n = node {
            defer { node = n.pointee.ifa_next }
            guard let saAny = n.pointee.ifa_addr,
                  saAny.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: n.pointee.ifa_name)
            // Only Ethernet-like — Apple names USB ethernet "enX". WiFi
            // is "en0" and we explicitly want to skip that.
            guard name.hasPrefix("en") && name != "en0" else { continue }

            // Pull the IPv4.
            var ip = saAny.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let addr = ip.sin_addr
            let bytes = withUnsafeBytes(of: addr) { Array($0) }
            guard bytes.count == 4 else { continue }
            // 172.32.<X>.71 → device is at 172.32.<X>.70
            if bytes[0] == 172 && bytes[1] == 32 && bytes[3] == 71 {
                let host = "172.32.\(bytes[2]).70"
                out.append(Candidate(host: host, interfaceName: name))
            }
        }
        return out
    }

    /// Probe candidates' /api/device_id in parallel; return those that
    /// respond within `timeout` seconds.
    public func scan(timeout: TimeInterval = 1.5) async -> [TrinetDevice] {
        let candidates = enumerateCandidates()
        return await withTaskGroup(of: TrinetDevice?.self) { group in
            for c in candidates {
                group.addTask {
                    let dev = TrinetDevice(host: c.host, interfaceName: c.interfaceName)
                    do {
                        try await withTimeout(seconds: timeout) {
                            try await dev.connect()
                        }
                        return dev
                    } catch {
                        return nil
                    }
                }
            }
            var hits: [TrinetDevice] = []
            for await dev in group { if let dev { hits.append(dev) } }
            return hits
        }
    }
}

private func withTimeout<T: Sendable>(seconds: TimeInterval,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
