import Foundation
import GyeolCore
import Testing

/// Every refusal `ProbeArguments` makes, asserted.
///
/// WHY THIS FILE EXISTS. The twenty-one refusals were verified once, by a
/// person reading a terminal, and nothing after that would have noticed if a
/// change quietly restored a fallback. That is the shape §4 warns about
/// eight times: the failure mode is not a red gate, it is a green one that
/// measures nothing. The refusals guard a HUMAN session whose only record is
/// a sheet of paper (부록 A-43 ②), so there is no second place to catch it.
///
/// The refusal SENTENCES are asserted, not just the fact of refusal. The
/// sentence is the deliverable — "print what was wrong and which argument
/// caused it" — and a refusal that names the wrong argument sends the person
/// looking in the wrong place.
private func parse(_ tokens: String...) -> ProbeArguments.Outcome {
    // argv[0] is the executable; the parser drops it.
    ProbeArguments.parse(["/path/to/Gyeol"] + tokens)
}

private func refusals(_ outcome: ProbeArguments.Outcome) -> [String] {
    guard case .refused(let reasons) = outcome else {
        Issue.record("expected a refusal, got \(outcome)")
        return []
    }
    return reasons
}

private func invocation(_ outcome: ProbeArguments.Outcome) -> ProbeArguments.Invocation? {
    guard case .probe(let invocation) = outcome else {
        Issue.record("expected an accepted invocation, got \(outcome)")
        return nil
    }
    return invocation
}

/// A real path, because the parser checks existence — `/tmp` always exists
/// and no probe ever opens it in these tests.
private let existingPath = "/tmp"

@Suite struct ProbeArgumentParseRefusalTests {

    // MARK: The A-43 incident itself

    /// `--playhead-probe --playhead-offset 12 <doc>` used to take the STRING
    /// "--playhead-offset" as the document path. Two problems, both named.
    @Test func offsetFlagIsNeverTakenAsTheDocumentPath() {
        let reasons = refusals(parse(
            "--playhead-probe", "--playhead-offset", "12", existingPath))
        #expect(reasons == [
            "--playhead-probe was followed by --playhead-offset, which looks like a flag, not a value",
            "stray argument: \(existingPath) — the probes take no positional arguments, every value belongs to a flag",
        ])
    }

    // MARK: The offset list — nothing dropped, nothing defaulted

    @Test func emptyOffsetList() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-offset", ""))
                == ["--playhead-offset was given an empty list"])
    }

    /// `compactMap` used to drop the bad entry and keep going.
    @Test func nonNumericOffsetEntry() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-offset", "3,x,5"))
                == ["--playhead-offset entry is not a whole number: x"])
    }

    @Test func trailingCommaLeavesAnEmptyEntry() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-offset", "12,"))
                == ["--playhead-offset has an empty entry in: 12,"])
    }

    @Test func negativeOffsetEntry() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-offset", "3,-5"))
                == ["--playhead-offset entry is negative: -5"])
    }

    // MARK: Numeric modifiers

    @Test func unparseableDwell() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-dwell", "abc"))
                == ["--playhead-dwell value is not a positive number of seconds: abc"])
    }

    /// Zero seconds per offset is not a session; the old reader fell back to
    /// three and said nothing.
    @Test func zeroDwell() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-dwell", "0"))
                == ["--playhead-dwell value is not a positive number of seconds: 0"])
    }

    @Test func unparseableSpan() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-span", "wide"))
                == ["--playhead-span value is not a positive number of seconds: wide"])
    }

    @Test func unparseableProbeMinutes() {
        #expect(refusals(parse("--timeline-probe", existingPath, "--probe-minutes", "nope"))
                == ["--probe-minutes value is not a non-negative number: nope"])
    }

    // MARK: Shape of the command line

    @Test func modeWithNoValueAtAll() {
        #expect(refusals(parse("--playhead-probe"))
                == ["--playhead-probe needs a value and nothing followed it"])
    }

    @Test func strayPositionalArgument() {
        #expect(refusals(parse("--playhead-probe", existingPath, "12"))
                == ["stray argument: 12 — the probes take no positional arguments, every value belongs to a flag"])
    }

    /// `firstIndex(of:)` used to take the first and drop the rest, and which
    /// one won is not something a paper session log can reconstruct.
    @Test func duplicateFlag() {
        #expect(refusals(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", "0,12", "--playhead-offset", "0,5"))
                == ["--playhead-offset was given more than once"])
    }

    @Test func unknownFlag() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-offsets", "12"))
                == [
                    "unknown probe flag: --playhead-offsets",
                    "stray argument: 12 — the probes take no positional arguments, every value belongs to a flag",
                ])
    }

    @Test func modifierWithNoMode() {
        #expect(refusals(parse("--playhead-offset", "0,12"))
                == ["probe modifier(s) --playhead-offset given with no probe mode"])
    }

    /// Ignoring it would leave the person believing something is controlled
    /// that is not.
    @Test func modifierUnderTheWrongMode() {
        #expect(refusals(parse("--g5-probe", existingPath, "--playhead-offset", "12"))
                == ["--playhead-offset belongs to --playhead-probe but the mode is --g5-probe"])
    }

    @Test func twoModesAtOnce() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--menu-probe"))
                == ["two probe modes at once: --menu-probe and --playhead-probe — which one runs is ambiguous"])
    }

    @Test func pathThatDoesNotExist() {
        #expect(refusals(parse("--playhead-probe", "/no/such/fixture.gyeol"))
                == ["--playhead-probe path does not exist: /no/such/fixture.gyeol"])
    }

    /// A blind pass with no control session never prints the key that makes
    /// written answers alignable — it would look normal and measure nothing.
    @Test func blindWithNoControlSession() {
        #expect(refusals(parse("--playhead-probe", existingPath, "--playhead-blind"))
                == ["--playhead-blind was given but no control session will run: it needs more than one --playhead-offset value, or --playhead-control-only"])
    }

    /// Several problems are reported together rather than one at a time: a
    /// person fixing a session command should not have to run it five times.
    @Test func everyProblemIsReportedAtOnce() {
        let reasons = refusals(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", "3,x,-5,",
            "--playhead-dwell", "0"))
        #expect(reasons.count == 4)
        #expect(reasons.contains("--playhead-offset entry is not a whole number: x"))
        #expect(reasons.contains("--playhead-offset entry is negative: -5"))
        #expect(reasons.contains("--playhead-offset has an empty entry in: 3,x,-5,"))
        #expect(reasons.contains("--playhead-dwell value is not a positive number of seconds: 0"))
    }
}

