# Gyeol (결)

A macOS-native video editor: automatic subtitles, everything local,
nothing uploaded.

> Development setup notes only. The v1 project README (license,
> trademark, disclosures) comes later — see docs/PRD.md §8.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon only
- Xcode 26 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — app target only

## Build

GyeolCore (the document model and all pure logic) is a Swift package:

```sh
swift build
swift test
```

## App target

`app/Gyeol.xcodeproj` is generated, not committed. After cloning — and
again whenever `app/project.yml` changes — run:

```sh
cd app && xcodegen generate
```

Then build the `Gyeol` scheme from the generated project.

## Contract

The scope contract is `docs/PRD.md`. It exists to refuse features;
read it before proposing one.
