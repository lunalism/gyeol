# M1 Bundle Inventory — D6 premise check

**Headline: NO — the Release bundle contains no nested binaries that would
each require signing.** WhisperKit resolves as a STATIC library and links
into the single main executable. No frameworks, no dylibs, no `.mlmodelc` /
`.mlpackage`, no resource bundles land in the app.

Measured with Xcode 26.6 (17F113) on macOS 26.5.2. Targets: `Gyeol` (links
product `WhisperKit` from `argmaxinc/argmax-oss-swift` v1.0.0, no API
calls) and `GyeolBare` (identical minus WhisperKit). Signing disabled
(`CODE_SIGNING_ALLOWED=NO`) — irrelevant to what lands in the bundle.

## Inventory

| bundle | total size | Mach-O binaries inside |
|---|---|---|
| Gyeol.app (Release) | 3.2 MB | `Contents/MacOS/Gyeol` only |
| GyeolBare.app (Release) | 608 KB | `Contents/MacOS/GyeolBare` only |
| Gyeol.app (Debug) | 5.1 MB | main + `Gyeol.debug.dylib` + `__preview.dylib` |
| GyeolBare.app (Debug) | 868 KB | main + `GyeolBare.debug.dylib` + `__preview.dylib` |

- `.mlmodelc` / `.mlpackage`: none in any configuration. WhisperKit does
  not bundle CoreML models — it downloads them at runtime (the 600 MB-class
  cost in PRD D4 is a runtime download, not app download size).
- Resource bundles: none. The two `resources: [.process("Resources")]`
  blocks in the package manifest belong to *test* targets
  (WhisperKitTests, SpeakerKitTests), so nothing propagates to the app.

## Linkage

- `otool -L` on the Release executable lists only `/System/...` frameworks
  and `/usr/lib/...` dylibs (OS-provided, never bundled). Notable pulls
  from WhisperKit: CoreML, AVFAudio, NaturalLanguage, Network, CryptoKit.
- `nm` finds 5,753 WhisperKit-mangled symbols inside the Release
  executable — the static link is real, not dead-stripped.
- Debug's extra dylibs (`*.debug.dylib`, `__preview.dylib`) are Xcode's
  debug-dylib/previews mechanism operating on the app's own code. They are
  absent in Release, which is the configuration that gets notarized.

## Debug vs Release difference

Debug adds the two debug-support dylibs; Release strips to a single
executable. WhisperKit's linkage (static) is identical in both.

## Size delta (feeds D4)

Release with WhisperKit 3.2 MB vs 608 KB without → **~2.6 MB of code**.
App download size is unaffected by model size; D4's model-size decision is
purely about the runtime download UX.

## Consequence for D6

The M1 notarization round trip, when the Developer ID certificate is
available, will sign exactly one Mach-O. **It will NOT exercise
nested-binary signing, because this configuration produces none.** D6's
target risk ("every nested binary must be signed individually, failure
messages unhelpful") does not exist in the current dependency graph. This
must be recorded in the PRD rather than treated as a pass: if M3 or later
adds a dynamically-linked dependency, a binary xcframework, or pre-bundled
CoreML models, the nested-binary signing risk returns and the round trip
must be repeated then.

## Not determined

- Actual notarization behavior (blocked: no Developer ID Application
  certificate on this machine — only Apple Development).
- Whether calling WhisperKit APIs in M3 changes what lands in the bundle
  (it should not — linkage is decided at build, not call time — but M3
  should re-run this inventory after real integration).
