# Transport: UVC (Android) vs CDC NCM (iOS)

The Trinet camera delivers the **same payload** — an H.264/H.265 elementary
stream with per-frame IMU embedded as SEI — to both platforms. But it reaches
each platform over a **different USB transport**, and that single difference
shapes the two SDKs. This document explains why, how each path works, and what
is identical across them.

## TL;DR

| | **Android** | **iOS** |
|---|---|---|
| USB class | **UVC** (USB Video Class) | **CDC NCM** (USB Ethernet) |
| How the app gets bytes | libusb + libuvc, **bulk or isochronous transfers** | HTTP `GET` over **TCP/IP** |
| Device appears as | a camera the app opens directly | an **Ethernet** interface (Settings → Ethernet) |
| IP stack | none | yes (DHCP lease, `172.32.x.0/24`) |
| Control / status | n/a (UVC controls) | JSON over HTTP `:8081` |
| Clock sync | device timestamps in the SEI | device timestamps in the SEI |
| Native code | C/C++ (libuvc, libusb via JNI) | none — pure Swift on Apple frameworks |

## Why they differ

**iOS does not let third-party apps open external UVC cameras.** Apple only
exposes the external-camera/UVC path to system apps and (partially) to iPadOS;
on iPhone a third-party app cannot enumerate or stream from a UVC device. (This
was confirmed with Apple Developer Technical Support.)

So the Trinet firmware presents **two different USB personalities**:

- To **Android**, it is a **UVC camera**. Android *can* drive USB devices
  directly from user space (via `UsbManager` + libusb), so the SDK talks UVC
  directly.
- To **iPhone**, it is a **CDC NCM** USB-Ethernet adapter. iOS happily brings up
  a USB-Ethernet interface, gets a DHCP lease, and lets apps open normal
  sockets — so the firmware serves the very same video stream over HTTP and the
  SDK is a plain network client.

Same camera, same encoder, same IMU — two USB descriptors.

## Android — UVC path

```
┌─────────────┐   USB-C    ┌───────────────────────────────┐
│  Trinet cam │◀──────────▶│  Android phone                 │
│  (UVC class)│ bulk/isoc  │                                │
└─────────────┘            │  libusb ── libuvc (event thd)  │
                           │        │                       │
                           │   libuvc_jni.cpp (JNI)         │
                           │        │                       │
                           │   NativeBridge.kt              │
                           │        │  SharedFlow<Frame>    │
                           │   TrinetSession.frames         │
                           │        │                       │
                           │   Mp4Writer / SeiImuParser     │
                           └───────────────────────────────┘
```

- The device enumerates as a **UVC camera class**. The app acquires USB
  permission (`UsbManager`) and hands the file descriptor to libuvc.
