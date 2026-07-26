import Foundation

/// Errors an editing operation throws for CALLER-side problems: a target
/// that does not exist, or a parameter outside the allowed range the
/// caller should have queried first (D26: range computation is Core's,
/// clamping is the app's, and the operation throws rather than silently
/// clamping — §7.4-6). The normal path never throws because the app
/// consults the range query before enabling the gesture.
public enum EditError: Error, Equatable, Sendable {
    case trackNotFound(TrackID)
    case clipNotFound(ClipID)
    /// The split time falls outside `allowedSplitRange` — either side
    /// would be shorter than one project frame (§5.2 minimum).
    case splitTimeOutsideAllowedRange(clip: ClipID)
}

/// The editing transaction (D26): a pure `(Document, edits) → Document`
/// transformation. No AVFoundation, no CoreMedia — this needs no §5.6.5
/// exception at all.
///
/// The transaction is the boundary where CROSS-FIELD invariants are
/// enforced (§5.6.7): between operations the working document may be
/// invalid ACROSS fields (a clip whose media entry is not yet added), but
/// never invalid WITHIN a field — per-field `didSet` preconditions stay
/// armed the whole time, which is why operations compute their results
/// fully and assign once.
///
/// NESTING: the closure form makes mismatched begin/end impossible to
/// express rather than detected — there is no begin/end API. An operation
/// implemented in terms of other operations just calls them on the same
/// `inout` transaction and is absorbed into the enclosing commit; a
/// nested `applyingEdit` on the working value is a pure function returning
/// an already-validated value, which the outer commit re-validates as its
/// own edit. Either way there is exactly one outer commit.
///
/// COMMIT VALIDATION is local — the neighbourhood of what changed —
/// with a DEBUG-build cross-check that runs the full validator (THE one
/// `GyeolDocument.fullValidationViolation`, shared with the decoder) and
/// traps if it finds anything local validation missed. Local coverage,
/// honestly stated:
///
/// - checked by neighbourhood: clip ordering, same-track overlap, and the
///   one-project-frame minimum length, for the touched index ranges only
///   (via the same `Track.clipOrderingViolation` the decoder uses, applied
///   to the window).
/// - NOT checked locally (full-scan invariants, unreachable by the
///   current operation set): dangling `MediaID` (split never touches the
///   pool), `duration` ≥ every clip end (split preserves the occupied
///   range exactly), subtitle and marker ordering (split touches neither).
///   When an operation that CAN violate one of these arrives (media
///   removal, M2.4+), its local check must be added — and the cross-check
///   exists to catch the round where that is forgotten.
public struct EditTransaction {
    /// The working value. Operations replace it wholesale; external code
    /// reads it (e.g. to chain queries) but only operations mutate it.
    public private(set) var document: GyeolDocument

    /// Track indices whose clip arrays changed, with the clip-index range
    /// to re-validate at commit (expanded to neighbours there).
    private var touchedClipRanges: [Int: Range<Int>] = [:]

    init(document: GyeolDocument) {
        self.document = document
    }

    // MARK: - Split (M2.3's one operation)

