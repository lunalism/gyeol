import AppKit
import Foundation
import GyeolCore
import Testing

// G5 MEASUREMENT (not a fix): the document → windowController → window →
// NSHostingController → DocumentView.file → document cycle relies on
// NSDocument.close() breaking it. Open and close repeatedly and confirm
// the document actually deallocates. If this fails, the cycle leaks and
// the fix belongs with M2's per-document controller structure.

@Suite @MainActor struct DocumentLifecycleMeasurement {
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
            // AppKit defers some releases to later runloop turns.
            for _ in 0..<5 {
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
        #expect(leaked == 0, "\(leaked)/5 documents leaked after close()")
    }
}
