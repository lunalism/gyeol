import Foundation
import Testing
@testable import GyeolCore

private func docTime(_ ticks: Int64) throws -> DocumentTime {
    DocumentTime(exactly: try RationalTime(value: ticks, timescale: 120_000))!
}

private func generatorClip(start: Int64, duration: Int64) throws -> Clip {
    Clip(
        id: ClipID(),
        timelineStart: try docTime(start),
        duration: try docTime(duration),
        source: .generator(identifier: "spectrum.bar", parameters: .object([:])))
}

private func clipObjectJSON(start: Int64, duration: Int64, index: Int) -> String {
    """
    {"audio": {"fadeIn": 0,
               "fadeOut": 0,
               "volume": 10000},
     "duration": \(duration),
     "effects": [],
     "id": "CCCCCCCC-0000-4000-8000-00000000000\(index)",
     "source": {"kind": "generator", "identifier": "spectrum.bar", "parameters": {}},
     "timelineStart": \(start)}
    """
}

private func trackJSON(clips: [(start: Int64, duration: Int64)], kind: String = "video") -> Data {
    let clipObjects = clips.enumerated()
        .map { clipObjectJSON(start: $1.start, duration: $1.duration, index: $0) }
        .joined(separator: ",\n")
    return Data("""
    {"id": "BBBBBBBB-0000-4000-8000-000000000001",
     "kind": "\(kind)",
     "isMuted": false,
     "clips": [\(clipObjects)]}
    """.utf8)
}

@Suite struct TrackTests {
    @Test func byteIdentityRoundTrip() throws {
        let encoder = GyeolCoding.makeEncoder()
        let track = Track(
            id: TrackID(),
            kind: .video,
            clips: [try generatorClip(start: 0, duration: 24_000),
                    try generatorClip(start: 48_000, duration: 24_000)],
            isMuted: true)
        let data1 = try encoder.encode(track)
        let decoded = try GyeolCoding.makeDecoder().decode(Track.self, from: data1)
        #expect(decoded == track)
        #expect(try encoder.encode(decoded) == data1)
    }

    @Test func unsortedClipsThrowAtDecode() {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(
                Track.self, from: trackJSON(clips: [(24_000, 24_000), (0, 12_000)]))
        }
    }

    @Test func overlappingClipsThrowAtDecode() throws {
        // First clip covers [0, 48000); second starts inside it.
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(
                Track.self, from: trackJSON(clips: [(0, 48_000), (24_000, 24_000)]))
        }
        // Equal starts necessarily overlap (durations are strictly positive).
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(
                Track.self, from: trackJSON(clips: [(0, 24_000), (0, 24_000)]))
        }
    }

    @Test func touchingClipsAreLegal() throws {
        // End == next start is a hard cut, not an overlap.
        let track = try GyeolCoding.makeDecoder().decode(
            Track.self, from: trackJSON(clips: [(0, 24_000), (24_000, 24_000)]))
        #expect(track.clips.count == 2)
    }

    @Test func unknownTrackKindThrowsAtDecode() {
        #expect(throws: (any Error).self) {
            try GyeolCoding.makeDecoder().decode(
                Track.self, from: trackJSON(clips: [], kind: "midi"))
        }
    }

    @Test func unsortedClipsInitTraps() async {
        await #expect(processExitsWith: .failure) {
            func docTime(_ ticks: Int64) throws -> DocumentTime {
                DocumentTime(exactly: try RationalTime(value: ticks, timescale: 120_000))!
            }
            let late = Clip(
                id: ClipID(), timelineStart: try docTime(24_000), duration: try docTime(1),
                source: .generator(identifier: "x", parameters: .object([:])))
            let early = Clip(
                id: ClipID(), timelineStart: try docTime(0), duration: try docTime(1),
                source: .generator(identifier: "x", parameters: .object([:])))
            _ = Track(id: TrackID(), kind: .video, clips: [late, early])
        }
    }

    @Test func overlappingClipsAssignmentTraps() async {
        await #expect(processExitsWith: .failure) {
            func docTime(_ ticks: Int64) throws -> DocumentTime {
                DocumentTime(exactly: try RationalTime(value: ticks, timescale: 120_000))!
            }
            func clip(start: Int64, duration: Int64) throws -> Clip {
                Clip(id: ClipID(), timelineStart: try docTime(start), duration: try docTime(duration),
                     source: .generator(identifier: "x", parameters: .object([:])))
            }
            var track = Track(id: TrackID(), kind: .video)
            track.clips = [try clip(start: 0, duration: 48_000),
                           try clip(start: 24_000, duration: 24_000)]
        }
    }
}
