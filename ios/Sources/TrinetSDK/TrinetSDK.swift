// TrinetSDK.swift — umbrella module
//
// The Trinet iOS SDK exposes a small surface for talking to a Trinet camera
// over a CDC NCM USB Ethernet link. Customers / app integrators interact
// mostly with `TrinetDevice` — the rest of this module is the implementation
// behind that one type.
//
// Quick start:
//
//     let discovery = TrinetDiscovery()
//     let devices   = await discovery.scan(timeout: 2.0)
//     guard let device = devices.first else { return }
//     try await device.connect()
//
//     // Apply codec/bitrate config (optional — defaults match firmware)
//     try await device.applyConfig(.init(codec: .h265, bitrateKbps: 15000))
//
//     // Open a live session: preview (sampleStream) + IMU (imuStream) + record
//     let session = await device.liveSession()
//     await session.start()
//     let handle = try await session.startRecording(in: outputDirectory)
//     // ... user records ...
//     session.stopRecording()
//     await session.stop()
//
// Wire-protocol details are in docs/PROTOCOLS.md (and docs/TRANSPORT.md for the
// UVC-vs-NCM comparison). This SDK is the canonical client implementation — if
// you find yourself opening raw sockets to the device, add a method here instead.

import Foundation

public enum TrinetSDK {
    /// SDK semantic version. Bumped when the public API or wire protocol
    /// changes in a way customers can observe.
    public static let version = "0.2.1"
}
