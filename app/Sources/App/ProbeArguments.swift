import Foundation
import GyeolCore

/// STRICT parsing of the diagnostic probes' command line (부록 A-43 ②,
/// closed before M2.4).
///
/// WHAT WAS WRONG. Every reader used to be `firstIndex(of:)` +
/// `compactMap` + `?? default`, so:
/// - `--playhead-probe --playhead-offset 12 doc.gyeol` took
///   `"--playhead-offset"` as the document path (that one raised an alert,
///   so it was noticed), and
/// - a mistyped offset list fell back to `[0]` and produced NO visible
///   sign at all. A human session run that way looks entirely normal for
///   its whole duration and ends in "not detectable" — and the only record
///   of a human session is a sheet of paper, so there is nothing to go
///   back and check.
///
/// THE RULE (§4 rule 6 — a read failure is neither a pass nor a fail):
/// **no probe argument has a fallback.** Anything malformed or ambiguous
/// prints what was wrong and which argument caused it, then exits 2
/// (UNVERIFIED, the same code `--menu-probe` uses for "could not read")
/// without opening a document or playing anything.
///
/// An ABSENT optional flag still has a documented default — nothing was
/// supplied, so nothing was silently replaced — and every default in force
/// is printed with the results.
///
/// When no probe flag appears at all this type returns `.notAProbe` before
/// looking at anything else: the normal launch path is not in scope and
/// must not start refusing arguments.
enum ProbeArguments {
    enum Mode: String, CaseIterable {
        case g5 = "--g5-probe"
        case menu = "--menu-probe"
        case churn = "--churn-probe"
        case playhead = "--playhead-probe"
        case timeline = "--timeline-probe"
    }

    struct Invocation {
        var mode: Mode
        /// The mode's document/package. `nil` only for `--menu-probe`,
        /// which opens an untitled document of its own.
        var path: URL?
        /// `nil` means the flag was absent — the probe's documented single
        /// zero-offset run. A PRESENT flag always yields a validated list.
        var offsets: [Int]?
        var dwellSeconds: Double = 3
        /// `nil` = zoom not controlled; the probe reports the span that was
        /// actually on screen either way.
        var spanSeconds: Double?
        var controlOnly = false
        var blind = false
        var minutes: Double = 0
        var dumpDirectory: URL?
    }

    enum Outcome {
        case notAProbe
        case refused([String])
        case probe(Invocation)
    }

    /// Flags that consume the next argv element.
    private static let valueFlags: Set<String> = [
        "--g5-probe", "--churn-probe", "--playhead-probe", "--timeline-probe",
        "--playhead-offset", "--playhead-dwell", "--playhead-span",
        "--probe-minutes", "--probe-dump",
    ]

    /// Which mode each modifier belongs to. A modifier given under the
    /// wrong mode is refused rather than ignored: `--playhead-offset` next
    /// to `--g5-probe` means the person believes something is being
    /// controlled that is not.
    private static let modifierOwner: [String: Mode] = [
        "--g5-leak": .g5, "--g5-block-leak": .g5, "--g5-early": .g5,
        "--menu-gate-drop-save": .menu,
        "--playhead-offset": .playhead, "--playhead-dwell": .playhead,
        "--playhead-span": .playhead, "--playhead-control-only": .playhead,
        "--playhead-blind": .playhead, "--playhead-gate-cut-link": .playhead,
        "--probe-minutes": .timeline, "--probe-dump": .timeline,
    ]

    private static var knownFlags: Set<String> {
        Set(Mode.allCases.map(\.rawValue)).union(modifierOwner.keys)
    }

