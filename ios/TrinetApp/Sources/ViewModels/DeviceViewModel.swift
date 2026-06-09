// DeviceViewModel.swift — discovered + selected Trinet, plus connection
// status used by every screen.

import Foundation
import TrinetSDK

/// Turn SDK/transport errors into a short, human, recovery-oriented message —
/// never raw `Domain=… Code=…` / enum-case text.
func friendlyTrinetError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        return "Couldn't reach the Trinet. Check the USB cable, then tap Rescan."
    }
    if let local = error as? LocalizedError, let d = local.errorDescription,
       !d.isEmpty, !d.contains("Domain="), !d.hasPrefix("HTTP "),
       !d.hasPrefix("transport"), !d.hasPrefix("decode") {
        return d
    }
    return "Couldn't reach the Trinet. Check the USB cable, then tap Rescan."
}

@MainActor
final class DeviceViewModel: ObservableObject {
    @Published var devices: [TrinetDevice] = []
    @Published var selected: TrinetDevice?
    @Published var deviceId: String = ""
    @Published var storageTotal: UInt64? = nil
    @Published var storageFree: UInt64? = nil
    @Published var isScanning: Bool = false
    @Published var lastError: String?

    private let discovery = TrinetDiscovery()

    func scan() async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }
        let found = await discovery.scan(timeout: 1.5)
        self.devices = found
        if selected == nil { self.selected = found.first }
        if let dev = selected {
            await refreshInfo(for: dev)
        }
    }

    func refreshInfo(for dev: TrinetDevice) async {
        do {
            self.deviceId = await dev.deviceId
            let st = try await dev.storage()
            self.storageTotal = st.total_bytes
            self.storageFree  = st.available_bytes
        } catch {
            lastError = friendlyTrinetError(error)
        }
    }
}
