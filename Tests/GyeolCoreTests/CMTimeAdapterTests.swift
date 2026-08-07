import CoreMedia
import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) -> DocumentTime {
    DocumentTime(exactly: try! RationalTime(value: ticks, timescale: 120_000))!
}

/// |residualNum/residualDen| ≤ boundNum/boundDen, cross-multiplied exactly.
private func residualWithin(_ snap: CMTimeAdapter.SnappedTime, boundNum: Int64, boundDen: Int64) -> Bool {
    Int128(snap.residualTickNumerator).magnitude * Int128(boundDen).magnitude
        <= Int128(boundNum).magnitude * Int128(snap.residualTickDenominator).magnitude
}

@Suite struct CMTimeAdapterSnapTests {
    /// Test 1 — what AVPlayer actually reports (measured: nanosecond
    /// timescale). Boundaries survive the trip and residual stays within
    /// 60000/T ticks (= half a nanosecond, in ticks).
    @Test(arguments: FrameRate.allCases)
    func nanosecondRoundTripRecoversEveryBoundary(rate: FrameRate) throws {
        for index in [0, 1, 2, 100, 1799, 107_892, 648_000] {
            let boundary = FrameMapping.time(ofFrame: index, rate: rate)
            let ns = CMTimeConvertScale(
                CMTimeAdapter.cmTime(exactly: boundary), timescale: 1_000_000_000, method: .default)
            let snap = try #require(CMTimeAdapter.documentTime(snappingToFrameGrid: ns, projectRate: rate))
            #expect(snap.time == boundary)
            #expect(FrameMapping.frameIndex(at: snap.time, rate: rate) == index)
            #expect(residualWithin(snap, boundNum: 60_000, boundDen: 1_000_000_000))
            #expect(!snap.exceedsQuarterFrameThreshold)
        }
    }

    /// Test 2 — the quantized container the probe measured (timescale 600).
    /// Every frame in a long sequence is recovered independently: residual
    /// stays within 60000/600 = 100 ticks and does not accumulate — frame
    /// 2000 is as exact as frame 1.
    @Test(arguments: FrameRate.allCases)
    func coarseContainerResidualIsBoundedAndDoesNotAccumulate(rate: FrameRate) throws {
        for index in 0..<2_000 {
            let boundary = FrameMapping.time(ofFrame: index, rate: rate)
            let coarse = CMTimeConvertScale(
                CMTimeAdapter.cmTime(exactly: boundary), timescale: 600, method: .default)
            let snap = try #require(CMTimeAdapter.documentTime(snappingToFrameGrid: coarse, projectRate: rate))
            #expect(snap.time == boundary)
            #expect(FrameMapping.frameIndex(at: snap.time, rate: rate) == index)
            #expect(residualWithin(snap, boundNum: 60_000, boundDen: 600))
            #expect(!snap.exceedsQuarterFrameThreshold)
        }
    }

    /// Test 3 — THE case this adapter exists for. One tick below a boundary
    /// floor-divides into the previous frame; the snap must land both sides
    /// on the intended frame. L1 alone cannot do this, by design.
    @Test(arguments: FrameRate.allCases)
    func oneTickEitherSideOfABoundaryLandsOnThatFrame(rate: FrameRate) throws {
        let d = rate.ticksPerFrame
        for index in [1, 2, 100, 12_345] {
            let boundaryTicks = Int64(index) * d
            for offset in [Int64(-1), 1] {
                let input = CMTime(value: boundaryTicks + offset, timescale: 120_000)
                let snap = try #require(CMTimeAdapter.documentTime(snappingToFrameGrid: input, projectRate: rate))
                #expect(FrameMapping.frameIndex(at: snap.time, rate: rate) == index)
                #expect(snap.time == docTime(boundaryTicks))
                // The discarded tick is visible, signed: input − boundary,
                // exactly ±1 tick (denominator is the input timescale).
                #expect(snap.residualTickDenominator == 120_000)
                #expect(snap.residualTickNumerator == offset * 120_000)
                #expect(!snap.exceedsQuarterFrameThreshold)
            }
        }
    }

