import Foundation
import GyeolCore

/// The visible time window of the timeline: where it starts and how many
/// document ticks one point covers.
///
/// COORDINATE CONTRACT (PRD §5.2): absolute timeline coordinates never reach
/// the GPU. All absolute arithmetic happens here, on the CPU, in `Int64`
/// ticks and `Double`; what leaves this type is a viewport-RELATIVE x in
/// points, whose magnitude is screen-width scale — safely inside float32
/// integer precision. Metal vertex coordinates are float32 (~1.67e7 exact
/// integers); three hours at high zoom runs to billions of ticks, and
/// pushing that through float32 shows up as clip edges shimmering at high
/// zoom — a failure nobody would trace to floating point.
///
/// Pixels-to-time and time-to-pixels live in the APP on purpose: GyeolCore
/// must not learn about points, zoom levels or pointer coordinates
/// (§5.6.5). The frame grid enters only through `FrameMapping` (§6.2 — no
/// `ticks / ticksPerFrame` anywhere else).
struct TimelineViewport: Equatable {
    /// Leftmost visible instant, absolute document ticks.
    var visibleStartTicks: Int64
    /// Zoom: document ticks per view point. Larger = more zoomed out.
    var ticksPerPoint: Double

    /// 40 ticks/pt ≈ one 30fps frame per 100 pt (fine trimming); 2M ticks/pt
    /// puts 3 h in ~650 pt (whole-project overview on a small window).
    static let minTicksPerPoint: Double = 40
    static let maxTicksPerPoint: Double = 2_000_000

    /// Below this zoom the average subtitle is wide enough to carry legible
    /// text (a 3 s segment ≥ ~40 pt). Above it we draw rectangles only —
    /// 3,600 Core Text lines nobody can read is pure waste (§5.2).
    static let maxTicksPerPointForSubtitleText: Double = 9_000

    static let initial = TimelineViewport(visibleStartTicks: 0, ticksPerPoint: 12_000)

    // MARK: - Coordinate conversion (CPU only)

    /// Viewport-relative x in points. Exact Int64 subtraction FIRST, then
    /// one Double division — the subtraction is what keeps the magnitude
    /// small before any floating point is involved.
    func x(ofTicks ticks: Int64) -> Double {
        Double(ticks - visibleStartTicks) / ticksPerPoint
    }

    /// Absolute ticks under viewport x, rounded to the nearest tick and
    /// clamped non-negative (pointer input; nothing exists before zero).
    func ticks(atX x: Double) -> Int64 {
        let offset = (x * ticksPerPoint).rounded()
        guard offset.isFinite else { return visibleStartTicks }
        return max(0, visibleStartTicks + Int64(offset))
    }

    func visibleEndTicks(width: Double) -> Int64 {
        let span = (Double(width) * ticksPerPoint).rounded(.up)
        let (end, overflow) = visibleStartTicks.addingReportingOverflow(Int64(span))
        return overflow ? Int64.max : end
    }

    // MARK: - Navigation

    /// Pan by a point delta (positive = content moves left / later times
    /// scroll into view). Clamped so the timeline origin cannot go negative.
    mutating func pan(byPoints delta: Double) {
        let ticksDelta = (delta * ticksPerPoint).rounded()
        guard ticksDelta.isFinite else { return }
        visibleStartTicks = max(0, visibleStartTicks + Int64(ticksDelta))
    }

    /// Zoom by a factor, keeping the time under `anchorX` stationary on
    /// screen — the standard cursor-anchored zoom.
    mutating func zoom(by factor: Double, anchorX: Double) {
        guard factor.isFinite, factor > 0 else { return }
        let anchorTicks = Double(visibleStartTicks) + anchorX * ticksPerPoint
        ticksPerPoint = (ticksPerPoint * factor)
            .clamped(to: Self.minTicksPerPoint...Self.maxTicksPerPoint)
        visibleStartTicks = max(0, Int64((anchorTicks - anchorX * ticksPerPoint).rounded()))
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
