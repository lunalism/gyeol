import Foundation
import Testing
@testable import GyeolCore

private func encode(_ value: GyeolValue) throws -> Data {
    try GyeolCoding.makeEncoder().encode(value)
}

private func decode(_ data: Data) throws -> GyeolValue {
    try GyeolCoding.makeDecoder().decode(GyeolValue.self, from: data)
}

private func decode(_ json: String) throws -> GyeolValue {
    try decode(Data(json.utf8))
}

@Suite struct GyeolValueRoundTripTests {
    @Test func byteIdentityForDeeplyNestedValue() throws {
        let value: GyeolValue = .object([
            "barCount": .int(64),
            "sensitivity": .int(7500),
            "label": .string("bass"),
            "enabled": .bool(true),
            "legacy": .null,
            "bands": .array([
                .object([
                    "range": .array([.int(20), .int(200)]),
                    "meta": .object([
                        "colors": .array([.string("#ff0000"), .string("#00ff00")]),
                        "nested": .object(["deeper": .array([.object(["x": .int(-1)])])]),
                    ]),
                ]),
                .int(0),
                .null,
            ]),
        ])
        let data1 = try encode(value)
        let decoded = try decode(data1)
        let data2 = try encode(decoded)
        #expect(decoded == value)
        #expect(data1 == data2)
    }

    @Test func encodesAsPlainJSONWithoutTypeTags() throws {
        let value: GyeolValue = .object([
            "barCount": .int(64), "sensitivity": .int(7500), "label": .string("bass"),
        ])
        let json = try JSONSerialization.jsonObject(with: encode(value))
        let dict = try #require(json as? [String: Any])
        #expect(Set(dict.keys) == ["barCount", "sensitivity", "label"])
        #expect(dict["barCount"] as? Int64 == 64)
        #expect(dict["label"] as? String == "bass")
    }

    @Test func keyOrderingIsStableAcrossRepeatedEncodes() throws {
        let value: GyeolValue = .object([
            "zeta": .int(1), "alpha": .int(2), "mid": .object(["b": .int(3), "a": .int(4)]),
        ])
        let first = try encode(value)
        for _ in 0..<20 {
            #expect(try encode(value) == first)
        }
    }
}

@Suite struct GyeolValueUnknownKeySurvivalTests {
    @Test func unknownKeysSurviveLoadSaveCycle() throws {
        // Keys and shapes this code has never seen — a future effect's params.
        let foreign = """
            {"v2OnlyParam": {"attack": 12, "curve": "exp"}, \
            "zzz_experimental": [1, 2, {"deep": null, "flag": false}], \
            "renamedLater": true}
            """
        let decoded = try decode(foreign)
        let object = try #require(decoded.objectValue)
        #expect(Set(object.keys) == ["v2OnlyParam", "zzz_experimental", "renamedLater"])

        let reencoded = try encode(decoded)
        #expect(try decode(reencoded) == decoded)
        // And the re-encode is itself stable byte-for-byte.
        #expect(try encode(decode(reencoded)) == reencoded)
    }
}

@Suite struct GyeolValueNumberStrictnessTests {
    @Test func fractionalNumberThrows() throws {
        #expect(throws: (any Error).self) { try decode(#"{"x": 1.5}"#) }
    }

    /// The rejection must not be swallowed by outer array/object decoding at
    /// any nesting shape or depth. The concrete case thrown is
    /// `DecodingError.dataCorrupted` — thrown by `GyeolValue.init(from:)`
    /// itself after `Int64` fails and `Double` succeeds — never
    /// `.typeMismatch`, which is what outer containers throw for the wrong
    /// token kind and what the array→object fallthrough is allowed to eat.
    @Test(arguments: [
        #"[1.5]"#,                          // in an array (top-level fragment)
        #"{"x": 1.5}"#,                     // in an object
        #"{"a": [1, 1.5]}"#,                // in an array inside an object
        #"{"a": {"b": [{"c": [1.5]}]}}"#,   // at depth 5
    ])
    func fractionalRejectionIsNeverSwallowed(json: String) {
        do {
            _ = try decode(json)
            Issue.record("expected a throw for \(json)")
        } catch let error as DecodingError {
            if case .typeMismatch = error {
                Issue.record("rejection degraded to typeMismatch for \(json): \(error)")
                return
            }
            guard case .dataCorrupted(let context) = error else {
                Issue.record("expected dataCorrupted for \(json), got \(error)")
                return
            }
            #expect(context.debugDescription.contains("fractional"))
        } catch {
            Issue.record("expected DecodingError for \(json), got \(error)")
        }
    }

