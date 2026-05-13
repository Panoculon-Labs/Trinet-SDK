# Trinet-SDK release keystore

`trinet-release.jks` is the **signing identity** for every distributed Trinet
Android APK. It is **not in git** — only the file checksum and the alias /
passphrase reference live in the repo.

## Why it matters

Android refuses to upgrade an installed APK if the new APK is signed by a
different key. Once we ship v0.1.x signed with this keystore, every future
release must be signed with the *same* keystore or users have to uninstall and
reinstall to upgrade. Lose this keystore → fleet-wide forced reinstall.

## Where it lives

- **In this checkout**: `keystore/trinet-release.jks` (gitignored)
- **Backup**: keep at least one off-machine copy (1Password file attachment,
  hardware token, sealed cold storage). The credentials below unlock it.

## Credentials

The four values referenced by `app/build.gradle.kts` are read from
`local.properties` (also gitignored):

```
RELEASE_STORE_FILE=keystore/trinet-release.jks
RELEASE_STORE_PASSWORD=<password>
RELEASE_KEY_ALIAS=trinet-release
RELEASE_KEY_PASSWORD=<password>
```

Both passwords are the same and live in the maintainer's password manager.
Anyone who needs to ship a release build needs:
1. A copy of `keystore/trinet-release.jks` placed at the path above.
2. The four values added to their `local.properties`.

## Building a signed release APK

```
./gradlew :app:assembleRelease
# → app/build/outputs/apk/release/app-release.apk (signed)
```

If `local.properties` is missing the release values, the build still produces
an APK but it falls back to debug-signing — fine for development, **not for
distribution**. The Gradle output prints which signing path was used.

## Verifying a built APK is properly release-signed

```
$ANDROID_SDK/build-tools/<ver>/apksigner verify --print-certs path/to/app.apk
# Should print:
#   Subject: CN=Trinet Camera, OU=Trinet, O=Panoculon Labs, ...
```

If you see `Subject: CN=Android Debug` instead, the build fell back to debug.

## Rotation

If the keystore is suspected to be compromised, all bets are off — every
already-installed user needs to uninstall and reinstall under the new key.
There is no graceful recovery. Treat this file like an SSH private key.