    /// Splits `clipID` at `time` into two clips that together occupy
    /// exactly the original range — no gap, no overlap, sort order
    /// preserved (§5.6.6).
    ///
    /// IDENTITY: the LEFT piece keeps the original `ClipID`. §5.6.6 keeps
    /// UUIDs stable so selection and undo payloads survive edits; the left
    /// piece keeps the original start position, so anything pointing at
    /// the clip a user could see and select — the selection itself, a
    /// future marker anchored near its head — keeps pointing at the same
    /// visual object, now merely shorter. The right piece is new material
    /// created by the cut and gets a fresh identity.
    ///
    /// SOURCE OFFSET: the right piece's `sourceStart` advances by the left
    /// piece's duration in EXACT ticks — pure time arithmetic with no
    /// rounding on either grid. No rate parameter is applied to the source
    /// offset at all, which is how §6.2's source/project separation is
    /// observed here: the SOURCE grid enters only when AVFoundation
    /// extracts frames, and the PROJECT grid only in the one-frame minimum
    /// (`allowedSplitRange`). The two never pass through one parameter.
    ///
    /// AUDIO FADES: the fade-in stays with the left piece and the fade-out
    /// moves to the right piece; the cut point itself gets no fade on
    /// either side — a split is a hard cut (§6.2), and the audible
    /// envelope at the ORIGINAL clip edges is preserved. (PRD is silent on
    /// this; reported.)
    public mutating func splitClip(
        _ clipID: ClipID, inTrack trackID: TrackID, at time: DocumentTime
    ) throws {
        guard let trackIndex = document.tracks.firstIndex(where: { $0.id == trackID }) else {
            throw EditError.trackNotFound(trackID)
        }
        guard let clipIndex = document.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            throw EditError.clipNotFound(clipID)
        }
        guard let allowed = document.allowedSplitRange(ofClipAt: clipIndex, inTrackAt: trackIndex),
              allowed.contains(time.ticks) else {
            throw EditError.splitTimeOutsideAllowedRange(clip: clipID)
        }

        let original = document.tracks[trackIndex].clips[clipIndex]
        let leftTicks = time.ticks - original.timelineStart.ticks
        let rightTicks = original.duration.ticks - leftTicks

        var left = original
        left.duration = DocumentTime(ticks: leftTicks)
        left.audio.fadeOut = .zero

        let rightSource: ClipSource = switch original.source {
        case .media(let source):
            .media(MediaSource(
                mediaID: source.mediaID,
                sourceStart: DocumentTime(ticks: source.sourceStart.ticks + leftTicks)))
        case .generator:
            // A generator has no source asset to offset into; both pieces
            // render from the same parameters at their own timeline times.
            original.source
        }
        let right = Clip(
            id: ClipID(),
            timelineStart: time,
            duration: DocumentTime(ticks: rightTicks),
            source: rightSource,
            effects: original.effects,
            audio: Clip.AudioSettings(
                volume: original.audio.volume,
                fadeIn: .zero,
                fadeOut: original.audio.fadeOut))

        // Compute fully, assign ONCE: the clips didSet validates ordering
        // on every assignment, so the array must never pass through a
        // half-edited state (§5.2).
        var clips = document.tracks[trackIndex].clips
        clips[clipIndex] = left
        clips.insert(right, at: clipIndex + 1)
        document.tracks[trackIndex].clips = clips

