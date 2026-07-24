import Foundation
import Testing
@testable import GyeolCore

/// Exit tests: each body runs in a child process and must trap. This is the
/// only way to verify preconditions — both the initializer checks and the
/// didSet guards that close the public-setter bypass.
///
/// Bodies capture nothing; every value is built inside the child process.
@Suite struct ClipPreconditionTests {
    private static func validClip() throws -> Clip {
        Clip(
            id: ClipID(),
            timelineStart: .zero,
            duration: DocumentTime(exactly: try RationalTime(value: 1, timescale: 120_000))!,
            source: .generator(identifier: "spectrum.bar", parameters: .object([:])))
    }

    private static func negativeTime() throws -> DocumentTime {
        DocumentTime(exactly: try RationalTime(value: -1, timescale: 120_000))!
    }

    @Test func zeroDurationInitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Clip(
                id: ClipID(),
                timelineStart: .zero,
                duration: .zero,
                source: .generator(identifier: "x", parameters: .object([:])))
        }
    }

    @Test func zeroDurationAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var clip = try Self.validClip()
            clip.duration = .zero
        }
    }

    @Test func negativeTimelineStartInitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Clip(
                id: ClipID(),
                timelineStart: try Self.negativeTime(),
                duration: DocumentTime(exactly: try RationalTime(value: 1, timescale: 120_000))!,
                source: .generator(identifier: "x", parameters: .object([:])))
        }
    }

    @Test func negativeTimelineStartAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var clip = try Self.validClip()
            clip.timelineStart = try Self.negativeTime()
        }
    }

    @Test func negativeFadeInInitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Clip.AudioSettings(
                volume: FixedPointScalar(rawValue: 10_000),
                fadeIn: try Self.negativeTime(),
                fadeOut: .zero)
        }
    }

    @Test func negativeFadeOutAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var audio = Clip.AudioSettings.default
            audio.fadeOut = try Self.negativeTime()
        }
    }

    @Test func negativeSourceStartInitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = MediaSource(mediaID: MediaID(), sourceStart: try Self.negativeTime())
        }
    }

    @Test func negativeSourceStartAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var media = MediaSource(mediaID: MediaID(), sourceStart: .zero)
            media.sourceStart = try Self.negativeTime()
        }
    }
}