    @Test func integersAbovePowerOf53DecodeExactly() throws {
        // JSONDecoder computes integral-valued float notation (1.5e1 → 15),
        // so some path evaluates numbers rather than reading raw digits. If
        // plain integer tokens also went through Double, 2^53 + 1 would
        // silently round to 2^53 while staying inside Int64 range — a loss
        // the out-of-range test cannot see.
        #expect(try decode(#"{"x": 9007199254740993}"#)["x"] == .int(9_007_199_254_740_993))
        #expect(try decode(#"{"x": -9007199254740993}"#)["x"] == .int(-9_007_199_254_740_993))
        #expect(try decode(#"{"x": 9223372036854775807}"#)["x"] == .int(Int64.max))
        #expect(try decode(#"{"x": -9223372036854775808}"#)["x"] == .int(Int64.min))
    }

    @Test func integerOutsideInt64RangeThrows() throws {
        #expect(throws: (any Error).self) { try decode(#"{"x": 9223372036854775808}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"x": -9223372036854775809}"#) }
        #expect(try decode(#"{"x": 9223372036854775807}"#)["x"] == .int(Int64.max))
        #expect(try decode(#"{"x": -9223372036854775808}"#)["x"] == .int(Int64.min))
    }

    /// Documented Foundation behavior, not a design goal: `JSONDecoder`
    /// accepts any number token whose mathematical value fits Int64 exactly,
    /// so integral-valued float notation cannot be rejected without replacing
    /// the parser. See the doc comment on `GyeolValue: Codable`. If this test
    /// ever fails, Foundation changed — update the documentation, not just
    /// the test.
    @Test func integralFloatNotationDecodesAsInt() throws {
        #expect(try decode(#"{"x": 1.0}"#)["x"] == .int(1))
        #expect(try decode(#"{"x": 1e2}"#)["x"] == .int(100))
        #expect(try decode(#"{"x": 1.5e1}"#)["x"] == .int(15))
    }

    @Test func boolAndIntNeverCrossDecode() throws {
        #expect(try decode(#"{"t": true, "f": false}"#) ==
            .object(["t": .bool(true), "f": .bool(false)]))
        #expect(try decode(#"{"n": 1, "z": 0}"#) ==
            .object(["n": .int(1), "z": .int(0)]))
    }
}

@Suite struct GyeolValueEdgeCaseTests {
    @Test(arguments: [
        GyeolValue.object([:]),
        .array([]),
        .null,
        .array([.int(42)]),
        // Depth 6: object > array > object > array > object > int
        .object(["l1": .array([.object(["l3": .array([.object(["l5": .int(6)])])])])]),
    ])
    func byteIdentityRoundTrip(value: GyeolValue) throws {
        let data1 = try encode(value)
        let decoded = try decode(data1)
        #expect(decoded == value)
        #expect(try encode(decoded) == data1)
    }

    @Test func emptyStringAndUnicodeSurvive() throws {
        let value: GyeolValue = .object([
            "empty": .string(""),
            "korean": .string("결 — 자막"),
            "path": .string("media/원본/클립.mov"),
        ])
        let data = try encode(value)
        #expect(try decode(data) == value)
        // .withoutEscapingSlashes: relative paths stay readable in diffs.
        #expect(String(data: data, encoding: .utf8)!.contains("media/원본/클립.mov"))
    }
}

@Suite struct GyeolValueAccessorTests {
    @Test func accessorsReturnValueOnlyForMatchingCase() throws {
        let value = try decode(#"{"count": 3, "name": "spectrum", "on": true, "items": [10, 20]}"#)
        #expect(value["count"]?.intValue == 3)
        #expect(value["name"]?.stringValue == "spectrum")
        #expect(value["on"]?.boolValue == true)
        #expect(value["items"]?[0]?.intValue == 10)
        #expect(value["items"]?[1]?.intValue == 20)

        // Mismatched case or missing key/index: nil, never a conversion.
        #expect(value["count"]?.stringValue == nil)
        #expect(value["count"]?.boolValue == nil)
        #expect(value["name"]?.intValue == nil)
        #expect(value["missing"] == nil)
        #expect(value["items"]?[2] == nil)
        #expect(value["items"]?[-1] == nil)
        #expect(value["count"]?["sub"] == nil)
        #expect(value[0] == nil)
    }

    @Test func nullIsDistinctFromAbsent() throws {
        let value = try decode(#"{"present": null}"#)
        #expect(value["present"]?.isNull == true)
        #expect(value["present"]?.intValue == nil)
        #expect(value["absent"] == nil)
    }
}
