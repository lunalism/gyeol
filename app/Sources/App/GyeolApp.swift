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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The AppKit document lifecycle would do this on its own; under the
        // SwiftUI lifecycle it is explicit: launching without a document
        // opens an untitled one.
        if NSDocumentController.shared.documents.isEmpty {
            NSDocumentController.shared.newDocument(nil)
        }
    }
}
