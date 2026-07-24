import Foundation

extension FrameRate {
    /// One frame's duration in document ticks — the integer that makes L1
    /// pure integer division. These literals are locked to `frameDuration`
    /// by a test; if the two ever disagree, the test fails, not the export.
    public var ticksPerFrame: Int64 {
        switch self {
        case .fps23_976: 5_005
        case .fps24: 5_000
        case .fps25: 4_800
        case .fps29_97: 4_004
        case .fps30: 4_000
        case .fps50: 2_400
        case .fps59_94: 2_002
        case .fps60: 2_000
        }
    }
}

/// L1: the time ↔ frame mapping (PRD §4.1).
///
/// This is the most safety-critical arithmetic in the project: §4 S3
/// (preview frame == export frame) rests entirely on preview and export
/// calling THESE functions and getting the same answer. There is exactly
/// one implementation — do not write a second helper anywhere else; that
/// duplication is the failure this layer exists to prevent.
///
/// Convention, from which both directions follow:
///
/// > Frame N occupies the half-open interval [N·d, (N+1)·d), where d is
/// > the frame duration in ticks. A time exactly on a boundary belongs to
/// > the LATER frame. Export writes frame N at presentation time N·d;
/// > preview at time t displays frame floor(t/d).
///
/// At timescale 120000 every supported rate has an integer tick duration
/// (23.976 → 5005, … 60 → 2000), so everything here is exact integer
/// division — no `Double`, no rational arithmetic. That exactness is the
/// whole reason 120000 was chosen.
///
/// Failure convention: in-memory misuse (negative index, a time not
/// representable at 120000) traps via precondition, matching the rest of
/// the model; only external-file boundaries throw.
public enum FrameMapping {
    /// The frame displayed at `time`: floor(t/d).
    public static func frameIndex(at time: DocumentTime, rate: FrameRate) -> Int {
        let t = ticks(of: time)
        // Swift's `/` truncates toward zero; floor rounds toward negative
        // infinity. The two differ only for negative t — which cannot be
        // stored, but if one ever reaches here, truncation would fold
        // (-d, 0) onto frame 0, the same frame as [0, d), and the off-by-one
        // would be invisible exactly at the origin. Write the floor.
        let (quotient, remainder) = t.quotientAndRemainder(dividingBy: rate.ticksPerFrame)
        return Int(remainder < 0 ? quotient - 1 : quotient)
    }

    /// The presentation time of frame `index`: exactly N·d ticks.
    public static func time(ofFrame index: Int, rate: FrameRate) -> DocumentTime {
        precondition(index >= 0, "frame index must be non-negative")
        let (ticks, overflow) = Int64(index).multipliedReportingOverflow(by: rate.ticksPerFrame)
        precondition(!overflow, "frame index \(index) overflows Int64 ticks")
        return DocumentTime(RationalTime(unchecked: ticks, timescale: DocumentTime.timescale))
    }

    /// The number of frames `duration` spans: ceil(t/d).
    ///
    /// A partial trailing frame COUNTS. The half-open convention means any
    /// time inside the trailing partial interval still displays a frame, so
    /// export must emit one covering it — an exported file's frame total is
    /// ceil, and L3 checks against this. For an exact multiple k·d the
    /// count is k (the boundary at k·d belongs to the frame after the
    /// duration ends).
    public static func frameCount(for duration: DocumentTime, rate: FrameRate) -> Int {
        let t = ticks(of: duration)
        precondition(t >= 0, "duration must be non-negative")
        // Ceiling via quotient/remainder, not (t + d - 1) / d: the addition
        // overflows for t within d - 2 of Int64.max, which decodes as a
        // valid document duration. q + 1 cannot overflow because d ≥ 2000.
        let (quotient, remainder) = t.quotientAndRemainder(dividingBy: rate.ticksPerFrame)
        return Int(remainder == 0 ? quotient : quotient + 1)
    }

    /// Normalizes a DocumentTime to ticks at 120000. Stored document times
    /// are already at 120000; an in-memory value at a foreign timescale is
    /// converted exactly (existing `RationalTime` machinery, not new math).
    /// A value that cannot be represented is in-memory misuse: trap.
    private static func ticks(of time: DocumentTime) -> Int64 {
        guard let converted = try? time.time.converted(to: DocumentTime.timescale) else {
            preconditionFailure(
                "time \(time.time) is not representable at document timescale \(DocumentTime.timescale)")
        }
        return converted.value
    }
}
