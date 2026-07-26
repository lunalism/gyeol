import Foundation
import GyeolCore
import Testing

// M2.3 vertical slice, app half: undo through the single mutation site,
// selection in the payload, and the byte-identity loop the round's
// verification demands.

@MainActor
private func makeSplittableFile() throws -> (GyeolDocumentFile, TrackID, ClipID) {
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
    // The seed edit is not part of the scenarios; clear it from the stack.
    file.undoManager?.removeAllActions()
    return (file, trackID, clipID)
}

@Suite @MainActor struct SplitUndoTests {
    /// The round's verification requirement: split + undo, MANY times, and
    /// the saved bytes never drift from the original. This is §4.2's
    /// byte-identity discipline applied to the first editing operation —
    /// and it is what proves undo restores the VALUE, not an equivalent.
    @Test func fiftySplitUndoCyclesStayByteIdentical() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        let baseline = try GyeolCoding.makeEncoder().encode(file.document)
        for cycle in 0..<50 {
            let edited = try file.document.splittingClip(
                clipID, inTrack: trackID, at: DocumentTime(ticks: 240_000))
            file.applyEdit(edited, actionName: "클립 분할")
            #expect(file.document.tracks[0].clips.count == 2)
            file.undoManager?.undo()
            #expect(file.document.tracks[0].clips.count == 1)
            let bytes = try GyeolCoding.makeEncoder().encode(file.document)
            #expect(bytes == baseline, "cycle \(cycle) drifted from baseline")
        }
    }

    @Test func redoRestoresTheSplitAndUndoLifts() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        let edited = try file.document.splittingClip(
            clipID, inTrack: trackID, at: DocumentTime(ticks: 240_000))
        let editedBytes = try GyeolCoding.makeEncoder().encode(edited)
        file.applyEdit(edited, actionName: "클립 분할")
        file.undoManager?.undo()
        file.undoManager?.redo()
        // Redo restores the exact edited VALUE — same identity for the
        // right piece, byte-for-byte (no UUID regeneration on redo).
        #expect(try GyeolCoding.makeEncoder().encode(file.document) == editedBytes)
    }

    /// D27: the payload carries the selection as it was immediately before
    /// the edit, and undo restores it. The restored UUID structurally
    /// exists because the document is back to the value containing it.
    @Test func undoRestoresSelectionFromBeforeTheEdit() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        file.selectedClip = .init(trackID: trackID, clipID: clipID)
        let edited = try file.document.splittingClip(
            clipID, inTrack: trackID, at: DocumentTime(ticks: 240_000))
        file.applyEdit(edited, actionName: "클립 분할")
        // User clicks away after the edit; undo must bring the OLD
        // selection back, not keep this one.
        let stranger = file.document.tracks[0].clips[1].id
        file.selectedClip = .init(trackID: trackID, clipID: stranger)
        file.undoManager?.undo()
        #expect(file.selectedClip == .init(trackID: trackID, clipID: clipID))
    }

    /// D27: selection changes alone create no undo step.
    @Test func selectionChangeAloneCreatesNoUndoStep() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        #expect(file.undoManager?.canUndo == false)
        file.selectedClip = .init(trackID: trackID, clipID: clipID)
        file.selectedClip = nil
        #expect(file.undoManager?.canUndo == false)
    }

    /// D27's explicit-over-default configuration, asserted so a regression
    /// to the defaults is loud.
    @Test func undoManagerConfigurationIsExplicit() throws {
        let (file, _, _) = try makeSplittableFile()
        #expect(file.undoManager?.groupsByEvent == false)
        #expect(file.undoManager?.levelsOfUndo == 100)
    }

    /// One transaction with two operations = ONE undo step.
    @Test func multiOperationTransactionIsOneUndoStep() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        let baseline = try GyeolCoding.makeEncoder().encode(file.document)
        let edited = try file.document.applyingEdit { txn in
            try txn.splitClip(clipID, inTrack: trackID, at: DocumentTime(ticks: 240_000))
            try txn.splitClip(clipID, inTrack: trackID, at: DocumentTime(ticks: 120_000))
        }
        file.applyEdit(edited, actionName: "이중 분할")
        #expect(file.document.tracks[0].clips.count == 3)
        file.undoManager?.undo()
        #expect(try GyeolCoding.makeEncoder().encode(file.document) == baseline)
        #expect(file.undoManager?.canUndo == false)
    }

    /// The blade's gating: no selection → cannot split; playhead outside
    /// the allowed range → cannot split. The action itself never throws on
    /// the enabled path (D26).
    @Test func bladeGatingFollowsTheAllowedRange() throws {
        let (file, trackID, clipID) = try makeSplittableFile()
        #expect(!file.canSplitSelectionAtPlayhead)  // no selection
        file.selectedClip = .init(trackID: trackID, clipID: clipID)
        // Playhead at frame 0 → tick 0, before the clip: outside range.
        #expect(!file.canSplitSelectionAtPlayhead)
        file.splitSelectedClipAtPlayhead()  // must be a no-op, not a throw
        #expect(file.document.tracks[0].clips.count == 1)
    }
}