    static func parse(_ argv: [String]) -> Outcome {
        let tokens = Array(argv.dropFirst())
        guard tokens.contains(where: { knownFlags.contains($0) }) else { return .notAProbe }

        var reasons: [String] = []
        var present: Set<String> = []
        var values: [String: String] = [:]
        var valueRefused: Set<String> = []
        var ignored: [String] = []

        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.hasPrefix("--") {
                guard knownFlags.contains(token) else {
                    reasons.append("unknown probe flag: \(token)")
                    i += 1
                    continue
                }
                if present.contains(token) {
                    // firstIndex(of:) used to pick the first and drop the
                    // rest; which one won is not something a paper session
                    // log can reconstruct.
                    reasons.append("\(token) was given more than once")
                }
                present.insert(token)
                guard valueFlags.contains(token) else { i += 1; continue }
                guard i + 1 < tokens.count else {
                    reasons.append("\(token) needs a value and nothing followed it")
                    valueRefused.insert(token)
                    i += 1
                    continue
                }
                let value = tokens[i + 1]
                guard !value.hasPrefix("-") else {
                    // The A-43 incident, refused at its source.
                    reasons.append("\(token) was followed by \(value), which looks like a flag, not a value")
                    valueRefused.insert(token)
                    i += 1
                    continue
                }
                values[token] = value
                i += 2
            } else if token.hasPrefix("-") {
                // NSUserDefaults argument domain (Xcode and Finder inject
                // e.g. -NSDocumentRevisionsDebugMode YES). Not probe input,
                // but RECORDED rather than swallowed.
                ignored.append(token)
                if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") {
                    ignored.append(tokens[i + 1])
                    i += 2
                } else {
                    i += 1
                }
            } else {
                reasons.append("stray argument: \(token) — the probes take no positional arguments, every value belongs to a flag")
                i += 1
            }
        }

        let modes = Mode.allCases.filter { present.contains($0.rawValue) }
        if modes.count > 1 {
            reasons.append("two probe modes at once: \(modes.map(\.rawValue).joined(separator: " and ")) — which one runs is ambiguous")
        }
        guard let mode = modes.first else {
            let orphans = present.sorted().filter { modifierOwner[$0] != nil }
            reasons.append("probe modifier(s) \(orphans.joined(separator: ", ")) given with no probe mode")
            return .refused(reasons)
        }
        for flag in present.sorted() {
            if let owner = modifierOwner[flag], owner != mode {
                reasons.append("\(flag) belongs to \(owner.rawValue) but the mode is \(mode.rawValue)")
            }
        }

        var invocation = Invocation(mode: mode, path: nil)

        if mode != .menu {
            if let raw = values[mode.rawValue] {
                if !FileManager.default.fileExists(atPath: raw) {
                    reasons.append("\(mode.rawValue) path does not exist: \(raw)")
                }
                invocation.path = URL(fileURLWithPath: raw)
            } else if !valueRefused.contains(mode.rawValue) {
                reasons.append("\(mode.rawValue) needs a document path")
            }
        }

        if let raw = values["--playhead-offset"] {
            invocation.offsets = parseOffsets(raw, into: &reasons)
        } else if present.contains("--playhead-offset") {
            // The value was already refused above; do NOT fall through to
            // the single-zero default, which is the exact failure A-43 ②
            // describes.
            invocation.offsets = []
        }

        if let raw = values["--playhead-dwell"] {
            if let value = Double(raw), value.isFinite, value > 0 {
                invocation.dwellSeconds = value
            } else {
                reasons.append("--playhead-dwell value is not a positive number of seconds: \(raw)")
            }
        }

        if let raw = values["--playhead-span"] {
            if let value = Double(raw), value.isFinite, value > 0 {
                invocation.spanSeconds = value
            } else {
                reasons.append("--playhead-span value is not a positive number of seconds: \(raw)")
            }
        }

        if let raw = values["--probe-minutes"] {
            if let value = Double(raw), value.isFinite, value >= 0 {
                invocation.minutes = value
            } else {
                reasons.append("--probe-minutes value is not a non-negative number: \(raw)")
            }
        }

        if let raw = values["--probe-dump"] {
            invocation.dumpDirectory = URL(fileURLWithPath: raw)
        }

        invocation.controlOnly = present.contains("--playhead-control-only")
        invocation.blind = present.contains("--playhead-blind")

        // A blind pass with no control session never prints the key that
        // makes written answers alignable — the run would look normal and
        // measure nothing.
        if invocation.blind, (invocation.offsets?.count ?? 1) <= 1, !invocation.controlOnly {
            reasons.append("--playhead-blind was given but no control session will run: it needs more than one --playhead-offset value, or --playhead-control-only")
        }

        guard reasons.isEmpty else { return .refused(reasons) }
        if !ignored.isEmpty {
            print("PROBE-ARGS: ignored (NSUserDefaults argument domain): \(ignored.joined(separator: " "))")
        }
        return .probe(invocation)
    }

    /// Comma list. Every entry must be a whole number ≥ 0; nothing is
    /// dropped, nothing is clamped. Repeats ARE allowed — the blind pass
    /// is a shuffled list with repeats, and that is what makes it scorable.
    /// The upper bound needs the document's frame count and is therefore
    /// checked after load, in the probe itself.
    private static func parseOffsets(_ raw: String, into reasons: inout [String]) -> [Int] {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reasons.append("--playhead-offset was given an empty list")
            return []
        }
        var offsets: [Int] = []
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let entry = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else {
                reasons.append("--playhead-offset has an empty entry in: \(raw)")
                continue
            }
            guard let value = Int(entry) else {
                reasons.append("--playhead-offset entry is not a whole number: \(entry)")
                continue
            }
            guard value >= 0 else {
                reasons.append("--playhead-offset entry is negative: \(entry)")
                continue
            }
            offsets.append(value)
        }
        return offsets
    }

    // MARK: - The refusals that need the document

    /// Four of the twenty-one refusals cannot be decided from argv alone —
    /// they need the document's frame count and duration, or the timeline's
    /// width. They live HERE anyway, as pure functions, for the reason this
    /// whole type was extracted: a refusal that only a run log has ever
    /// exercised is a refusal the next change can delete silently (§4).
    ///
    /// Each returns the refusal sentence, or `nil` when the invocation is
    /// fine. The probe prints it and exits 2 — same shape as `parse`.

    /// An offset at or past the last frame draws the playhead outside the
    /// document. REFUSED, not clamped: a clamped control is a control whose
    /// strength is not what the session log says it is (§4 rule 8).
    static func offsetsFitDocument(offsets: [Int], frameCount: Int) -> String? {
        guard let tooBig = offsets.first(where: { $0 >= frameCount }) else { return nil }
        return "--playhead-offset entry \(tooBig) is not smaller than the document's frame count \(frameCount)"
    }

    /// A control session longer than the document is not a session. The pass
    /// never restarts playback (deliberately — the sound stays a fixed
    /// reference), so once the document ends the remaining segments are
    /// SILENCE with a frozen playhead and nothing in the output says so.
    ///
    /// This is the M2.3.1 human session exactly: twelve segments × 12 s =
    /// 144 s on a 30 s fixture, everything after the third segment judged
    /// against nothing. A warning would not have stopped it.
    static func controlSessionFitsDocument(
        offsets: [Int], dwellSeconds: Double, controlOnly: Bool, documentSeconds: Double
    ) -> String? {
        let travel = controlSessionSeconds(
            offsets: offsets, dwellSeconds: dwellSeconds, controlOnly: controlOnly)
        guard travel > documentSeconds + 1e-9 else { return nil }
        return String(
            format: "the control session is %.1f s (%d --playhead-offset values × %g s --playhead-dwell) but the document is only %.1f s; playback ends mid-session and every segment after that is silence with a frozen playhead",
            travel, offsets.count, dwellSeconds, documentSeconds)
    }

    /// Seconds the control session spends playing. Zero when no control
    /// session runs (one offset and no `--playhead-control-only`).
    static func controlSessionSeconds(
        offsets: [Int], dwellSeconds: Double, controlOnly: Bool
    ) -> Double {
        (offsets.count > 1 || controlOnly) ? Double(offsets.count) * dwellSeconds : 0
    }

    /// How wide the visible window has to be for the DRAWN playhead to stay
    /// on screen for the whole run.
    ///
    /// Two terms, and the second one was missed on the first pass (Codex
    /// review): what is drawn is `displayOnlyFrame + displayOffsetFrames`,
    /// so the rightmost drawn position is the playback travel PLUS the
    /// largest offset. The document clamp applies to the TRAVEL only — a run
    /// that stops at the end of the document still draws further right by
    /// the offset. Frames → time goes through `FrameMapping`, never a divide
    /// by the frame rate (§6.2).
    static func requiredSpan(
        offsets: [Int], dwellSeconds: Double, controlOnly: Bool,
        documentSeconds: Double, rate: FrameRate?
    ) -> (total: Double, travel: Double, offset: Double, maxOffset: Int) {
        let gateTravel = controlOnly ? 0.0 : 1.5
        let control = controlSessionSeconds(
            offsets: offsets, dwellSeconds: dwellSeconds, controlOnly: controlOnly)
        let travel = min(documentSeconds, max(gateTravel, control))
        let maxOffset = offsets.max() ?? 0
        let offsetSeconds = rate.map {
            Double(FrameMapping.time(ofFrame: maxOffset, rate: $0).ticks)
                / Double(DocumentTime.timescale)
        } ?? 0
        return (travel + offsetSeconds, travel, offsetSeconds, maxOffset)
    }

    static func spanCoversTheRun(
        requested: Double,
        required: (total: Double, travel: Double, offset: Double, maxOffset: Int)
    ) -> String? {
        guard requested + 1e-9 < required.total else { return nil }
        return String(
            format: "--playhead-span %g s is shorter than the %.3f s this run draws (%.3f s of playback travel + %.3f s of --playhead-offset %d); the playhead would leave the visible window mid-pass",
            requested, required.total, required.travel, required.offset, required.maxOffset)
    }
}

