import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) -> DocumentTime { DocumentTime(ticks: ticks) }

/// A 30fps project (frame = 4,000 ticks) holding a 24fps-sourced media
/// clip — the mixed-rate shape the three-hour fixture uses (§6.2's
/// source/project separation must keep a consumer).
private func makeDocument(
    clipStart: Int64 = 60_000, clipDuration: Int64 = 480_000, sourceStart: Int64 = 0
) -> (GyeolDocument, TrackID, ClipID, MediaID) {
    let mediaID = MediaID()
    let trackID = TrackID()
    let clipID = ClipID()
    let document = GyeolDocument(
        schemaVersion: .current,
        settings: ProjectSettings(frameRate: .fps30, renderWidth: 1280, renderHeight: 720),
        media: [mediaID: MediaReference(
            relativePath: "clip24.mov", displayName: "clip24.mov",
            duration: docTime(480_000))],
        tracks: [Track(id: trackID, kind: .video, clips: [
            Clip(
                id: clipID,
                timelineStart: docTime(clipStart),
                duration: docTime(clipDuration),
                source: .media(MediaSource(mediaID: mediaID, sourceStart: docTime(sourceStart))),
                audio: Clip.AudioSettings(
                    volume: FixedPointScalar(rawValue: 8_000),
                    fadeIn: docTime(12_000),
                    fadeOut: docTime(24_000)))
        ])],
        duration: docTime(600_000))
    return (document, trackID, clipID, mediaID)
}

