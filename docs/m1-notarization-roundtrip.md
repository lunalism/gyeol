# M1 Notarization Round Trip

Executed 2026-07-24 on macOS 26.5.2, Xcode 26.6 (17F113), team T394S9X9HC,
keychain profile `gyeol-notary`. Subject: Release `Gyeol.app` (single
Mach-O; WhisperKit statically linked — see `m1-bundle-inventory.md`).

## Result

**Accepted end-to-end on the first attempt. Zero failures, zero
entitlements.** Signing → app notarization → app staple → dmg →
dmg notarization → dmg staple → Gatekeeper acceptance → launch under
hardened runtime, including a quarantined copy.

## What this did and did not prove (for the PRD)

- **This round trip did NOT exercise nested-binary signing.** The bundle
  contains no nested binaries (WhisperKit resolves statically; models are
  runtime downloads). D6's original target — per-binary inside-out signing
  of frameworks/dylibs/mlmodelc and its unhelpful failure messages — was
  not and could not be verified here. It returns the moment a dynamic
  dependency, binary xcframework, or pre-bundled model appears; repeat the
  round trip then.
- **Hardened Runtime × WhisperKit's runtime-downloaded CoreML models is
  UNVERIFIED and moves to M3.** No WhisperKit API ran. Model download,
  on-disk model compilation (`MLModel.compileModel`), and ANE execution
  under hardened runtime are all untested.

## Timings

| submission | wall clock (`--wait`, incl. upload) | status |
|---|---|---|
| Gyeol.zip (app, 3.2 MB) | 25.3 s | Accepted |
| Gyeol.dmg | 23.2 s | Accepted |

Small payloads; expect upload time to dominate as the app grows.

## Failures encountered

None. Recorded explicitly so a future failure is known to be a regression,
not a flaky baseline: signing with `--options runtime --timestamp` and no
entitlements file, submitting via keychain profile, and stapling both
artifacts worked exactly as documented.

## Entitlements

None required. A blank SwiftUI window with GyeolCore + statically linked
(uncalled) WhisperKit signs, notarizes, and launches under hardened
runtime with an empty entitlement set. Add entitlements only when a
capability actually fails at launch (likely candidates for later
milestones: none known yet; JavaScriptCore JIT would need one in v2).

## Was stapling the .app (not just the .dmg) necessary?

Gatekeeper acceptance while online: no — the ticket is discoverable from
Apple's servers for any notarized cdhash. But an app copied out of the dmg
carries no ticket of its own unless the app was stapled BEFORE the dmg was
built; offline first-launch then depends on the app-level staple. So the
sequence used here (and recommended): **notarize the app, staple the app,
then build the dmg from the stapled app, notarize the dmg, staple the
dmg.** `stapler validate` confirmed the extracted app still carries its
ticket. Stapling the app after building the dmg would leave dmg contents
unstapled (the dmg is immutable), and rebuilding the dmg afterwards would
produce a new, un-notarized dmg.

## Verification transcript

- `spctl -a -vvv -t install Gyeol.dmg` → `accepted`, `source=Notarized Developer ID`
- `spctl -a -vvv -t exec extracted-Gyeol.app` → `accepted`, `source=Notarized Developer ID`
- `codesign -vvv --strict` → `valid on disk`, `satisfies its Designated Requirement`
- `codesign -dvv` → `flags=0x10000(runtime)` (hardened runtime active), full
  Developer ID chain, secure timestamp
- Launch (no quarantine): process ran; hardened runtime caused no launch failure
- Quarantine simulation: synthetic `com.apple.quarantine` attribute
  attached to a fresh copy; `gktool scan` → "would be allowed but the user
  still needs to approve it on first launch"; `open` then launched the
  process successfully

## Not verified

- **A real download on a machine that never built the app.** The
  quarantine attribute here was synthetic; the first-launch approval
  dialog (which `gktool` predicts) was not observed interactively in this
  headless session, and a hand-written quarantine string is an
  approximation of what a browser writes. Do one real-download check
  before the first public release.
- Notarization behavior with nested binaries (none exist yet — see above).
- Hardened runtime with WhisperKit actually running (M3).

## Release-time checklist

Prereqs: Developer ID Application certificate in the keychain; notarytool
keychain profile (`xcrun notarytool store-credentials`), here named
`gyeol-notary`.

1. Build Release: `xcodebuild -project app/Gyeol.xcodeproj -scheme Gyeol -configuration Release build`
   (CI: sign in-build instead of post-hoc once a real release pipeline exists).
2. Sign inside-out. Today there is only the bundle itself; when nested code
   appears, sign the deepest items first, NEVER `codesign --deep`:
   `codesign --sign "Developer ID Application: BYUNGJIN CHOI (T394S9X9HC)" --options runtime --timestamp Gyeol.app`
3. Verify locally: `codesign -vvv --strict Gyeol.app` and check
   `codesign -dvv` shows `flags=0x10000(runtime)`.
4. Zip and notarize the app:
   `ditto -c -k --keepParent Gyeol.app Gyeol.zip`
   `xcrun notarytool submit Gyeol.zip --keychain-profile "gyeol-notary" --wait`
   On failure: `xcrun notarytool log <submission-id> --keychain-profile "gyeol-notary"`.
5. Staple the app: `xcrun stapler staple Gyeol.app` (before the dmg — order matters).
6. Build the dmg from the stapled app:
   `hdiutil create -volname "Gyeol" -srcfolder <folder-with-app> -ov -format UDZO Gyeol.dmg`
7. Sign the dmg: `codesign --sign "Developer ID Application: …" --timestamp Gyeol.dmg`
8. Notarize the dmg: `xcrun notarytool submit Gyeol.dmg --keychain-profile "gyeol-notary" --wait`
9. Staple the dmg: `xcrun stapler staple Gyeol.dmg`
10. Verify: `spctl -a -vvv -t install Gyeol.dmg`; mount, copy the app out,
    `spctl -a -vvv -t exec` + `stapler validate` on the copy; launch it.
11. Before first public release only: download the dmg on a second machine
    via a browser and confirm the first-launch flow.
