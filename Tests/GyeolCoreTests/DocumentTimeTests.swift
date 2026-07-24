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
        let data = try GyeolCoding.makeEncoder().encode(DocumentTime(try rt(1, 2)))
        #expect(String(decoding: data, as: UTF8.self) == "60000")
    }

    @Test func byteIdentityRoundTrip() throws {
        let encoder = GyeolCoding.makeEncoder()
        let time = DocumentTime(try rt(5_005, 120_000))
        let data1 = try encoder.encode(time)
        let decoded = try GyeolCoding.makeDecoder().decode(DocumentTime.self, from: data1)
        #expect(decoded == time)
        #expect(try encoder.encode(decoded) == data1)
    }
}
