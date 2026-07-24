import Foundation
import Testing
@testable import GyeolCore

private func rt(_ value: Int64, _ timescale: Int32) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

@Suite struct MediaReferenceTests {
    func fullReference() throws -> MediaReference {
        MediaReference(
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            relativePath: "media/원본/클립.mov",
            contentFingerprint: ContentFingerprint(value: Data([0x01, 0x02]), byteSize: 1_048_576),
            displayName: "클립.mov",
            duration: DocumentTime(try rt(600_000, 120_000)))
    }

    @Test func byteIdentityRoundTripFullyPopulated() throws {
        let encoder = GyeolCoding.makeEncoder()
        let reference = try fullReference()
        let data1 = try encoder.encode(reference)
        let decoded = try GyeolCoding.makeDecoder().decode(MediaReference.self, from: data1)
        #expect(decoded == reference)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func binaryDataEncodesAsBase64String() throws {
        // GyeolCoding pins the Data strategy to base64 explicitly.
        // 0xDEADBEEF → "3q2+7w==", 0x0102 → "AQI=". Deterministic, so it
        // participates in byte-identity like any other field.
        let data = try GyeolCoding.makeEncoder().encode(fullReference())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("3q2+7w=="))
        #expect(json.contains("AQI="))
        // .withoutEscapingSlashes keeps the relative path diffable.
        #expect(json.contains("media/원본/클립.mov"))
    }

    @Test func absentOptionalLocatorsRoundTrip() throws {
        let encoder = GyeolCoding.makeEncoder()
        let reference = MediaReference(
            relativePath: "media/a.mov",
            displayName: "a.mov",
            duration: DocumentTime(try rt(120_000, 120_000)))
        let data1 = try encoder.encode(reference)
        // Synthesized Codable omits nil optionals entirely — no "null" noise.
        let json = try #require(String(data: data1, encoding: .utf8))
        #expect(!json.contains("bookmarkData"))
        #expect(!json.contains("contentFingerprint"))

        let decoded = try GyeolCoding.makeDecoder().decode(MediaReference.self, from: data1)
        #expect(decoded == reference)
        #expect(decoded.bookmarkData == nil)
        #expect(decoded.contentFingerprint == nil)
        #expect(try encoder.encode(decoded) == data1)
    }
}
