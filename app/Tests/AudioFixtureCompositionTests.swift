import AVFoundation
import Foundation
import GyeolCore
import GyeolPlayback
import Testing

/// Headless smoke test for the audio verification fixtures (부록 A-38).
///
/// WHY THIS EXISTS: the seven fixtures were built, validated and gated in
/// `tools/AudioFixtureGen`, but nothing had ever put them through
/// `CompositionBuilder`. Two of them sit on exactly the boundary cases a
/// builder breaks on:
///
/// - `click-control` / `click-control-weak`: the right clip's
///   `sourceStart + duration` equals the media duration EXACTLY, with zero
///   slack. An off-by-one in the insert range fails here and nowhere else.
/// - `mute-one`: a 2 s gap between 10 s and 12 s. If the builder appends
///   instead of placing, the second clip moves to 10 s and the document
///   silently means something different.
///
/// This is NOT an audio equivalence gate — that does not exist (D32), and
/// nothing here listens to anything. It asserts that a composition is
/// produced and has the SHAPE the document describes.
///
/// This test needs the fixture MEDIA, which is gitignored derived data.
/// It fails loudly rather than skipping when the media is absent: a
/// skipped audio fixture test is precisely the "초록불인데 무측정" pattern
/// §4's gate rules were written for.
/// File scope, NOT inside the @MainActor enum below: `@Test(arguments:)`
/// evaluates its argument list outside the actor, so an isolated property
/// does not compile there.
private let audioFixtureNames = [
    "tone-const-a",
    "tone-const-44100-a",
    "tone-envelope-a",
    "envelope-shifted-control",
    "click-control",
    "click-control-weak",
    "mute-one",
    "tone-envelope-long-a",
]

/// Internal, not file-private: `AudioOnlyPlayheadTests` (M2.3.1) loads the
/// same fixtures through the same resolver, and a second copy of this would
/// be a second place for the fixture path to go stale.
@MainActor
enum AudioFixtureLocation {
    /// Repository root from this file's path: app/Tests/<file> → 3 up.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }()

    static let directory = repoRoot.appendingPathComponent("fixtures/audio")

    static func packageURL(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).gyeol")
    }

    static func document(_ name: String) throws -> GyeolDocument {
        let data = try Data(contentsOf: packageURL(name).appendingPathComponent("document.json"))
        return try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)
    }

    /// Resolves through `MediaResolver`, so the fingerprint check runs for
    /// real: this doubles as the first end-to-end evidence that a
    /// regenerated .wav still satisfies the committed document.
    static func mediaURLs(for document: GyeolDocument, name: String) throws -> [MediaID: URL] {
        var urls: [MediaID: URL] = [:]
        for (id, reference) in document.media {
            switch MediaResolver.resolve(
                reference: reference, bookmark: nil, packageURL: packageURL(name)) {
            case .resolved(let url), .resolvedAndHealed(let url, _):
                urls[id] = url
            case .needsReconnect(let reason):
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: """
                fixture \(name): media '\(reference.relativePath)' unresolvable (\(reason)). \
                The fixture media is gitignored derived data — regenerate it with: \
                swift run --package-path tools/AudioFixtureGen audio-fixture-gen fixtures/audio
                """])
            }
        }
        return urls
    }
}

@Suite @MainActor struct AudioFixtureCompositionTests {
    /// Every fixture builds, has audio, and the composition is exactly as
    /// long as the document says.
    ///
    /// The duration assertion is meaningful here in a way it is not for the
    /// M2.1 video fixture: these documents have NO trailing space, so
    /// `composition.duration` and `document.duration` must agree exactly.
    /// (AVFoundation discards trailing emptiness — the M2.1 fixture
    /// deliberately has some and therefore cannot make this assertion.)
    @Test(arguments: audioFixtureNames)
    func fixtureBuildsWithAudioOfTheDocumentedLength(name: String) async throws {
        let document = try AudioFixtureLocation.document(name)
        let urls = try AudioFixtureLocation.mediaURLs(for: document, name: name)

        let built = try await CompositionBuilder.build(document: document, mediaURLs: urls)

        let audioTracks = built.composition.tracks(withMediaType: .audio)
        #expect(audioTracks.count == 1, "\(name): expected exactly one audio composition track")
        #expect(!audioTracks.isEmpty, "\(name): the document contributes no audio at all")
        // An audioMix exists whenever any track contributed audio — the
        // carrier of volume and fades (D31).
        #expect(built.audioMix != nil, "\(name): no audioMix")

        let expected = CMTime(value: document.duration.ticks, timescale: DocumentTime.timescale)
        #expect(CMTimeCompare(built.composition.duration, expected) == 0,
                "\(name): composition \(built.composition.duration.seconds)s vs document \(expected.seconds)s")
        #expect(built.timelineEnd.ticks == document.duration.ticks)