@Suite struct SplitTests {
    @Test func splitProducesExactOccupancyNoGapNoOverlap() throws {
        let (document, trackID, clipID, _) = makeDocument()
        let splitAt = docTime(240_000)
        let result = try document.splittingClip(clipID, inTrack: trackID, at: splitAt)

        let clips = result.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].timelineStart.ticks == 60_000)
        #expect(clips[0].duration.ticks == 180_000)
        #expect(clips[1].timelineStart.ticks == 240_000)
        #expect(clips[1].duration.ticks == 300_000)
        // Together exactly the original range.
        #expect(try clips[0].timelineEnd().ticks == clips[1].timelineStart.ticks)
        #expect(try clips[1].timelineEnd().ticks == 540_000)
        // Sorted, non-overlapping — the invariant the decoder enforces.
        #expect(Track.clipOrderingViolation(clips) == nil)
    }

    /// Identity: LEFT keeps the original (§5.6.6 — selection and undo
    /// payloads keep pointing at the same visual object).
    @Test func leftPieceKeepsTheOriginalIdentity() throws {
        let (document, trackID, clipID, _) = makeDocument()
        let result = try document.splittingClip(clipID, inTrack: trackID, at: docTime(240_000))
        #expect(result.tracks[0].clips[0].id == clipID)
        #expect(result.tracks[0].clips[1].id != clipID)
    }

    /// The right piece's source offset advances by exact ticks — no
    /// rounding on either grid, no rate parameter anywhere near it.
    @Test func rightPieceSourceOffsetIsExact() throws {
        let (document, trackID, clipID, mediaID) = makeDocument(sourceStart: 40_000)
        let result = try document.splittingClip(clipID, inTrack: trackID, at: docTime(240_000))
        guard case .media(let leftSource) = result.tracks[0].clips[0].source,
              case .media(let rightSource) = result.tracks[0].clips[1].source else {
            Issue.record("expected media sources")
            return
        }
        #expect(leftSource.mediaID == mediaID)
        #expect(leftSource.sourceStart.ticks == 40_000)
        // left duration = 240000 - 60000 = 180000 → right source start
        // = 40000 + 180000.
        #expect(rightSource.sourceStart.ticks == 220_000)
    }

    /// Fades: fade-in stays left, fade-out moves right, nothing at the cut.
    @Test func fadesSplitToOuterEdges() throws {
        let (document, trackID, clipID, _) = makeDocument()
        let result = try document.splittingClip(clipID, inTrack: trackID, at: docTime(240_000))
        let left = result.tracks[0].clips[0].audio
        let right = result.tracks[0].clips[1].audio
        #expect(left.fadeIn.ticks == 12_000)
        #expect(left.fadeOut.ticks == 0)
        #expect(right.fadeIn.ticks == 0)
        #expect(right.fadeOut.ticks == 24_000)
        #expect(left.volume == right.volume)
    }

    @Test func generatorClipSplitsWithoutSourceShift() throws {
        let trackID = TrackID()
        let clipID = ClipID()
        let document = GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps30, renderWidth: 1280, renderHeight: 720),
            tracks: [Track(id: trackID, kind: .video, clips: [
                Clip(id: clipID, timelineStart: .zero, duration: docTime(120_000),
                     source: .generator(identifier: "text", parameters: .object([:])))
            ])])
        let result = try document.splittingClip(clipID, inTrack: trackID, at: docTime(60_000))
        guard case .generator(let id, _) = result.tracks[0].clips[1].source else {
            Issue.record("expected generator source")
            return
        }
        #expect(id == "text")
    }

    /// The original document is untouched — the edit is a pure transformation.
    @Test func editIsPure() throws {
        let (document, trackID, clipID, _) = makeDocument()
        _ = try document.splittingClip(clipID, inTrack: trackID, at: docTime(240_000))
        #expect(document.tracks[0].clips.count == 1)
    }

    // MARK: - Range query and rejections

    @Test func allowedRangeKeepsBothSidesOneProjectFrame() {
        let (document, trackID, clipID, _) = makeDocument()
        // 30fps → 4,000 ticks per frame. Clip [60000, 540000).
        let range = document.allowedSplitRange(ofClip: clipID, inTrack: trackID)
        #expect(range == 64_000...536_000)
    }

    @Test func clipShorterThanTwoFramesCannotSplit() {
        let (document, trackID, clipID, _) = makeDocument(clipDuration: 7_999)
        #expect(document.allowedSplitRange(ofClip: clipID, inTrack: trackID) == nil)
        // Exactly two frames CAN split, at exactly one place.
        let (doc2, track2, clip2, _) = makeDocument(clipDuration: 8_000)
        #expect(doc2.allowedSplitRange(ofClip: clip2, inTrack: track2) == 64_000...64_000)
    }

    @Test func splitOutsideAllowedRangeThrows() {
        let (document, trackID, clipID, _) = makeDocument()
        #expect(throws: EditError.splitTimeOutsideAllowedRange(clip: clipID)) {
            try document.splittingClip(clipID, inTrack: trackID, at: docTime(63_999))
        }
        #expect(throws: EditError.splitTimeOutsideAllowedRange(clip: clipID)) {
            try document.splittingClip(clipID, inTrack: trackID, at: docTime(536_001))
        }
        // Boundaries themselves are allowed.
        #expect(throws: Never.self) {
            try document.splittingClip(clipID, inTrack: trackID, at: docTime(64_000))
        }
    }

    @Test func unknownTargetsThrow() {
        let (document, trackID, _, _) = makeDocument()
        let strangerClip = ClipID()
        let strangerTrack = TrackID()
        #expect(throws: EditError.clipNotFound(strangerClip)) {
            try document.splittingClip(strangerClip, inTrack: trackID, at: docTime(240_000))
        }
        #expect(throws: EditError.trackNotFound(strangerTrack)) {
            try document.splittingClip(ClipID(), inTrack: strangerTrack, at: docTime(240_000))
        }
    }

    // MARK: - Transaction composition

    /// Two operations in ONE transaction — the inner "nesting" shape: an
    /// operation sequence absorbed into a single commit.
    @Test func twoSplitsInOneTransactionCommitTogether() throws {
        let (document, trackID, clipID, _) = makeDocument()
        let result = try document.applyingEdit { txn in
            try txn.splitClip(clipID, inTrack: trackID, at: docTime(240_000))
            // Split the LEFT piece (kept the original id) again.
            try txn.splitClip(clipID, inTrack: trackID, at: docTime(120_000))
        }
        #expect(result.tracks[0].clips.count == 3)
        #expect(Track.clipOrderingViolation(result.tracks[0].clips) == nil)
        #expect(result.tracks[0].clips.map(\.timelineStart.ticks) == [60_000, 120_000, 240_000])
    }

    /// A nested applyingEdit on the working value is just a pure function;
    /// the outer transaction absorbs its result. No begin/end exists to
    /// mismatch.
    @Test func nestedApplyingEditIsAbsorbed() throws {
        let (document, trackID, clipID, _) = makeDocument()
        let result = try document.applyingEdit { txn in
            let inner = try txn.document.splittingClip(clipID, inTrack: trackID, at: docTime(240_000))
            #expect(inner.tracks[0].clips.count == 2)
            try txn.splitClip(clipID, inTrack: trackID, at: docTime(240_000))
        }
        #expect(result.tracks[0].clips.count == 2)
    }
}

