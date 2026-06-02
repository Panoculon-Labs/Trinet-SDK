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
| How the app gets bytes | libusb + libuvc, **isochronous transfers** | HTTP `GET` over **TCP/IP** |
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
│  (UVC class)│  isoc xfer │                                │
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
  H.264/H.265 access units arrive via **isochronous USB transfers**, frame by
  frame, with no IP stack in the path.
- The JNI shim copies each frame to Kotlin and stamps it with `CLOCK_MONOTONIC`.
- IMU is parsed from the SEI NALs inside those same frames.

Android-specific gotchas (Android 9–14): the app must hold `CAMERA` at the
moment of the USB-permission request, the receiver must be `RECEIVER_EXPORTED`
on API 33+, and the pending intent must be package-scoped for Android 14.
Details in the Android SDK docs ([streaming](streaming.md), [IMU](imu.md)).

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
  (UUID `TRINETIMUSEI`), ~19 samples/frame at 562 Hz / 30 fps; SoC temperature
  as a second SEI (`TRINETTEMP`).
- **Sync:** per-frame device **Start-of-Frame** time
  (`sof = timestamp_ns − fsync_delay_us × 1000`) gives ~1 ms video↔IMU
  alignment.
- **On-disk format:** `<base>.mp4` (IMU SEI muxed in) + `<base>.imu`
  (TRIMU001 v4) + `<base>.vts` (TRIVTS01 v2), byte-for-byte identical on both
  platforms and with the Linux toolchain.
- **Fusion:** Madgwick 6-axis (accel + gyro) orientation, `beta = 0.1`.

## Trade-offs

| Concern | UVC (Android) | CDC NCM (iOS) |
|---|---|---|
| App complexity | Native libusb/libuvc + JNI, USB permission dance | Pure Swift sockets; needs interface pinning |
| Bring-up | Plug in, grant USB permission | Wait for DHCP lease + Ethernet iface to appear |
| Portability of client | Tied to libusb/libuvc + NDK ABIs | Standard networking; zero native deps |
| Multi-device | Multiple UVC handles | Multiple interfaces / per-interface socket binding |
| Why this platform | Android can drive USB directly from user space | iPhone can't open external UVC at all |