        // No video track in an audio-only document, and therefore no
        // instructions: absence, not loss (§5.3).
        #expect(built.composition.tracks(withMediaType: .video).isEmpty)
        // D36's structural flag (§7.4-8). Asserted against the composition
        // as well as read from the field, so the two can never drift: the
        // field is what callers branch on and the composition is the truth
        // it must keep reporting.
        #expect(!built.hasVideoTrack)
        #expect(built.hasVideoTrack == !built.composition.tracks(withMediaType: .video).isEmpty)
        // MEASURED, and it contradicts §7.4-8's stated premise (reported):
        // that clause says a document "always has three video tracks" under
        // the 3+2 layout, so a document-based test "would never fire". No
        // document in this repository is like that — §5.2 puts 3+2 in the
        // UI only and keeps the count OUT of the schema, `GyeolDocument
        // .empty` has zero tracks, and these fixtures carry one audio track
        // and nothing else. Computing the flag from the composition is
        // still right, but for the opposite reason: a document with three
        // EMPTY video tracks would answer "has video" and take a display
        // PTS path that can never produce evidence.
        #expect(document.tracks.allSatisfy { $0.kind == .audio })
    }

    /// `mute-one`'s 10–12 s gap must render as SILENCE in place, not as a
    /// 2 s-earlier second clip.
    ///
    /// Read structurally, not by duration alone (§4 rule 5): duration would
    /// also be 22 s if the builder placed the second clip at 10 s and the
    /// document had said 22 s for another reason. The track's segment list
    /// says where the emptiness actually is.
    @Test func muteOneGapIsSilenceInPlace() async throws {
        let name = "mute-one"
        let document = try AudioFixtureLocation.document(name)
        let urls = try AudioFixtureLocation.mediaURLs(for: document, name: name)
        let built = try await CompositionBuilder.build(document: document, mediaURLs: urls)

        let track = try #require(built.composition.tracks(withMediaType: .audio).first)
        let segments = track.segments
        #expect(segments.count == 3, "expected filled/empty/filled, got \(segments.count) segments")

        func ticks(_ time: CMTime) -> Int64 {
            CMTimeConvertScale(time, timescale: DocumentTime.timescale, method: .default).value
        }

        guard segments.count == 3 else { return }
        #expect(!segments[0].isEmpty)
        #expect(ticks(segments[0].timeMapping.target.start) == 0)
        #expect(ticks(segments[0].timeMapping.target.duration) == 1_200_000)   // 0–10 s

        // The load-bearing one: the middle segment is EMPTY and occupies
        // exactly the 10–12 s gap.
        #expect(segments[1].isEmpty, "the 10–12 s gap is not empty — the second clip shifted")
        #expect(ticks(segments[1].timeMapping.target.start) == 1_200_000)
        #expect(ticks(segments[1].timeMapping.target.duration) == 240_000)     // 2 s

        #expect(!segments[2].isEmpty)
        #expect(ticks(segments[2].timeMapping.target.start) == 1_440_000)      // 12 s, not 10 s
        #expect(ticks(segments[2].timeMapping.target.duration) == 1_200_000)

        // The silenced clip is silenced by VOLUME (the schema has no
        // per-clip mute field), so it must still be PRESENT in the
        // composition — a missing second segment would be a different bug
        // that the duration check alone would not distinguish.
        let inputs = try #require(built.audioMix?.inputParameters)
        #expect(inputs.count == 1)
    }

    /// The click controls read to the very last sample of the source. A
    /// builder that clamps or rejects a range ending exactly at the asset
    /// duration fails here.
    @Test(arguments: [("click-control", Int64(1_800_136), Int64(1_799_864)),
                      ("click-control-weak", Int64(1_800_273), Int64(1_799_727))])
    func clickControlRightClipConsumesTheSourceToItsEnd(
        name: String, sourceStart: Int64, duration: Int64
    ) async throws {
        let document = try AudioFixtureLocation.document(name)
        // Guard the premise rather than assuming it (§4 rule 2): if the
        // fixture ever stops being flush against the media end, this test
        // silently stops testing what it claims to.
        let clip = try #require(document.tracks.first?.clips.last)
        guard case .media(let source) = clip.source else {
            Issue.record("\(name): right clip is not a media clip")
            return
        }
        #expect(source.sourceStart.ticks == sourceStart)
        #expect(clip.duration.ticks == duration)
        let reference = try #require(document.media[source.mediaID])
        #expect(source.sourceStart.ticks + clip.duration.ticks == reference.duration.ticks,
                "\(name): the right clip is no longer flush with the media end")

        let urls = try AudioFixtureLocation.mediaURLs(for: document, name: name)
        let built = try await CompositionBuilder.build(document: document, mediaURLs: urls)
        let track = try #require(built.composition.tracks(withMediaType: .audio).first)
        // Two abutting clips: one continuous filled span, no empty segment.
        #expect(track.segments.count == 2)
        #expect(track.segments.allSatisfy { !$0.isEmpty })
        #expect(CMTimeCompare(
            built.composition.duration,
            CMTime(value: document.duration.ticks, timescale: DocumentTime.timescale)) == 0)

        // MEASURED: the composition preserves the sub-sample offset EXACTLY
        // at timescale 120000 — the builder does not quantize it onto the
        // asset's 48 kHz grid. 1800273/120000 is 720109.2 samples, so
        // whichever sample the seam actually starts on is decided further
        // down the audio render path, not here. That matters for
        // `click-control-weak`, whose seam step is 515 counts at sample
        // 720109 but only 43 at 720110 — see the fixture README.
        let rightSegment = try #require(track.segments.last)
        #expect(rightSegment.timeMapping.source.start
            == CMTime(value: sourceStart, timescale: DocumentTime.timescale))
        #expect(rightSegment.timeMapping.source.duration
            == CMTime(value: duration, timescale: DocumentTime.timescale))
    }
}
