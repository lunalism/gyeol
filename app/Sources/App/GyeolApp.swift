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
        // G5 ground truth (M2.1 task 2): `--g5-probe <path>` runs the real
        // open → close cycle in the real app process and prints a lifetime
        // table, because the headless measurement and the GUI memory graph
        // disagreed and only the app itself can arbitrate.
        if let probeURL = Self.g5ProbeURL() {
            // Launched from a shell the app is not activated, the document
            // window never actually appears, and the probe silently
            // measures the A-36 headless artifact instead of the app
            // (reproduced in M2.2: an un-activated baseline HEAD reports
            // ALIVE at t≈3s). Activation restores the probe's documented
            // precondition — a window that is really on screen.
            NSApp.activate(ignoringOtherApps: true)
            runG5Probe(documentAt: probeURL)
            return
        }
        // M2.3 r2: --menu-probe asserts the document menu the user relies
        // on actually EXISTS with a document open — nobody opened the File
        // menu for two milestones and ⌘S silently did nothing (G12 gap).
        // Same spirit as --g5-probe: the running app is the only place the
        // real menu bar exists.
        if CommandLine.arguments.contains("--menu-probe") {
            NSApp.activate(ignoringOtherApps: true)
            NSDocumentController.shared.newDocument(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                Self.runMenuProbe()
            }
            return
        }
        // M2.3 r2 task 6: --churn-probe <pkg> opens and closes the package
        // ten times, sampling resident footprint and live-document count —
        // the autosave-timer retention is system-owned (M2.2 doctrine),
        // but ownership and RESOURCE CONSUMPTION are different questions,
        // and on the 8GB floor (D3) a 48–92MB document accumulating per
        // close would matter.
        if let flag = CommandLine.arguments.firstIndex(of: "--churn-probe"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await Self.runChurnProbe(documentAt: url)
                NSApp.terminate(nil)
            }
            return
        }
        // M2.2 measurement harness — same rationale as --g5-probe: the
        // running app process is the only environment whose numbers count.
        if let probe = TimelineProbe.arguments() {
            Task { @MainActor in
                await TimelineProbe.run(packageURL: probe.packageURL, minutes: probe.minutes)
                NSApp.terminate(nil)
            }
            return
        }
        // The AppKit document lifecycle would do this on its own; under the
        // SwiftUI lifecycle it is explicit: launching without a document
        // opens an untitled one.
        if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
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

    private static func g5ProbeURL() -> URL? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--g5-probe"), args.indices.contains(flag + 1) else {
            return nil
        }
        return URL(fileURLWithPath: args[flag + 1])
    }

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
