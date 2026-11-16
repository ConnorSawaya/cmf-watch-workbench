# Build the phone companions

Generate the public example if you want an offline map on first launch:

```sh
./tools/build_demo.sh
./tools/build_apps.sh
# After the emulator checks:
uv run python tools/stage_packages.py --proof build/arm-proof/report.json
```

The staging step checks exact package hashes against the test report, then
copies only source-built `.wp2app` files and their records into the local app
resources. It does not bundle a stock firmware image. Without staged packages,
the companion can still build and show its disconnected/import screens.

## Android

Use JDK 21 and Android SDK 36. Point `ANDROID_HOME` at your SDK, or create your
own ignored `android/local.properties` containing `sdk.dir=...`.

```sh
cd android
./gradlew :protocol:test :app:assembleDebug
```

The local development APK is at
`app/build/outputs/apk/debug/app-debug.apk`. The protocol module is plain Java
and tests without a phone. The app requires Android 8 / API 26 or newer.

Grant Nearby devices permission to scan/connect. Location permission is only
requested when using phone location (and for legacy Android BLE scanning).
Scan results are chosen explicitly; QR image/link input helps identify the
matching watch. Standard controls need a valid stock pairing/session, separate
from the custom loader channel. Pairing keys are protected with Android Keystore;
app backups are disabled. Actual device readings are not synthesized.

Keep Trail Map open on the watch for a native-map transfer. Android's connected
device foreground service supports the BLE connection; the visible app reports
progress and prevents its own idle screen timeout during an operation.

## Signed Android releases

The GitHub release APK uses a dedicated signing identity. Future releases must
use the same identity to update an installed copy. CI debug artifacts have
separate development signing and are not interchangeable with that release.

To publish your own build, create a keystore and a private JSON file outside
this checkout with `keystore`, `store_password`, `alias` and `key_password`.
Keep a secure backup of the key. Run:

```sh
python3 tools/build_android_release.py --signing-config "$SIGNING_CONFIG"
```

The script passes credentials through the build environment. The output is
`android/app/build/outputs/apk/release/app-release.apk`. iOS signing is separate.

## iOS

Use Xcode 16+ with a recent Swift toolchain, and XcodeGen. Set your own unique
bundle identifier/signing team if needed.

```sh
xcodegen generate --spec ios/TrailCompanion/project.yml
xcodebuild -project ios/TrailCompanion/TrailCompanion.xcodeproj \
  -scheme TrailCompanion -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO
swift test --package-path ios/CompanionCore
```

For a physical iPhone, open the generated project in Xcode, select your signing
team and device, and run. No signing identity or device identifier is supplied
by the project. Allow Bluetooth and, if wanted, location. Use Watch apps for
reviewed package installs and map imports/downloads. The first stock patch is
prepared separately as described in [getting started](getting-started.md).
