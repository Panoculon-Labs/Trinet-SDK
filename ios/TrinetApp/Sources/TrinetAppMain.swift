// TrinetAppMain.swift — SwiftUI app entry point.

import SwiftUI
import TrinetSDK

@main
struct TrinetApp: App {
    @StateObject private var deviceVM = DeviceViewModel()

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
