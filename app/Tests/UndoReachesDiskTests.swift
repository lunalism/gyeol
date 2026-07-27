import Foundation
import GyeolCore
import Testing

/// M2.3 round 2 task 2: autosave after a SPLIT is confirmed (the fixture
/// grew 900 → 902 clips on disk), but an UNDO must equally mark the
/// document edited and reach disk — otherwise the file keeps the undone
/// state forever. NSDocument's automatic change counting is driven by
/// undo-manager notifications (D27/D7); this asserts that chain holds
/// through our manual groups (`groupsByEvent = false`).
@Suite @MainActor struct UndoReachesDiskTests {
    /// NSDocument applies undo-driven change counts on a RUN LOOP
    /// CHECKPOINT, not synchronously at group close (measured in a minimal
    /// probe: right after an edit `isDocumentEdited` is still false, and a
    /// save awaited immediately afterwards absorbs the pending +1 AFTER
    /// clearing, leaving the doc re-marked edited). Real user timing always
    /// has run loop turns between edit and save; the spins reproduce that.
    private func settleChangeCount() {
        for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test func undoMarksDirtyAndTheSaveRestoresPreviousBytes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-undo-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let packageURL = dir.appendingPathComponent("UndoDisk.gyeol")

        let trackID = TrackID()
        let clipID = ClipID()
        let document = GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps30, renderWidth: 1280, renderHeight: 720),
            tracks: [Track(id: trackID, kind: .video, clips: [
                Clip(id: clipID, timelineStart: DocumentTime(ticks: 60_000),
                     duration: DocumentTime(ticks: 480_000),
                     source: .generator(identifier: "test", parameters: .object([:])))
            ])],
            duration: DocumentTime(ticks: 600_000))

        let file = GyeolDocumentFile()
        file.applyEdit(document, actionName: "seed")
        file.undoManager?.removeAllActions()
        settleChangeCount()
        try await file.save(to: packageURL, ofType: GyeolDocumentFile.documentType, for: .saveAsOperation)
        settleChangeCount()
        let bodyURL = packageURL.appendingPathComponent(GyeolDocumentFile.bodyFilename)
        let savedBytes = try Data(contentsOf: bodyURL)

        // Split → the document must be edited; save it.
        let edited = try file.document.splittingClip(
            clipID, inTrack: trackID, at: DocumentTime(ticks: 240_000))
        file.applyEdit(edited, actionName: "클립 분할")
        settleChangeCount()
        #expect(file.isDocumentEdited, "an edit through the single site must mark the document edited")
        try await file.save(to: packageURL, ofType: GyeolDocumentFile.documentType, for: .saveOperation)
        settleChangeCount()
        let splitBytes = try Data(contentsOf: bodyURL)
        #expect(splitBytes != savedBytes)
        #expect(!file.isDocumentEdited)

        // Undo → THE assertion of this task: the undone document is dirty
        // again, and saving writes the pre-split bytes back.
        file.undoManager?.undo()
        settleChangeCount()
        #expect(file.isDocumentEdited, "undo must mark the document edited or the undone state never reaches disk")
        try await file.save(to: packageURL, ofType: GyeolDocumentFile.documentType, for: .saveOperation)
        settleChangeCount()
        #expect(try Data(contentsOf: bodyURL) == savedBytes, "saving after undo must restore the previous on-disk state")
        #expect(!file.isDocumentEdited)
        file.close()
    }
}
