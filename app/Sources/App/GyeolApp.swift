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
            runG5Probe(documentAt: probeURL)
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
            print("G5-app: opened \(url.lastPathComponent); closing in 2 s")
            // No strong capture of the document in this task: close is
            // reached through the weak probe (the open document is retained
            // by NSDocumentController until close), so the sampling below
            // measures the app's ownership and not this closure's.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.probedFile?.close()
                print("G5-app: close() returned; sampling in 3 s")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                print("""
                G5-app table t≈3s: document=\(self.probedFile != nil ? "ALIVE" : "freed") \
                playback=\(self.probedPlayback != nil ? "ALIVE" : "freed") \
                player=\(self.probedPlayer != nil ? "ALIVE" : "freed")
                """)
                NSApp.terminate(nil)
            }
        }
    }
}
