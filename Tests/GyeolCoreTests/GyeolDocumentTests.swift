import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) throws -> DocumentTime {
    DocumentTime(try RationalTime(value: ticks, timescale: 120_000))
}

private func uuid(_ string: String) -> UUID {
    UUID(uuidString: string)!
}

/// The S4 fixture: every field of the schema populated, including data this
/// build cannot interpret (unknown effect identifiers, deep parameter
/// trees) and legal edge shapes (cross-track overlap, overlapping
/// subtitles, an empty muted track).
private enum Fixture {
    static let media1 = MediaID(rawValue: uuid("AAAAAAAA-0000-4000-8000-000000000001"))
    static let media2 = MediaID(rawValue: uuid("AAAAAAAA-0000-4000-8000-000000000002"))
    static let trackIDs = (1...4).map { TrackID(rawValue: uuid("BBBBBBBB-0000-4000-8000-00000000000\($0)")) }
    static let clipIDs = (1...4).map { ClipID(rawValue: uuid("CCCCCCCC-0000-4000-8000-00000000000\($0)")) }
    static let subtitleIDs = (1...3).map { SubtitleID(rawValue: uuid("DDDDDDDD-0000-4000-8000-00000000000\($0)")) }
    static let markerIDs = (1...2).map { MarkerID(rawValue: uuid("EEEEEEEE-0000-4000-8000-00000000000\($0)")) }

    static func document() throws -> GyeolDocument {
        GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps23_976, renderWidth: 3840, renderHeight: 2160),
            media: [
                media1: MediaReference(
                    bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                    relativePath: "media/원본/인터뷰.mov",
                    contentFingerprint: ContentFingerprint(value: Data([0x01, 0x02]), byteSize: 1_048_576),
                    displayName: "인터뷰.mov",
                    duration: try docTime(1_200_000)),
                media2: MediaReference(
                    relativePath: "media/배경음악.aac",
                    displayName: "배경음악.aac",
                    duration: try docTime(2_400_000)),
            ],
            tracks: [
                Track(id: trackIDs[0], kind: .video, clips: [
                    Clip(
                        id: clipIDs[0],
                        timelineStart: try docTime(0),
                        duration: try docTime(240_000),
                        source: .media(MediaSource(mediaID: media1, sourceStart: try docTime(60_000))),
                        effects: [EffectInstance(
                            identifier: "dev.future.motion-blur",
                            parameters: .object([
                                "amount": .int(7_500),
                                "curve": .object(["points": .array([
                                    .object(["x": .int(0), "y": .int(10_000)]),
                                    .object(["x": .int(5_000), "y": .int(2_500)]),
                                ])]),
                                "flag": .bool(true),
                                "note": .null,
                            ]))]),
                    Clip(
                        id: clipIDs[1],
                        timelineStart: try docTime(240_000),
                        duration: try docTime(120_000),
                        source: .generator(
                            identifier: "spectrum.bar",
                            parameters: .object(["barCount": .int(64), "sensitivity": .int(7_500)]))),
                ]),
                // Overlaps track 1's [0, 360000) range — legal across tracks.
                Track(id: trackIDs[1], kind: .video, clips: [
                    Clip(
                        id: clipIDs[2],
                        timelineStart: try docTime(120_000),
                        duration: try docTime(240_000),
                        source: .media(MediaSource(mediaID: media2, sourceStart: try docTime(0)))),
                ]),
                Track(id: trackIDs[2], kind: .audio, clips: [
                    Clip(
                        id: clipIDs[3],
                        timelineStart: try docTime(0),
                        duration: try docTime(360_000),
                        source: .media(MediaSource(mediaID: media2, sourceStart: try docTime(0))),
                        audio: Clip.AudioSettings(
                            volume: FixedPointScalar(rawValue: 8_000),
                            fadeIn: try docTime(12_000),
                            fadeOut: try docTime(24_000))),
                ]),
                Track(id: trackIDs[3], kind: .audio, clips: [], isMuted: true),
            ],
            subtitles: [
                SubtitleSegment(id: subtitleIDs[0], start: try docTime(0),
                                duration: try docTime(240_000), text: "첫 자막"),
                // Overlaps the first — legal; two simultaneous lines.
                SubtitleSegment(id: subtitleIDs[1], start: try docTime(120_000),
                                duration: try docTime(240_000), text: "두 번째 줄 (겹침)"),
                // Equal start — ordering allows ties.
                SubtitleSegment(id: subtitleIDs[2], start: try docTime(120_000),
                                duration: try docTime(60_000), text: "Third line"),
            ],
            subtitleStyle: SubtitleStyle(
                fontFamily: "AppleSDGothicNeo",
                fontSize: FixedPointScalar(rawValue: 600),
                textColor: SubtitleStyle.Color(red: 255, green: 255, blue: 0),
                outlineColor: SubtitleStyle.Color(red: 32, green: 32, blue: 32, alpha: 200),
                outlineWidth: FixedPointScalar(rawValue: 60),
                position: SubtitleStyle.NormalizedPosition(
                    x: FixedPointScalar(rawValue: 5_000),
                    y: FixedPointScalar(rawValue: 8_800))),
            markers: [
                Marker(id: markerIDs[0], time: try docTime(0), label: "인트로"),
                Marker(id: markerIDs[1], time: try docTime(600_000), label: "챕터 1"),
            ])
    }

    /// Encodes the fixture, applies `mutate` to the JSON object, and
    /// returns re-serialized bytes — the only way to build invalid
    /// documents, since the model's preconditions refuse to construct them.
    static func mutatedJSON(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
        let data = try GyeolCoding.makeEncoder().encode(document())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }
}

