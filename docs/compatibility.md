# Compatibility and verification

| Target | Status |
| --- | --- |
| CMF Watch Pro 2, JX402 / D398, stock 1.0.0.73 | Current ROM port. Loader v4 / Trail Map v10 have hardware history; v5 / v11 pass ARM guest checks and await physical validation. |
| Other firmware on Watch Pro 2 | Unsupported; ROM addresses must be re-derived and verified. |
| Watch Pro, other CMF models, other brands | Unsupported. |
| iOS | Native build, protocol tests, simulator checks; the custom app channel and native map transfer have been verified on an iPhone. |
| Android | APK build, JVM protocol tests and Android emulator UI checks. Physical Android-to-watch verification remains pending. |
| New stopwatch / intervals / counter apps | Unit tests, scripted host simulation and the recorded ARM guest checks. See generated proof scope. |

## Companion features

| Feature | iOS | Android |
| --- | --- | --- |
| Stock pairing/session, clock, battery | Implemented | Implemented |
| Health sync, activity, heart rate, oxygen, stress, sleep | Implemented | Implemented |
| Alarms and favorite contacts | Implemented | Implemented |
| Units, wrist wake, time format, goals, profile, reminders, monitoring | Supported protocol controls | Supported protocol controls |
| Reviewed app installs and loader updates | Implemented | Implemented |
| Native watch region download/resume/readback | Implemented | Implemented |
| Regional phone map/search/saved points | Rich CMFMAP1 reader | Native WP2MAP1 reader |
| Watch GNSS status and phone position fallback | Implemented | Implemented |
| Detailed phone artwork / recent-view cache sync | Implemented | Not yet implemented |
| GPX/GeoJSON point bookmarks and GPX export | Implemented | Implemented |
| Organic Maps location links | Implemented | Implemented |
| Full MWM rendering, watch routing/elevation gain | Not implemented | Not implemented |
| Complete Nothing X replacement: phone notification forwarding, call/music control, watch-face store and all vendor services | Not complete | Not complete |

The stock-based patch leaves stock watch functions in place. That does not mean
every phone-side vendor service has been reproduced by these companions.
Unsupported features are not represented by pretend readings or active toggles.

## Installation properties

The app install path checks the supported stock version, a battery reading less
than two minutes old with at least 30% charge, and a closed Custom Apps view.
The BLE receiver stages and checks an app before replacing its active file.
Apps run native code with access through the SDK; they are not isolated from
one another by a security sandbox.

The first stock application patch is a different operation from app installs.
Physical recovery is not universally verified. Emulator transfer/install proof
cannot guarantee that every physical watch or a different firmware will recover.

The loader's GNSS code preserves the stock listener and releases its receiver
ownership when the app exits. A phone location does not supply a watch satellite
count. Missing GNSS status stays unknown; a lost position can remain last-known.

The [0.1.0 ARM report](verification/0.1.0-arm.json) records the tested package
hashes. It is test evidence, not a substitute for reviewing new code or rerunning
the checks after a change.

Loader v4 has physical hardware history from the stock-based source port. The
release loader normalizes embedded compiler paths; its exact binary hash is
covered by the ARM guest report rather than a new physical installation.

The [0.2.0 ARM report](verification/0.2.0-arm.json) covers loader v5,
Trail Map v11, codec 2 native rendering, swipe/crown input and cold restart
without phone artwork. Its public sample reached 10 ms on the last redraw
and 79 ms on the slowest measured redraw. These are emulator measurements,
not physical-watch frame rates.
