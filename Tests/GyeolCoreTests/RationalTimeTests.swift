import Foundation
import Testing
@testable import GyeolCore

private func rt(_ value: Int64, _ timescale: Int32) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

@Suite struct RationalTimeEqualityTests {
    @Test func exactEqualityAcrossTimescales() throws {
        #expect(try rt(1, 2) == rt(2, 4))
        #expect(try rt(24, 48000) == rt(1, 2000))
        #expect(try rt(1001, 30000) == rt(2002, 60000))
        #expect(try rt(1, 2) != rt(3, 4))
        #expect(try rt(1, 2) != rt(1, 3))
    }

    @Test func zeroIsEqualAcrossTimescales() throws {
        #expect(try rt(0, 5) == rt(0, 7))
        #expect(try rt(0, 1) == RationalTime.zero)
    }

    @Test func zeroReducesToCanonicalForm() throws {
        let reduced = try rt(0, 48000).reduced()
        #expect(reduced.value == 0)
        #expect(reduced.timescale == 1)

        let zeros = try [rt(0, 1), rt(0, 48000), rt(0, 120000)]
        #expect(zeros[0].hashValue == zeros[1].hashValue)
        #expect(zeros[1].hashValue == zeros[2].hashValue)
        #expect(Set(zeros).count == 1)
    }

    @Test func hashingIsConsistentWithEquality() throws {
        let set: Set<RationalTime> = try [rt(1, 2), rt(2, 4), rt(500, 1000)]
        #expect(set.count == 1)
        #expect(try set.contains(rt(3, 6)))
    }

    @Test func orderingAcrossTimescales() throws {
        #expect(try rt(1, 3) < rt(1, 2))
        #expect(try rt(1001, 30000) < rt(1002, 30000))
        #expect(try rt(1, 2) > rt(1, 3))
    }
}

@Suite struct RationalTimeOverflowTests {
    @Test func comparisonAtInt64BoundariesDoesNotOverflow() throws {
        // Cross-multiplication here is ~2^94; verifies comparisons use 128-bit math.
        #expect(try rt(Int64.max, Int32.max) > rt(Int64.max - 1, Int32.max))
        #expect(try rt(Int64.min, Int32.max) < rt(Int64.min + 1, Int32.max))
        #expect(try rt(Int64.max, Int32.max) == rt(Int64.max, Int32.max))
    }

    @Test func addingBeyondInt64MaxThrows() throws {
        let max = try rt(Int64.max, 1)
        #expect(throws: RationalTimeError.overflow) { try max.adding(rt(1, 1)) }
    }

    @Test func subtractingBeyondInt64MinThrows() throws {
        let min = try rt(Int64.min, 1)
        #expect(throws: RationalTimeError.overflow) { try min.subtracting(rt(1, 1)) }
    }

    @Test func addingReducesToFitWhenExactResultIsRepresentable() throws {
        // max/2 + max/2 = max/1: the numerator 2·max exceeds Int64, but the
        // reduced exact result fits and must be returned, not rejected.
        let sum = try rt(Int64.max, 2).adding(rt(Int64.max, 2))
        #expect(sum.value == Int64.max)
        #expect(sum.timescale == 1)
    }

    @Test func boundaryValuesSurviveArithmeticExactly() throws {
        let almostMax = try rt(Int64.max - 1, 1)
        let sum = try almostMax.adding(rt(1, 1))
        #expect(sum.value == Int64.max)

        let backDown = try sum.subtracting(rt(1, 1))
        #expect(backDown == almostMax)
    }

    @Test func conversionOverflowThrows() throws {
        #expect(throws: RationalTimeError.overflow) {
            try rt(Int64.max, 1).converted(to: 2)
        }
    }

    @Test func coprimeTimescaleLCMBeyondInt32Throws() throws {
        // Two large distinct primes: the LCM is their product (~4.6e18), far
        // beyond Int32.max, and (p+q)/(p·q) is already in lowest terms, so the
        // reduction path cannot rescue it. The *timescale* overflows here even
        // though the value would fit Int64.
        let p: Int32 = 2_147_483_647 // Int32.max, prime
        let q: Int32 = 2_147_483_629 // prime
        #expect(throws: RationalTimeError.overflow) {
            try rt(1, p).adding(rt(1, q))
        }
    }
}

@Suite struct RationalTimeNegativeValueTests {
    @Test func negativeEqualityAcrossTimescales() throws {
        #expect(try rt(-1, 2) == rt(-2, 4))
        #expect(try rt(-1, 2) != rt(1, 2))
    }

