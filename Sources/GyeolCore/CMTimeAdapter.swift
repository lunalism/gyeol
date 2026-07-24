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

    /// Snaps `time` to the nearest frame boundary at `rate` and reports the
    /// discarded distance. Returns nil for non-numeric CMTime (invalid,
    /// indefinite, ±infinity — AVPlayer reports these transiently) and for
    /// values whose boundary does not fit Int64 ticks.
    ///
    /// `assertOnThresholdExceeded` exists so tests can exercise the
    /// over-threshold path; production call sites keep the default and get
    /// a debug-build assert while release builds continue with the flag set.
    public static func documentTime(
        snappingToFrameGrid time: CMTime,
        rate: FrameRate,
        assertOnThresholdExceeded: Bool = true
    ) -> SnappedTime? {
        guard time.isNumeric, time.timescale > 0 else { return nil }
        let value = Int128(time.value)
        let scale = Int128(time.timescale)
        let d = Int128(rate.ticksPerFrame)

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
        let exceeds = 4 * Int128(residualNumerator).magnitude
            > (d * Int128(residualDenominator)).magnitude
        if exceeds, assertOnThresholdExceeded {
            assertionFailure("""
                time \(time.value)/\(time.timescale) is \
                \(residualNumerator)/\(residualDenominator) ticks from the \
                nearest \(rate.rawValue) fps frame boundary — more than 1/4 \
                frame; the source timescale cannot address frames at this rate
                """)
        }
        return SnappedTime(
            time: DocumentTime(RationalTime(unchecked: boundaryTicks, timescale: DocumentTime.timescale)),
            residualTickNumerator: residualNumerator,
            residualTickDenominator: residualDenominator,
            exceedsQuarterFrameThreshold: exceeds)
    }

    // MARK: - Direction 2a: DocumentTime → CMTime, exact

    /// Lossless conversion for composition construction. No offset, no
    /// rounding: document ticks become a CMTime at 120000 verbatim.
    /// A DocumentTime not representable at 120000 is in-memory misuse and
    /// traps, matching `FrameMapping`'s convention.
    public static func cmTime(exactly time: DocumentTime) -> CMTime {
        guard let converted = try? time.time.converted(to: DocumentTime.timescale) else {
            preconditionFailure(
                "time \(time.time) is not representable at document timescale \(DocumentTime.timescale)")
        }
        return CMTime(value: converted.value, timescale: DocumentTime.timescale)
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
    public static func cmTimeForSeek(toFrame index: Int, rate: FrameRate) -> CMTime {
        precondition(index >= 0, "frame index must be non-negative")
        let d = rate.ticksPerFrame
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