@Suite struct GyeolDocumentS4Tests {
    @Test func fullDocumentRoundTripsByteIdentically() throws {
        let encoder = GyeolCoding.makeEncoder()
        let document = try Fixture.document()

        let data1 = try encoder.encode(document)
        let decoded = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data1)
        let data2 = try encoder.encode(decoded)

        #expect(decoded == document)
        #expect(data1 == data2)  // §4 S4: the byte-identity gate

        print("=== S4 fixture JSON (\(data1.count) bytes) ===")
        print(String(decoding: data1, as: UTF8.self))
        print("=== end fixture ===")
    }

    @Test func everyIDSurvivesUnchanged() throws {
        let data = try GyeolCoding.makeEncoder().encode(Fixture.document())
        let decoded = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)

        #expect(Set(decoded.media.keys) == [Fixture.media1, Fixture.media2])
        #expect(decoded.tracks.map(\.id) == Fixture.trackIDs)
        #expect(decoded.tracks.flatMap { $0.clips.map(\.id) } == Fixture.clipIDs)
        #expect(decoded.subtitles.map(\.id) == Fixture.subtitleIDs)
        #expect(decoded.markers.map(\.id) == Fixture.markerIDs)
    }

    @Test func emptyDocumentRoundTripsByteIdentically() throws {
        let encoder = GyeolCoding.makeEncoder()
        let data1 = try encoder.encode(GyeolDocument.empty)
        let decoded = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data1)
        #expect(decoded == .empty)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func overlappingSubtitlesDecodeSuccessfully() throws {
        // The fixture contains overlapping and equal-start subtitles; their
        // survival through the round trip is asserted above. Belt and
        // braces: decode them in isolation too.
        let data = try GyeolCoding.makeEncoder().encode(Fixture.document())
        let decoded = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)
        #expect(decoded.subtitles.count == 3)
        #expect(decoded.subtitles[1].start == decoded.subtitles[2].start)
    }
}

