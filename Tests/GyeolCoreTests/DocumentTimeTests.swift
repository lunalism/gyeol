import Foundation
import Testing
@testable import GyeolCore

private func rt(_ value: Int64, _ timescale: Int32) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

private func decodeTime(_ json: String) throws -> DocumentTime {
    try GyeolCoding.makeDecoder().decode(DocumentTime.self, from: Data(json.utf8))
}

@Suite struct DocumentTimeTests {
    @Test func bareIntegerDecodesAsTicksAt120000() throws {
        let time = try decodeTime("240000")
        #expect(time.time.value == 240_000)
        #expect(time.time.timescale == 120_000)
        #expect(try decodeTime("0").time == .zero)
    }

    @Test func fractionalNumberThrows() {
        #expect(throws: (any Error).self) { try decodeTime("1.5") }
    }

    @Test func outOfInt64RangeThrows() throws {
        #expect(throws: (any Error).self) { try decodeTime("9223372036854775808") }
        #expect(throws: (any Error).self) { try decodeTime("-9223372036854775809") }
        #expect(try decodeTime("9223372036854775807").time.value == Int64.max)
    }

    @Test func legacyObjectFormThrowsWithExplicitMessage() throws {
        do {
            _ = try decodeTime(#"{"timescale": 120000, "value": 240000}"#)
            Issue.record("expected a throw")
        } catch let error as DecodingError {
            guard case .dataCorrupted(let context) = error else {
                Issue.record("expected dataCorrupted, got \(error)")
                return
            }
            // The message must say what shape was expected, not surface a
            // confusing type mismatch.
            #expect(context.debugDescription.contains("bare integer tick count"))
        }
    }

    @Test func encodingConvertsExactlyTo120000Ticks() throws {
        // In-memory values at foreign timescales still write as 120000
        // ticks; the exactness of the conversion itself is RationalTime's
        // contract, covered by RationalTimeConversionTests.
        let data = try GyeolCoding.makeEncoder().encode(DocumentTime(exactly: try rt(1, 2))!)
        #expect(String(decoding: data, as: UTF8.self) == "60000")
    }

    @Test func byteIdentityRoundTrip() throws {
        let encoder = GyeolCoding.makeEncoder()
        let time = DocumentTime(exactly: try rt(5_005, 120_000))!
        let data1 = try encoder.encode(time)
        let decoded = try GyeolCoding.makeDecoder().decode(DocumentTime.self, from: data1)
        #expect(decoded == time)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func exactlyRejectsTimesOffTheTickGrid() throws {
        // Audio sample times are the motivating case: 1/44100 s is not an
        // integer number of 120000 ticks.
        #expect(DocumentTime(exactly: try rt(1, 44_100)) == nil)
        #expect(DocumentTime(exactly: try rt(1, 7)) == nil)
        // 441/44100 = 1/100 s = 1200 ticks — on the grid, accepted, and
        // NORMALIZED at construction: the stored value is ticks, not the
        // caller's representation. (Contract change from the previous
        // preserve-representation behavior — the type is "항상 120000" now.)
        let hundredth = try #require(DocumentTime(exactly: try rt(441, 44_100)))
        #expect(hundredth.ticks == 1_200)
        #expect(hundredth.time.value == 1_200)
        #expect(hundredth.time.timescale == 120_000)
    }

    @Test func roundingConvertsAudioSampleTimesVisibly() throws {
        // 1/44100 s = 2.721… ticks.
        #expect(try DocumentTime(rounding: rt(1, 44_100)).time.value == 3)
        #expect(try DocumentTime(rounding: rt(1, 44_100), rule: .down).time.value == 2)
        // 1/48000 s = exactly 2.5 ticks — the half boundary, both rules.
        #expect(try DocumentTime(rounding: rt(1, 48_000)).time.value == 3)  // away from zero
        #expect(try DocumentTime(rounding: rt(1, 48_000), rule: .toNearestOrEven).time.value == 2)
        #expect(try DocumentTime(rounding: rt(-1, 48_000)).time.value == -3)  // symmetric
        // On-grid input passes through without loss.
        #expect(try DocumentTime(rounding: rt(1, 2)).time.value == 60_000)
        #expect(try DocumentTime(rounding: rt(1, 2)).time.timescale == 120_000)
    }

    @Test func offGridAssignmentTraps() async {
        // Triple guard, didSet leg: a valid DocumentTime cannot be mutated
        // into an unserializable one.
        await #expect(processExitsWith: .failure) {
            var time = DocumentTime.zero
            time.time = try RationalTime(value: 1, timescale: 44_100)
        }
    }
}