// MARK: - The accepting side

/// §4 rule 2: a parser only ever seen to refuse is half verified. These are
/// the three session forms that must keep working, plus the permanent gate.
@Suite struct ProbeArgumentAcceptanceTests {

    /// The normal app launch is NOT in scope and must not start refusing
    /// arguments — including arguments that would be refused in probe mode.
    @Test(arguments: [
        [],
        ["--unknown-thing", "stray.txt"],
        ["-NSDocumentRevisionsDebugMode", "YES"],
        ["/Users/someone/Movies/holiday.gyeol"],
    ])
    func noProbeFlagMeansNotAProbe(tokens: [String]) {
        guard case .notAProbe = ProbeArguments.parse(["/path/to/Gyeol"] + tokens) else {
            Issue.record("normal launch was disturbed by \(tokens)")
            return
        }
    }

    /// The permanent gate (§9 M2.3.1): no modifiers at all.
    @Test func permanentGateForm() {
        let parsed = invocation(parse("--playhead-probe", existingPath))
        #expect(parsed?.mode == .playhead)
        #expect(parsed?.path?.path == existingPath)
        // nil, not [0]: the flag was ABSENT, and the probe's documented
        // single zero-offset run is what an absent flag means. A present
        // flag never yields nil.
        #expect(parsed?.offsets == nil)
        #expect(parsed?.dwellSeconds == 3)
        #expect(parsed?.spanSeconds == nil)
        #expect(parsed?.controlOnly == false)
        #expect(parsed?.blind == false)
    }

