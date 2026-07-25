import CoreMedia

// CoreMedia is the ONE permitted exception to GyeolCore's purity (D19):
// CMTime crosses this boundary and nothing else does. AVFoundation must not
// be imported here or anywhere else in GyeolCore.

/// The CMTime ↔ DocumentTime boundary adapter (PRD §5.6.1).
///
/// Rounding happens HERE, once, and nowhere else. `FrameMapping` (L1) stays
/// exact — it floor-divides times that are already on the document grid. The
/// bug L1 structurally cannot catch is an *incoming* time that sits slightly
/// off a frame boundary because it lived in a coarser timescale: the probe
/// (docs/m1-asset-timescale-probe.md) measured containers quantizing the
/// 23.976 frame-1 boundary 5005 to 5000 ticks. Floor-dividing 5000 yields
/// frame 0 — one frame early. This adapter absorbs that error by snapping to
/// the nearest frame boundary and reporting exactly what it discarded.
///
/// Frame index is authoritative; CMTime is derived (principle 7.4-8). The
/// seek direction therefore starts from a frame index, not from a time.
public enum CMTimeAdapter {

    // MARK: - Direction 1: CMTime → DocumentTime

    /// The outcome of snapping an incoming CMTime onto the frame grid.
    /// The residual is part of the return value — ignoring it is a visible
    /// decision at the call site, which is why this API does not throw:
    /// a throwing version would get wrapped in `try?` inside playback loops
    /// and the loss would become silent (principle 6).
    public struct SnappedTime: Hashable, Sendable {
        /// Exactly N·d ticks at 120000 — safe to hand to `FrameMapping`.
        public let time: DocumentTime
        /// The N of that boundary (D23). Computed by `FrameMapping` on the
        /// snapped time — the ONE mapping (§4.1) — and carried here so
        /// consumers never feel the pull toward `ticks / ticksPerFrame`
        /// that §6.2 forbids.
        public let frameIndex: Int
        /// What snapping discarded: (incoming time − chosen boundary), as an
        /// exact fraction of one 120000 tick: `residualTickNumerator /
        /// residualTickDenominator` ticks. The denominator is the incoming
        /// timescale, so the fraction is exact for any input — a Double here
        /// would defeat the point of measuring the loss.
        public let residualTickNumerator: Int64
        public let residualTickDenominator: Int64
        /// True when |residual| > 1/4 frame (PRD §5.6.1). At that distance
        /// the incoming time no longer identifies a frame unambiguously —
        /// a signal to surface, not a crash.
        public let exceedsQuarterFrameThreshold: Bool
    }
}

/// The log-friendly form callers were assembling by hand at every site
/// (M1.2 friction). A description, not a formatting layer.
extension CMTimeAdapter.SnappedTime: CustomStringConvertible {
    public var description: String {
        "frame \(frameIndex), residual \(residualTickNumerator)/\(residualTickDenominator) ticks"
            + (exceedsQuarterFrameThreshold ? " — EXCEEDS 1/4 frame" : "")
    }
}

