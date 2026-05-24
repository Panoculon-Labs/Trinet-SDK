# Trinet SDK for Android

Kotlin SDK for capturing video and per-frame inertial data from **Trinet cameras**
over USB on Android — UVC streaming, IMU/recording sidecar parsing, and playback.

The Trinet camera is a wearable, synchronized video + inertial-measurement device for
**egocentric (first-person) data collection** in visual-inertial SLAM, camera–IMU
calibration, and dead-reckoning research. The SDK wraps the USB transport, sensor
parsing, recording, and playback so app developers don't have to.

This repository distributes the **prebuilt SDK (AAR)** and documentation. The demo
app is published as installable APKs under [**Releases**](../../releases).

## Install

The AAR is in [`aar/`](aar/). Add it as a local dependency:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        flatDir { dirs("aar") }            // or an absolute path to the .aar
    }
}

// app/build.gradle.kts
dependencies {
    implementation(":trinet-sdk-0.1.0@aar")

    // Transitive runtime dependencies the SDK expects on the classpath
    // (a flat AAR carries no POM, so declare them explicitly):
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation(platform("androidx.compose:compose-bom:2024.10.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
}
```

Requires `minSdk 28`. The AAR bundles native libraries for `arm64-v8a`,
`armeabi-v7a`, and `x86_64`.

## Usage

```kotlin
// Discover + open a connected Trinet camera, stream UVC frames, read IMU/pose
// sidecars, and play back recordings. See the demo app (Releases) for a full example.
val devices = DeviceDiscovery.listTrinetDevices(context)
```

## Demo app

Prebuilt demo APKs are attached to each [GitHub Release](../../releases).

## License

See [LICENSE](LICENSE).
