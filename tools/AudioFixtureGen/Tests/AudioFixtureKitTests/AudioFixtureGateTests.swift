import CryptoKit
import Foundation
import Testing
@testable import AudioFixtureKit
import GyeolCore

/// Repository root, derived from this file's own path — the committed
/// fixtures are repository data, not bundle resources.
private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { url.deleteLastPathComponent() }  // …/tools/AudioFixtureGen/Tests/AudioFixtureKitTests/<file>
    return url
}()

private let fixtureDirectory = repoRoot.appendingPathComponent("fixtures/audio")

private let fixtureNames = [
    "tone-const-a",
    "tone-const-44100-a",
    "tone-envelope-a",
    "envelope-shifted-control",
    "click-control",
    "click-control-weak",
    "mute-one",
]

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("audio-fixture-gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Gate 1: every committed document decodes and passes full validation

@Suite struct CommittedFixtureValidationTests {
    @Test(arguments: fixtureNames)
    func decodesAndValidates(name: String) throws {
        let url = fixtureDirectory
            .appendingPathComponent("\(name).gyeol")
            .appendingPathComponent("document.json")
        let data = try Data(contentsOf: url)
        // Decoding IS the full validation (D26): `GyeolDocument.init(from:)`
        // calls `fullValidationViolation` and throws on any violation. The
        // explicit call below is not a second implementation — it is the
        // SAME function, asserted directly so a future decoder that
        // forgot to call it would still be caught here.
        let document = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)
        #expect(GyeolDocument.fullValidationViolation(
            media: document.media,
            tracks: document.tracks,
            duration: document.duration,
            subtitles: document.subtitles,
            markers: document.markers) == nil)
    }

    /// The fixtures exist to be HEARD, so an empty audio track would be a
    /// silently passing gate (§4 rule 4).
    @Test(arguments: fixtureNames)
    func carriesAudioClips(name: String) throws {
        let url = fixtureDirectory
            .appendingPathComponent("\(name).gyeol")
            .appendingPathComponent("document.json")
        let document = try GyeolCoding.makeDecoder().decode(
            GyeolDocument.self, from: try Data(contentsOf: url))
        let clips = document.tracks.flatMap(\.clips)
        #expect(!clips.isEmpty)
        for clip in clips {
            guard case .media(let source) = clip.source else {
                Issue.record("fixture \(name) has a non-media clip")
                continue
            }
            #expect(document.media[source.mediaID] != nil)
        }
    }

    /// The committed documents must equal what the generator produces —
    /// otherwise the checked-in files and the generator have drifted and
    /// nobody would notice until a regeneration.
    @Test func committedDocumentsMatchRegeneration() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try AudioFixtures.generate(into: directory)
        for name in fixtureNames {
            let fresh = try Data(contentsOf: directory
                .appendingPathComponent("\(name).gyeol/document.json"))
            let committed = try Data(contentsOf: fixtureDirectory
                .appendingPathComponent("\(name).gyeol/document.json"))
            #expect(fresh == committed, "\(name).gyeol/document.json differs from the generator's output")
        }
    }
}

// MARK: - Gate 2: the generator is byte-deterministic

@Suite struct GeneratorDeterminismTests {
    /// Two full runs into separate directories must produce byte-identical
    /// media. Everything downstream depends on this: the committed
    /// documents carry content fingerprints of media that is NOT committed,
    /// so a non-deterministic generator means a fresh clone's regenerated
    /// media fails `MediaResolver`'s fingerprint check and every fixture
    /// stops opening.
    @Test func mediaIsByteIdenticalAcrossRuns() throws {
        let first = try makeTempDirectory()
        let second = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let runA = try AudioFixtures.generate(into: first)
        let runB = try AudioFixtures.generate(into: second)

        #expect(runA.media.count == AudioFixtures.allSpecs.count)
        #expect(runA.media.count == runB.media.count)
        for (a, b) in zip(runA.media, runB.media) {
            #expect(a.spec.fileName == b.spec.fileName)
            // Hash the files on DISK, not the in-memory buffers: the claim
            // under test is about the artifacts, and reading them back also
            // catches a truncated or partially written file.
            let digestA = Data(SHA256.hash(data: try Data(contentsOf: a.url)))
            let digestB = Data(SHA256.hash(data: try Data(contentsOf: b.url)))
            #expect(digestA == digestB, "\(a.spec.fileName) differs between runs")
            #expect(digestA == a.fileDigest)
        }
    }

