// InterfacePinning.swift — pin device-bound NWConnections to the USB CDC-NCM
// interface so they don't leak onto Wi-Fi.
//
// The Trinet has no Wi-Fi; it's reachable only over the USB link, where the
// phone holds 172.32.x.71 and the camera is 172.32.x.70. Raw NWConnection,
// left to default routing, sends these sockets out en0 (the phone's Wi-Fi to
// its normal network) and they fail with "Socket is not connected". Binding
// each connection to the specific USB interface (the one discovery found the
// device on) forces traffic onto the right link.
//
// We pin by resolving the exact NWInterface for the discovered BSD name and
// setting `requiredInterface`. This is deliberately NOT `prohibitedInterface-
// Types = [.wifi]`: that only removes Wi-Fi and leaves no satisfied path
// (the connection then reports `unsatisfied` and never connects). Pinning to
// the concrete interface forces the link where the connected-subnet route
// actually lives.
//
// SAFE FALLBACK: if the interface can't be resolved (name nil / not currently
// in the path), we return plain parameters and let the system route. That can
// never sever a working path — worst case it behaves like the unpinned code.

import Network

enum InterfacePinning {
    /// Snapshot the current path and find the NWInterface matching `name`
    /// (e.g. "en5"). Blocks briefly on an NWPathMonitor update; returns nil
    /// if not present.
    static func interface(named name: String) -> NWInterface? {
        let monitor = NWPathMonitor()
        let sem = DispatchSemaphore(value: 0)
        var found: NWInterface?
        monitor.pathUpdateHandler = { path in
            found = path.availableInterfaces.first { $0.name == name }
            sem.signal()
        }
        monitor.start(queue: DispatchQueue(label: "com.panoculon.trinet.ifresolve"))
        _ = sem.wait(timeout: .now() + 0.5)   // never on the main thread (see VideoStream)
        monitor.cancel()
        return found
    }

    static func tcp(boundTo interfaceName: String?) -> NWParameters {
        let p = NWParameters.tcp
        bind(p, to: interfaceName)
        return p
    }

    static func udp(boundTo interfaceName: String?) -> NWParameters {
        let p = NWParameters.udp
        bind(p, to: interfaceName)
        return p
    }

    private static func bind(_ p: NWParameters, to interfaceName: String?) {
        guard let interfaceName, let iface = interface(named: interfaceName) else { return }
        p.requiredInterface = iface
    }
}
