// ContentView.swift — root tab bar.

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "video") }

            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }

            LibraryView()
                .tabItem { Label("Library", systemImage: "folder") }

            ControlsView()
                .tabItem { Label("Controls", systemImage: "slider.horizontal.3") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
