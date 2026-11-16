# Compatibility and verification

| Target | Status |
| --- | --- |
| Watch Pro 2, JX402 / D398, firmware 1.0.0.73 | Supported ROM port. Loader v6 and the three example apps are covered by the ARM report. |
| Other firmware or watch models | Unsupported; ROM addresses and runtime behavior must be re-derived and tested. |
| iOS base companion | Swift protocol tests, native build and simulator UI checks. The existing custom app channel has physical iPhone history; this base revision has not been installed on hardware. |
| Android base companion | JVM protocol tests, signed APK build, release lint and emulator UI checks. Physical Android BLE validation remains pending. |
| Custom watch faces | Production Swift upload, stock ARM activation and natural minute tick verified. Physical face installation remains pending. |

The [0.4.0 ARM report](verification/0.4.0-arm.json) pins the exact loader and
example package hashes, with interrupted/corrupt transfer preservation, same-name
updates, app launch, touch/crown input and button exit. This is emulator evidence;
it is not a physical-watch recovery guarantee.

The public phone UI is a base for connection, device status, custom app packages
and watch faces. It is not a full replacement for Nothing X. Standard settings
and health codecs remain available in the protocol libraries for developers.
Absent readings stay unknown until the watch supplies them.

App installation requires the supported firmware, a battery reading less than
two minutes old at 30% or above, and a closed Custom Apps view. Packages must
match the staged manifest and be confirmed by the watch after transfer.

The first stock patch is a separate operation. It can leave a watch unusable;
physical recovery is not universally verified. Native apps are not isolated
by a security sandbox. Test and review new code before installing it.

Watch-face verification is recorded separately in the
[0.3.0 face report](verification/0.3.0-faces.json). It uses the stock face
manager, without firmware OTA. See [watch faces](watch-faces.md) for supported
formats and limits.