    /// The other half of the same claim: a regenerated file must still
    /// satisfy the fingerprint stored in the COMMITTED documents. Byte
    /// determinism alone would not prove it — the fingerprint algorithm
    /// (4 MiB prefix + size) is a separate copy of app-layer code.
    @Test func regeneratedMediaMatchesCommittedFingerprints() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try AudioFixtures.generate(into: directory)
        let generated = Dictionary(
            uniqueKeysWithValues: report.media.map { ($0.spec.fileName, $0) })

        var checked = 0
        for name in fixtureNames {
            let document = try GyeolCoding.makeDecoder().decode(
                GyeolDocument.self,
                from: try Data(contentsOf: fixtureDirectory
                    .appendingPathComponent("\(name).gyeol/document.json")))
            for reference in document.media.values {
                guard let media = generated[reference.relativePath] else {
                    Issue.record("\(name) references unknown media \(reference.relativePath)")
                    continue
                }
                #expect(reference.contentFingerprint == media.contentFingerprint)
                checked += 1
            }
        }
        // §4 rule 3: distinguish a trivial pass (nothing compared) from a
        // real one.
        #expect(checked == fixtureNames.count)
    }
}

// MARK: - Signal properties the human checks depend on

@Suite struct ToneSignalTests {
    /// The phase accumulator never resets, so the tone that resumes after a
    /// silent stretch must be in phase with an uninterrupted tone. This is
    /// the property that keeps the fixture from manufacturing the click it
    /// is meant to detect.
    @Test func phaseSurvivesSilentSegments() {
        let continuous = ToneSignal.samples(
            sampleRate: 48_000, frequencyHz: 220,
            segments: [ToneSegment(seconds: 5, amplitude: 0.5)])
        let interrupted = ToneSignal.samples(
            sampleRate: 48_000, frequencyHz: 220,
            segments: [
                ToneSegment(seconds: 2, amplitude: 0.5),
                ToneSegment(seconds: 1, amplitude: 0),
                ToneSegment(seconds: 2, amplitude: 0.5),
            ])
        #expect(continuous.count == interrupted.count)
        // The third segment starts at 3 s; compare it against the same
        // absolute window of the uninterrupted tone.
        let start = 3 * 48_000
        #expect(Array(continuous[start...]) == Array(interrupted[start...]))
    }

    /// 220 Hz × 30 s is 6600 whole periods, so the file starts on a zero
    /// crossing and the sample AFTER the last one would be zero again — no
    /// fade is needed to avoid an edge click.
    @Test(arguments: [48_000, 44_100])
    func fileSpansWholePeriods(sampleRate: Int) {
        let samples = ToneSignal.samples(
            sampleRate: sampleRate, frequencyHz: 220,
            segments: [ToneSegment(seconds: 30, amplitude: 0.5)])
        #expect(samples.count == 30 * sampleRate)
        #expect(samples.first == 0)
        // 220 × 30 s = 6600 periods exactly at BOTH rates, even though at
        // 44100 one period is 200.4545… samples and never lands on one.
        #expect((220 * samples.count) % sampleRate == 0)
    }

    @Test func envelopeSegmentAmplitudes() {
        let samples = ToneSignal.samples(
            sampleRate: 48_000, frequencyHz: 220,
            segments: AudioFixtures.toneEnvelope.segments)
        #expect(samples.count == 30 * 48_000)
        func peak(secondsFrom: Int, to: Int) -> Int {
            samples[(secondsFrom * 48_000)..<(to * 48_000)]
                .map { Int(abs(Int32($0))) }.max() ?? 0
        }
        #expect(peak(secondsFrom: 0, to: 2) == 16_384)   // 0.5 × 32767, rounded
        #expect(peak(secondsFrom: 2, to: 3) == 0)        // silence
        #expect(peak(secondsFrom: 3, to: 5) == 4_096)    // 0.125 × 32767, rounded
        #expect(peak(secondsFrom: 5, to: 6) == 0)
    }

    /// The rounded half-period offset and its residual are part of the
    /// fixture's contract (§5.6.1's "residual은 삼키지 않는다" applied to a
    /// fixture rather than to the adapter).
    @Test func phaseOffsetsAreExactlyReported() {
        #expect(AudioFixtures.halfPeriodTicks == 273)
        // 273 ticks − 120000/440 ticks = +3/11 tick, exactly (rounded UP).
        #expect(273 * 440 - 120_000 == 120)
        #expect(AudioFixtures.halfPeriodResidualTicks == (numerator: 3, denominator: 11))

        #expect(AudioFixtures.quarterPeriodTicks == 136)
        // 136 ticks − 120000/880 ticks = −4/11 tick, exactly (rounded DOWN).
        #expect(136 * 880 - 120_000 == -320)
        #expect(AudioFixtures.quarterPeriodResidualTicks == (numerator: -4, denominator: 11))
    }
}
