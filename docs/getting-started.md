# Install and build

## 1. Check compatibility

Use a **CMF Watch Pro 2, board JX402 / model D398**, with stock firmware
**1.0.0.73**. Read the version on the watch itself. The ROM addresses in this
port do not apply to another firmware version, Watch Pro, Watch 3 or another
brand. Stop before patching if the model/version does not match.

The first installation modifies the stock application. It can leave a physical
watch unusable; physical recovery is not universally verified. Later `.wp2app`
installs use separate app slots and do not repeat that stock firmware flash.

## 2. Prepare the tools

Install Git, Python 3.12+, `uv`, Rust with the `thumbv7em-none-eabi` target,
`llvm-tools` / `llvm-objcopy`, and `resvg`. For a Nix environment the existing
SDK scripts can use `nix-shell -p llvm resvg`. iOS requires macOS, Xcode and
XcodeGen; Android requires JDK 21 and Android SDK 36.

```sh
git clone https://github.com/ConnorSawaya/cmf-watch-workbench.git
cd cmf-watch-workbench
rustup target add thumbv7em-none-eabi
rustup component add llvm-tools
uv sync
./tools/build_demo.sh
```

The demo downloads the public historical Monaco extract identified in
`examples/source.json`. It generates local assets; it is not a current trail
navigation dataset. Use a current extract for an area you intend to navigate.

Obtain the emulator/tool checkout separately, following its own setup guide:

```sh
git clone https://github.com/freethinkel/cmf-watch-utils firmware/cmf-watch-utils
export CMF_WATCH_UTILS="$PWD/firmware/cmf-watch-utils"
```

Set up that project's runtime, fixtures and your matching stock firmware as
described upstream. The SDK's Python dependencies are pinned in its `uv.lock`.
Use an emulator stock NOR with synthetic pairing data when testing.

## 3. Build the stock stub and loader

```sh
cd firmware/wp2-apps
WP2_LOADER_VERSION=4 scripts/build-fw
# Keep stock vibration options when producing your initial app patch:
uv run --locked wp2apps firmware --stub target/wp2-stub.bin \
  --weak 0 --output target/app-loader.bin
uv run --locked wp2apps ota-image --app target/app-loader.bin \
  --version-code 0x10003 --output target/initial-loader-ota.bin
```

The patcher checks the reference stock application. It preserves the stock OTA
container and resource partitions. The ROM port and that fingerprint check are
both required; changing a version string is not a port to another watch.

The generated OTA contains vendor material and stays local. Keep the original
matching firmware and your backups. Do not substitute an unrelated OTA file.

## 4. Verify the initial update in the emulator

Follow [the SDK OTA procedure](../firmware/wp2-apps/docs/ota.md) to test the
temporary OTA form, then boot its resulting NOR and install the loader. This
exercises the stock pull-based transfer, INIT2 acknowledgement, image checking
and mandatory end acknowledgement. The emulator's install model does not prove
a physical bootloader recovery path.

Build the app packages with `tools/build_apps.sh` from the repository root.
The [verification guide](testing.md) includes the disposable ARM-guest checks.

## 5. First physical OTA

Only proceed with the exact matching model/version and the image you just
validated. Charge the watch, keep the connection stable, and prevent another
phone client from rebinding during OTA. Use the stock OTA client supplied by
your configured `cmf-watch-utils` checkout; run its `--help` for the installed
version's device and image arguments. Pair freshly if its saved auth key is
stale. Transfer completion requires the watch's image-valid response **and**
the final `0x9041 A5` end acknowledgement.

Do not interrupt a physical update based only on bytes-sent or a percentage.
Wait for the watch to finish and reboot. Check its stock clock/settings first,
then confirm the custom channel and package listing. The stock version still
reads `1.0.0.73`; the custom stub/loader versions are queried separately.

## 6. Install the loader and apps

With the patched watch at its clock face and Custom Apps closed:

```sh
cd firmware/wp2-apps
uv run --locked wp2apps scan
# Use the identifier returned by that scan:
uv run --locked wp2apps install target/loader.wp2app --address "$WATCH_ADDRESS"
uv run --locked wp2apps install target/trail-map.wp2app --address "$WATCH_ADDRESS"
uv run --locked wp2apps list --address "$WATCH_ADDRESS"
```

`WATCH_ADDRESS` is an environment variable you set to your scan result. On
macOS the identifier is a CoreBluetooth UUID. Do not paste identifiers or
pairing output into an issue report.

The stock app list must use **list style**. Open **Custom Apps**, then tap an
installed app. Swipe to pan Trail Map and turn the crown to zoom. Keep Trail
Map open for map downloads; close Custom Apps before installing app code.

Alternatively, build a companion with the reviewed packages and use its app
manager. [Companion build instructions](companions.md).