@Suite struct GyeolDocumentValidationTests {
    @Test func unsortedSubtitlesThrow() throws {
        let json = try Fixture.mutatedJSON { object in
            object["subtitles"] = Array((object["subtitles"] as! [Any]).reversed())
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func unsortedMarkersThrow() throws {
        let json = try Fixture.mutatedJSON { object in
            object["markers"] = Array((object["markers"] as! [Any]).reversed())
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func unsortedClipsWithinDocumentThrow() throws {
        let json = try Fixture.mutatedJSON { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[0]["clips"] = Array((tracks[0]["clips"] as! [Any]).reversed())
            object["tracks"] = tracks
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func overlappingClipsOnOneTrackThrow() throws {
        let json = try Fixture.mutatedJSON { object in
            var tracks = object["tracks"] as! [[String: Any]]
            var clips = tracks[0]["clips"] as! [[String: Any]]
            // Pull the second clip's start inside the first clip's range.
            clips[1]["timelineStart"] = 120_000
            tracks[0]["clips"] = clips
            object["tracks"] = tracks
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func sameOverlapAcrossTwoTracksIsFine() throws {
        // The fixture already places track 2's clip [120000, 360000) inside
        // track 1's clip range — and decodes. Make the contrast explicit.
        let data = try GyeolCoding.makeEncoder().encode(Fixture.document())
        let decoded = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)
        let track1First = decoded.tracks[0].clips[0]
        let track2Clip = decoded.tracks[1].clips[0]
        #expect(track2Clip.timelineStart.time < (try track1First.timelineEnd()).time)
    }

    @Test func caseVariantDuplicateMediaKeysThrow() throws {
        // UUID(uuidString:) normalizes case; two keys differing only in
        // case must be rejected, not silently collapsed into one entry.
        let json = try Fixture.mutatedJSON { object in
            var media = object["media"] as! [String: Any]
            let canonical = Fixture.media2.rawValue.uuidString
            media[canonical.lowercased()] = media[canonical]
            object["media"] = media
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func nonUUIDMediaKeyThrows() throws {
        let json = try Fixture.mutatedJSON { object in
            var media = object["media"] as! [String: Any]
            media["not-a-uuid"] = media[Fixture.media1.rawValue.uuidString]
            object["media"] = media
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func danglingMediaInitTraps() async {
        await #expect(processExitsWith: .failure) {
            func docTime(_ ticks: Int64) throws -> DocumentTime {
                DocumentTime(try RationalTime(value: ticks, timescale: 120_000))
            }
            let clip = Clip(
                id: ClipID(),
                timelineStart: .zero,
                duration: try docTime(1),
                source: .media(MediaSource(mediaID: MediaID(), sourceStart: .zero)))
            _ = GyeolDocument(
                schemaVersion: .current,
                settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080),
                media: [:],
                tracks: [Track(id: TrackID(), kind: .video, clips: [clip])])
        }
    }

    @Test func danglingMediaIDThrows() throws {
        let json = try Fixture.mutatedJSON { object in
            var media = object["media"] as! [String: Any]
            media[Fixture.media2.rawValue.uuidString] = nil
            object["media"] = media
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func unknownFrameRateInDocumentThrows() throws {
        let json = try Fixture.mutatedJSON { object in
            var settings = object["settings"] as! [String: Any]
            settings["frameRate"] = "31"
            object["settings"] = settings
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func unknownTrackKindInDocumentThrows() throws {
        let json = try Fixture.mutatedJSON { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[3]["kind"] = "midi"
            object["tracks"] = tracks
        }
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: json)
        }
    }

    @Test func negativeMarkerTimeThrows() throws {
        let json = Data("""
        {"id": "EEEEEEEE-0000-4000-8000-000000000009", "label": "x",
         "time": -1}
        """.utf8)
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(Marker.self, from: json)
        }
    }

    @Test func negativeSubtitleStartThrows() throws {
        let json = Data("""
        {"id": "DDDDDDDD-0000-4000-8000-000000000009", "text": "x",
         "start": -1,
         "duration": 1}
        """.utf8)
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(SubtitleSegment.self, from: json)
        }
    }

    @Test func negativeSubtitleStartInitTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = SubtitleSegment(
                id: SubtitleID(),
                start: DocumentTime(try RationalTime(value: -1, timescale: 120_000)),
                duration: DocumentTime(try RationalTime(value: 1, timescale: 120_000)),
                text: "x")
        }
    }

    @Test func negativeSubtitleStartAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            var segment = SubtitleSegment(
                id: SubtitleID(),
                start: .zero,
                duration: DocumentTime(try RationalTime(value: 1, timescale: 120_000)),
                text: "x")
            segment.start = DocumentTime(try RationalTime(value: -1, timescale: 120_000))
        }
    }

    @Test func nonPositiveSubtitleDurationThrows() throws {
        let json = Data("""
        {"id": "DDDDDDDD-0000-4000-8000-000000000009", "text": "x",
         "start": 0,
         "duration": 0}
        """.utf8)
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(SubtitleSegment.self, from: json)
        }
    }

    @Test func unsortedSubtitlesInitTraps() async {
        await #expect(processExitsWith: .failure) {
            func docTime(_ ticks: Int64) throws -> DocumentTime {
                DocumentTime(try RationalTime(value: ticks, timescale: 120_000))
            }
            let late = SubtitleSegment(
                id: SubtitleID(), start: try docTime(24_000), duration: try docTime(1), text: "b")
            let early = SubtitleSegment(
                id: SubtitleID(), start: try docTime(0), duration: try docTime(1), text: "a")
            _ = GyeolDocument(
                schemaVersion: .current,
                settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080),
                subtitles: [late, early])
        }
    }

    @Test func unsortedMarkersAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            func docTime(_ ticks: Int64) throws -> DocumentTime {
                DocumentTime(try RationalTime(value: ticks, timescale: 120_000))
            }
            var document = GyeolDocument.empty
            document.markers = [
                Marker(id: MarkerID(), time: try docTime(24_000), label: "b"),
                Marker(id: MarkerID(), time: try docTime(0), label: "a"),
            ]
        }
    }
}