    /// Test 4a — residual exactly AT the 1/4-frame threshold: reported with
    /// exact values, flag off (the threshold is strict), no trap. 1/40 s at
    /// 30 fps is 3000 ticks — precisely 1000 ticks (= d/4) from boundary
    /// 4000.
    @Test func residualAtExactlyQuarterFrameIsReportedWithoutTrapping() throws {
        let input = CMTime(value: 1, timescale: 40)
        let snap = try #require(CMTimeAdapter.documentTime(
            snappingToFrameGrid: input, projectRate: .fps30))
        #expect(snap.time == docTime(4_000))
        #expect(!snap.exceedsQuarterFrameThreshold)
        // residual = 3000 − 4000 = −1000 ticks, exact: −40000/40.
        #expect(snap.residualTickNumerator == -40_000)
        #expect(snap.residualTickDenominator == 40)
    }

    /// Test 4b — beyond the threshold the FLAG is set and the values stay
    /// exact; no trap. The assert that used to live here fired on external
    /// runtime data (AVFoundation echoing a seek target as a display PTS
    /// under decoder failure — measured in M2.1), so exceeding is a signal
    /// the caller owns, never a crash (§7.4-6).
    @Test func residualBeyondQuarterFrameSetsTheFlagWithExactValues() throws {
        let snap = try #require(CMTimeAdapter.documentTime(
            snappingToFrameGrid: CMTime(value: 1, timescale: 50), projectRate: .fps30))
        #expect(snap.exceedsQuarterFrameThreshold)
        #expect(snap.time == docTime(4_000))
        #expect(snap.residualTickNumerator == -80_000)
        #expect(snap.residualTickDenominator == 50)
    }

    /// D23: the carried frame index must be exactly what L1 says about the
    /// snapped time — one mapping, even when the adapter could shortcut it.
    @Test(arguments: FrameRate.allCases)
    func carriedFrameIndexMatchesL1(rate: FrameRate) throws {
        for index in [0, 1, 100, 107_892] {
            let boundary = FrameMapping.time(ofFrame: index, rate: rate)
            let ns = CMTimeConvertScale(
                CMTimeAdapter.cmTime(exactly: boundary), timescale: 1_000_000_000, method: .default)
            let snap = try #require(CMTimeAdapter.documentTime(snappingToFrameGrid: ns, projectRate: rate))
            #expect(snap.frameIndex == index)
            #expect(snap.frameIndex == FrameMapping.frameIndex(at: snap.time, rate: rate))
        }
    }

    @Test func descriptionCarriesResidualAndThresholdState() throws {
        let snap = try #require(CMTimeAdapter.documentTime(
            snappingToFrameGrid: CMTime(value: 1, timescale: 40), projectRate: .fps30))
        #expect(snap.description == "frame 1, residual -40000/40 ticks")
        let clean = try #require(CMTimeAdapter.documentTime(
            snappingToFrameGrid: CMTime(value: 4_000, timescale: 120_000), projectRate: .fps30))
        #expect(clean.description == "frame 1, residual 0/120000 ticks")
    }

    @Test func nonNumericTimesReturnNilInsteadOfLying() {
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            #expect(CMTimeAdapter.documentTime(snappingToFrameGrid: time, projectRate: .fps30) == nil)
        }
    }
}

