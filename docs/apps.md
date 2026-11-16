# Write a watch app

The detailed API reference and examples are in the retained
[SDK app guide](../firmware/wp2-apps/docs/app-guide.md). This workbench adds
native offline-map and GNSS services plus three small tool apps.

## Start from a working example

```sh
cd firmware/wp2-apps
cp -R sdk/examples/counter sdk/examples/my-tool
```

Rename the crate and binary in `Cargo.toml`, add the new crate to the members
in `sdk/Cargo.toml`, and replace the entry point's logic. `stopwatch`,
`intervals` and `counter` share a small toolkit in `sdk/cmf-workbench-tools`;
your app can depend directly on `cmf-wp2-app` instead.

Apps are `no_std` Rust binaries. `entry!` supplies the loader entry point;
`app_icon!` embeds the SVG-derived menu icon. Build with `scripts/build-app`,
which renders the icon and packs relocations correctly.

```sh
scripts/build-app my-tool 1
uv run --locked wp2apps info target/my-tool.wp2app
scripts/sim my-tool
```

Keep hardware-independent state transitions in ordinary Rust code and test
them on the host. Handle `PAUSE`, `RESUME` and `BUTTON`; stop motors and release
screen wake ownership when leaving. Use `api.event(timeout)` instead of a busy
loop. Save on changes with coalescing, not every frame.

## Budgets and device access

| Resource | Current bound |
| --- | --- |
| App image | 128 KiB |
| Loader image | 64 KiB |
| Installed app slots | 8 |
| App message | 128 bytes |
| Screen | 466 × 466 RGB565, circular display |
| Recent detailed map images | 8 bounded, replaceable cache entries |
| Named watch map places | 32 |
| Native offline map | At most 9.2 MB, also subject to actual free NAND |

The SDK table supports graphics, touch/crown/button events, clock, battery,
bounded vibration, app messages, atomic app storage, display wake ownership,
stock widget commands and the services implemented by this loader. It is not
a general Wear OS runtime or an app security sandbox. New direct ROM calls
need a matching firmware port and emulator proof.

## Review and stage a package

1. Run the crate's unit tests and scripted host-simulator input.
2. Build the ARM package and check its image/relocation budgets.
3. Run the ARM guest install/input/exit checks in `tools/verify_arm_apps.py`.
4. Run `tools/stage_packages.py --proof build/arm-proof/report.json`.
5. Rebuild the companion. It only accepts packages matching its staged
   name, kind, version, byte length and SHA-256 record.

The same-name update reuses its app slot and preserves that app's stored blob.
You are responsible for migrating your storage format. Truncated or corrupt
package transfers cannot activate a replacement. Installing an app does not
make arbitrary firmware images compatible with the watch.

Android source uses google-java-format 1.28.0. Keep user-visible strings and
unsupported-feature states clear, and leave absent device readings empty.
