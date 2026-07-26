import AVFoundation
import AppKit
import Foundation
import GyeolCore
import SwiftUI
import Testing

// G5 MEASUREMENT (not a fix): the document → windowController → window →
// NSHostingController → DocumentView.file → document cycle relies on
// NSDocument.close() breaking it. Open and close repeatedly and confirm
// the document actually deallocates.
//
// VERDICT (M2.1 reconciliation round): the "leak" is a HARNESS ARTIFACT.
// Ground truth is the running app — `Gyeol --g5-probe <package>` opens and
// closes a real document and logs deinit: document, controller, and player
// all freed immediately after close(). The GUI memory graph agrees (no
// GyeolDocumentFile instance after close). Only THIS headless environment
// keeps the trio alive, and it survives every harness correction tried:
// scope isolation (creation+close in a function returning weak refs),
// autoreleasepool, and NSDocumentController registration. Two diagnosis
// rounds were spent treating this as an app defect; it is not one. The
// suite stays as a record and as the instrument that measured the
// DIFFERENCE between environments — its failures must never again be read
// as app leaks without an app-probe cross-check.

@Suite @MainActor struct DocumentLifecycleMeasurement {
    /// M2.3 MEASURED ADDITION: a document that took a REAL EDIT (an undo
    /// group through `applyEdit`) is retained after close by AppKit's own
    /// `-[NSDocument _scheduleAutosavingAfterDelay:reset:]` timer block —
    /// traced with `leaks --traceTree`; the root is an AppKit
    /// `__NSMallocBlock__` on an NSTimer, i.e. SYSTEM-owned under the g5
    /// ownership doctrine (M2.2). The manual undo group is what triggers
    /// the scheduling (`groupsByEvent = false`, D27); the default run-loop
    /// grouping does not — measured, both ways, in a minimal NSDocument
    /// probe. Neither `removeAllActions` nor `updateChangeCount(.changeCleared)`
    /// unschedules it, and no public API does. Deallocation timing after
    /// an edited close therefore belongs to AppKit's autosave timer; the
    /// strict isolation tests below deliberately stay on the M2.2-era
    /// dirty condition (change count only, no undo group) so they keep
    /// measuring what they measured.
    @Test func editedDocumentRidesAppKitAutosaveTimerAfterClose() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.applyEdit(.empty, actionName: "edit")
            weakFile = file
            file.close()
        }
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        withKnownIssue("AppKit autosave timer holds the edited document past close (system-owned; measured)") {
            #expect(weakFile == nil)
        }
    }

    /// Isolation stage 1: no window at all. If this leaks, the @Observable
    /// macro or NSDocument machinery retains the document by itself.
    @Test func documentWithoutWindowDeallocates() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
            weakFile = file
            file.close()
        }
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(weakFile == nil, "document leaked with no window involved")
    }

    /// Isolation stage 2: a window with a PLAIN SwiftUI view (no
    /// DocumentView, no PlaybackController, no observation of the file).
    @Test func documentWithPlainWindowDeallocates() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
            let window = NSWindow(contentViewController: NSHostingController(rootView: Text("x")))
            file.addWindowController(NSWindowController(window: window))
            weakFile = file
            file.close()
        }
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        #expect(weakFile == nil, "document leaked with a plain hosted view")
    }

    private struct ObservationOnlyView: View {
        let file: GyeolDocumentFile
        var body: some View { Text("\(file.document.markers.count)") }
    }

    private struct TaskView: View {
        let file: GyeolDocumentFile
        var body: some View {
            Text("\(file.document.markers.count)").task(id: file.document) {}
        }
    }

    private struct ControllerView: View {
        let file: GyeolDocumentFile
        @State private var playback = PlaybackController()
        var body: some View { Text("\(file.document.markers.count)") }
    }

    private func measure(_ makeView: (GyeolDocumentFile) -> some View) -> Bool {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
            let window = NSWindow(contentViewController: NSHostingController(rootView: AnyView(makeView(file))))
            file.addWindowController(NSWindowController(window: window))
            weakFile = file
            file.close()
        }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return weakFile == nil
    }

    private struct RealTaskView: View {
        let file: GyeolDocumentFile
        @State private var playback = PlaybackController()
        var body: some View {
            Text("\(file.document.markers.count)")
                .task(id: file.document) {
                    await playback.load(document: file.document, mediaURLs: [:])
                }
        }
    }

    private struct LayerOnlyView: View {
        let file: GyeolDocumentFile
        @State private var playback = PlaybackController()
        var body: some View { PlayerLayerView(player: playback.player) }
    }

    @Test func isolateLeakSource() {
        print("G5-isolate: observation-only deallocates: \(measure { ObservationOnlyView(file: $0) })")
        print("G5-isolate: +task deallocates: \(measure { TaskView(file: $0) })")
        print("G5-isolate: +controller deallocates: \(measure { ControllerView(file: $0) })")
        print("G5-isolate: +real-load-task deallocates: \(measure { RealTaskView(file: $0) })")
        print("G5-isolate: +player-layer deallocates: \(measure { LayerOnlyView(file: $0) })")
        print("G5-isolate: +sleep-task deallocates: \(measure { SleepTaskView(file: $0) })")
        print("G5-isolate: +load-without-file-read deallocates: \(measure { DetachedLoadView(file: $0) })")
        print("G5-isolate: +state-writes-only deallocates: \(measure { StateWriteView(file: $0) })")
    }

    private struct StateWriteView: View {
        let file: GyeolDocumentFile
        @State private var playback = PlaybackController()
        var body: some View {
            Text("\(file.document.markers.count)")
                .task(id: file.document) {
                    playback.reportLoadFailure("probe")
                }
        }
    }

    private struct SleepTaskView: View {
        let file: GyeolDocumentFile
        var body: some View {
            Text("\(file.document.markers.count)")
                .task(id: file.document) { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
    }

    private struct DetachedLoadView: View {
        let file: GyeolDocumentFile
        @State private var playback = PlaybackController()
        var body: some View {
            Text("\(file.document.markers.count)")
                .task(id: file.document) {
                    await playback.load(document: .empty, mediaURLs: [:])
                }
        }
    }

    private struct LifetimeProbes {
        weak var file: GyeolDocumentFile?
        weak var playback: PlaybackController?
        weak var player: AVPlayer?
        weak var item: AVPlayerItem?
        weak var window: NSWindow?
        weak var windowController: NSWindowController?
        weak var hosting: NSViewController?
    }

    /// Task 3 (harness audit): creation, settling, and close are confined
    /// to THIS function, which returns only weak references — debug builds
    /// keep strong locals alive to end of scope, so the measuring scope
    /// must never be the scope that owned the document. The
    /// `viaDocumentController` leg reproduces how the app actually obtains
    /// a document (registered with NSDocumentController; close() also
    /// deregisters), which the direct leg does not.
    private func openSettleClose(viaDocumentController: Bool) -> LifetimeProbes {
        // The pool matters as much as the scope: without it, autoreleased
        // AppKit references pin the window chain in the runner's outer pool
        // (measured — window/hosting flipped to ALIVE when the pool was
        // dropped from this harness).
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
            if viaDocumentController {
                NSDocumentController.shared.addDocument(file)
            }
            file.makeWindowControllers()
            // Let the view's task run so the composition load wires the
            // machinery — the configuration that measured as leaking.
            for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            var probes = LifetimeProbes()
            probes.file = file
            probes.playback = file.playback
            probes.player = file.playback.player
            probes.item = file.playback.player.currentItem
            probes.windowController = file.windowControllers.first
            probes.window = probes.windowController?.window
            probes.hosting = probes.window?.contentViewController
            file.close()
            return probes
        }
    }

    /// WHAT survives (not why), and does it EVENTUALLY go away? Sampled
    /// right after close, after 0.5 s, and after 3 s of run-loop draining —
    /// AVFoundation tears players down asynchronously, and an object alive
    /// at t=0 is not yet a leak.
    @Test func lifetimeTableAfterClose() throws {
        for viaController in [false, true] {
            let path = viaController ? "NSDocumentController" : "direct"
            let probes = openSettleClose(viaDocumentController: viaController)

            func table(_ label: String) {
                print("""
                G5-table [\(path)] \(label): document=\(probes.file != nil ? "ALIVE" : "freed") \
                playback=\(probes.playback != nil ? "ALIVE" : "freed") \
                player=\(probes.player != nil ? "ALIVE" : "freed") \
                item=\(probes.item != nil ? "ALIVE" : "freed") \
                window=\(probes.window != nil ? "ALIVE" : "freed") \
                windowController=\(probes.windowController != nil ? "ALIVE" : "freed") \
                hosting=\(probes.hosting != nil ? "ALIVE" : "freed")
                """)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            table("t≈0")
            for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            table("t≈0.5s")
            for _ in 0..<50 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            table("t≈3s")
        }
    }

    /// Ordering variant: let the view's task actually run BEFORE closing.
    /// If this deallocates while the close-immediately rounds leak, the
    /// leak is specific to a task queued against an already-closed window.
    @Test func settledThenClosedDocumentDeallocates() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
            file.makeWindowControllers()
            weakFile = file
            for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            file.close()
        }
        for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // KNOWN ISSUE (M2.1, RESOLVED as harness artifact — see the header
        // comment): the running app frees the document at close; only this
        // headless environment pins it. The expectation is kept so the
        // artifact's disappearance (an SDK or harness change) gets noticed.
        withKnownIssue("M2.1 G5 verdict: harness artifact — the running app frees document/controller/player at close (--g5-probe); only the headless environment pins the document") {
            #expect(weakFile == nil, "document leaked even when closed after settling")
        }
    }

    @Test func closedDocumentsDeallocate() throws {
        var leaked = 0
        for round in 0..<5 {
            weak var weakFile: GyeolDocumentFile?
            weak var weakWindow: NSWindow?
            autoreleasepool {
                let file = GyeolDocumentFile()
                file.updateChangeCount(.changeDone)  // M2.2-era dirty condition; see editedDocumentNote below
                file.makeWindowControllers()
                weakFile = file
                weakWindow = file.windowControllers.first?.window
                file.close()
            }
            // AppKit defers some releases to later runloop turns, and the
            // real DocumentView runs an async reload whose task must land
            // before retention can be judged.
            for _ in 0..<25 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            if weakFile != nil {
                leaked += 1
                print("G5: document from round \(round) still alive after close()")
            }
            if weakWindow != nil {
                print("G5: window from round \(round) still alive after close()")
            }
        }
        // KNOWN ISSUE (M2.1, RESOLVED as harness artifact) — see the header
        // comment and settledThenClosedDocumentDeallocates.
        withKnownIssue("M2.1 G5 verdict: harness artifact — the running app frees document/controller/player at close (--g5-probe); only the headless environment pins the document") {
            #expect(leaked == 0, "\(leaked)/5 documents leaked after close()")
        }
    }
}
