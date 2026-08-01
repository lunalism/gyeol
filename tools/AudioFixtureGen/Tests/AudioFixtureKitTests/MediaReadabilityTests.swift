import AVFoundation
import Foundation
import Testing
@testable import AudioFixtureKit

/// The fixtures exist for a human listening session. A file that
/// AVFoundation refuses to open would burn that session before it starts,
/// and neither the validation gate nor the determinism gate would notice —
/// both are happy with a well-formed file nobody can decode.
///
/// This is NOT an audio equivalence gate (D32 — that does not exist). It
/// asserts only that the container is readable and has the shape the
/// documents assume.
@Suite struct MediaReadabilityTests {
    @Test(arguments: AudioFixtures.allSpecs)
    func avFoundationOpensGeneratedMedia(spec: AudioMediaSpec) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-fixture-readable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let media = try AudioFixtures.writeMedia(spec, into: directory)
        let asset = AVURLAsset(url: media.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)

        let duration = try await asset.load(.duration)
        // Exactly 30 s, expressed in the asset's own timescale — no
        // tolerance, because uncompressed PCM has no reason to be off.
        #expect(duration == CMTime(value: CMTimeValue(spec.sampleCount),
                                   timescale: CMTimeScale(spec.sampleRate)))

        guard let track = tracks.first else { return }
        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        #expect(asbd?.mSampleRate == Float64(spec.sampleRate))
        #expect(asbd?.mChannelsPerFrame == 1)
        #expect(asbd?.mBitsPerChannel == 16)
    }
}

extension AudioMediaSpec: CustomTestStringConvertible {
    public var testDescription: String { fileName }
}