    @Test func negativeOrdering() throws {
        #expect(try rt(-1, 2) < rt(-1, 4))
        #expect(try rt(-1, 4) < RationalTime.zero)
        #expect(try rt(-1, 2) < rt(1, 2))
    }

    @Test func negativeArithmetic() throws {
        #expect(try rt(-1, 2).adding(rt(1, 2)) == RationalTime.zero)
        #expect(try rt(1, 4).subtracting(rt(3, 4)) == rt(-1, 2))
        #expect(try rt(-1, 2).adding(rt(-1, 3)) == rt(-5, 6))
    }

    @Test func negativeConversion() throws {
        let converted = try rt(-1, 2).converted(to: 1000)
        #expect(converted.value == -500)
        #expect(converted.timescale == 1000)
    }
}

@Suite struct RationalTimeTimescaleValidationTests {
    @Test func zeroTimescaleThrows() {
        #expect(throws: RationalTimeError.invalidTimescale(0)) {
            try RationalTime(value: 1, timescale: 0)
        }
    }

    @Test func negativeTimescaleThrows() {
        #expect(throws: RationalTimeError.invalidTimescale(-5)) {
            try RationalTime(value: 1, timescale: -5)
        }
    }

    @Test func conversionToZeroTimescaleThrows() throws {
        #expect(throws: RationalTimeError.invalidTimescale(0)) {
            try rt(1, 2).converted(to: 0)
        }
    }

    @Test func decodingZeroTimescaleFails() throws {
        let json = Data(#"{"value": 1, "timescale": 0}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RationalTime.self, from: json)
        }
    }
}

@Suite struct RationalTimeArithmeticTests {
    @Test func mismatchedTimescalesCombineExactly() throws {
        #expect(try rt(1, 2).adding(rt(1, 3)) == rt(5, 6))
        #expect(try rt(1, 24).adding(rt(1, 30)) == rt(9, 120))
        #expect(try rt(1, 2).subtracting(rt(1, 3)) == rt(1, 6))
    }

    @Test func sameTimescaleIsPreservedVerbatim() throws {
        let sum = try rt(1, 48000).adding(rt(1, 48000))
        #expect(sum.value == 2)
        #expect(sum.timescale == 48000)
    }

    @Test func throwingOperatorsMatchNamedMethods() throws {
        #expect(try rt(1, 2) + rt(1, 3) == rt(1, 2).adding(rt(1, 3)))
        #expect(try rt(1, 2) - rt(1, 3) == rt(1, 2).subtracting(rt(1, 3)))
    }
}

@Suite struct RationalTimeConversionTests {
    @Test func exactConversion() throws {
        let converted = try rt(1, 2).converted(to: 1000)
        #expect(converted.value == 500)
        #expect(converted.timescale == 1000)
        #expect(try rt(1, 3).converted(to: 6) == rt(2, 6))
    }

    @Test func lossyConversionThrowsInsteadOfTruncating() throws {
        #expect(throws: RationalTimeError.lossyConversion) {
            try rt(1, 3).converted(to: 1000)
        }
        #expect(throws: RationalTimeError.lossyConversion) {
            try rt(1001, 30000).converted(to: 25)
        }
    }
}

@Suite struct RationalTimeCodableTests {
    @Test func roundTripPreservesRepresentation() throws {
        let original = try rt(1001, 30000)
        let decoded = try JSONDecoder().decode(
            RationalTime.self, from: JSONEncoder().encode(original))
        #expect(decoded.value == original.value)
        #expect(decoded.timescale == original.timescale)
    }

    @Test func encodingPreservesStoredFormWithoutReduction() throws {
        // 2/4 is == to 1/2 but must encode its stored representation.
        let decoded = try JSONDecoder().decode(
            RationalTime.self, from: JSONEncoder().encode(rt(2, 4)))
        #expect(decoded.value == 2)
        #expect(decoded.timescale == 4)
    }

    @Test func modelToDataRoundTripIsByteIdenticalUnderFixedEncoder() throws {
        // Deterministic configuration is the caller's job — RationalTime
        // itself must not configure encoders. Default JSONEncoder key order
        // is nondeterministic, so .sortedKeys is required for byte-identity.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let first = try encoder.encode(rt(1001, 30000))
        let second = try encoder.encode(
            JSONDecoder().decode(RationalTime.self, from: first))
        #expect(first == second)
    }
}
