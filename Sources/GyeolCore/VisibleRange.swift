import Foundation

/// Visible-range queries for viewport virtualization (PRD §5.2).
///
/// STATELESS BY CONTRACT (D26): no index cache, no memo of the last query.
/// That contract is conditional on the binary-search cost measured in M2.2 —
/// if the measurement comes back bad, the answer is a PRD revision, never a
/// quietly added cache.
///
/// This module speaks DocumentTime only. Pixels, zoom levels and pointer
/// coordinates never reach Core (§5.6.5); converting a viewport's pixel
/// bounds into a time range is the app's job.
///
/// The viewport is the half-open interval [start, end). An item is visible
/// when it intersects that interval: itemStart < end && itemEnd > start.
/// An item ending exactly at `start` or starting exactly at `end` is NOT
/// visible — consistent with `FrameMapping`'s half-open frame convention.
///
/// Binary search alone does not close these queries; §5.2 names the two
/// corrections, one per shape of data:
///
/// - CLIPS: searching by start time misses a clip that straddles the left
///   viewport edge. Starting the scan ONE element earlier is sufficient —
///   the no-overlap invariant (§5.6.6) guarantees at most one clip per
///   track can straddle any boundary.
/// - SUBTITLES: overlap is legal, so that guarantee is gone and there is no
///   bound on how many straddle. The query therefore takes
///   `maxSubtitleDuration` — computed and held by the APP (it is derived
///   data, so it is not stored in the document, and recomputing it here
///   would be O(n) per query).
public enum VisibleRange {

    // MARK: - Clips

    /// The clips of `track` intersecting [start, end), as a slice of the
    /// track's sorted storage. Contiguity of the result is a theorem of the
    /// sorted + non-overlapping invariants, which is why a slice (not a
    /// filtered copy) is the honest return type.
    public static func visibleClips(
        in track: Track, from start: DocumentTime, to end: DocumentTime
    ) -> ArraySlice<Clip> {
        let clips = track.clips
        guard start.ticks < end.ticks, !clips.isEmpty else { return clips[0..<0] }

        let firstAtOrAfterStart = lowerBound(clips, startingAt: start.ticks) { $0.timelineStart.ticks }
        var begin = firstAtOrAfterStart
        // The §5.2 correction: one step back catches the (at most one) clip
        // straddling the left edge. Its end is exclusive, so a clip ending
        // exactly at the viewport start stays invisible.
        if begin > clips.startIndex, endTicks(of: clips[begin - 1]) > start.ticks {
            begin -= 1
        }
        let upper = lowerBound(clips, startingAt: end.ticks) { $0.timelineStart.ticks }
        return clips[begin..<upper]
    }

    // MARK: - Subtitles

    /// The subtitle segments intersecting [start, end).
    ///
    /// `maxSubtitleDuration` is the caller's promise: no segment in
    /// `subtitles` is longer. It bounds how far left of the viewport the
    /// scan must begin; a value smaller than the true maximum silently
    /// drops long segments straddling the left edge — exactly the failure
    /// §5.2 rejects guessing (3–10s conventions) for. The app computes it
    /// once per document change and passes it in.
    ///
    /// Returns a lazy sequence over the candidate slice rather than a
    /// filtered copy: at maximum zoom-out every one of 3,600 segments is a
    /// candidate, and materializing an array per query would put an O(n)
    /// allocation on the render path for nothing — the renderer only
    /// iterates.
    public static func visibleSubtitles(
        in subtitles: [SubtitleSegment],
        from start: DocumentTime,
        to end: DocumentTime,
        maxSubtitleDuration: DocumentTime
    ) -> some Sequence<SubtitleSegment> {
        precondition(
            maxSubtitleDuration.ticks >= 0, "maxSubtitleDuration must be non-negative")
        guard start.ticks < end.ticks, !subtitles.isEmpty else {
            return subtitles[0..<0].lazy.filter { _ in true }
        }
        // A straddling segment satisfies segStart > start − maxDuration
        // (strictly: segStart + duration > start and duration ≤ maxDuration).
        // subtractingReportingOverflow: start can be any tick count and the
        // subtraction may underflow Int64; clamping to min is exact there —
        // no stored start is below zero anyway.
        let (scanFloor, underflow) = start.ticks.subtractingReportingOverflow(maxSubtitleDuration.ticks)
        let lo = lowerBound(subtitles, startingAt: underflow ? Int64.min : scanFloor) { $0.start.ticks }
        let hi = lowerBound(subtitles, startingAt: end.ticks) { $0.start.ticks }
        let startTicks = start.ticks
        return subtitles[lo..<hi].lazy.filter { segment in
            endTicks(start: segment.start, duration: segment.duration) > startTicks
        }
    }

    // MARK: - Markers

    /// The markers whose time lies in [start, end). Point events: no
    /// straddling, so plain binary search on both edges closes this one.
    public static func visibleMarkers(
        in markers: [Marker], from start: DocumentTime, to end: DocumentTime
    ) -> ArraySlice<Marker> {
        guard start.ticks < end.ticks, !markers.isEmpty else { return markers[0..<0] }
        let lo = lowerBound(markers, startingAt: start.ticks) { $0.time.ticks }
        let hi = lowerBound(markers, startingAt: end.ticks) { $0.time.ticks }
        return markers[lo..<hi]
    }

    // MARK: - Helpers

    /// First index whose key is ≥ `target`, or `endIndex`. The array must be
    /// sorted by `key` ascending — the §5.6.6 invariant every stored
    /// collection already carries.
    private static func lowerBound<Element>(
        _ elements: [Element], startingAt target: Int64, key: (Element) -> Int64
    ) -> Int {
        var low = elements.startIndex
        var high = elements.endIndex
        while low < high {
            let mid = low + (high - low) / 2
            if key(elements[mid]) < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    private static func endTicks(of clip: Clip) -> Int64 {
        endTicks(start: clip.timelineStart, duration: clip.duration)
    }

    /// start + duration, saturating: an Int64 overflow here means the item
    /// extends past every representable viewport, so "visible forever" is
    /// the exact answer. (Unreachable for a valid document — construction
    /// rejects overflowing ends — but the query should not trap on the
    /// arithmetic when the saturation is correct anyway.)
    private static func endTicks(start: DocumentTime, duration: DocumentTime) -> Int64 {
        let (sum, overflow) = start.ticks.addingReportingOverflow(duration.ticks)
        return overflow ? Int64.max : sum
    }
}
