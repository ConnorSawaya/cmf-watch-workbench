The Bluetooth app channel, loader and package format use
https://github.com/cmf-tech-community/wp2-apps at
630ab1f51242d709cc93eb4961a5de0d8bf46d34 (MIT).
The complete upstream license is retained in firmware/wp2-apps/LICENSE.
WatchBLE.swift adapts that project's iOS/Workout/BLE.swift.
WireKit is linked as a local Swift package; FrameParser adds malformed-length validation.
StockConnection.swift implements the documented stock Bluetooth protocol and is tested with a synthetic peer.

cmf-watch-utils at 8252c34d7a3e332338b4bd66b451afec942d92f2 (AGPL-3.0)
is used as a separate build/validation tool, not copied into the iOS app.
The generated initial OTA contains vendor firmware/resources; it is a local artifact,
not part of the source distribution. Map data has its own attribution in README.md.

Standard settings and health packet facts were cross-checked with
https://github.com/joshuapassos/CMF-Watch-Pro-2-BLE-Protocol and the documented
CMF wire protocol. The codecs are independently written Swift; no Gadgetbridge
or AGPL implementation source is included. Reminder endianness is checked
against the ARM firmware's own readback, which supersedes conflicting notes.
