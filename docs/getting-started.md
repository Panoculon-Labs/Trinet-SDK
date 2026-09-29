# Getting started

This guide takes you from an empty Android project to an open Trinet camera with USB permission granted. It
covers the manifest, the permissions Android requires for a USB video device, the
runtime permission flow, and the discovery API.

- [Install](#install)
- [AndroidManifest](#androidmanifest)
- [The USB permission flow](#the-usb-permission-flow)
- [Discovering a camera](#discovering-a-camera)
- [Opening a camera](#opening-a-camera)
- [Auto-launch on attach](#auto-launch-on-attach)
- [Lifecycle and cleanup](#lifecycle-and-cleanup)
- [Reconnecting after USB re-enumeration](#reconnecting-after-usb-re-enumeration)

---

## Install

See the [README install section](../README.md#install). In short: add the AAR via a
`flatDir` repository and declare the transitive dependencies (`androidx.core:core-ktx`,
`kotlinx-coroutines-android`, and — only if you use the `ui` widgets — Compose).

`minSdk` is **28**. The AAR ships native libraries for `arm64-v8a`, `armeabi-v7a`, and
`x86_64`.

---

## AndroidManifest

Three things are mandatory for any app that talks to a Trinet camera:

1. **`android.hardware.usb.host` feature** — the device must be a USB host (OTG).
2. **`android.permission.CAMERA`** — Android 9+ silently *denies* USB permission for
   video-class (UVC) devices unless the CAMERA runtime permission has been granted.
   You must request it at runtime before (or alongside) requesting USB permission.
3. **A `USB_DEVICE_ATTACHED` intent-filter + `device_filter.xml`** — optional, but
   strongly recommended: it makes your activity launch automatically when the camera is
   plugged in, and Android pre-grants USB permission to the activity it launches that
   way.

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <uses-feature android:name="android.hardware.usb.host" android:required="true" />
    <uses-feature android:name="android.hardware.camera.external" android:required="false" />

    <!-- Required for UVC USB camera access on Android 9+. Without it the system
         silently denies USB permission for video-class devices. -->
    <uses-permission android:name="android.permission.CAMERA" />

    <application ...>
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTask">

            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>

            <intent-filter>
                <action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" />
            </intent-filter>
            <meta-data
                android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED"
                android:resource="@xml/device_filter" />
        </activity>
    </application>
</manifest>
```

### `res/xml/device_filter.xml`

The Trinet camera enumerates under USB vendor ID `0x2207` (decimal `8711`). The product
ID varies across camera variants; list all of them. **The `device_filter.xml` values
are decimal**, while the SDK constants in code are hex.

```xml
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <usb-device vendor-id="8711" product-id="22" />   <!-- 0x2207 / 0x0016 -->
    <usb-device vendor-id="8711" product-id="24" />   <!-- 0x2207 / 0x0018 -->
    <usb-device vendor-id="8711" product-id="26" />   <!-- 0x2207 / 0x001A -->
</resources>
```

These match the SDK's `DeviceInfo` constants:

```kotlin
DeviceInfo.TRINET_VID   // 0x2207
DeviceInfo.TRINET_PIDS  // setOf(0x0016, 0x0018, 0x001A)
```

**The product ID does not tell you which camera it is.** A stereo camera enumerates
with the same product ID as a mono one. To tell them apart, open a session and check
its negotiated frame shape (`session.layout` / `session.isSideBySide` — see
[stereo cameras](streaming.md#stereo-cameras)); `getGeneration()` is a cross-check.

### Bluetooth (wireless status only)

Nothing above involves Bluetooth. Only if you use [wireless status](wireless-status.md)
— following cameras that record to their own card, without connecting — add the
Bluetooth LE feature and scan permissions listed in
[Wireless status → Permissions](wireless-status.md#permissions), and request
`WirelessCameraMonitor.requiredPermissions()` at runtime. The SDK itself declares none.

### Requesting CAMERA at runtime

CAMERA is a dangerous permission, so the manifest entry is not enough — request it at
runtime before opening a device:

```kotlin
private val cameraPermissionLauncher = registerForActivityResult(
    ActivityResultContracts.RequestPermission(),
) { granted -> /* retry discovery when granted */ }

fun ensureCameraPermission(): Boolean {
    val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
        PackageManager.PERMISSION_GRANTED
    if (!granted) cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
    return granted
}
```

---

## The USB permission flow

Even with the camera attached and CAMERA granted, Android requires the user to grant
**per-device USB permission**. The SDK wraps the broadcast dance (and the API 31/33/34
`PendingIntent` mutability + receiver-export changes) in a single suspend function.

```kotlin
import com.panoculon.trinet.sdk.device.DeviceDiscovery

// On a coroutine (the call suspends until the user accepts/rejects the system dialog):
val devices = DeviceDiscovery.connectedDevices(context)   // List<UsbDevice>
val usbDevice = devices.firstOrNull() ?: return
val granted: Boolean = DeviceDiscovery.requestPermission(context, usbDevice)
if (!granted) {
    // User declined, or another app holds the device. Ask them to replug.
}
```

`requestPermission` returns `true` immediately if permission was already held (e.g. the
activity was launched by `USB_DEVICE_ATTACHED`).

> **Permission-denied recovery:** if the user denies once, or another app has claimed
> the device, replugging is the reliable reset. A good UX is to detect denial and prompt
> the user to unplug, foreground your app, then plug back in.

---

## Discovering a camera

```kotlin
import com.panoculon.trinet.sdk.device.DeviceDiscovery
import com.panoculon.trinet.sdk.device.DeviceInfo

// All currently-attached Trinet-class devices.
val attached: List<android.hardware.usb.UsbDevice> =
    DeviceDiscovery.connectedDevices(context)

// Alternatively, you can filter raw UsbManager output:
val isTrinet = DeviceInfo(
    vendorId = usbDevice.vendorId,
    productId = usbDevice.productId,
    serial = usbDevice.serialNumber,
    productName = usbDevice.productName,
    deviceName = usbDevice.deviceName,
).isTrinet
```

`connectedDevices` only returns devices whose VID/PID match the Trinet set, so you
won't pick up unrelated USB peripherals.

---

## Opening a camera

The one-shot convenience that combines discovery, permission, and construction:

```kotlin
import com.panoculon.trinet.sdk.device.TrinetDevice

// Off the main thread — opening the USB device + initializing the native layer blocks.
val device: TrinetDevice? = withContext(Dispatchers.IO) {
    DeviceDiscovery.openFirstAvailable(context)   // null if none attached or denied
}
```

`openFirstAvailable` returns a `TrinetDevice` that owns the granted USB connection. To
begin streaming, call [`device.open(config)`](streaming.md) which returns a
`TrinetSession`.

If you need more control (e.g. choosing among multiple attached cameras), construct the
`TrinetDevice` yourself once permission is granted:

```kotlin
val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
val device = TrinetDevice(usbDevice, manager)   // usbDevice already permission-granted
```

`TrinetDevice.info` exposes the parsed `DeviceInfo` (vendor/product IDs, USB serial,
product name). The serial is the camera's public per-unit ID and is recorded into every
recording's metadata.

---

## Auto-launch on attach

With the `USB_DEVICE_ATTACHED` intent-filter (above), Android launches your activity and
pre-grants USB permission for the attached device. Read it from the launch intent so you
can skip the permission prompt:

```kotlin
override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    intent?.let(::handleUsbAttachIntent)
    // ...
}

override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    handleUsbAttachIntent(intent)
}

private fun handleUsbAttachIntent(intent: Intent) {
    if (intent.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
    val device: UsbDevice? =
        if (Build.VERSION.SDK_INT >= 33)
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        else
            @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
    // `device` is pre-granted; hand it to TrinetDevice(device, usbManager) directly.
}
```

To react to attach/detach while your app is foregrounded (without relying on the launch
intent), register a `BroadcastReceiver` for `ACTION_USB_DEVICE_ATTACHED` /
`ACTION_USB_DEVICE_DETACHED` in `onStart`/`onStop` and refresh your device list on each
event. On API 33+ register with `Context.RECEIVER_EXPORTED`.

---

## Lifecycle and cleanup

`TrinetDevice` and `TrinetSession` both implement `Closeable`. The native USB handle is
owned by the **device**, not the session:

```kotlin
session.close()   // stops streaming; does NOT release the USB handle
device.close()    // releases the USB handle (also closes the session)
```

Close them in that order, and never call `close()` on both for the same handle from two
paths — close the session, then the device, once.

---

## Reconnecting after USB re-enumeration

**The camera re-enumerates on the USB bus a few seconds after its connection is
closed** — including when your process is killed and Android closes the file
descriptors for you. To the host this looks like a quick detach → re-attach: the
`UsbDevice` object your app was holding (or grabs immediately on relaunch) goes
stale, and any `TrinetDevice` opened from it is dead.

If your app connects during that window and never re-checks the bus, it will sit
on the dead handle forever — typically seen as an app that is force-stopped and
relaunched failing to connect until the camera is unplugged and replugged. The
fix is a small self-heal loop; every screen (or repository) that owns a
connection should follow it:

1. **Listen for bus changes** — register a `BroadcastReceiver` for
   `ACTION_USB_DEVICE_ATTACHED` / `ACTION_USB_DEVICE_DETACHED` (fan the events out
   to your connection owner; on API 33+ register with `Context.RECEIVER_EXPORTED`).
2. **On detach: assume dead, tear down.** If `DeviceDiscovery.connectedDevices()`
   comes back empty, the connection you hold is unusable — stop any recording,
   `close()` the session and device, drop every cached reference, and show a
   "connecting" state. Do **not** keep the old `TrinetDevice` around to retry.
3. **On attach: reconnect from scratch.** Run the normal discovery → permission →
   `open()` → `start()` flow again.
4. **Guard the in-flight connect.** Key detail: the re-attach often arrives while
   a first connect attempt (made against the pre-re-enumeration device) is still
   in flight. Track the connect job itself — not just a UI "connecting" flag — and
   let a fresh attach event cancel/supersede it. Otherwise the reconnect is
   silently swallowed.

```kotlin
// 1. Fan out attach/detach (register in your Activity, onStart/onStop):
val usbEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 8,
                                        onBufferOverflow = BufferOverflow.DROP_OLDEST)
val receiver = object : BroadcastReceiver() {
    override fun onReceive(c: Context, i: Intent) { usbEvents.tryEmit(Unit) }
}

// 2–4. In the ViewModel/repository that owns the connection:
scope.launch {
    usbEvents.collect {
        val present = DeviceDiscovery.connectedDevices(context).isNotEmpty()
        if (!present) {
            // Camera left the bus (unplug, reboot, or re-enumeration after a
            // connection closed): everything we hold is dead.
            runCatching { recordingHandle?.stop() }
            session?.close(); session = null
            device?.close(); device = null
            uiState.value = Connecting
        } else if (!isStreaming) {
            connectJob?.cancel()               // supersede a stale in-flight attempt
            connectJob = launch { connectAndStartPreview() }
        }
    }
}
```

The demo app implements exactly this on its record and settings screens (v0.3.0+),
which is why it survives kill-and-relaunch and camera restarts (mode changes,
bitrate/GOP applies, firmware updates) without a replug. If you keep a single
shared connection for control calls (recommended — never open a second connection
while streaming), invalidate that cache in step 2 as well.

---

Next: [Streaming →](streaming.md)
