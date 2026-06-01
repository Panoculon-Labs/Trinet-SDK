// swift-tools-version:5.9
//
// TrinetSDK — iOS-facing client SDK for the Trinet camera.
//
// ┌──────────────────────────────────────────────────────────────────────┐
// │  This is the iOS half of a cross-platform monorepo.                    │
// │    • iOS  SDK + demo app live under  ios/  (full Swift source)         │
// │    • Android SDK is distributed as a prebuilt AAR under  aar/          │
// │      (+ docs/); see the top-level README.                             │
// │                                                                        │
// │  KEEP THIS FILE AT THE REPOSITORY ROOT. Swift Package Manager only     │
// │  reads `Package.swift` from a repo's root when resolving a             │
// │  `.package(url:)` dependency — it cannot target a subdirectory. The    │
// │  targets below use `path:` to reach the sources under ios/.            │
// └──────────────────────────────────────────────────────────────────────┘
//
// The SDK targets the CDC NCM (USB-Ethernet) transport because iPhone does
// not expose external UVC cameras to third-party apps. The Android SDK uses
// UVC directly. See docs/TRANSPORT.md for the full comparison.

import PackageDescription

let package = Package(
    name: "TrinetSDK",
    platforms: [
        // iOS 17 is the deployment floor — the SDK uses Network.framework
        // patterns (NWParameters.requiredInterface) and AVFoundation hooks
        // that pre-iOS 17 lacks. macOS 13 is declared too so `swift build` /
        // `swift test` work on the host machine for CI; production targets
        // are iPhone-only.
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "TrinetSDK", targets: ["TrinetSDK"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "TrinetSDK",
            path: "ios/Sources/TrinetSDK"
        ),
        .testTarget(
            name: "TrinetSDKTests",
            dependencies: ["TrinetSDK"],
            path: "ios/Tests/TrinetSDKTests"
        ),
    ]
)
