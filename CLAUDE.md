# Gyeol (결) — macOS native video editor

## The PRD is the only contract

Canonical: `docs/PRD.md`.
That file and nothing else.
`docs/archive/` holds superseded versions, never read them.
The version number lives in the document's first line, not in the filename.

**Do not restate PRD rules in this file.**
This file points, the PRD decides.
If a rule appears in both and they disagree, the PRD wins and this file is the bug.

Section 6 lists what we deliberately do NOT build.
Treat it as binding.
If a request would add something from section 6, say so and stop.

## Current milestone

**M1 — playback.**
Five steps, in this order:

1. ~~CMTime boundary adapter~~ — done (`Sources/GyeolCore/CMTimeAdapter.swift`)
2. **Media open → preview playback → frame stepping** ← current
3. NSDocument adapter + bookmark sidecar + deletion test (D18)
4. Custom compositor prototype + L2 skeleton
5. ~~Notarization round trip~~ — done

`Gyeol.app` exists (xcodegen, `project.yml`).
GyeolCore stays free of NSDocument and FileWrapper, PRD 5.6.5.

`app/Gyeol.xcodeproj` is generated, not committed.
Run `xcodegen generate` in `app/` after cloning, and again whenever
`project.yml` changes.

## Before writing code

Read the PRD sections that govern the task.
For M1 that is at minimum: 4.1 (three-layer S3 verification), 5.6.1 (time and
the CMTime adapter), 5.6.5 (module boundary), 7.4 (architecture principles,
**all 8**, violating one means the PR is rejected).

Measurement reports live in `docs/m1-*.md`.
They record what AVFoundation actually did on this machine, not what it should do.
**Prefer them over reasoning from first principles.**

**If a PRD section referenced in a prompt does not exist in `docs/PRD.md`, stop
and report it before writing any code.**
Do not implement from the prompt alone.
A missing section means the PRD and this repo have diverged, and that has
already happened once.

## Stack (fixed — never propose alternatives)

Swift · SwiftUI + AppKit (AppKit + Metal for timeline and preview) ·
AVFoundation (edit engine) · Core Image + Metal (effects) ·
Accelerate/vDSP (signal processing) · WhisperKit (subtitles)

Never propose: C++/Qt, Electron, cross-platform frameworks, FFmpeg as the
primary engine, libraries from Chinese vendors.

Minimum target macOS 26, Apple Silicon only.

## How to work

- **One step at a time.**
  I give one step per message.
  Do not run ahead to later steps, and do not add files I did not ask for.
- Before writing code, state in 3 lines or less what you are about to do.
  Then do it.
- **Actually run `swift build` and `swift test`, and paste the real output.**
  Never claim something works without having run it.
- If an Apple API signature is uncertain, check the SDK or the docs.
  Do not guess.
  Say "I need to verify this" rather than inventing a signature.
- Comment **why**, not what, especially where a trap was avoided.
- **If you disagree with an instruction, say so directly before doing it.**
  This is load-bearing, not politeness.
  The frame-grid snap decision in the CMTime adapter was right and the PRD was wrong.
  That only surfaced because it was raised.
- Report what you could not verify.
  A known gap is useful, a plausible guess is not.

## Language

Reply in Korean.
Short, no preamble, no summary of what you just did unless I ask.