        recordTouch(trackIndex: trackIndex, clipRange: clipIndex..<(clipIndex + 2))
    }

    // MARK: - Commit (internal to applyingEdit)

    private mutating func recordTouch(trackIndex: Int, clipRange: Range<Int>) {
        if let existing = touchedClipRanges[trackIndex] {
            touchedClipRanges[trackIndex] =
                min(existing.lowerBound, clipRange.lowerBound)..<max(existing.upperBound, clipRange.upperBound)
        } else {
            touchedClipRanges[trackIndex] = clipRange
        }
    }

    /// Commit-time validation. Local first (the touched neighbourhoods),
    /// then in DEBUG the full-validator cross-check. Failures TRAP rather
    /// than throw: an invalid state at commit is a bug in an operation or
    /// in a caller-composed transaction — in-memory misuse, which this
    /// model traps on (§5.6.7); only external files throw.
    func validateForCommit() {
        let ticksPerFrame = document.settings.frameRate.ticksPerFrame
        for (trackIndex, range) in touchedClipRanges {
            let clips = document.tracks[trackIndex].clips
            // Neighbourhood: one clip either side of the touched range —
            // ordering and overlap are pairwise-adjacent properties, so
            // the window sees every pair a change could have broken.
            let lo = max(clips.startIndex, range.lowerBound - 1)
            let hi = min(clips.endIndex, range.upperBound + 1)
            // The same rule function the decoder uses, applied to the window.
            if let violation = Track.clipOrderingViolation(Array(clips[lo..<hi])) {
                preconditionFailure("edit produced an invalid track: \(violation)")
            }
            for clip in clips[range.clamped(to: clips.startIndex..<clips.endIndex)]
            where clip.duration.ticks < ticksPerFrame {
                preconditionFailure("""
                edit produced a clip shorter than one project frame: \
                \(clip.id.rawValue.uuidString) (\(clip.duration.ticks) ticks)
                """)
            }
        }
        #if DEBUG
        // D26 cross-check: local validation being sufficient is a PROOF,
        // and this comparison is that proof's consumer. Runs the SAME full
        // validator as the decoder; a hit here means an operation (or the
        // local-check table above) has a bug — never ship-quiet.
        if let violation = GyeolDocument.fullValidationViolation(
            media: document.media, tracks: document.tracks,
            duration: document.duration,
            subtitles: document.subtitles, markers: document.markers) {
            preconditionFailure("""
            D26 cross-check: the full validator found what local validation \
            missed — \(violation.message)
            """)
        }
        #endif
    }

    // MARK: - Task-7 gate-proof seam

    /// TEST-ONLY (internal): corrupts the media pool WITHOUT recording a
    /// touch, constructing exactly the situation the debug cross-check
    /// exists for — an invariant violation (dangling `MediaID`) that local
    /// validation, by its own honest coverage statement, does not check.
    /// The exit test proves the cross-check gate can fail (§4 gate rules:
    /// a gate that has only ever passed cannot distinguish the subject
    /// from the measurement conditions).
    mutating func _removeMediaBypassingLocalValidationForGateTest(_ id: MediaID) {
        document.media[id] = nil
    }
}

extension GyeolDocument {
    /// Runs `body` as one editing transaction and returns the committed
    /// document. Pure: `self` is never mutated. One call = one commit =
    /// (in the app) one undo step.
    public func applyingEdit(_ body: (inout EditTransaction) throws -> Void) rethrows -> GyeolDocument {
        var transaction = EditTransaction(document: self)
        try body(&transaction)
        transaction.validateForCommit()
        return transaction.document
    }

    /// Single-operation convenience wrapper (D26's "명시적 트랜잭션 + 단일
    /// 연산 편의 래퍼").
    public func splittingClip(
        _ clipID: ClipID, inTrack trackID: TrackID, at time: DocumentTime
    ) throws -> GyeolDocument {
        try applyingEdit { try $0.splitClip(clipID, inTrack: trackID, at: time) }
    }

    // MARK: - Range queries (D26: Core computes the range, the app applies it)

    /// The tick range within which `clipID` may be split so that BOTH
    /// pieces are at least one PROJECT frame long (§5.2). nil when the
    /// clip does not exist or is too short to split at all (< 2 frames).
    /// Stateless, like every Core query (D26).
    public func allowedSplitRange(
        ofClip clipID: ClipID, inTrack trackID: TrackID
    ) -> ClosedRange<Int64>? {
        guard let trackIndex = tracks.firstIndex(where: { $0.id == trackID }),
              let clipIndex = tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else {
            return nil
        }
        return allowedSplitRange(ofClipAt: clipIndex, inTrackAt: trackIndex)
    }

    fileprivate func allowedSplitRange(ofClipAt clipIndex: Int, inTrackAt trackIndex: Int) -> ClosedRange<Int64>? {
        let clip = tracks[trackIndex].clips[clipIndex]
        // The PROJECT grid's frame length — the one place the project rate
        // enters the split. The label on ProjectSettings keeps this from
        // ever being handed a source rate (§6.2).
        let frame = settings.frameRate.ticksPerFrame
        let earliest = clip.timelineStart.ticks + frame
        let latest = clip.timelineStart.ticks + clip.duration.ticks - frame
        guard earliest <= latest else { return nil }
        return earliest...latest
    }
}
