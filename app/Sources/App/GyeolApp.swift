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

    // MARK: - G5 lifetime probe

    private weak var probedFile: GyeolDocumentFile?
    private weak var probedPlayback: PlaybackController?
    private weak var probedPlayer: AVPlayer?

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
                // M2.2 extra samples: with many-clip compositions the whole
                // window chain (window → windowController → document →
                // controller → player) deallocates LATE, not never —
                // AVFoundation/CA teardown of a segment-heavy item is
                // asynchronous. The later rows tell bounded-late apart from
                // leaked; only "still ALIVE at the last row" is a failure.
                for (label, delay) in [("t≈10s", UInt64(7)), ("t≈30s", 20), ("t≈60s", 30)] {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    print("""
                    G5-app table \(label): document=\(self.probedFile != nil ? "ALIVE" : "freed") \
                    playback=\(self.probedPlayback != nil ? "ALIVE" : "freed") \
                    player=\(self.probedPlayer != nil ? "ALIVE" : "freed")
                    """)
                    if self.probedFile == nil && self.probedPlayback == nil && self.probedPlayer == nil {
                        break
                    }
                }
                NSApp.terminate(nil)
            }
        }
    }
}
