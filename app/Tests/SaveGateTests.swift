import Foundation
import GyeolCore
import Testing

@Suite @MainActor struct SaveGateTests {
    /// M2.3 r2 task 5 + §4 rule 1 in one test: the pre-save gate REFUSES a
    /// document the decoder would reject — proving simultaneously that the
    /// gate works and that it can fail. Without it, a local-validation gap
    /// in some future operation writes a file that never opens again.
    @Test func saveRefusesADocumentThatCouldNotBeReopened() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-savegate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let packageURL = dir.appendingPathComponent("Broken.gyeol")

        let file = GyeolDocumentFile()
        file.applyEdit(.empty, actionName: "seed")
        file.applyEdit(._danglingMediaDocumentForGateTests(), actionName: "corrupt")
        await #expect(throws: (any Error).self) {
            try await file.save(
                to: packageURL, ofType: GyeolDocumentFile.documentType, for: .saveAsOperation)
        }
        // Nothing may have been written: a refused save leaves no package.
        #expect(!FileManager.default.fileExists(atPath: packageURL.path))
        // The refusal names the invariant (G7 diagnostics discipline).
        do {
            _ = try file.fileWrapper(ofType: GyeolDocumentFile.documentType)
            Issue.record("fileWrapper must refuse")
        } catch {
            let reason = (error as NSError).userInfo[NSLocalizedFailureReasonErrorKey] as? String
            #expect(reason?.contains("absent from the media pool") == true)
        }
        file.undoManager?.removeAllActions()
        file.close()
    }

    /// A valid document still saves — the gate's pass branch.
    @Test func saveGatePassesAValidDocument() throws {
        let file = GyeolDocumentFile()
        file.applyEdit(.empty, actionName: "seed")
        #expect(throws: Never.self) {
            _ = try file.fileWrapper(ofType: GyeolDocumentFile.documentType)
        }
        file.undoManager?.removeAllActions()
        file.close()
    }

    /// M2.3 r2 task 6: a no-op applyEdit registers NO undo group — an
    /// empty group is enough to schedule AppKit's autosave timer
    /// (measured, round 1), and an undo step that visibly does nothing is
    /// wrong regardless.
    @Test func noOpEditRegistersNoUndoGroup() throws {
        let file = GyeolDocumentFile()
        file.applyEdit(.empty, actionName: "seed")
        file.undoManager?.removeAllActions()
        #expect(file.undoManager?.canUndo == false)
        file.applyEdit(file.document, actionName: "no-op")
        #expect(file.undoManager?.canUndo == false)
        #expect(!file.isDocumentEdited)
        file.close()
    }
}