@Suite struct CMTimeAdapterSeekTests {
    /// Test 5 — the failure the half-frame offset prevents: a seek target
    /// rounded DOWN to a coarse timescale must still land inside the
    /// intended frame. The exact boundary itself fails this for NTSC rates
    /// (measured: 5005 → 600-scale floor → 5000 → frame 0), which is why
    /// the offset exists.
    @Test(arguments: FrameRate.allCases)
    func seekTimeSurvivesRoundingDownToCoarseTimescales(rate: FrameRate) throws {
        for index in [0, 1, 2, 100, 1799, 107_892] {
            for coarseScale in [CMTimeScale(600), 1_000, 24_000, 1_000_000_000] {
                let seek = CMTimeAdapter.cmTimeForSeek(toFrame: index, projectRate: rate)
                let roundedDown = CMTimeConvertScale(
                    seek, timescale: coarseScale, method: .roundTowardNegativeInfinity)
                // Where did the rounded-down target actually land on the
                // document grid? Snap is not used here on purpose — the
                // question is which frame CONTAINS the degraded time.
                let ticks = Int128(roundedDown.value) * 120_000 / Int128(roundedDown.timescale)
                let landedFrame = Int(ticks / Int128(rate.ticksPerFrame))
                #expect(landedFrame == index,
                        "rate \(rate.rawValue), frame \(index), via \(coarseScale)")
            }
        }
    }

    @Test func exactBoundaryWithoutOffsetDemonstrablyFails() {
        // Contrast case documenting WHY the offset exists: frame 1 of
        // 23.976 rounded down through timescale 600 lands in frame 0.
        let boundary = CMTimeAdapter.cmTime(exactly: FrameMapping.time(ofFrame: 1, rate: .fps23_976))
        let degraded = CMTimeConvertScale(boundary, timescale: 600, method: .roundTowardNegativeInfinity)
        let ticks = Int64(degraded.value) * (120_000 / Int64(degraded.timescale))
        #expect(ticks == 5_000)  // below the true boundary 5005
        #expect(ticks / FrameRate.fps23_976.ticksPerFrame == 0)  // wrong frame
    }

    @Test func seekTimeIsTheFrameCenterExactly() {
        // N·d + d/2 at timescale 240000, exact even for odd d (5005).
        let seek = CMTimeAdapter.cmTimeForSeek(toFrame: 1, projectRate: .fps23_976)
        #expect(seek.value == 2 * 5_005 + 5_005)
        #expect(seek.timescale == 240_000)
    }

    @Test func exactConversionIsLossless() {
        // Not a frame boundary on purpose: composition times (clip starts,
        // durations) are arbitrary ticks and must pass through verbatim.
        let cm = CMTimeAdapter.cmTime(exactly: docTime(840_601))
        #expect(cm.value == 840_601)
        #expect(cm.timescale == 120_000)
    }
}

// MARK: - Direction 1b: frameIndexContaining (floor)

/// Exact rational location of frame `index`'s start in NANOSECONDS:
/// `index · d · 25000 / 3`. Returned as (numerator, denominator) so the
/// tests never touch a Double — the whole point is that 1e9 is not a
/// multiple of 120000 and the boundary is often not an integer nanosecond.
private func boundaryNanoseconds(frame index: Int, rate: FrameRate) -> (num: Int128, den: Int128) {
    (Int128(index) * Int128(rate.ticksPerFrame) * 25_000, 3)
}

/// The greatest integer nanosecond strictly BELOW the boundary, and the
/// least integer nanosecond AT OR ABOVE it.
private func straddlingNanoseconds(frame index: Int, rate: FrameRate) -> (below: Int64, atOrAbove: Int64) {
    let (num, den) = boundaryNanoseconds(frame: index, rate: rate)
    let floored = num / den
    let exact = num % den == 0
    return (Int64(exact ? floored - 1 : floored), Int64(exact ? floored : floored + 1))
}

private func ns(_ value: Int64) -> CMTime {
    CMTime(value: value, timescale: 1_000_000_000)
}

@Suite struct CMTimeAdapterContainingFrameTests {
    private static let frames = [0, 1, 2, 100, 1_799, 107_892]

    /// The premise the rest of this suite rests on: the item timebase
    /// reports nanoseconds, and that timescale does NOT divide evenly into
    /// document ticks. If this ever became false the "exact only at 25 µs
    /// multiples" reasoning in the adapter would be stale.
    @Test func nanosecondTimescaleIsNotAMultipleOfDocumentTicks() {
        #expect(1_000_000_000 % 120_000 != 0)
        #expect(1_000_000_000 * 120_000 % 1_000_000_000 == 0)  // ticks = ns·3/25000
        #expect(25_000 * 3 == 75_000)  // one tick = 25000/3 ns, exact at 25 µs
    }

    /// Test 1 — the half-open convention at the document timescale, where
    /// every boundary IS representable, for all eight rates. A time exactly
    /// on a boundary belongs to the LATER frame; one tick earlier belongs to
    /// the earlier one.
    @Test(arguments: FrameRate.allCases)
    func boundaryBelongsToTheLaterFrameAtDocumentTimescale(rate: FrameRate) throws {
        let d = rate.ticksPerFrame
        for index in Self.frames {
            let boundary = CMTime(value: Int64(index) * d, timescale: 120_000)

            let on = try #require(CMTimeAdapter.frameIndexContaining(boundary, projectRate: rate))
            #expect(on.frameIndex == index)
            #expect(on.residualTickNumerator == 0)
            #expect(on.frameStart.ticks == Int64(index) * d)

            let after = try #require(CMTimeAdapter.frameIndexContaining(
                CMTime(value: Int64(index) * d + 1, timescale: 120_000), projectRate: rate))
            #expect(after.frameIndex == index)
            // The residual is a FRACTION of a tick: numerator/denominator.
            // One whole tick in, with denominator = the incoming timescale.
            #expect(after.residualTickNumerator == after.residualTickDenominator)