extension CMTimeAdapter {
    /// Snaps `time` to the nearest frame boundary at `projectRate` and
    /// reports the discarded distance. Returns nil for non-numeric CMTime
    /// (invalid, indefinite, ±infinity — AVPlayer reports these
    /// transiently) and for values whose boundary does not fit Int64 ticks.
    ///
    /// `projectRate`, not `rate`: the grid being snapped to is the PROJECT
    /// timeline grid (playhead, scrubbing, frame stepping). In M1 the
    /// project rate and the source media rate are the same value; from M2 a
    /// 24fps clip can sit in a 30fps project and the two grids diverge.
    /// Mixing them is exactly the S3 failure §4.1 describes — the label
    /// exists so the wrong call site LOOKS wrong.
    public static func documentTime(
        snappingToFrameGrid time: CMTime,
        projectRate: FrameRate
    ) -> SnappedTime? {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        let value = Int128(time.value)
        let scale = Int128(time.timescale)
        let d = Int128(projectRate.ticksPerFrame)

        // exact ticks = value·120000/scale; frame N = round(exact/d), half
        // away from zero. All in Int128: value·120000 alone can overflow
        // Int64 for nanosecond-scale times (10^13 ns · 120000 ≈ 1.3·10^18
        // is fine, but nothing forces callers to stay near there).
        let n = roundedHalfAwayFromZero(value * 120_000, dividedBy: scale * d)
        guard let boundaryTicks = Int64(exactly: n * d) else { return nil }

        // residual = exact − boundary = (value·120000 − N·d·scale)/scale
        // ticks. |numerator| ≤ scale·d/2 at worst, comfortably Int64.
        let residualNumerator = Int64(value * 120_000 - n * d * scale)
        let residualDenominator = Int64(scale)

        // |residual| > d/4 ⟺ 4·|num| > d·den (cross-multiplied, exact).
        //
        // No assert on exceeding, DELIBERATELY (M2.1 finding): this input
        // is external runtime data, not programmer error. Measured — under
        // decoder failure AVPlayerItemVideoOutput echoes the SEEK TARGET
        // (a frame centre, mid-frame by construction) as the display
        // timestamp, and a debug assert here killed the process on data no
        // code path controls. §7.4-6: the threshold is a SIGNAL the caller
        // owns; the flag below carries it.
        let exceeds = 4 * Int128(residualNumerator).magnitude
            > (d * Int128(residualDenominator)).magnitude
        let snappedTime = DocumentTime(ticks: boundaryTicks)
        return SnappedTime(
            time: snappedTime,
            // Through L1, not from our internal quotient: the mapping stays
            // singular even inside the adapter that could shortcut it.
            frameIndex: FrameMapping.frameIndex(at: snappedTime, rate: projectRate),
            residualTickNumerator: residualNumerator,
            residualTickDenominator: residualDenominator,
            exceedsQuarterFrameThreshold: exceeds)
    }

    // MARK: - Direction 2a: DocumentTime → CMTime, exact

    /// Lossless conversion for composition construction. No offset, no
    /// rounding, no conversion: the stored ticks ARE the 120000 value.
    public static func cmTime(exactly time: DocumentTime) -> CMTime {
        CMTime(value: time.ticks, timescale: DocumentTime.timescale)
    }

    // MARK: - Direction 2b: frame index → CMTime, seek target

    /// The CMTime to hand AVPlayer to land on frame `index`. This is NOT the
    /// frame's presentation time: it is the frame's CENTER, N·d + d/2.
    ///
    /// Why the half-frame offset exists: AVFoundation may round a seek
    /// target down to a coarser internal timescale. Rounding the exact
    /// boundary N·d down by even one tick crosses into frame N−1 (measured:
    /// boundary 5005 → 600-scale → 5000 → frame 0). The frame center is
    /// maximally far from both boundaries, so any round-off strictly smaller
    /// than half a frame still lands inside frame N.
    ///
    /// The offset is born and dies here — it is never expressed as a
    /// DocumentTime, so it can never leak into the document or into L1.
    /// Timescale 240000 (= 2 × 120000) makes N·d + d/2 exact even for odd d
    /// (23.976's 5005).
    public static func cmTimeForSeek(toFrame index: Int, projectRate: FrameRate) -> CMTime {
        precondition(index >= 0, "frame index must be non-negative")
        let d = projectRate.ticksPerFrame
        let (doubled, mulOverflow) = Int64(index).multipliedReportingOverflow(by: 2 * d)
        let (numerator, addOverflow) = doubled.addingReportingOverflow(d)
        precondition(!mulOverflow && !addOverflow, "frame index \(index) overflows Int64")
        return CMTime(value: numerator, timescale: 2 * DocumentTime.timescale)
    }

    // MARK: - Helpers

    /// Round-half-away-from-zero integer division; Swift's `/` truncates
    /// toward zero, which would bias snapping for values just under a
    /// half-frame on the negative side.
    private static func roundedHalfAwayFromZero(_ numerator: Int128, dividedBy denominator: Int128) -> Int128 {
        precondition(denominator > 0)
        let quotient = numerator / denominator
        let remainder = numerator % denominator
        if 2 * remainder.magnitude >= denominator.magnitude {
            return numerator >= 0 ? quotient + 1 : quotient - 1
        }
        return quotient
    }
}
