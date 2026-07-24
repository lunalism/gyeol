import Foundation
import Testing
@testable import GyeolCore

private func rt(_ value: Int64, _ timescale: Int32) throws -> RationalTime {
    try RationalTime(value: value, timescale: timescale)
}

private func docTime(_ ticks: Int64) throws -> DocumentTime {
    DocumentTime(try rt(ticks, 120_000))
}

/// A hand-written clip JSON at document timescale, parameterized on the
/// fields the validation tests need to push out of range.
private func clipJSON(
    duration: Int64, fadeIn: Int64 = 0, fadeOut: Int64 = 0, timelineStart: Int64 = 0
) -> Data {
    Data("""
    {
      "audio": {
        "fadeIn": \(fadeIn),
        "fadeOut": \(fadeOut),
        "volume": 10000
      },
      "duration": \(duration),
      "effects": [],
      "id": "8E2C5B7A-1111-4222-8333-000000000001",
      "source": {"kind": "generator", "identifier": "spectrum.bar", "parameters": {}},
      "timelineStart": \(timelineStart)
    }
    """.utf8)
}

@Suite struct ClipSourceTests {
    @Test func mediaAndGeneratorRoundTripByteIdentically() throws {
        let encoder = GyeolCoding.makeEncoder()
        let sources: [ClipSource] = [
            .media(MediaSource(mediaID: MediaID(), sourceStart: try docTime(24_000))),
            .generator(
                identifier: "spectrum.bar",
                parameters: .object(["barCount": .int(64), "colors": .array([.string("#fff")])])),
        ]
        for source in sources {
            let data1 = try encoder.encode(source)
            let decoded = try GyeolCoding.makeDecoder().decode(ClipSource.self, from: data1)
            #expect(decoded == source)
            #expect(try encoder.encode(decoded) == data1)
        }
    }

    @Test func negativeSourceStartThrowsAtDecode() throws {
        let json = Data("""
        {"kind": "media", "mediaID": "8E2C5B7A-1111-4222-8333-000000000001",
         "sourceStart": -1}
        """.utf8)
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(ClipSource.self, from: json)
        }
        // Zero is the legal boundary.
        let zero = Data("""
        {"kind": "media", "mediaID": "8E2C5B7A-1111-4222-8333-000000000001",
         "sourceStart": 0}
        """.utf8)
        _ = try GyeolCoding.makeDecoder().decode(ClipSource.self, from: zero)
    }

    @Test func unknownKindThrows() {
        let json = Data(#"{"kind": "transition", "identifier": "crossDissolve", "parameters": {}}"#.utf8)
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(ClipSource.self, from: json)
        }
    }
}

@Suite struct EffectInstanceTests {
    @Test func unknownEffectWithDeepParameterTreeSurvivesUnchanged() throws {
        // An effect this build has never heard of, with structure it cannot
        // interpret. Load → save must carry every byte of meaning through.
        let foreign = Data("""
        {"identifier": "dev.future.motion-blur",
         "parameters": {"zUnknown": [1, {"curve": {"points": [{"x": 0, "y": 10000},
         {"x": 5000, "y": 2500}], "kind": "bezier"}}, null, true],
         "amount": 7500, "label": "future"}}
        """.utf8)
        let decoded = try GyeolCoding.makeDecoder().decode(EffectInstance.self, from: foreign)
        #expect(decoded.identifier == "dev.future.motion-blur")

        let encoder = GyeolCoding.makeEncoder()
        let reencoded = try encoder.encode(decoded)
        let decodedAgain = try GyeolCoding.makeDecoder().decode(EffectInstance.self, from: reencoded)
        #expect(decodedAgain == decoded)
        #expect(try encoder.encode(decodedAgain) == reencoded)
        // Spot-check that deep structure actually survived, not just equality
        // of some lossy normal form.
        #expect(decoded.parameters["zUnknown"]?[1]?["curve"]?["points"]?[1]?["y"]?.intValue == 2500)
    }
}

@Suite struct ClipTests {
    func fullClip() throws -> Clip {
        Clip(
            id: ClipID(),
            timelineStart: try docTime(240_000),
            duration: try docTime(600_600),
            source: .media(MediaSource(mediaID: MediaID(), sourceStart: try docTime(5_005))),
            effects: [
                EffectInstance(identifier: "dev.gyeol.opacity", parameters: .object(["amount": .int(7500)])),
                EffectInstance(identifier: "dev.unknown.future", parameters: .object(["deep": .array([.null])])),
            ],
            audio: Clip.AudioSettings(
                volume: FixedPointScalar(rawValue: 8_000),
                fadeIn: try docTime(12_000),
                fadeOut: try docTime(24_000)))
    }

    @Test func byteIdentityRoundTripEveryFieldPopulated() throws {
        let encoder = GyeolCoding.makeEncoder()
        let clip = try fullClip()
        let data1 = try encoder.encode(clip)
        let decoded = try GyeolCoding.makeDecoder().decode(Clip.self, from: data1)
        #expect(decoded == clip)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func clipIDSurvivesRoundTripUnchanged() throws {
        let fixed = try #require(UUID(uuidString: "8E2C5B7A-1111-4222-8333-000000000001"))
        let decoded = try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 1))
        #expect(decoded.id == ClipID(rawValue: fixed))

        let reencoded = try GyeolCoding.makeEncoder().encode(decoded)
        let decodedAgain = try GyeolCoding.makeDecoder().decode(Clip.self, from: reencoded)
        #expect(decodedAgain.id == ClipID(rawValue: fixed))
    }

    @Test func zeroAndNegativeDurationThrow() throws {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 0))
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: -1))
        }
        // Sanity: the smallest positive duration is fine.
        _ = try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 1))
    }

    @Test func negativeFadeThrows() throws {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 1, fadeIn: -1))
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 1, fadeOut: -1))
        }
        _ = try GyeolCoding.makeDecoder().decode(Clip.self, from: clipJSON(duration: 1, fadeIn: 0, fadeOut: 0))
    }

    @Test func negativeTimelineStartThrowsAtDecode() throws {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(
                Clip.self, from: clipJSON(duration: 1, timelineStart: -1))
        }
        // Zero is the legal boundary (a clip at the very head of the timeline).
        _ = try GyeolCoding.makeDecoder().decode(
            Clip.self, from: clipJSON(duration: 1, timelineStart: 0))
    }

    @Test func timelineEndIsDerived() throws {
        let clip = try fullClip()
        #expect(try clip.timelineEnd() == DocumentTime(try rt(840_600, 120_000)))
    }
}
