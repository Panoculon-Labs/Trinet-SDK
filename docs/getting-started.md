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

Next: [Streaming →](streaming.md)
