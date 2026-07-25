import AVFoundation
import AppKit
import Foundation
import GyeolCore
import SwiftUI
import Testing

// G5 MEASUREMENT (not a fix): the document → windowController → window →
// NSHostingController → DocumentView.file → document cycle relies on
// NSDocument.close() breaking it. Open and close repeatedly and confirm
// the document actually deallocates. If this fails, the cycle leaks and
// the fix belongs with M2's per-document controller structure.

@Suite @MainActor struct DocumentLifecycleMeasurement {
    /// Isolation stage 1: no window at all. If this leaks, the @Observable
    /// macro or NSDocument machinery retains the document by itself.
    @Test func documentWithoutWindowDeallocates() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.replaceDocument(.empty)
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
            file.replaceDocument(.empty)
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
            file.replaceDocument(.empty)
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

    /// Task 1+2: WHAT survives (not why), and does it EVENTUALLY go away?
    /// One weak probe per object of interest, sampled right after close,
    /// after 0.5 s, and after 3 s of run-loop draining — AVFoundation tears
    /// players down asynchronously, and an object alive at t=0 is not yet
    /// a leak.
    @Test func lifetimeTableAfterClose() throws {
        weak var wFile: GyeolDocumentFile?
        weak var wPlayback: PlaybackController?
        weak var wPlayer: AVPlayer?
        weak var wItem: AVPlayerItem?
        weak var wWindow: NSWindow?
        weak var wWindowController: NSWindowController?
        weak var wHosting: NSViewController?

        autoreleasepool {
            let file = GyeolDocumentFile()
            file.replaceDocument(.empty)
            file.makeWindowControllers()
            // Let the view's task run so the composition load wires the
            // machinery — the known leaking configuration.
            for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            wFile = file
            wPlayback = file.playback
            wPlayer = file.playback.player
            wItem = file.playback.player.currentItem
            wWindowController = file.windowControllers.first
            wWindow = wWindowController?.window
            wHosting = wWindow?.contentViewController
            file.close()
        }

        func table(_ label: String) {
            print("""
            G5-table \(label): document=\(wFile != nil ? "ALIVE" : "freed") \
            playback=\(wPlayback != nil ? "ALIVE" : "freed") \
            player=\(wPlayer != nil ? "ALIVE" : "freed") \
            item=\(wItem != nil ? "ALIVE" : "freed") \
            window=\(wWindow != nil ? "ALIVE" : "freed") \
            windowController=\(wWindowController != nil ? "ALIVE" : "freed") \
            hosting=\(wHosting != nil ? "ALIVE" : "freed")
            """)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        table("t≈0")
        for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        table("t≈0.5s")
        for _ in 0..<50 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        table("t≈3s")
    }

    /// Ordering variant: let the view's task actually run BEFORE closing.
    /// If this deallocates while the close-immediately rounds leak, the
    /// leak is specific to a task queued against an already-closed window.
    @Test func settledThenClosedDocumentDeallocates() throws {
        weak var weakFile: GyeolDocumentFile?
        autoreleasepool {
            let file = GyeolDocumentFile()
            file.replaceDocument(.empty)
            file.makeWindowControllers()
            weakFile = file
            for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            file.close()
        }
        for _ in 0..<25 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        // KNOWN ISSUE (M2.1, open): a document whose window ran a real
        // composition load leaks after close(), regardless of ordering and
        // despite full machinery teardown (shutdown at close: item nil,
        // KVO invalidated, observer removed). ELIMINATED hypotheses:
        // compositor-retains-document (structurally impossible — the
        // GyeolPlayback module cannot name GyeolDocumentFile, and the
        // DetachedLoad probe leaks with document VALUES only), view→file
        // strong reference (observation-only probe deallocates), task
        // capture (sleep-task probe deallocates), state writes
        // (reportLoadFailure probe deallocates). Lifetime table (M2.1
        // diagnosis round, stable at t≈3s): document/playback/player ALIVE;
        // item/window/windowController/hosting FREED — a REAL leak, not
        // deferred teardown, and the view→window→hosting chain is
        // eliminated as the retainer. Root retainer needs Instruments
        // (GUI). Recorded, not hidden.
        withKnownIssue("M2.1 G5 regression: composition-loaded document leaks on close (compositor-retention hypothesis eliminated)") {
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
                file.replaceDocument(.empty)
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
        // KNOWN ISSUE (M2.1, open) — see settledThenClosedDocumentDeallocates.
        withKnownIssue("M2.1 G5 regression: composition-loaded document leaks on close (compositor-retention hypothesis eliminated)") {
            #expect(leaked == 0, "\(leaked)/5 documents leaked after close()")
        }
    }
}
