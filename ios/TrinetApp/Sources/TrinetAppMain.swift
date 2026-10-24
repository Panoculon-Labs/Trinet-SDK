// TrinetAppMain.swift — SwiftUI app entry point.

import SwiftUI
import TrinetSDK

@main
struct TrinetApp: App {
    @StateObject private var deviceVM = DeviceViewModel()

    init() {
        #if DEBUG
        // Logs "STALL: main thread blocked ≥ 250 ms — open intervals: …" (and
        // the total once it clears) under subsystem com.panoculon.trinet,
        // category perf — see TrinetDiagnostics.
        MainThreadStallDetector.shared.start(thresholdMs: 250)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceVM)
                .task {
                    await deviceVM.scan()
                }
        }
    }
}
