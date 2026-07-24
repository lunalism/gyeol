import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) -> DocumentTime {
    DocumentTime(try! RationalTime(value: ticks, timescale: 120_000))
}

@Suite struct FrameMappingTests {
    /// Locks the integer literals to FrameRate's rational frame durations.
    /// If either representation changes without the other, this fails.
    @Test(arguments: FrameRate.allCases)
    func ticksPerFrameMatchesFrameDuration(rate: FrameRate) throws {
        let fromRational = try rate.frameDuration.converted(to: DocumentTime.timescale)
        #expect(rate.ticksPerFrame == fromRational.value)
    }

    @Test(arguments: FrameRate.allCases)
    func roundTripReturnsOriginalIndex(rate: FrameRate) {
        for index in [0, 1, 2, 59, 60, 1_799, 1_800, 107_892, 648_000, 10_000_000] {
            let time = FrameMapping.time(ofFrame: index, rate: rate)
            #expect(FrameMapping.frameIndex(at: time, rate: rate) == index)
        }
    }

    @Test(arguments: FrameRate.allCases)
    func boundaryBelongsToTheLaterFrame(rate: FrameRate) {
        let d = rate.ticksPerFrame
        for n in [Int64(1), 30, 12_345] {
            #expect(FrameMapping.frameIndex(at: docTime(n * d), rate: rate) == Int(n))
            #expect(FrameMapping.frameIndex(at: docTime(n * d - 1), rate: rate) == Int(n) - 1)
            #expect(FrameMapping.frameIndex(at: docTime(n * d + 1), rate: rate) == Int(n))
        }
    }

    @Test(arguments: FrameRate.allCases)
    func interiorTicksMapToTheSameFrame(rate: FrameRate) {
        let d = rate.ticksPerFrame
        let base = 7 * d
        for offset in [Int64(0), 1, d / 2, d - 1] {
            #expect(FrameMapping.frameIndex(at: docTime(base + offset), rate: rate) == 7)
        }
    }

    @Test func oneHourOfNTSCHasNoAccumulatedDrift() {
        // The case that breaks naive implementations: 1/29.97 as a Double
        // accumulates error over 100k frames; integer ticks do not.
        let oneHour = docTime(3_600 * 120_000)  // 432,000,000 ticks

        // 29.97: d = 4004. 432e6 / 4004 = 107,892.107… — the hour mark sits
        // inside frame 107892, and the partial frame counts.
        #expect(FrameMapping.frameIndex(at: oneHour, rate: .fps29_97) == 107_892)
        #expect(FrameMapping.frameCount(for: oneHour, rate: .fps29_97) == 107_893)
        #expect(FrameMapping.time(ofFrame: 107_892, rate: .fps29_97) == docTime(431_999_568))

        // 23.976: d = 5005. 432e6 / 5005 = 86,313.686…
        #expect(FrameMapping.frameIndex(at: oneHour, rate: .fps23_976) == 86_313)
        #expect(FrameMapping.frameCount(for: oneHour, rate: .fps23_976) == 86_314)
        #expect(FrameMapping.time(ofFrame: 86_313, rate: .fps23_976) == docTime(431_996_565))
    }

    @Test func threeHoursAt60fpsIsExactWithNoOverflow() {
        let threeHours = docTime(10_800 * 120_000)  // 1,296,000,000 ticks
        #expect(FrameMapping.frameCount(for: threeHours, rate: .fps60) == 648_000)
        // Exactly on the boundary: belongs to the later frame.
        #expect(FrameMapping.frameIndex(at: threeHours, rate: .fps60) == 648_000)
        #expect(FrameMapping.time(ofFrame: 648_000, rate: .fps60) == threeHours)
    }

    @Test func frameCountCeilsPartialTrailingFrames() {
        // fps30: d = 4000.
        #expect(FrameMapping.frameCount(for: docTime(12_000), rate: .fps30) == 3)  // exact multiple
        #expect(FrameMapping.frameCount(for: docTime(12_001), rate: .fps30) == 4)  // one tick over
        #expect(FrameMapping.frameCount(for: docTime(11_999), rate: .fps30) == 3)  // one tick under
        #expect(FrameMapping.frameCount(for: docTime(1), rate: .fps30) == 1)       // sliver
        #expect(FrameMapping.frameCount(for: docTime(0), rate: .fps30) == 0)
    }

    @Test func frameCountAtInt64MaxDurationDoesNotOverflow() {
        // Int64.max ticks decodes as a valid duration; the ceiling must not
        // trap on the way to a representable count.
        // Int64.max = 4_611_686_018_427_387 × 2000 + 1807.
        #expect(FrameMapping.frameCount(for: docTime(Int64.max), rate: .fps60)
            == 4_611_686_018_427_388)
    }

    /// In-memory misuse traps (precondition), matching the project
    /// convention — only external-file boundaries throw.
    @Test func negativeFrameIndexTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = FrameMapping.time(ofFrame: -1, rate: .fps30)
        }
    }
}