            let beforeTime = CMTime(value: Int64(index) * d - 1, timescale: 120_000)
            if index == 0 {
                // Before zero is rejected, not trapped (external data).
                #expect(CMTimeAdapter.frameIndexContaining(beforeTime, projectRate: rate) == nil)
            } else {
                let before = try #require(
                    CMTimeAdapter.frameIndexContaining(beforeTime, projectRate: rate))
                #expect(before.frameIndex == index - 1)
                #expect(before.residualTickNumerator == (d - 1) * before.residualTickDenominator)
            }
        }
    }

    /// Test 2 — the literal ±1 ns triple, for the rates whose frame
    /// boundaries land on a whole nanosecond. Only 25 and 50 fps qualify:
    /// the boundary is `N·d·25000/3` ns, so it is an integer exactly when
    /// `N·d` is a multiple of 3, and d is 4800 / 2400 for those two.
    @Test(arguments: [FrameRate.fps25, .fps50])
    func nanosecondBoundaryTripleWhereTheBoundaryIsAWholeNanosecond(rate: FrameRate) throws {
        for index in Self.frames where index > 0 {
            let (num, den) = boundaryNanoseconds(frame: index, rate: rate)
            try #require(num % den == 0)  // the premise of this test
            let boundary = Int64(num / den)

            let before = try #require(CMTimeAdapter.frameIndexContaining(ns(boundary - 1), projectRate: rate))
            let on = try #require(CMTimeAdapter.frameIndexContaining(ns(boundary), projectRate: rate))
            let after = try #require(CMTimeAdapter.frameIndexContaining(ns(boundary + 1), projectRate: rate))

            #expect(before.frameIndex == index - 1)
            #expect(on.frameIndex == index)
            #expect(after.frameIndex == index)
            #expect(on.residualTickNumerator == 0)
        }
    }

    /// Test 3 — the same split for ALL eight rates at the nanosecond
    /// timescale, stated in the only form that is exact for every rate:
    /// the greatest ns strictly below the boundary is the earlier frame, the
    /// least ns at or above it is the later one. Six of the eight rates have
    /// no whole-nanosecond boundary at all, which this also records.
    @Test(arguments: FrameRate.allCases)
    func nanosecondStraddleSplitsAtTheBoundaryForEveryRate(rate: FrameRate) throws {
        for index in Self.frames where index > 0 {
            let (below, atOrAbove) = straddlingNanoseconds(frame: index, rate: rate)
            let earlier = try #require(CMTimeAdapter.frameIndexContaining(ns(below), projectRate: rate))
            let later = try #require(CMTimeAdapter.frameIndexContaining(ns(atOrAbove), projectRate: rate))
            #expect(earlier.frameIndex == index - 1)
            #expect(later.frameIndex == index)
        }
    }

    /// Which rates have whole-nanosecond frame boundaries — recorded so the
    /// premise of test 2 cannot drift silently.
    @Test(arguments: FrameRate.allCases)
    func onlyRatesWhoseTicksPerFrameIsAMultipleOfThreeLandOnWholeNanoseconds(rate: FrameRate) {
        let exact = rate.ticksPerFrame % 3 == 0
        #expect(exact == (rate == .fps25 || rate == .fps50))
        let (num, den) = boundaryNanoseconds(frame: 1, rate: rate)
        #expect((num % den == 0) == exact)
    }

    /// Test 4 — the load-bearing property. For nanosecond inputs that are
    /// NOT multiples of 25000 (where ns→ticks is inexact), what flooring
    /// discards must never carry the answer across a frame boundary. Checked
    /// against the exact rational interval, in integers:
    ///   N·d·25000 ≤ ns·3 < (N+1)·d·25000
    @Test(arguments: FrameRate.allCases)
    func discardedRemainderNeverCrossesAFrameBoundary(rate: FrameRate) throws {
        let d = Int128(rate.ticksPerFrame)
        // One frame in whole nanoseconds (floor) — the sweep below has to
        // cover the WHOLE frame, not just its head: floor and nearest agree
        // in the first half and only diverge past the midpoint, so a sweep
        // that stops early would pass under a rounding implementation and
        // measure nothing.
        let frameNs = Int64(Int128(rate.ticksPerFrame) * 25_000 / 3)
        // Small offsets are coprime-ish with 25000 so the ns→tick
        // conversion has a nonzero remainder (25_000 is the exact control);
        // the fractional ones walk past the half-frame midpoint.
        let offsets: [Int64] = [1, 7, 24_999, 25_000, 25_001, 41_666, 999_983]
            + [frameNs / 4, frameNs / 2, frameNs / 2 + 1, 3 * frameNs / 4, frameNs - 1]
        for index in Self.frames {
            let (num, den) = boundaryNanoseconds(frame: index, rate: rate)
            let base = Int64(num / den)  // at or just below the boundary
            for offset in offsets {
                let value = base + offset
                let containing = try #require(
                    CMTimeAdapter.frameIndexContaining(ns(value), projectRate: rate))
                let n = Int128(containing.frameIndex)
                let scaled = Int128(value) * 3
                #expect(n * d * 25_000 <= scaled)
                #expect(scaled < (n + 1) * d * 25_000)
            }
        }
    }

    /// The residual is exact and lives in [0, one frame). Reconstructing the
    /// incoming time from frameStart + residual must be an identity — that
    /// is what "exact" means here, and it is why the denominator is the
    /// incoming timescale rather than something normalized.
    @Test(arguments: FrameRate.allCases)
    func residualIsExactAndStaysInsideOneFrame(rate: FrameRate) throws {
        let d = Int128(rate.ticksPerFrame)
        for index in Self.frames {
            let (num, den) = boundaryNanoseconds(frame: index, rate: rate)
            for offset: Int64 in [0, 3, 12_345, 1_000_000, 20_000_000] {
                let value = Int64(num / den) + offset
                let c = try #require(CMTimeAdapter.frameIndexContaining(ns(value), projectRate: rate))
                #expect(c.residualTickDenominator == 1_000_000_000)
                #expect(c.residualTickNumerator >= 0)
                // residual < d ticks, cross-multiplied.
                #expect(Int128(c.residualTickNumerator) < d * Int128(c.residualTickDenominator))
                #expect(c.frameStart == FrameMapping.time(ofFrame: c.frameIndex, rate: rate))
                // frameStart·scale + residual == value·120000, exactly.
                #expect(Int128(c.frameStart.ticks) * Int128(c.residualTickDenominator)
                        + Int128(c.residualTickNumerator) == Int128(value) * 120_000)
            }
        }
    }

    /// On an exact frame boundary the two entry points agree. They are only
    /// allowed to differ off-boundary, which is the reason both exist.
    @Test(arguments: FrameRate.allCases)
    func theTwoEntryPointsAgreeOnExactBoundaries(rate: FrameRate) throws {
        for index in Self.frames {
            let boundary = CMTimeAdapter.cmTime(exactly: FrameMapping.time(ofFrame: index, rate: rate))
            let snapped = try #require(
                CMTimeAdapter.documentTime(snappingToFrameGrid: boundary, projectRate: rate))
            let containing = try #require(
                CMTimeAdapter.frameIndexContaining(boundary, projectRate: rate))
            #expect(snapped.frameIndex == containing.frameIndex)
            #expect(snapped.time == containing.frameStart)
        }
    }

    @Test func nonNumericAndNegativeInputsReturnNil() {
        #expect(CMTimeAdapter.frameIndexContaining(.invalid, projectRate: .fps30) == nil)
        #expect(CMTimeAdapter.frameIndexContaining(.indefinite, projectRate: .fps30) == nil)
        #expect(CMTimeAdapter.frameIndexContaining(.positiveInfinity, projectRate: .fps30) == nil)
        #expect(CMTimeAdapter.frameIndexContaining(ns(-1), projectRate: .fps30) == nil)
        #expect(CMTimeAdapter.frameIndexContaining(
            CMTime(value: 1, timescale: 0), projectRate: .fps30) == nil)
    }
}
