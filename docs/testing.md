# Verification

## Host checks

```sh
./tools/build_demo.sh
cd firmware/wp2-apps
host=$(rustc -vV | sed -n 's/^host: //p')
(cd sdk && cargo test --target "$host")
(cd fw && cargo test -p wp2-core --target "$host")
uv run --locked python -m unittest discover -s tests -v
cd ../..
swift test --package-path ios/CompanionCore
(cd android && ./gradlew :protocol:test :app:assembleDebug)
```

Swift tests include malformed/corrupt package checks, stock session pairing,
feature codecs, map/saved-place transfers and synchronization guards. Java
tests use the same known crypto/frame vectors, fragmented pairing replies,
read/write endianness, invalid readings and resumable map readback. Both map
readers open the real output produced by the Python demo converter.

Scripted watch runs test timing, input, pause/resume, wake release and persistent
counter state. Screenshots in the gallery come from these runs, not a separate
imaginary watch interface.

## Disposable ARM guest

The public runner accepts reference resources explicitly; none are distributed:

```sh
uv run --project firmware/wp2-apps --locked python tools/verify_arm_apps.py \
  --stock-nor "$STOCK_NOR" --patched-app "$PATCHED_APP" \
  --qemu "$QEMU" --rom "$COMPAT_ROM" --fixtures "$FIXTURES" \
  --netsimd "$NETSIMD"
```

Use an emulator fixture with synthetic pairing data. This runner only uses a
local HCI socket and a disposable guest. It checks package install/readback,
interrupted/corrupt transfer preservation, app launch, touch/crown input and
button exit. The current debug-call helper uses macOS LLDB; the upstream SDK
also supplies GDB-based tests for other configured hosts.

`build/arm-proof/report.json` pins the exact successful package hashes. Staging
refuses a different artifact even when its name/version matches. Rebuilds after
source changes need new proof. Simulator frame time is not a physical FPS claim.

CI builds/tests source and the public map example. Physical BLE, stock OTA and
recovery checks remain explicit hardware work, never a scheduled CI action.

The [0.1.0 ARM report](verification/0.1.0-arm.json) records the tested package
hashes. It is test evidence, not a substitute for reviewing new code or rerunning
the checks after a change.