    /// Session form 1 — the two-value control pass.
    @Test func twoValueControlPass() {
        let parsed = invocation(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", "0,12", "--playhead-control-only",
            "--playhead-dwell", "12", "--playhead-span", "30"))
        #expect(parsed?.offsets == [0, 12])
        #expect(parsed?.controlOnly == true)
        #expect(parsed?.dwellSeconds == 12)
        #expect(parsed?.spanSeconds == 30)
        #expect(parsed?.blind == false)
    }

    /// Session form 2 — the descending pass. Order is preserved exactly;
    /// sorting it would silently change what the person judges.
    @Test func descendingPass() {
        let parsed = invocation(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", "12,5,4,3", "--playhead-control-only",
            "--playhead-dwell", "12", "--playhead-span", "180"))
        #expect(parsed?.offsets == [12, 5, 4, 3])
    }

    /// Session form 3 — the blind pass, offsets read from a file. REPEATS
    /// ARE LEGAL and load-bearing: the twelve-segment scoring only works
    /// because values recur in a shuffled order.
    @Test func blindPassWithRepeatedOffsets() {
        let parsed = invocation(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", "0,12,5,0,12,4,3,12,0,5,4,3",
            "--playhead-blind", "--playhead-control-only",
            "--playhead-dwell", "12", "--playhead-span", "180"))
        #expect(parsed?.offsets == [0, 12, 5, 0, 12, 4, 3, 12, 0, 5, 4, 3])
        #expect(parsed?.blind == true)
        #expect(parsed?.controlOnly == true)
    }

    /// `$(cat offsets.txt)` carries whatever whitespace the file had.
    @Test func offsetsToleranceForFileWhitespace() {
        #expect(invocation(parse(
            "--playhead-probe", existingPath,
            "--playhead-offset", " 0 , 12 ,5\n"))?.offsets == [0, 12, 5])
    }

    /// A single zero offset is legal and is NOT the same thing as an absent
    /// flag — the parser must not collapse them, or the fallback it exists
    /// to remove comes back through the other door.
    @Test func explicitSingleZeroOffset() {
        #expect(invocation(parse(
            "--playhead-probe", existingPath, "--playhead-offset", "0"))?.offsets == [0])
    }

    /// NSUserDefaults arguments (Xcode, Finder) are not probe input; they
    /// must not refuse the run and must not be mistaken for a value.
    @Test func nsUserDefaultsArgumentsAreIgnoredNotConsumed() {
        let parsed = invocation(parse(
            "--playhead-probe", existingPath,
            "-NSDocumentRevisionsDebugMode", "YES",
            "--playhead-span", "30"))
        #expect(parsed?.path?.path == existingPath)
        #expect(parsed?.spanSeconds == 30)
    }

    /// Every other probe mode still parses, with its own modifiers.
    @Test func theOtherProbeModes() {
        #expect(invocation(parse("--menu-probe"))?.mode == .menu)
        #expect(invocation(parse("--menu-probe", "--menu-gate-drop-save"))?.mode == .menu)
        #expect(invocation(parse("--g5-probe", existingPath, "--g5-early", "--g5-leak"))?.mode == .g5)
        #expect(invocation(parse("--churn-probe", existingPath))?.mode == .churn)
        let timeline = invocation(parse(
            "--timeline-probe", existingPath,
            "--probe-minutes", "2", "--probe-dump", "/tmp/dump"))
        #expect(timeline?.minutes == 2)
        #expect(timeline?.dumpDirectory?.path == "/tmp/dump")
        // Zero is a legal --probe-minutes: it means "skip the sustained
        // phase", which is what the flag's absence also means.
        #expect(invocation(parse("--timeline-probe", existingPath, "--probe-minutes", "0"))?.minutes == 0)
    }

    /// `--menu-probe` is the one mode with no document argument.
    @Test func menuProbeNeedsNoPath() {
        #expect(invocation(parse("--menu-probe"))?.path == nil)
    }
}

// MARK: - The refusals that need the document

@Suite struct ProbeArgumentDocumentRefusalTests {

