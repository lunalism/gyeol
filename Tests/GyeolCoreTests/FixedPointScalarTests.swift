import Foundation
import Testing
@testable import GyeolCore

private func ticks(_ raw: Int32) -> FixedPointScalar {
    FixedPointScalar(rawValue: raw)
}

@Suite struct FixedPointScalarCodableTests {
    @Test(arguments: [Int32]([0, 1, -1, 7500, -7500, 10000, Int32.max, Int32.min]))
    func byteIdentityRoundTrip(raw: Int32) throws {
        let encoder = GyeolCoding.makeEncoder()
        let data1 = try encoder.encode(ticks(raw))
        let decoded = try GyeolCoding.makeDecoder().decode(FixedPointScalar.self, from: data1)
        #expect(decoded == ticks(raw))
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func encodesAsBareIntegerNotObject() throws {
        let data = try GyeolCoding.makeEncoder().encode(["volume": ticks(7500)])
        let json = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(json as? [String: Any])
        #expect(dict["volume"] as? Int32 == 7500)
    }

    @Test func decodingFractionalJSONNumberFails() throws {
        let decoder = GyeolCoding.makeDecoder()
        #expect(throws: (any Error).self) {
            try decoder.decode([String: FixedPointScalar].self, from: Data(#"{"v": 7500.5}"#.utf8))
        }
        // Outside Int32 range must also fail, not wrap.
        #expect(throws: (any Error).self) {
            try decoder.decode([String: FixedPointScalar].self, from: Data(#"{"v": 3000000000}"#.utf8))
        }
        #expect(try decoder.decode(
            [String: FixedPointScalar].self, from: Data(#"{"v": 7500}"#.utf8)) == ["v": ticks(7500)])
    }
}

@Suite struct FixedPointScalarRoundingTests {
    @Test func halfTickBoundaryUnderEachRule() throws {
        // 2.5 / 10000 is not dyadic, so first pin down that the scaled
        // product is exactly 2.5 in Double — the boundary the test is about.
        // If this ever fails, the assertions below are testing nothing.
        let halfUp = 2.5 / Double(FixedPointScalar.scale)
        #expect(halfUp * Double(FixedPointScalar.scale) == 2.5)

        #expect(try FixedPointScalar(rounding: halfUp).rawValue == 3)  // default: away from zero
        #expect(try FixedPointScalar(rounding: halfUp, rule: .toNearestOrAwayFromZero).rawValue == 3)
        #expect(try FixedPointScalar(rounding: halfUp, rule: .toNearestOrEven).rawValue == 2)
        #expect(try FixedPointScalar(rounding: halfUp, rule: .down).rawValue == 2)
        #expect(try FixedPointScalar(rounding: halfUp, rule: .up).rawValue == 3)
        #expect(try FixedPointScalar(rounding: halfUp, rule: .towardZero).rawValue == 2)

        let evenSide = 3.5 / Double(FixedPointScalar.scale)
        #expect(evenSide * Double(FixedPointScalar.scale) == 3.5)
        #expect(try FixedPointScalar(rounding: evenSide, rule: .toNearestOrEven).rawValue == 4)
    }

    @Test func negativeHalfTickBoundary() throws {
        let halfDown = -2.5 / Double(FixedPointScalar.scale)
        #expect(halfDown * Double(FixedPointScalar.scale) == -2.5)

        #expect(try FixedPointScalar(rounding: halfDown).rawValue == -3)  // symmetric about zero
        #expect(try FixedPointScalar(rounding: halfDown, rule: .toNearestOrEven).rawValue == -2)
        #expect(try FixedPointScalar(rounding: halfDown, rule: .down).rawValue == -3)
        #expect(try FixedPointScalar(rounding: halfDown, rule: .up).rawValue == -2)
        #expect(try FixedPointScalar(rounding: halfDown, rule: .towardZero).rawValue == -2)
    }

    @Test func negativeValuesAndOffscreenPositionsAreNotClamped() throws {
        #expect(try FixedPointScalar(rounding: -0.25).rawValue == -2500)
        #expect(try FixedPointScalar(rounding: 1.5).rawValue == 15000)
        #expect(ticks(-2500).doubleValue == -0.25)
        #expect(ticks(-1) < ticks(0))
        #expect(ticks(10001) > ticks(10000))
    }

    @Test func nonFiniteInputThrows() {
        #expect(throws: FixedPointScalarError.nonFinite) { try FixedPointScalar(rounding: .nan) }
        #expect(throws: FixedPointScalarError.nonFinite) { try FixedPointScalar(rounding: .infinity) }
        #expect(throws: FixedPointScalarError.nonFinite) { try FixedPointScalar(rounding: -.infinity) }
    }

    @Test func outOfInt32RangeThrowsInsteadOfClamping() {
        // 300000 * 10000 = 3e9 > Int32.max
        #expect(throws: FixedPointScalarError.outOfRange) { try FixedPointScalar(rounding: 300_000) }
        #expect(throws: FixedPointScalarError.outOfRange) { try FixedPointScalar(rounding: -300_000) }
    }

    @Test func int32Extremes() throws {
        #expect(ticks(Int32.max).doubleValue == Double(Int32.max) / 10000)
        #expect(ticks(Int32.min).doubleValue == Double(Int32.min) / 10000)
        #expect(try FixedPointScalar(rounding: ticks(Int32.max).doubleValue).rawValue == Int32.max)
        #expect(try FixedPointScalar(rounding: ticks(Int32.min).doubleValue).rawValue == Int32.min)
    }
}

@Suite struct FixedPointScalarExactConversionTests {
    @Test func exactlyAcceptsOnGridValues() {
        #expect(FixedPointScalar(exactly: 0.75)?.rawValue == 7500)
        #expect(FixedPointScalar(exactly: 0)?.rawValue == 0)
        #expect(FixedPointScalar(exactly: -0.25)?.rawValue == -2500)
        #expect(FixedPointScalar(exactly: 1.0)?.rawValue == 10000)
    }

    @Test func exactlyRejectsOffGridAndUnrepresentableInput() {
        #expect(FixedPointScalar(exactly: 1.0 / 3.0) == nil)
        #expect(FixedPointScalar(exactly: 1.5 / Double(FixedPointScalar.scale)) == nil)  // 1.5 ticks
        #expect(FixedPointScalar(exactly: 1e300) == nil)  // integral but far outside Int32
        #expect(FixedPointScalar(exactly: .nan) == nil)
        #expect(FixedPointScalar(exactly: .infinity) == nil)
        #expect(FixedPointScalar(exactly: -.infinity) == nil)
    }

    @Test(arguments: [Int32]([-10000, -1, 0, 1, 9999, 12345, Int32.max, Int32.min]))
    func doubleValueRoundTripsThroughExactly(raw: Int32) {
        #expect(FixedPointScalar(exactly: ticks(raw).doubleValue) == ticks(raw))
    }
}
