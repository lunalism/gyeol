# Gyeol (결) — macOS native video editor

Full scope contract: @docs/gyeol-prd-v0.7.md

The PRD is a **contract, not a wish list**. Section 6 lists what we are
deliberately NOT building. Treat it as binding. If a request would add
something from section 6, say so and stop.

## Current milestone

**M0 — document model.**

Scope is the `GyeolCore` Swift Package only.

- Do NOT create an Xcode project. Do NOT create an app target. No UI.
- Everything must build and pass tests from the command line:
  `swift build` and `swift test`.
- If a step seems to need Xcode, that step does not belong in M0.

## Stack (fixed — never propose alternatives)

Swift · SwiftUI + AppKit (AppKit + Metal for the timeline) ·
AVFoundation (edit engine) · Core Image + Metal (effects) ·
Accelerate/vDSP (signal processing) · WhisperKit (subtitles)

Never propose: C++/Qt, Electron, cross-platform frameworks,
FFmpeg as the primary engine, libraries from Chinese vendors.

## Non-negotiable technical decisions

- **Project timescale is 120000.** Verified: it is the value where
  23.976 / 24 / 25 / 29.97 / 30 / 50 / 59.94 / 60 fps all yield integer
  tick counts per frame. 600600 fails on the NTSC rates. Do not change
  this without redoing the arithmetic.
- **Time is a rational** (`value: Int64`, `timescale: Int32`).
  Never `Double` seconds. Frame-boundary math on doubles accumulates
  error and desyncs preview from export.
- **Do not serialize `CMTime`.** We define our own `RationalTime` and
  convert only at the AVFoundation boundary. The on-disk format must not
  be coupled to a CoreMedia struct.
- **The render path is a pure function of `(document, time)`.**
  No hidden state, no caches consulted at render time that could differ
  between preview and export. This is why PRD section 4 S3 exists.
- **Document model is a value type.** Undo is a snapshot stack.

## How to work

- **One step at a time.** I give one step per message. Do not run ahead
  to later steps, and do not add files I did not ask for.
- Before writing code, state in 3 lines or less what you are about to
  do. Then do it.
- **Actually run `swift build` and `swift test`, and paste the real
  output.** Never claim something works without having run it.
- If an Apple API signature is uncertain, check the SDK or the docs.
  Do not guess. Say "I need to verify this" rather than inventing a
  signature.
- Comment **why**, not what — especially where a trap was avoided.
- If you disagree with an instruction, say so directly before doing it.

## Language

Reply in Korean. Short, no preamble, no summary of what you just did
unless I ask.
