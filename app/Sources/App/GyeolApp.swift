import AVFoundation
import AppKit
import GyeolCore
import SwiftUI

@main
struct GyeolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No standalone player window (G12): every window is a document
        // window created by NSDocumentController. SwiftUI requires at least
        // one Scene; Settings is the one that does not open at launch.
        Settings {
            EmptyView()
        }
        .commands {
            // THE FULL DOCUMENT MENU, restored (M2.3 r2 task 1). G12
            // replaced WindowGroup with a Settings scene + AppKit document
            // windows, which silently discarded the document menu SwiftUI
            // had been providing — D7 adopted NSDocument to NOT rebuild
            // free machinery, and the missing menu was giving part of that
            // back (⌘S did nothing for two milestones; round 1's undo
            // routing was the first symptom, this is the full repair).
            // All items route explicitly through currentDocument, same
            // rationale as undo below: the SwiftUI scene is not in the
            // document window's responder chain, so implicit routing
            // cannot be trusted — explicit routing is verifiable, and
            // --menu-probe verifies it.
            CommandGroup(replacing: .newItem) {
                Button("새 프로젝트") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n")
                Button("열기…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("닫기") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w")
                Divider()
                // The gate's self-test (§4 rule 1): --menu-gate-drop-save
                // deliberately omits Save so --menu-probe can be SHOWN to
                // fail. Compiled in, harmless in normal launches.
                if !CommandLine.arguments.contains("--menu-gate-drop-save") {
                    Button("저장") {
                        NSDocumentController.shared.currentDocument?.save(nil)
                    }
                    .keyboardShortcut("s")
                }
                Button("다른 이름으로 저장…") {
                    NSDocumentController.shared.currentDocument?.saveAs(nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("복제") {
                    NSDocumentController.shared.currentDocument?.duplicate(nil)
                }
                Button("마지막 저장 상태로 되돌리기") {
                    NSDocumentController.shared.currentDocument?.revertToSaved(nil)
                }
            }
            // Explicit ⌘Z/⇧⌘Z wired to the CURRENT DOCUMENT's undo manager
            // (D27, round 1).
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") {
                    NSDocumentController.shared.currentDocument?.undoManager?.undo()
                }
                .keyboardShortcut("z")
                Button("실행 복귀") {
                    NSDocumentController.shared.currentDocument?.undoManager?.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // ONE strict parse for every probe, before anything is opened
        // (부록 A-43 ②). The old per-flag readers each had their own
        // fallback; this branch has none.
        switch ProbeArguments.parse(CommandLine.arguments) {
        case .notAProbe:
            break  // normal launch, below — not in scope
        case .refused(let reasons):
            reasons.forEach { print("PROBE-ARGS: ✘ \($0)") }
            print("PROBE-ARGS: UNVERIFIED — invocation refused, \(reasons.count) problem(s); no document opened, nothing played (§4 rule 6)")
            exit(2)
        case .probe(let invocation):
            run(invocation)
            return
        }
        // The AppKit document lifecycle would do this on its own; under the
        // SwiftUI lifecycle it is explicit: launching without a document
        // opens an untitled one.
        if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
    }

    private func run(_ invocation: ProbeArguments.Invocation) {
        // --menu-probe is the one mode with no document argument: it opens
        // an untitled one itself.
        //
        // M2.3 r2: it asserts the document menu the user relies on actually
        // EXISTS with a document open — nobody opened the File menu for two
        // milestones and ⌘S silently did nothing (G12 gap). Same spirit as
        // --g5-probe: the running app is the only place the real menu bar
        // exists.
        if invocation.mode == .menu {
            NSApp.activate(ignoringOtherApps: true)
            NSDocumentController.shared.newDocument(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Self.runMenuProbe()
            }
            return
        }
        // Structurally guaranteed by the parser — a mode with no path is
        // refused there. Re-checked so a later flag cannot quietly turn
        // that guarantee into a crash inside a diagnostic tool.
        guard let path = invocation.path else {
            print("PROBE-ARGS: ✘ \(invocation.mode.rawValue) reached the runner with no path")
            print("PROBE-ARGS: UNVERIFIED — invocation refused, 1 problem(s); no document opened, nothing played (§4 rule 6)")
            exit(2)
        }
        switch invocation.mode {
        case .menu:
            break  // returned above
        // G5 ground truth (M2.1 task 2): `--g5-probe <path>` runs the real
        // open → close cycle in the real app process and prints a lifetime
        // table, because the headless measurement and the GUI memory graph
        // disagreed and only the app itself can arbitrate.
        case .g5:
            // Launched from a shell the app is not activated, the document
            // window never actually appears, and the probe silently
            // measures the A-36 headless artifact instead of the app
            // (reproduced in M2.2: an un-activated baseline HEAD reports
            // ALIVE at t≈3s). Activation restores the probe's documented
            // precondition — a window that is really on screen.
            NSApp.activate(ignoringOtherApps: true)
            runG5Probe(documentAt: path)
        // M2.3 r2 task 6: --churn-probe <pkg> opens and closes the package
        // ten times, sampling resident footprint and live-document count —
        // the autosave-timer retention is system-owned (M2.2 doctrine),
        // but ownership and RESOURCE CONSUMPTION are different questions,
        // and on the 8GB floor (D3) a 48–92MB document accumulating per
        // close would matter.
        case .churn:
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await Self.runChurnProbe(documentAt: path)
                NSApp.terminate(nil)
            }
        // M2.3.1: --playhead-probe <pkg> [--playhead-offset N[,N…]]
        // [--playhead-control-only] [--playhead-dwell S] [--playhead-blind]
        // [--playhead-span S]. Same rationale as --g5-probe and
        // --menu-probe — the running app is the only place the CADisplayLink
        // exists. See runPlayheadProbe for the claim.
        case .playhead:
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await Self.runPlayheadProbe(
                    documentAt: path,
                    offsets: invocation.offsets ?? [0],
                    dwell: invocation.dwellSeconds,
                    spanSeconds: invocation.spanSeconds,
                    controlOnly: invocation.controlOnly,
                    blind: invocation.blind)
            }
        // M2.2 measurement harness — same rationale as --g5-probe: the
        // running app process is the only environment whose numbers count.
        case .timeline:
            Task { @MainActor in
                await TimelineProbe.run(
                    packageURL: path,
                    minutes: invocation.minutes,
                    dumpDirectory: invocation.dumpDirectory)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Playhead probe (M2.3.1)

    /// WHAT THIS PROBE CLAIMS — exactly two things, and nothing beyond them
    /// (§4 rule 4):
    ///
    /// 1. **The display link drives the display-only update.** The probe
    ///    never calls `pollDisplayedFrame()` itself; it only samples
    ///    `timelinePlayheadFrame`, which is the very value
    ///    `TimelineHostView` hands the renderer. Movement therefore came
    ///    from the `CADisplayLink` tick and from nothing else.
    /// 2. **The drawn index advances monotonically during playback.**
    ///
    /// IT DOES NOT CLAIM THE PLAYHEAD IS IN THE RIGHT PLACE. Nothing here
    /// listens to anything, and a drawn index that advanced smoothly while
    /// sitting a second away from the sound would pass every check below.
    /// That question is M2.3.1's completion condition ②, it is a human
    /// check, and `--playhead-offset` exists to give it a control rather
    /// than to answer it.
    ///
    /// The committed index and the stop report are PRINTED, not claimed:
    /// their agreement with the drawn index is gated by the app test suite
    /// (`AudioOnlyPlayheadTests`, `DocumentPlaybackTests`), which can assert
    /// it deterministically. This probe reaches the one thing those tests
    /// structurally cannot: they call the polling function directly and
    /// never build a `TimelineMetalView`, so they stay green with the
    /// display link wire cut. `--playhead-gate-cut-link` demonstrates that.
    ///
    /// `--playhead-offset N` shifts the DRAWN playhead by N frames while
    /// playing — display only; the commit path never reads the offset value
    /// (see `PlaybackController.displayOffsetFrames`). Pass a comma list to
    /// cycle values inside ONE uninterrupted playback: the person comparing
    /// them back to back must not lose the audio reference between values.
    ///
    /// THE THREE HUMAN-SESSION FLAGS BELOW EXIST TO PROTECT THE JUDGEMENT,
    /// and none of them is on by default — the permanent gate (§9 M2.3.1)
    /// is what runs when they are absent.
    ///
    /// - `--playhead-control-only` skips the gate runs. The gate plays every
    ///   offset three times WITH ITS VALUE PRINTED, which is a labelled
    ///   preview of exactly the values the person must then judge blind.
    ///   Skipping measures nothing, so this run reports SKIPPED, never PASS
    ///   (§4 rule 4). It also forces the control session for a single
    ///   offset, which the default path skips — otherwise the flag would
    ///   leave nothing to run at all.
    /// - `--playhead-dwell S` sets the seconds spent on each offset,
    ///   default 3. Three seconds is roughly one envelope peak in
    ///   `tone-envelope-a` and a judgement needs several.
    /// - `--playhead-blind` withholds the offset value during the control
    ///   session — each segment announces only its index — and prints the
    ///   ordered list once the session is over. The person judges with the
    ///   terminal hidden, so the printed markers are what lets written
    ///   answers be aligned to segments afterwards; deferring the values to
    ///   the end is what makes the pass blind, rather than trusting that
    ///   the terminal stayed covered.
    /// - `--playhead-span S` fixes the visible time window to S seconds
    ///   (부록 A-43 ①). **The zoom is a measurement condition**: the check
    ///   happens on screen, and the default zoom drew the 30 s fixture
    ///   across a four-minute width, where a 400 ms offset is a few pixels.
    ///   Without this the last session zoomed by hand before each pass, so
    ///   the passes were not held at the same zoom. The span, not an
    ///   internal scale factor, is what the person can check against the
    ///   ruler. It is REPORTED whether or not it was requested — a session
    ///   log has to state its own measurement condition — and a span that
    ///   cannot be satisfied is refused, never clamped.
    ///
    /// Every argument above is parsed by `ProbeArguments`, which refuses
    /// rather than falling back (부록 A-43 ②).
    private static func runPlayheadProbe(
        documentAt url: URL,
        offsets: [Int],
        dwell: Double = 3,
        spanSeconds: Double? = nil,
        controlOnly: Bool = false,
        blind: Bool = false
    ) async {
        let file: GyeolDocumentFile? = await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, error in
                if let error { print("PLAYHEAD: open failed: \(error)") }
                continuation.resume(returning: doc as? GyeolDocumentFile)
            }
        }
        guard let file, case let playback = file.playback else {
            print("PLAYHEAD-GATE: FAIL — no document")
            exit(1)
        }
        for _ in 0..<100 where playback.loadState != .ready {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard playback.loadState == .ready, playback.frameCount > 0 else {
            print("PLAYHEAD-GATE: FAIL — document never became playable (\(playback.loadState))")
            exit(1)
        }
        // ---- The refusals that needed the document. The RULES are pure and
        // live in `ProbeArguments` beside the argv ones (and are tested
        // there); what happens here is printing and exiting.
        let rate = playback.projectRate
        let documentSeconds = rate.map {
            Double(FrameMapping.time(ofFrame: playback.frameCount, rate: $0).ticks)
                / Double(DocumentTime.timescale)
        } ?? 0
        func refuse(_ reason: String) -> Never {
            print("PROBE-ARGS: ✘ \(reason)")
            print("PROBE-ARGS: UNVERIFIED — invocation refused, 1 problem(s); nothing played (§4 rule 6)")
            exit(2)
        }
        if let reason = ProbeArguments.offsetsFitDocument(
            offsets: offsets, frameCount: playback.frameCount) {
            refuse(reason)
        }
        if let reason = ProbeArguments.controlSessionFitsDocument(
            offsets: offsets, dwellSeconds: dwell, controlOnly: controlOnly,
            documentSeconds: documentSeconds) {
            refuse(reason)
        }

        // ---- Zoom, the measurement condition (부록 A-43 ①). Nothing scrolls
        // the timeline to follow the playhead (there is no auto-follow —
        // §5.2 draws only what the viewport asks for), so a span narrower
        // than what this run DRAWS would run the playhead off screen
        // mid-pass and the person would be judging a blank strip.
        let requiredSpan = ProbeArguments.requiredSpan(
            offsets: offsets, dwellSeconds: dwell, controlOnly: controlOnly,
            documentSeconds: documentSeconds, rate: rate)
        // POLLED, not sampled once: the document can reach `.ready` before
        // SwiftUI has built and laid out the window, and a single early
        // lookup reported "no timeline view" on runs whose zoom was in fact
        // perfectly ordinary — an unreadable measurement condition, which
        // is the thing being fixed, not a way to fix it.
        var timeline: TimelineMetalView?
        for _ in 0..<40 {
            if let found = Self.timelineView(), found.bounds.width > 0 {
                timeline = found
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        var spanReport = "span=UNREPORTED (no laid-out timeline view found)"
        if let timeline {
            if let requested = spanSeconds {
                if let reason = ProbeArguments.spanCoversTheRun(
                    requested: requested, required: requiredSpan) {
                    refuse(reason)
                }
                switch timeline.setVisibleSpan(seconds: requested) {
                case .applied(let ticksPerPoint, let width):
                    spanReport = String(
                        format: "span=%.3f s requested over %.1f pt (ticksPerPoint %.3f)",
                        requested, width, ticksPerPoint)
                case .widthUnavailable:
                    print("PROBE-ARGS: ✘ --playhead-span cannot be applied: the timeline has no width yet")
                    print("PROBE-ARGS: UNVERIFIED — invocation refused, 1 problem(s); nothing played (§4 rule 6)")
                    exit(2)
                case .unattainable(let width, let minSeconds, let maxSeconds):
                    print(String(
                        format: "PROBE-ARGS: ✘ --playhead-span %g s is outside what this %.1f pt timeline can show (%.3f s … %.1f s); refusing rather than clamping — a clamped zoom is a measurement condition the log would misreport",
                        requested, width, minSeconds, maxSeconds))
                    print("PROBE-ARGS: UNVERIFIED — invocation refused, 1 problem(s); nothing played (§4 rule 6)")
                    exit(2)
                }
            } else if let current = timeline.currentVisibleSpan() {
                // Not controlled, still stated: A-43 ① went unnoticed
                // precisely because no line in the log said what the screen
                // was showing.
                spanReport = String(
                    format: "span=%.3f s NOT CONTROLLED over %.1f pt (ticksPerPoint %.3f, default zoom)",
                    current.seconds, current.widthPoints, current.ticksPerPoint)
            }
        } else if spanSeconds != nil {
            print("PROBE-ARGS: ✘ --playhead-span cannot be applied: no timeline view exists in this process")
            print("PROBE-ARGS: UNVERIFIED — invocation refused, 1 problem(s); nothing played (§4 rule 6)")
            exit(2)
        }

        print("PLAYHEAD: \(url.lastPathComponent) rate=\(rate?.rawValue ?? "?") frames=\(playback.frameCount) \(spanReport) hasVideoTrack=\(playback.sessionHasVideoTrack)")

        var failures: [String] = []
        var committedByOffset: [Int: [Int]] = [:]

        for offset in offsets where !controlOnly {
            playback.displayOffsetFrames = offset
            for run in 1...3 {
                await playback.step(by: -playback.playheadFrame)
                playback.togglePlayPause()
                var drawn: [Int] = []
                var offsetChecks: [Int] = []
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    // Sampled in the same instant: the difference between
                    // what the renderer draws and the raw display-only frame
                    // must be exactly the injected offset, which is what
                    // makes the offset provably display-side.
                    drawn.append(playback.timelinePlayheadFrame)
                    offsetChecks.append(playback.timelinePlayheadFrame - playback.displayOnlyFrame)
                }
                playback.togglePlayPause()
                for _ in 0..<200 where playback.isPlaying {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                committedByOffset[offset, default: []].append(playback.playheadFrame)

                print("PLAYHEAD: offset=\(offset) run \(run) drawn@100ms=\(drawn) committed=\(playback.playheadFrame) drawnAfterStop=\(playback.timelinePlayheadFrame)")
                print("PLAYHEAD: offset=\(offset) run \(run) stopReport=\(playback.lastStopReport ?? "nil")")

                // Claim 1 — the link drove it. The probe called no polling.
                if drawn.allSatisfy({ $0 == drawn[0] }) {
                    failures.append("offset=\(offset) run \(run): drawn index never moved (\(drawn[0])) — the display link did not drive the update")
                }
                // Claim 2 — monotonic.
                if drawn != drawn.sorted() {
                    failures.append("offset=\(offset) run \(run): drawn index went backwards: \(drawn)")
                }
                // The offset is display-side and exact (clamping aside).
                if offset != 0, let bad = offsetChecks.first(where: { $0 != offset && $0 != 0 }) {
                    failures.append("offset=\(offset) run \(run): drawn − displayOnly was \(bad)")
                }
                // §7.4-8: after the handoff the drawn playhead is the
                // committed one, offset or not. PRINTED as a claim only in
                // the narrow sense that the offset must not survive a stop.
                if playback.timelinePlayheadFrame != playback.playheadFrame {
                    failures.append("offset=\(offset) run \(run): after stop drawn \(playback.timelinePlayheadFrame) ≠ committed \(playback.playheadFrame)")
                }
            }
        }
        playback.displayOffsetFrames = 0

        // Skipped under --playhead-control-only: with no gate runs these
        // lines carry empty lists AND name every offset before the blind
        // session starts, which is the leak the flag exists to close.
        for offset in offsets.sorted() where !controlOnly {
            print("PLAYHEAD: committed indices at offset=\(offset): \(committedByOffset[offset] ?? [])")
        }

        // The human control session: ONE uninterrupted playback, cycling the
        // offsets. Playback never restarts, so the waveform on screen and
        // the sound in the room stay a fixed reference while only the drawn
        // playhead moves. Switching costs one property write — no rebuild,
        // no seek, no waveform reload — so every N is equally cheap.
        if offsets.count > 1 || controlOnly {
            print(String(format: "PLAYHEAD: control session — one continuous pass, %g s per offset", dwell))
            await playback.step(by: -playback.playheadFrame)
            playback.togglePlayPause()
            for (segment, offset) in offsets.enumerated() {
                playback.displayOffsetFrames = offset
                if blind {
                    // Index only. The drawn frame is omitted too: it is the
                    // raw index PLUS the offset, so printing it hands over
                    // the value this flag is withholding.
                    print("PLAYHEAD: control segment \(segment + 1) started")
                } else {
                    print("PLAYHEAD: control offset=\(offset) now active (drawn=\(playback.timelinePlayheadFrame))")
                }
                try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
            }
            playback.displayOffsetFrames = 0
            playback.togglePlayPause()
            for _ in 0..<200 where playback.isPlaying {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // After the sound has stopped, never before.
            if blind {
                let key = offsets.enumerated().map { "\($0.offset + 1)=\($0.element)" }.joined(separator: " ")
                print("PLAYHEAD: control segments in order — \(key)")
            }
        }

        // Nothing was measured, so nothing is claimed — a PASS here would be
        // the "green with no measurement" §4 warns about eight times.
        if controlOnly {
            print("PLAYHEAD-GATE: SKIPPED — --playhead-control-only, no gate runs; this run measured nothing")
            exit(0)
        }

        if failures.isEmpty {
            print("PLAYHEAD-GATE: PASS — display link drove the drawn index, monotonic, \(offsets.count * 3) runs")
            exit(0)
        }
        failures.forEach { print("PLAYHEAD-GATE: ✘ \($0)") }
        print("PLAYHEAD-GATE: FAIL — \(failures.count) problem(s)")
        exit(1)
    }

    /// The document window's timeline view, for `--playhead-span`. The
    /// probe reaches it through the real view hierarchy rather than through
    /// a back channel: the zoom that matters is the one on the screen the
    /// person is looking at.
    private static func timelineView() -> TimelineMetalView? {
        func search(_ view: NSView) -> TimelineMetalView? {
            if let found = view as? TimelineMetalView { return found }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let found = search(root) { return found }
        }
        return nil
    }

    // MARK: - Churn probe (M2.3 r2 task 6)

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static var churnSurvivors: [WeakDocumentBox] = []
    final class WeakDocumentBox { weak var document: GyeolDocumentFile? }

    private static func runChurnProbe(documentAt url: URL) async {
        print(String(format: "CHURN: launch footprint %.1f MB", footprintMB()))
        for cycle in 1...10 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                NSDocumentController.shared.openDocument(
                    withContentsOf: url, display: true
                ) { document, _, error in
                    guard let file = document as? GyeolDocumentFile else {
                        print("CHURN: open failed: \(error.map(String.init(describing:)) ?? "?")")
                        continuation.resume()
                        return
                    }
                    let box = WeakDocumentBox()
                    box.document = file
                    churnSurvivors.append(box)
                    Task { @MainActor in
                        // Let load settle, then close — the real cycle.
                        var waited = 0
                        while file.playback.loadState == .loading || file.playback.loadState == .empty {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            waited += 1
                            if waited > 100 { break }
                        }
                        file.close()
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        continuation.resume()
                    }
                }
            }
            let alive = churnSurvivors.filter { $0.document != nil }.count
            print(String(format: "CHURN: cycle %d — footprint %.1f MB, documents alive %d", cycle, footprintMB(), alive))
        }
        // Settle and final tally.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let alive = churnSurvivors.filter { $0.document != nil }.count
        print(String(format: "CHURN: final — footprint %.1f MB, documents alive %d of 10", footprintMB(), alive))
    }

    // MARK: - Menu gate (M2.3 r2)

    /// Walks the REAL menu bar and asserts every required document-menu
    /// item exists, carries its key equivalent, and validates as enabled
    /// with a document open. Exit 0 = PASS, 1 = FAIL (missing/disabled),
    /// 2 = UNVERIFIED (menu bar absent — never a pass, §4 rule 6).
    private static func runMenuProbe() {
        struct Requirement {
            let title: String
            let key: String
            let modifiers: NSEvent.ModifierFlags
        }
        let required: [Requirement] = [
            .init(title: "새 프로젝트", key: "n", modifiers: [.command]),
            .init(title: "열기…", key: "o", modifiers: [.command]),
            .init(title: "닫기", key: "w", modifiers: [.command]),
            .init(title: "저장", key: "s", modifiers: [.command]),
            .init(title: "다른 이름으로 저장…", key: "s", modifiers: [.command, .shift]),
            .init(title: "복제", key: "", modifiers: []),
            .init(title: "마지막 저장 상태로 되돌리기", key: "", modifiers: []),
            .init(title: "실행 취소", key: "z", modifiers: [.command]),
            .init(title: "실행 복귀", key: "z", modifiers: [.command, .shift]),
        ]
        guard let mainMenu = NSApp.mainMenu else {
            print("MENU-GATE: UNVERIFIED — no main menu in this environment")
            exit(2)
        }
        var flat: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            // update() runs menu validation so isEnabled is meaningful.
            menu.update()
            for item in menu.items {
                flat.append(item)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(mainMenu)
        var failures: [String] = []
        for requirement in required {
            guard let item = flat.first(where: { $0.title == requirement.title }) else {
                failures.append("missing: \(requirement.title)")
                continue
            }
            if !requirement.key.isEmpty {
                let mods = item.keyEquivalentModifierMask
                if item.keyEquivalent.lowercased() != requirement.key || mods != requirement.modifiers {
                    failures.append("wrong shortcut on \(requirement.title): '\(item.keyEquivalent)' \(mods)")
                }
            }
            if !item.isEnabled {
                failures.append("disabled with a document open: \(requirement.title)")
            }
            if item.action == nil {
                failures.append("no action wired: \(requirement.title)")
            }
        }
        if failures.isEmpty {
            print("MENU-GATE: PASS — \(required.count) required items present, enabled, and wired")
            exit(0)
        } else {
            failures.forEach { print("MENU-GATE: ✘ \($0)") }
            print("MENU-GATE: FAIL — \(failures.count) problem(s)")
            exit(1)
        }
    }

    // MARK: - G5 lifetime probe

    private weak var probedFile: GyeolDocumentFile?
    private weak var probedPlayback: PlaybackController?
    private weak var probedPlayer: AVPlayer?
    /// `--g5-leak`: the gate's SELF-TEST. Holding the document in a static
    /// is exactly the failure class the ownership gate exists to catch (an
    /// app-owned root in the Gyeol image); running the probe with this
    /// flag must end in OWNERSHIP: FAIL / exit 1, or the gate is
    /// decorative. A gate nobody has ever seen fail is untested.
    private static var deliberateLeakForGateTest: GyeolDocumentFile?

    private func runG5Probe(documentAt url: URL) {
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { [weak self] document, _, error in
            guard let self, let file = document as? GyeolDocumentFile else {
                print("G5-app: open failed: \(error.map { String(describing: $0) } ?? "wrong document class")")
                NSApp.terminate(nil)
                return
            }
            self.probedFile = file
            self.probedPlayback = file.playback
            self.probedPlayer = file.playback.player
            if CommandLine.arguments.contains("--g5-leak") {
                Self.deliberateLeakForGateTest = file
            }
            // `--g5-block-leak`: SELF-TEST of the classifier's BLOCK/
            // CLOSURE branch — the gate's primary use case (M2.1's failure
            // was an unremoved observer whose block held state). The run
            // loop retains the timer (a SYSTEM root), the timer retains
            // OUR block, the block strongly captures the document: rule 1
            // (region roots) sees nothing of ours, so only rule 2 can
            // catch this. Expect OWNERSHIP: FAIL / exit 1 naming the
            // block line.
            if CommandLine.arguments.contains("--g5-block-leak") {
                Timer.scheduledTimer(withTimeInterval: 3_600, repeats: true) { _ in
                    _ = file  // deliberate strong capture
                }
            }
            // Address dropped to a file so `leaks --traceTree` can name the
            // retainer when a table row reports ALIVE (stdout is buffered
            // when redirected, so print alone arrives too late).
            let addrInfo = "\(Unmanaged.passUnretained(file).toOpaque()) \(ProcessInfo.processInfo.processIdentifier)"
            try? addrInfo.write(
                toFile: "/tmp/gyeol-g5-addr.txt", atomically: true, encoding: .utf8)
            print("G5-app: opened \(url.lastPathComponent) document=\(addrInfo); waiting for load, then closing")
            // No strong capture of the document in this task: close is
            // reached through the weak probe (the open document is retained
            // by NSDocumentController until close), so the sampling below
            // measures the app's ownership and not this closure's.
            Task { @MainActor in
                // M2.2: close AFTER the load settles — a fixed 2 s close
                // raced the 3-hour fixture's composition build and measured
                // "close during in-flight load" (the load task's bounded
                // hold on the view), not the teardown the probe exists to
                // verify. The load duration is printed because it is a real
                // M2.2 number: document-open latency for the 3-hour case.
                let loadStart = CFAbsoluteTimeGetCurrent()
                var waitedMs = 0
                while self.probedPlayback?.loadState == .loading
                    || self.probedPlayback?.loadState == .empty {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    waitedMs += 250
                    if waitedMs > 120_000 { break }
                }
                print(String(
                    format: "G5-app: load settled (%@) in %.1f s; closing in 2 s",
                    String(describing: self.probedPlayback?.loadState),
                    CFAbsoluteTimeGetCurrent() - loadStart))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                // autoreleasepool is LOAD-BEARING (A-36 already recorded
                // "풀 자체가 측정 조건"): a main-actor Task job runs outside
                // any transient pool, so autoreleases inside close() would
                // otherwise land in main()'s bottom pool and drain only at
                // process exit — reading as a leak that is really the
                // harness's own calling context.
                autoreleasepool { self.probedFile?.close() }
                // `--g5-early`: SELF-TEST of the system-owned-survivor
                // branch (the branch whose classifier bug Codex found —
                // it had never been observed passing). Sample at ≈1 s,
                // inside the measured 3–60 s window where AppKit still
                // holds the closed window chain: the verdict must be PASS
                // with system-only roots. No cache-flush window here — the
                // retention is the fixture.
                if CommandLine.arguments.contains("--g5-early") {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    print("""
                    G5-app table t≈1s: document=\(self.probedFile != nil ? "ALIVE" : "freed") \
                    playback=\(self.probedPlayback != nil ? "ALIVE" : "freed") \
                    player=\(self.probedPlayer != nil ? "ALIVE" : "freed")
                    """)
                    if self.probedFile == nil && self.probedPlayback == nil && self.probedPlayer == nil {
                        // The early check needs a survivor; none at 1 s
                        // contradicts the recorded 3–60 s AppKit retention
                        // observation and must be REPORTED, not shrugged.
                        print("G5-app: ⚠️ early check found NO survivor at t≈1s — the recorded 3–60 s AppKit window retention did not reproduce; the system-owned branch was NOT exercised")
                    }
                    await self.finishG5Verdict(immediately: true)
                    return
                }
                // Flush AppKit's window caches (M2.2, measured with
                // `leaks --traceTree`): in a one-window probe process the
                // closed window stays referenced by AppKit globals —
                // NSApp's previous-key-window, drag-destination and
                // HIToolbox active-document registrations, and the main
                // thread's autorelease pool — for a NONDETERMINISTIC 3 to
                // 60+ seconds, document and player riding along. That is
                // AppKit's ownership, not the app's; a throwaway window
                // taking key displaces the caches so the table below
                // measures OUR ownership. In the real app another window
                // or app quit does this naturally.
                let flush = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 60, height: 40),
                    styleMask: [.titled], backing: .buffered, defer: false)
                flush.isReleasedWhenClosed = false
                flush.makeKeyAndOrderFront(nil)
                try? await Task.sleep(nanoseconds: 200_000_000)
                flush.close()
                print("G5-app: close() returned; sampling in 3 s")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                print("""
                G5-app table t≈3s: document=\(self.probedFile != nil ? "ALIVE" : "freed") \
                playback=\(self.probedPlayback != nil ? "ALIVE" : "freed") \
                player=\(self.probedPlayer != nil ? "ALIVE" : "freed")
                """)
                // THE GATE (M2.2 revision): OWNERSHIP, not timing. The
                // v0.20 recommendation to gate on "freed shortly after
                // close" measured activation state and AppKit's window
                // caching, not our code — leaks --traceTree on a
                // still-ALIVE document showed 46 roots, every one through
                // system globals (previous-key-window, drag-destination /
                // HIToolbox registrations, the root autorelease pool) and
                // ZERO owned by app code. AppKit holds the closed window
                // for a nondeterministic 3-60+ s; we neither control nor
                // need to control that. The contract worth gating on:
                // after close, NO retain path is owned by app code.
                await self.finishG5Verdict()
            }
        }
    }


    /// The shared verdict tail of the g5 probe: informational late sample,
    /// then the OWNERSHIP gate over whatever survived, then exit.
    /// `immediately` is the early self-test's requirement: it must run the
    /// gate WHILE AppKit still holds the chain — the first version slept
    /// 7 s here first, the objects freed meanwhile, and the branch under
    /// test silently degraded to the trivial freed-PASS again.
    private func finishG5Verdict(immediately: Bool = false) async {
        if !immediately,
           self.probedFile != nil || self.probedPlayback != nil || self.probedPlayer != nil {
            // One informational row for late-but-clean teardowns;
            // the verdict below does not depend on it.
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            print("""
            G5-app table t≈10s: document=\(self.probedFile != nil ? "ALIVE" : "freed") \
            playback=\(self.probedPlayback != nil ? "ALIVE" : "freed") \
            player=\(self.probedPlayer != nil ? "ALIVE" : "freed")
            """)
        }
        var appOwnedFindings: [String] = []
        var unverified = false
        let survivors: [(String, AnyObject)] = [
            ("document", self.probedFile as AnyObject?),
            ("playback", self.probedPlayback as AnyObject?),
            ("player", self.probedPlayer as AnyObject?),
        ].compactMap { label, object in object.map { (label, $0) } }
        for (label, object) in survivors {
            let address = "\(Unmanaged.passUnretained(object).toOpaque())"
            guard let report = Self.ownershipReport(address: address) else {
                unverified = true
                print("G5-app: could not run leaks for \(label) — ownership UNVERIFIED")
                continue
            }
            if report.appOwnedLines.isEmpty {
                print("G5-app: \(label) ALIVE but held only by system roots (\(report.rootCount) roots)")
            } else {
                appOwnedFindings.append(contentsOf: report.appOwnedLines.map { "\(label): \($0)" })
                print("G5-app: APP-OWNED retain path(s) hold \(label):")
                report.appOwnedLines.forEach { print("    \($0)") }
                print(report.tree)
            }
        }
        // The KIND of pass is part of the verdict. This gate has already
        // been a green light that measured nothing three separate times —
        // the un-activated v0.20 probe, the always-ALIVE headless suite,
        // and the first --g5-early's seven-second wait — and every one of
        // them was invisible precisely because a pass that classified
        // nothing looked identical to a pass that classified survivors.
        if !appOwnedFindings.isEmpty {
            print("G5-app OWNERSHIP: FAIL — \(appOwnedFindings.count) app-owned retain path(s) after close")
            exit(1)
        } else if unverified {
            print("G5-app OWNERSHIP: UNVERIFIED — leaks unavailable or unparseable; not a pass")
            exit(2)
        } else if survivors.isEmpty {
            print("G5-app OWNERSHIP: PASS (trivial) — all three freed before sampling; the classifier did NOT run")
        } else {
            print("G5-app OWNERSHIP: PASS (substantive) — \(survivors.count) survivor(s) classified, every root system-owned; deallocation timing is AppKit's, not ours")
        }
        NSApp.terminate(nil)
    }

    /// Runs `leaks --traceTree` against THIS process for one address and
    /// hands the output to `G5OwnershipClassifier.classify` (the pure,
    /// unit-tested parser — see its header for the classification rules
    /// and the gate's actual coverage statement).
    ///
    /// Returns nil — UNVERIFIED, never "clean" — when leaks cannot run OR
    /// the classifier cannot parse its output.
    ///
    /// leaks suspends this process briefly while it snapshots; the blocked
    /// read below resumes when the snapshot completes.
    private static func ownershipReport(address: String) -> G5OwnershipClassifier.Report? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = [
            "--traceTree=\(address)",
            "\(ProcessInfo.processInfo.processIdentifier)",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let tree = String(data: data, encoding: .utf8) else {
            return nil
        }
        // The image name is derived, not hardcoded (the D25 lesson, and
        // the first version of this parser missed the bare-image-name form
        // of OUR OWN binary): a rename must not silently disable the gate.
        return G5OwnershipClassifier.classify(
            tree: tree, imageName: ProcessInfo.processInfo.processName)
    }
}
