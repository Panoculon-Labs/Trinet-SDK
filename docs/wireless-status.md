# Wireless status

A Trinet camera recording to its own memory card — no phone attached — can
broadcast its status over **Bluetooth LE**. `WirelessCameraMonitor` listens to those
broadcasts and tells you, for every camera in range, whether it is recording, whether
its card is present, which take it is on, and when each recording started and
stopped, in **UTC**.

The phone **only listens; it never connects** to a camera. Any number of phones can
follow any number of cameras at once, and no USB connection is involved. The monitor
also keeps a history on the phone that you can export, so the desktop sync tool can
later put every frame of the card recordings on UTC.

- [Requirements](#requirements)
- [Turning the broadcast on or off](#turning-the-broadcast-on-or-off)
- [Permissions](#permissions)
- [Following cameras live](#following-cameras-live)
- [Camera identity](#camera-identity)
- [Stored history](#stored-history)
- [Exporting, and putting card recordings on UTC](#exporting-and-putting-card-recordings-on-utc)
- [Scan modes and background logging](#scan-modes-and-background-logging)
- [Limitations](#limitations)
- [Your own scanner](#your-own-scanner)

---

## Requirements

- **Camera firmware 0.5.9 or newer.** Older firmware never broadcasts, so a camera
  that does not appear is most often one that needs a firmware update.
- A phone with Bluetooth LE. The feature is optional: declare Bluetooth LE with
  `android:required="false"` so the app still installs on phones without it.
- SDK **0.5.3** or newer.

---

## Turning the broadcast on or off

The broadcast is **on by default** on Pro Mono, Pro Stereo and Pro Stereo GS
cameras running firmware 0.5.9 or newer. Switch it over the USB
connection:

```kotlin
device.setWirelessBroadcast(enabled = true)   // Boolean: true if the camera accepted it
device.getWirelessBroadcast()                 // Boolean?, null on firmware without the control
```

The camera saves the setting and **applies it from its next boot**. `resetSettings()`
restores the default. For a camera you have not opened as a `TrinetDevice`, the same
pair exists on `DeviceControls`:
`DeviceControls.setWirelessBroadcast(context, usbDevice, enabled)` /
`DeviceControls.getWirelessBroadcast(context, usbDevice)`.

---

## Permissions

The SDK's manifest declares **no Bluetooth permissions**, so apps that don't use this
feature don't inherit them. Add these to your app:

```xml
<uses-feature android:name="android.hardware.bluetooth_le" android:required="false" />

<!-- Android 12+: scan only, never used for location. -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />

<!-- Android 11 and older. -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

Request `WirelessCameraMonitor.requiredPermissions()` at runtime — `BLUETOOTH_SCAN` on
Android 12+, `ACCESS_FINE_LOCATION` on Android 11 and older, where location services
must also be switched on for scan results to arrive. `monitor.hasScanPermission()`
checks them.

Optional extras:

| Permission | Needed for |
|---|---|
| `INTERNET` | The internet time check that makes the phone's own clock more trustworthy. Without it the check is skipped. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `POST_NOTIFICATIONS` | Logging with the screen off — see [background logging](#scan-modes-and-background-logging). |

---

## Following cameras live

```kotlin
import com.panoculon.trinet.sdk.wireless.WirelessCameraMonitor
import com.panoculon.trinet.sdk.wireless.WirelessEvent
import com.panoculon.trinet.sdk.wireless.WirelessMonitorState

val monitor = WirelessCameraMonitor(context)      // history on by default

// Ask for the scan permission, then start. start() is idempotent: call it again
// after the user grants the permission.
permissionLauncher.launch(WirelessCameraMonitor.requiredPermissions())
monitor.start()                                   // main thread

// Every camera heard, ordered by unit id; republished at most 4 times a second.
scope.launch {
    monitor.cameras.collect { cameras ->
        for (cam in cameras) {
            val status = when {
                cam.recording  -> "recording take ${cam.takeNumber}"
                cam.finalizing -> "finalizing"
                else           -> "idle"
            }
            val card = if (cam.sdOk) "${cam.recordingCount} on card" else "no card"
            show(cam.unitId, status, card, cam.rssiAvg)
        }
    }
}

// Recording starts / stops as they are detected (not replayed to late collectors).
scope.launch {
    monitor.events.collect { e ->
        when (e) {
            is WirelessEvent.Started      -> log("${e.unitId} started take ${e.takeNumber} at ${e.utcMillis}")
            is WirelessEvent.Stopped      -> log("${e.unitId} stopped at ${e.utcMillis}")
            is WirelessEvent.AbnormalStop -> alert("${e.unitId} stopped unexpectedly (restarted: ${e.cameraRestarted})")
        }
    }
}

// Whether the scan is running, or why not.
scope.launch {
    monitor.state.collect { s ->
        if (s is WirelessMonitorState.Error) showError(s.reason, s.message)
    }
}

// ... later
monitor.stop()   // camera state, event history and stored history are kept
```

**`WirelessCamera`** (one entry of `cameras`):

| Member | Description |
|---|---|
| `unitId` | 8 lowercase hex characters: the first 8 of the camera's device id — the USB serial, and the prefix of phone recording folder names. |
| `recording` / `finalizing` / `sdOk` | Recording now / closing a take / memory card present. |
| `takeNumber` | Current take while recording, else the last one; 0 = none yet. |
| `recordingCount` | Recordings on the camera's card. |
| `groupId` / `role` | Kit id (16 bits; 0 = not in a kit) and the camera's `WirelessRole` in it (`UNPAIRED`, `MASTER`, `SLAVE`, `UNKNOWN`). |
| `rssi` / `rssiAvg` | Last signal strength and the value smoothed over ~3 s (dBm). A "near / far" hint, never a distance. |
| `lastSeenElapsedNanos`, `secondsSinceSeen(nowElapsedNanos)` | When it was last heard, on the phone's `SystemClock.elapsedRealtimeNanos()` clock. |
| `lastEdgeUtcMillis` / `lastEdgeDeviceMs` | Time of the last start/stop this camera boot (UTC / camera clock). |
| `fit` | Quality of the camera-clock fit: `samples`, `buckets`, `residualMs`, `skewPpm`, `ready`. |
| `identity` / `identityIsCurrent` | Model and firmware — see [camera identity](#camera-identity). |
| `advert` | The raw last `WirelessAdvert`. |

**Events.** Each `WirelessEvent` (`Started`, `Stopped`, `AbnormalStop`) carries
`unitId`, `takeNumber`, `deviceMs` (camera clock), `utcMillis` (null only while no
clock fit exists yet), `bootNonce`, `missedEdges` and `kind`. If several starts/stops
happened while a camera was out of range they collapse into one event reporting the
camera's *current* state, with `missedEdges` set. The first advert heard from a camera
produces no event. A camera that restarts while recording yields an `AbnormalStop`
with `cameraRestarted = true`, timed at the last camera time heard. `eventHistory`
holds the last 2000 events.

`monitor.toUtcMillis(unitId, deviceMs)` converts any camera time on that camera's
current boot to UTC.

**Errors** (`WirelessMonitorState.Error.reason`): `NO_BLUETOOTH`, `BLUETOOTH_OFF` (the
monitor resumes by itself when Bluetooth comes back on), `PERMISSION_DENIED`,
`SCAN_FAILED`.

**Threading.** Call `start`, `stop` and `setScanMode` from the main thread. Scan
results are handed straight to a background thread, so a crew of 100 cameras stays
smooth. Use **one monitor per process**, and leave it running: Android throttles apps
that start more than five scans in 30 s.

---

## Camera identity

Besides its status, a camera broadcasts an **identity** about every 10 s and right
after it boots: which model it is, its hardware generation, and its firmware.

```kotlin
val id = cam.identity                     // WirelessIdentity?, null until heard
if (id == null) {
    label = "unknown"                     // older firmware never sends one
} else {
    label = buildString {
        append(id.board.displayName)      // "Pro Mono", "Pro Stereo", "Pro Stereo GS"
        id.fwVersion?.let { append(" · $it") }   // "0.5.9", null if unknown
        if (!id.shipping) append(" · dev")        // development build
    }
}
```

| Member | Description |
|---|---|
| `board` | `WirelessBoard.MONO`, `STEREO`, `STEREO_GS` or `UNKNOWN`. Each has `displayName` ("Pro Stereo GS"), `shortName` ("Stereo GS"), `productName` ("Trinet Pro Stereo GS") and a `shutter` hint (`WirelessShutter.GLOBAL` for Pro Stereo GS, `ROLLING` otherwise). |
| `boardName` | `board.displayName`, or "Unknown (n)" for a model newer than this SDK. |
| `generation` | Hardware generation, e.g. `"v6"`; null if unknown. |
| `fwVersion` | Firmware version, e.g. `"0.5.9"`; null if the camera does not know it. |
| `shipping` | `false` for a development build. |
| `bootNonce` | The camera boot it was sent in. |

The identity can take a few seconds to appear. `cam.identityIsCurrent` is `false`
after the camera restarted and before it re-sent its identity (the firmware may have
changed in between). The identity carries no time and never affects the clock fit or
start/stop detection.

---

## Stored history

With persistence on (the default) the monitor keeps, across app restarts and phone
reboots, everything needed to put recordings on UTC afterwards: for every camera
boot, the least-delayed broadcast of **every** 5 s of camera time; every start and
stop; the takes built from them; minute-by-minute signal; each camera's last
identity; and the phone's own clock pairings (every minute, at each start/stop, when
the phone's time is changed, network time on Android 13+, and the optional internet
time check). It is a small SQLite database in the app's no-backup files directory,
using the framework SQLite — no extra dependencies. History older than 30 days, or
beyond 256 MB, is deleted.

```kotlin
import com.panoculon.trinet.sdk.wireless.WirelessMonitorConfig
import com.panoculon.trinet.sdk.wireless.WirelessPersistence

// Defaults: history on, 30 days / 256 MB, internet time check on.
WirelessCameraMonitor(context)

// Tuned, or off (live state only; monitor.history is then null):
WirelessCameraMonitor(context, WirelessMonitorConfig(persistence = WirelessPersistence(retentionDays = 7)))
WirelessCameraMonitor(context, WirelessMonitorConfig(persistence = WirelessPersistence.Disabled))
```

`WirelessPersistence(enabled, retentionDays, maxBytes, sntpServer, sntpIntervalMs,
fileName)` — set `sntpServer = null` to turn the internet time check off.

Query it through `monitor.history` (a `WirelessHistory`, package
`com.panoculon.trinet.sdk.wireless.log`), or open it without a running monitor with
`WirelessHistory.open(context)`. Queries are `suspend` and run on `Dispatchers.IO`:

```kotlin
val h = monitor.history ?: return

h.units(WirelessTimeRange(fromUtcMillis = since), query = "a1b2")  // cameras heard, newest first
h.unit(unitId); h.kits()
h.takes(unitId, limit = 50, offset = 0)       // newest first, with refined UTC start/stop
h.kitTakes(groupId)                           // members' starts within 2 s = one kit take
h.segments(unitId)                            // clock fit per camera boot ("time sync" quality)
h.sightings(unitId, sinceUtcMillis)           // minute-by-minute reception
h.seenRanges(unitId, sinceUtcMillis)          // when the camera was in range
h.setLabel(unitId, "Left wrist")              // names survive history deletion
h.setKitLabel(groupId, "Alpha rig")
h.stats(); h.estimate(scope)                  // store size; rough size of an export
h.deleteBefore(utcMillis); h.clear()          // names are kept

h.observe { takes(unitId) }                   // Flow that re-runs whenever the history changes
```

`units(query = …)` matches any part of a unit id, a camera or kit name, a 4-digit
kit id, the camera's model ("stereo gs") or firmware version ("0.5.9").

Each `WirelessTake` has `unitId`, `groupId`, `takeNumber`, `bootNonce`,
`startUtcMillis` / `stopUtcMillis` (recomputed from the camera's latest clock fit, so
usually better than what was shown live), `startDeviceMs` / `stopDeviceMs`,
`durationMs`, `stopKind` (`STOPPED`, `ABNORMAL_STOP`, `REBOOT`; null while no stop has
been heard), `endedAbnormally`, `missedEdges`, and `pairing`:

| `pairing` | Meaning |
|---|---|
| `EXACT` | Start and stop were consecutive: both times are exact. |
| `MISSED_EDGES` | Both heard, but other starts/stops were missed in between (out of range). |
| `START_ONLY` | Still recording, or the stop was missed. |
| `STOP_ONLY` | The start happened before logging began, or out of range. |

A camera restart closes an open take as `REBOOT`. `WirelessUnitSummary.identity` holds
each camera's last stored identity (`board`, `hwGeneration`, `fwVersion`, `shipping`).

---

## Exporting, and putting card recordings on UTC

A Trinet camera has no wall clock: the frame timestamps in a card recording's `.vts`
count from the camera's power-on. The monitor's history holds the relation between
each camera's clock and UTC, and exporting it lets the desktop tool stamp every frame.

```kotlin
import com.panoculon.trinet.sdk.wireless.log.WirelessExportScope

withContext(Dispatchers.IO) {                                  // blocking: never on main
    File(dir, "wireless_$stamp.jsonl.gz").outputStream().use { out ->
        val summary = monitor.exportTo(out, WirelessExportScope.ALL, gzip = true)
        // summary.units, .segments, .takes, .bytes …
    }
    File(dir, "takes_$stamp.csv").outputStream().use { out ->
        monitor.history?.exportTakesCsv(out, WirelessExportScope.ALL)   // spreadsheet of takes
    }
}
```

- **Format.** `exportTo` writes the **Trinet wireless status log, format v2**: JSON
  Lines, gzip-compressed unless `gzip = false`. It flushes whatever the monitor still
  holds in memory first, and does not close `out`. `monitor.exportTo` throws
  `IllegalStateException` when persistence is disabled; `WirelessHistory.exportTo`
  works without a running monitor.
- **Scope.** `WirelessExportScope(units, groups, fromUtcMillis, toUtcMillis)` — `null`
  means no restriction. Shorthands: `WirelessExportScope.ALL`,
  `WirelessExportScope.unit(unitId, from, to)`, `WirelessExportScope.kit(groupId, from, to)`.
  A camera boot's clock samples are always exported whole, never clipped to the range,
  so the desktop tool gets every sample.
- **Takes CSV.** `exportTakesCsv(out, scope)`: one row per take with UTC start/stop
  (ISO 8601), duration, how it stopped, pairing and missed edges.
- `exportLog()` (format v1, only the last two minutes of each live fit) is deprecated;
  use `exportTo`.

**Desktop sync tool.** The [Trinet-tools](https://github.com/Panoculon-Labs/Trinet-tools)
repo's `scripts/wireless_utc.py` reads one or more exports plus the camera cards, refits
each camera boot's clock over the whole session, matches every take to its camera boot,
and writes the UTC of the first and last frame — or of every frame — with an
uncertainty and a confidence:

```bash
python scripts/wireless_utc.py wireless_20260928.jsonl.gz --recordings /media/CARD1 /media/CARD2
```

Field workflow: start the monitor **before** the first take, keep the phone within
Bluetooth range (a pocket is fine) for the whole session including a few minutes after
the last take, give the phone a network connection if you can, then export and run the
tool. Exports from several phones can be passed together. In Trinet-tools,
`docs/wireless_utc.md` covers the options and troubleshooting, and
`docs/wireless_log_format.md` is the format specification.

**How the clock fit works.** Each broadcast carries the camera's clock (the same clock
as `.vts` `sof_ts_ns`) and the phone stamps its arrival. Radio latency is never
negative, so the monitor keeps the least-delayed broadcast in every 5 s of camera time
and fits a line through those (offset + clock skew). Typical accuracy is 1–2 ms plus the
phone's minimum Bluetooth latency; `WirelessCamera.fit` and `WirelessHistory.segments`
report the quality.

**Kits.** When cameras are paired into a kit, their broadcast times are on the kit
master's clock, so every camera in the kit reports one shared timeline and one kit take
groups the members' takes. The desktop tool handles the per-camera offsets for you.

---

## Scan modes and background logging

```kotlin
monitor.setScanMode(WirelessScanMode.BALANCED)   // e.g. while no screen shows the cameras
```

| `WirelessScanMode` | Use |
|---|---|
| `LOW_LATENCY` (default) | Continuous scan: every broadcast is heard. For a screen the user is looking at. |
| `BALANCED` | Duty-cycled: hears most broadcasts at a fraction of the power. For background logging. |
| `LOW_POWER` | The system's lowest-power scan; many broadcasts are missed. |

Switching restarts the scan, so switches are applied at most once every 10 s (the
latest request wins). The initial mode can also be set with
`WirelessMonitorConfig(scanMode = …)`.

The scan keeps running with the screen off, but **the SDK starts no service**. To keep
logging while your app is in the background, hold the monitor from a foreground service
of type `connectedDevice`:

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />   <!-- Android 13+: ask at runtime -->

<service android:name=".YourLoggingService" android:exported="false"
    android:foregroundServiceType="connectedDevice" />
```

On Android 14+ call `startForeground` with
`ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE`, with the scan permission already
granted, and start the service while your app is in the foreground.

---

## Limitations

- **The camera has no real-time clock.** UTC comes from the **phone**: the monitor
  maps each camera's clock onto the phone's clock, and the phone's clock onto UTC. A
  phone whose clock is off shifts every time by the same amount; network time and the
  internet time check (both recorded in the export) let the desktop tool correct for it.
- **A clock fit is valid for one camera boot.** A camera restart resets its clock, and
  the broadcast then starts a new fit. For a recording to be placed on UTC, the phone
  must have heard that camera during the **same camera boot** as the recording —
  before, during or shortly after the take. The skew term extrapolates well for
  minutes, less well for hours.
- The phone must be within Bluetooth range; takes whose start or stop happened out of
  range show as `START_ONLY` / `STOP_ONLY` / `MISSED_EDGES`.
- Signal strength is a proximity hint only, never a distance.

---

## Your own scanner

If you run your own Bluetooth scanner, `WirelessAdvert.parse(bytes)` decodes a status
broadcast and `WirelessIdentity.parse(bytes)` an identity broadcast (each rejects the
other's frame type), from the scan record's manufacturer-specific data under
`WirelessAdvert.COMPANY_ID`. `WirelessAdvert.unitIdFromAddress(address)` maps the
advertiser address to the unit id, and
`WirelessAdvert.groupIdFromAddress(address, groupLow)` recovers the full kit id.

---

See also: [API reference](api-reference.md#package-wireless) ·
[Recording](recording.md) · [File formats](file-formats.md).