/// Task 7: the D26 debug cross-check is a GATE, so §4's gate rules apply —
/// it must be SHOWN to fail. The seam removes a media entry while
/// deliberately not recording a touch: dangling `MediaID` is on the
/// honest "not checked locally" list, so ONLY the cross-check can see it.
/// Branch exercised: full-validator-hit → preconditionFailure. (The
/// local-validation trap branches are separately unreachable through the
/// public API — operations construct valid neighbourhoods by
/// construction — and remain observed only through this same exit-test
/// mechanism if an operation bug ever lands.)
@Suite struct EditCrossCheckGateTests {
    @Test func crossCheckCatchesWhatLocalValidationMisses() async {
        await #expect(processExitsWith: .failure) {
            let (document, trackID, clipID, mediaID) = makeDocument()
            _ = try document.applyingEdit { txn in
                try txn.splitClip(clipID, inTrack: trackID, at: docTime(240_000))
                txn._removeMediaBypassingLocalValidationForGateTest(mediaID)
            }
        }
    }

    /// The same corruption WITHOUT the split still trips the cross-check:
    /// the gate does not depend on local validation having anything to do.
    @Test func crossCheckFiresEvenWithNoLocalTouches() async {
        await #expect(processExitsWith: .failure) {
            let (document, _, _, mediaID) = makeDocument()
            _ = document.applyingEdit { txn in
                txn._removeMediaBypassingLocalValidationForGateTest(mediaID)
            }
        }
    }
}

@Suite struct ClipHitTestTests {
    private func track(_ spans: [(Int64, Int64)]) -> Track {
        Track(id: TrackID(), kind: .video, clips: spans.map { start, duration in
            Clip(id: ClipID(), timelineStart: docTime(start), duration: docTime(duration),
                 source: .generator(identifier: "t", parameters: .object([:])))
        })
    }

    @Test func hitInsideFindsTheClip() {
        let t = track([(0, 100), (200, 100)])
        #expect(VisibleRange.clip(at: docTime(50), in: t)?.id == t.clips[0].id)
        #expect(VisibleRange.clip(at: docTime(250), in: t)?.id == t.clips[1].id)
    }

    /// Half-open [start, end): the start hits, the end does not.
    @Test func boundariesAreHalfOpen() {
        let t = track([(0, 100), (100, 100)])
        #expect(VisibleRange.clip(at: docTime(0), in: t)?.id == t.clips[0].id)
        // Exactly at the cut between two abutting clips: the LATER clip.
        #expect(VisibleRange.clip(at: docTime(100), in: t)?.id == t.clips[1].id)
        #expect(VisibleRange.clip(at: docTime(200), in: t) == nil)
    }

    @Test func gapsAndEmptyTrackMiss() {
        let t = track([(0, 100), (200, 100)])
        #expect(VisibleRange.clip(at: docTime(150), in: t) == nil)
        #expect(VisibleRange.clip(at: docTime(999), in: t) == nil)
        #expect(VisibleRange.clip(at: docTime(0), in: track([])) == nil)
    }
}