    @Test func offsetAtOrPastTheLastFrameIsRefused() {
        #expect(ProbeArguments.offsetsFitDocument(offsets: [0, 900], frameCount: 900)
                == "--playhead-offset entry 900 is not smaller than the document's frame count 900")
        #expect(ProbeArguments.offsetsFitDocument(offsets: [0, 899], frameCount: 900) == nil)
    }

    /// The M2.3.1 human session, exactly: twelve segments × 12 s on the 30 s
    /// fixture. Everything after the third segment was silence with a frozen
    /// playhead and the person recorded answers for it anyway.
    @Test func theSessionThatWasInvalidIsNowRefused() {
        let reason = ProbeArguments.controlSessionFitsDocument(
            offsets: Array(repeating: 12, count: 12),
            dwellSeconds: 12, controlOnly: true, documentSeconds: 30)
        #expect(reason == "the control session is 144.0 s (12 --playhead-offset values × 12 s --playhead-dwell) but the document is only 30.0 s; playback ends mid-session and every segment after that is silence with a frozen playhead")
    }

    /// The same session on the 180 s fixture is what the new fixture is for.
    @Test func theSameSessionFitsTheLongFixture() {
        #expect(ProbeArguments.controlSessionFitsDocument(
            offsets: Array(repeating: 12, count: 12),
            dwellSeconds: 12, controlOnly: true, documentSeconds: 180) == nil)
    }

    /// A single offset without `--playhead-control-only` runs no control
    /// session at all, so no length check applies.
    @Test func noControlSessionMeansNoLengthCheck() {
        #expect(ProbeArguments.controlSessionSeconds(
            offsets: [12], dwellSeconds: 999, controlOnly: false) == 0)
        #expect(ProbeArguments.controlSessionFitsDocument(
            offsets: [12], dwellSeconds: 999, controlOnly: false, documentSeconds: 30) == nil)
    }

    /// The Codex review's case: the drawn playhead is travel PLUS offset, and
    /// counting travel alone let a span that exactly fits the playback still
    /// push the drawn playhead off the right edge.
    @Test func requiredSpanIncludesTheDisplayOffset() {
        let required = ProbeArguments.requiredSpan(
            offsets: [12], dwellSeconds: 3, controlOnly: false,
            documentSeconds: 30, rate: .fps30)
        #expect(required.travel == 1.5)
        #expect(abs(required.offset - 0.4) < 1e-9)   // 12 frames at 30 fps
        #expect(abs(required.total - 1.9) < 1e-9)
        #expect(ProbeArguments.spanCoversTheRun(requested: 1.5, required: required)
                == "--playhead-span 1.5 s is shorter than the 1.900 s this run draws (1.500 s of playback travel + 0.400 s of --playhead-offset 12); the playhead would leave the visible window mid-pass")
        #expect(ProbeArguments.spanCoversTheRun(requested: 1.9, required: required) == nil)
    }

    /// The offset term is frames → time through `FrameMapping` (§6.2), so
    /// the same offset means different seconds at different rates. 12 frames
    /// is 400 ms at 30 fps but 500.5 ms at 23.976.
    @Test func theOffsetTermFollowsTheProjectRate() {
        let at30 = ProbeArguments.requiredSpan(
            offsets: [12], dwellSeconds: 3, controlOnly: false,
            documentSeconds: 30, rate: .fps30)
        let at23976 = ProbeArguments.requiredSpan(
            offsets: [12], dwellSeconds: 3, controlOnly: false,
            documentSeconds: 30, rate: .fps23_976)
        #expect(abs(at30.offset - 0.4) < 1e-9)
        #expect(abs(at23976.offset - 0.5005) < 1e-9)
    }

    /// The document clamp is on the TRAVEL term only: a pass that stops at
    /// the end of the document still draws further right by the offset.
    @Test func theDocumentClampDoesNotSwallowTheOffset() {
        let required = ProbeArguments.requiredSpan(
            offsets: [0, 12], dwellSeconds: 100, controlOnly: true,
            documentSeconds: 30, rate: .fps30)
        #expect(required.travel == 30)            // clamped to the document
        #expect(abs(required.offset - 0.4) < 1e-9)  // NOT clamped away
        #expect(abs(required.total - 30.4) < 1e-9)
    }
}

// MARK: - The zoom limits behind the fourth refusal

@Suite struct VisibleSpanArithmeticTests {

    /// `--playhead-span 30` on a 928 pt timeline, the value the session
    /// actually uses.
    @Test func aRequestedSpanBecomesTheZoom() {
        let ticksPerPoint = TimelineViewport.ticksPerPoint(forSpanSeconds: 30, width: 928)
        #expect(ticksPerPoint != nil)
        #expect(abs(TimelineViewport.spanSeconds(
            ticksPerPoint: ticksPerPoint!, width: 928) - 30) < 1e-9)
    }

    /// nil, never a clamped value — the refusal depends on this.
    @Test(arguments: [100_000.0, 0.001, 0, -5, .infinity, Double.nan])
    func unattainableSpansReturnNil(seconds: Double) {
        #expect(TimelineViewport.ticksPerPoint(forSpanSeconds: seconds, width: 928) == nil)
    }

    @Test func widthlessViewHasNoSpan() {
        #expect(TimelineViewport.ticksPerPoint(forSpanSeconds: 30, width: 0) == nil)
    }

    /// The range a refusal names has to be the range that is actually
    /// accepted, or the message sends the person to a value that also fails.
    @Test func theAttainableRangeIsTheAcceptedRange() {
        let range = TimelineViewport.attainableSpanSeconds(width: 928)
        #expect(TimelineViewport.ticksPerPoint(
            forSpanSeconds: range.lowerBound, width: 928) != nil)
        #expect(TimelineViewport.ticksPerPoint(
            forSpanSeconds: range.upperBound, width: 928) != nil)
        #expect(TimelineViewport.ticksPerPoint(
            forSpanSeconds: range.lowerBound * 0.99, width: 928) == nil)
        #expect(TimelineViewport.ticksPerPoint(
            forSpanSeconds: range.upperBound * 1.01, width: 928) == nil)
    }
}