- libuvc owns its libusb context and runs an **event-handler thread**;
  H.264/H.265 access units arrive over **bulk or isochronous USB transfers**
  (see [Bulk vs isochronous](#bulk-vs-isochronous) below), frame by frame, with
  no IP stack in the path.
- The JNI shim copies each frame to Kotlin and stamps it with `CLOCK_MONOTONIC`.
- IMU is parsed from the SEI NALs inside those same frames.

Android-specific requirements (Android 9–14): the app must hold `CAMERA` at the
moment of the USB-permission request, the receiver must be `RECEIVER_EXPORTED`
on API 33+, and the pending intent must be package-scoped for Android 14.
Details in the Android SDK docs ([streaming](streaming.md), [IMU](imu.md)).

### Bulk vs isochronous

A UVC camera can deliver video over either USB transfer type, and Trinet cameras
ship in both configurations depending on firmware. **You do not choose, and you
do not configure anything**: the SDK reads the transfer type out of the device's
own descriptors when the stream opens and takes the matching path. Which one you
got is reported on `TrinetSession.health` as `StreamHealth.transport`
(`BULK`, `ISOCHRONOUS`, or `UNKNOWN` before the first health tick).

|  | **Bulk** | **Isochronous** |
|---|---|---|
| Bandwidth | Whatever is left on the bus; no reservation | Reserved slice of every USB frame |
| On error | The controller retries; data waits on the wire | The packet is dropped, permanently |
| Under load | Slows down | Corrupts |

Bulk is the default on current firmware. The trade is the classic one: bulk is
flow-controlled, so a busy phone or a marginal cable costs you latency rather
than pixels, whereas isochronous drops whatever did not fit and never resends
it. Some host controllers handle isochronous poorly enough to hand back
zero-filled or spliced frames under load, which is the failure bulk avoids.

Both paths are exercised and both are supported — a camera on older firmware
that presents isochronous streams to this SDK with no change on your side.
Corruption defences (frame budget, access-unit validation, stall detection) are
transport-independent, and `StreamHealth` exposes per-transport counters so a
bug report can say which path it was on.

## iOS — CDC NCM path

```
┌─────────────┐   USB-C    ┌───────────────────────────────┐
│  Trinet cam │◀──────────▶│  iPhone                        │
│ (CDC NCM /  │  Ethernet  │  USB-Ethernet iface (DHCP)     │
│  USB-Ether) │  frames    │  172.32.<X>.71  ⇄  cam .<X>.xx │
└─────────────┘            │        │                       │
                           │   NWConnection (pinned iface)  │
                           │        │                       │
                           │     VideoStream   DeviceAPI    │
                           │    :8080 video    :8081 JSON   │
                           │        │                       │
                           │   Mp4Writer / TrinetSEI        │
                           └───────────────────────────────┘
```

- The device enumerates as a **USB-Ethernet adapter**; iOS shows it under
  **Settings → Ethernet** and assigns the iPhone a DHCP lease on
  `172.32.<X>.0/24`.
- The SDK pins every `NWConnection` to that USB interface
  (`NWParameters.requiredInterface`) so traffic can't escape to Wi-Fi/cellular.
- Video is pulled with a plain `GET /live.h264` (or `.h265`) over **TCP `:8080`**;
  device control/status is JSON over **HTTP `:8081`**.
- Video↔IMU sync needs no extra channel: every frame's IMU SEI carries the
  device Start-of-Frame timestamp on the same clock as the frames. (A `:5557`
  UDP host-offset probe exists for a future multi-camera case, but is not used
  for normal sync.)
- No native code: the whole SDK is Swift over Network.framework / AVFoundation /
  VideoToolbox.

Full wire spec in [`../ios/docs/PROTOCOLS.md`](../ios/docs/PROTOCOLS.md).

## What's identical across both platforms

The transport differs; everything above it is shared by design so recordings
and tooling are cross-compatible:

- **Codec:** H.264 / H.265 **Annex-B** elementary stream; parameter sets
  (SPS/PPS, +VPS for H.265) sent up front.
- **IMU:** embedded **in-stream** as `user_data_unregistered` **SEI**
  (UUID `TRINETIMUSEI`). The rate varies by camera generation (commonly 400 Hz
  or ~562 Hz) — read the exact value from the sidecar header rather than
  assuming one. Camera temperature rides as a second SEI (`TRINETTEMP`).
- **Sync:** a per-frame device frame time on the same clock as the IMU samples.
  How it is derived depends on the camera generation — older cameras carry a
  hardware frame-sync delay to subtract, newer ones timestamp the sample
  directly — so use `SeiImuParser.deriveSofNs(sample, version)` and let it
  branch. Either way the result is ~1 ms video↔IMU alignment. See
  [file formats](file-formats.md).
- **On-disk format:** `<base>.mp4` (IMU SEI muxed in, plus TMF metadata in
  `moov/udta`) + `<base>.imu` (TRIMU001) + `<base>.vts` (TRIVTS01),
  byte-for-byte identical on both platforms and with the Linux toolchain.
- **Fusion:** Madgwick 6-axis (accel + gyro) orientation, `beta = 0.1`.

## Trade-offs

| Concern | UVC (Android) | CDC NCM (iOS) |
|---|---|---|
| App complexity | Native libusb/libuvc + JNI, USB permission dance | Pure Swift sockets; needs interface pinning |
| Bring-up | Plug in, grant USB permission | Wait for DHCP lease + Ethernet iface to appear |
| Portability of client | Tied to libusb/libuvc + NDK ABIs | Standard networking; zero native deps |
| Multi-device | Multiple UVC handles | Multiple interfaces / per-interface socket binding |
| Why this platform | Android can drive USB directly from user space | iPhone can't open external UVC at all |
