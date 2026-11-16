# Build the base companions

The public companions provide connection, pairing, device status, app package
management and watch faces. Add your own screens alongside those features;
keep protocol handling in `CompanionCore` or the Android `protocol` module.

## Stage reviewed packages

Download the four tested packages and stage their exact hashes:

```sh
mkdir -p firmware/wp2-apps/target
gh release download v0.4.0 --repo ConnorSawaya/cmf-watch-workbench \
  --pattern '*.wp2app' --dir firmware/wp2-apps/target
python3 tools/stage_packages.py --proof docs/verification/0.4.0-arm.json
```

For your own app, build with `tools/build_apps.sh`, add meaningful runtime
checks to `tools/verify_arm_apps.py`, then stage using the resulting
`build/arm-proof/report.json`. Rebuild the companion after staging. An app
must match the manifest's name, kind, version, size and SHA-256 before installation.

The apps also build without staged packages; the Examples section explains
how to add them. No firmware image is bundled.

## iOS

Use macOS, Xcode 16+ with a recent Swift toolchain, and XcodeGen:

```sh
swift test --package-path ios/CompanionCore
xcodegen generate --spec ios/Workbench/project.yml
xcodebuild -project ios/Workbench/CMFWorkbench.xcodeproj \
  -scheme CMFWorkbench -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO
```

For an iPhone, open the generated project, set your signing team and a unique
bundle identifier, then run on the device. The source project supplies neither
a signing identity nor a device identifier. Allow Bluetooth; the QR scanner
uses the camera only when opened. The public app does not request location.

The three tabs are **Apps**, **Faces** and **Watch**. Add a screen and send
app-defined payloads through the SDK's message channel when extending the app.
Bluetooth pairing alone does not install the initial stock loader patch;
follow [getting started](getting-started.md) for that separate operation.

## Android

Use JDK 21, Android SDK 36 and an Android 8 / API 26 or newer device:

```sh
./android/gradlew -p android :protocol:test :app:assembleDebug :app:lintRelease
```

The development APK is `android/app/build/outputs/apk/debug/app-debug.apk`.
Grant Nearby devices permission to scan/connect. Android 8–11 use location
permission for Bluetooth scanning only; the app does not collect position data.
Choose a scan result explicitly. A QR image or link can identify the watch's
name suffix. Pairing keys are protected by Android Keystore; backups are disabled.

**Watch** shows connection and device status. **Apps** manages reviewed packages.
**Device** provides reset pairing, clock sync and battery reads. Watch faces
are available from Watch or Device.

## Signed releases

The published Android APK uses a dedicated signing identity. Future updates
use that same identity. CI debug APKs use a separate development signature.

To build your own signed APK, keep a keystore and private JSON configuration
outside the checkout. The JSON keys are `keystore`, `store_password`, `alias`
and `key_password`. Then run:

```sh
python3 tools/build_android_release.py --signing-config "$SIGNING_CONFIG"
```

Signing credentials are passed through the local build environment. iOS
signing is configured separately in Xcode.
