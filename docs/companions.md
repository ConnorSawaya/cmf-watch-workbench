# Build the phone companions

Generate the optional public map example first:

```sh
./tools/build_demo.sh
```

For a companion containing the published, tested loader and apps, download the
five `.wp2app` release assets into `firmware/wp2-apps/target/`. With GitHub CLI:

```sh
mkdir -p firmware/wp2-apps/target
gh release download v0.2.0 --repo ConnorSawaya/cmf-watch-workbench \
  --pattern '*.wp2app' --dir firmware/wp2-apps/target
python3 tools/stage_packages.py --proof docs/verification/0.2.0-arm.json
```

Staging verifies each exact package hash and its checksums, then copies the
source-built files and their records into both local companion resource folders.
It does not bundle or install a stock firmware image.

For changed app code, build with `./tools/build_apps.sh`, rerun the
[ARM guest verification](testing.md), then stage with
`--proof build/arm-proof/report.json`. A different build cannot reuse the
published hashes. Without staged packages the companions still build, but
app installation requires a matching test manifest.

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

Both companions include a [watch-face editor and importer](watch-faces.md).
Face upload uses the stock protocol and does not depend on staged app packages.
