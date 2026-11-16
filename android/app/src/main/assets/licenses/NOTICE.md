# Third-party notices

- The stock stub, app loader, Rust SDK, host simulator, BLE installer and WireKit
  are derived from `cmf-tech-community/wp2-apps` (now `cmf-watch-sdk`), base
  revision `630ab1f51242d709cc93eb4961a5de0d8bf46d34`.
  Copyright 2026 Egor Kolesnikov. The complete MIT notice is in
  `firmware/wp2-apps/LICENSE`.
- `WatchBLE.swift` adapts that SDK's MIT-licensed iOS BLE transport. The stock
  protocol codecs are independently written, using the public protocol facts
  linked in `ios/Workbench/THIRD_PARTY.md`.
- The independently written WFDL codecs and face uploaders use public protocol
  facts from [FMC](https://github.com/freethinkel/fmc/blob/main/docs/cmf-protocol.md)
  and [CMF Watch Pro 2 BLE research](https://github.com/joshuapassos/CMF-Watch-Pro-2-BLE-Protocol).
  These projects' implementation code is not included.
- Roboto Regular is from Google's `roboto-2` project, under Apache 2.0. Font
  source, license and notice are in `assets/fonts`. Generated coverage tables
  preserve that attribution.
- `cmf-watch-utils` and `cmf-watch-fwkit` are external build/emulator tools under
  their own licenses. Their implementation and vendor binaries are not part
  of this source distribution.
- Android uses ZXing Core (Apache 2.0) to decode user-selected QR images and
  Gradle/Android build tooling under their respective upstream licenses.

CMF and Nothing are trademarks of their respective owners. This is an
independent community development project.
