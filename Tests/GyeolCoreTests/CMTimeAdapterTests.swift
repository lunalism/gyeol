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
