import CryptoKit
import Foundation
import GyeolCore

// MARK: - Media specs

/// One generated media file. Everything the signal needs is here, so the
/// spec IS the documentation of what the human will hear.
public struct AudioMediaSpec: Sendable {
    public let fileName: String
    public let sampleRate: Int
    public let segments: [ToneSegment]

    public var sampleCount: Int { segments.reduce(0) { $0 + $1.seconds * sampleRate } }
    public var seconds: Int { segments.reduce(0) { $0 + $1.seconds } }
}

/// What one media file came out as, after writing.
public struct GeneratedMedia: Sendable {
    public let spec: AudioMediaSpec
    public let url: URL
    public let byteSize: Int64
    /// SHA-256 of the whole file — the determinism gate's subject.
    public let fileDigest: Data
    /// The document-level fingerprint: SHA-256 over the first 4 MiB plus
    /// the byte size, i.e. what `MediaResolver` recomputes at open time.
    public let contentFingerprint: ContentFingerprint
}

public struct FixtureReport: Sendable {
    public let media: [GeneratedMedia]
    public let packages: [URL]
}

// MARK: - Generator

public enum AudioFixtures {
    /// 220 Hz: 220 × 1 s is a whole number of periods, so EVERY boundary in
    /// these fixtures (segment edges, the 15 s cut, the 10/12/22 s clip
    /// edges) sits on a zero crossing. That is what makes a click at a cut
    /// point attributable to the edit path rather than to the fixture.
    public static let toneFrequencyHz = 220

    /// 120000, PRD §5.6.1. Restated here as a local constant only because
    /// `DocumentTime` deliberately exposes ticks, not a scale.
    static let ticksPerSecond: Int64 = 120_000

    // ---- The phase offsets of the two click controls.
    //
    // Neither offset lands on the 120000 grid, so both round, and both
    // report what rounding discarded rather than swallowing it — the same
    // contract §5.6.1 puts on `CMTimeAdapter`'s residual.
    //
    // WHY TWO. Half a period on a pure sine is a POLARITY FLIP at a zero
    // crossing: the seam has no amplitude step, only a slope reversal, and
    // the measured excess over the natural sample-to-sample delta was 44
    // counts — 0.13% of full scale. A control nobody can hear makes the
    // check it guards look validated when it is not. The quarter-period
    // offset lands on the waveform PEAK instead, a ~51% step. Keeping both
    // turns the human session from a yes/no question into a measurement of
    // the ear's detection floor, and that floor bounds what ③ may claim.

    /// Quarter period of 220 Hz: 1/880 s = 120000/880 = 1500/11 =
    /// 136.3636… ticks → **136**. The audible control.
    public static let quarterPeriodTicks: Int64 = (ticksPerSecond + 440) / 880
    /// 136 − 1500/11 = −4/11 = −0.363636… ticks ≈ −3.03 µs ≈ −0.145 samples
    /// at 48 kHz. NEGATIVE: rounding went down, so the offset is slightly
    /// EARLY.
    public static let quarterPeriodResidualTicks = (numerator: Int64(-4), denominator: Int64(11))

    /// Half period of 220 Hz: 1/440 s = 120000/440 = 3000/11 = 272.7272…
    /// ticks → **273**. The near-inaudible control, kept deliberately.
    public static let halfPeriodTicks: Int64 = (ticksPerSecond + 220) / 440
    /// 273 − 3000/11 = +3/11 = +0.272727… ticks ≈ +2.27 µs ≈ +0.109 samples
    /// at 48 kHz. POSITIVE: the placed offset is slightly LATE.
    public static let halfPeriodResidualTicks = (numerator: Int64(3), denominator: Int64(11))

    public static let toneConst = AudioMediaSpec(
        fileName: "tone-const.wav",
        sampleRate: 48_000,
        segments: [ToneSegment(seconds: 30, amplitude: 0.5)])

    public static let toneConst44100 = AudioMediaSpec(
        fileName: "tone-const-44100.wav",
        sampleRate: 44_100,
        segments: [ToneSegment(seconds: 30, amplitude: 0.5)])

    /// Five repetitions of tone(0.5) 2 s / silence 1 s / tone(0.125) 2 s /
    /// silence 1 s. The two tone levels differ by 12 dB, which is far
    /// larger than any waveform-drawing rounding error — if the drawn
    /// envelope and the ear disagree, the disagreement is structural.
    public static let toneEnvelope = AudioMediaSpec(
        fileName: "tone-envelope.wav",
        sampleRate: 48_000,
        segments: (0..<5).flatMap { _ in
            [
                ToneSegment(seconds: 2, amplitude: 0.5),
                ToneSegment(seconds: 1, amplitude: 0),
                ToneSegment(seconds: 2, amplitude: 0.125),
                ToneSegment(seconds: 1, amplitude: 0),
            ]
        })

    /// The SAME 6 s envelope period as `toneEnvelope`, thirty times over —
    /// **180 s**. Only the length differs, so the peak pattern the person
    /// judges is the same kind of thing and A-43's results stay comparable.
    ///
    /// WHY 180 s. `tone-envelope` is 30 s, and the M2.3.1 human session ran
    /// twelve blind segments at twelve seconds each = **144 s**. The control
    /// session never restarts playback (deliberately — the sound is the
    /// fixed reference), so on a 30 s fixture everything after the third
    /// segment was SILENCE with a frozen playhead, and the written
    /// procedure told the person to guess rather than mark unknown. Only
    /// the first pass — two values × 12 s = 24 s — stayed inside the
    /// document. 180 s is 12 × 15 s: it holds the recorded 12 × 12 s
    /// session with 36 s to spare and still fits a longer 15 s dwell
    /// exactly.
    ///
    /// SIDE EFFECT WORTH KNOWING: at 48 kHz mono this file is ~16.5 MB, the
    /// first fixture LARGER than the fingerprint's 4 MiB prefix (≈43.7 s of
    /// audio). The stored fingerprint therefore no longer covers the whole
    /// file, and the content gate has to reach past that boundary itself —
    /// see `longEnvelopeIsExactlyPeriodicPastTheFingerprintPrefix`.
    public static let toneEnvelopeLong = AudioMediaSpec(
        fileName: "tone-envelope-long.wav",
        sampleRate: 48_000,
        segments: (0..<30).flatMap { _ in
            [
                ToneSegment(seconds: 2, amplitude: 0.5),
                ToneSegment(seconds: 1, amplitude: 0),
                ToneSegment(seconds: 2, amplitude: 0.125),
                ToneSegment(seconds: 1, amplitude: 0),
            ]
        })

    public static let allSpecs = [toneConst, toneConst44100, toneEnvelope, toneEnvelopeLong]

    // MARK: Writing

    public static func writeMedia(_ spec: AudioMediaSpec, into directory: URL) throws -> GeneratedMedia {
        let samples = ToneSignal.samples(
            sampleRate: spec.sampleRate,
            frequencyHz: toneFrequencyHz,
            segments: spec.segments)
        let data = WAVWriter.data(samples: samples, sampleRate: spec.sampleRate)
        let url = directory.appendingPathComponent(spec.fileName)
        try data.write(to: url, options: .atomic)
        return GeneratedMedia(
            spec: spec,
            url: url,
            byteSize: Int64(data.count),
            fileDigest: Data(SHA256.hash(data: data)),
            contentFingerprint: fingerprint(of: data))
    }

    /// The app layer's algorithm (`MediaResolver.readFingerprint`): SHA-256
    /// over the first 4 MiB, carried with the exact byte size.
    ///
    /// DUPLICATED, knowingly: `MediaResolver` is an app-target file, not a
    /// library, so no tool can import it — `tools/FixtureGen` already
    /// carries the same copy. If the algorithm ever changes, every
    /// committed fixture stops resolving and this copy is one of the places
    /// to fix. Not hidden: recorded here and in the fixture README.
    static let fingerprintPrefixLength = 4 * 1024 * 1024

    public static func fingerprint(of data: Data) -> ContentFingerprint {
        let prefix = data.prefix(fingerprintPrefixLength)
        return ContentFingerprint(value: Data(SHA256.hash(data: prefix)), byteSize: Int64(data.count))
    }

    /// Writes every media file and every document into `directory`.
    ///
    /// Media sits BESIDE the packages, not inside them: `MediaResolver`
    /// resolves `relativePath` against the package's PARENT directory.
    @discardableResult
    public static func generate(into directory: URL) throws -> FixtureReport {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = try allSpecs.map { try writeMedia($0, into: directory) }
        let byName = Dictionary(uniqueKeysWithValues: media.map { ($0.spec.fileName, $0) })
        let documents = buildDocuments(media: byName)
        var packages: [URL] = []
        for (name, document) in documents.sorted(by: { $0.name < $1.name }) {
            let packageURL = directory.appendingPathComponent("\(name).gyeol")
            try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try GyeolCoding.makeEncoder().encode(document)
                .write(to: packageURL.appendingPathComponent("document.json"), options: .atomic)
            packages.append(packageURL)
        }
        return FixtureReport(media: media, packages: packages)
    }
}

// MARK: - Documents

extension AudioFixtures {
    /// Deterministic identifiers: the six documents are COMMITTED, so a
    /// regenerated document must be byte-identical to the committed one.
    /// `UUID()` would make every regeneration a diff.
    static func uuid(_ prefix: String, _ serial: Int) -> UUID {
        UUID(uuidString: String(format: "\(prefix)-0000-4000-8000-%012d", serial))!
    }

    static func ticks(seconds: Int64) -> DocumentTime {
        DocumentTime(ticks: seconds * ticksPerSecond)
    }

    /// Audio fixtures still need a project rate; 30 is the app's default
    /// and none of the four checks depends on it.
    static func settings() -> ProjectSettings {
        ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080)
    }

    static func reference(_ media: GeneratedMedia) -> MediaReference {
        MediaReference(
            // No bookmark: a bookmark is machine-local and §5.6 forbids
            // machine-varying data in the document body. Relative path +
            // fingerprint is the committed reference form.
            bookmarkData: nil,
            relativePath: media.spec.fileName,
            contentFingerprint: media.contentFingerprint,
            displayName: media.spec.fileName,
            duration: ticks(seconds: Int64(media.spec.seconds)))
    }

    static func audioTrack(_ serial: Int, clips: [Clip]) -> Track {
        Track(id: TrackID(rawValue: uuid("BBBBBBBB", serial)), kind: .audio, clips: clips)
    }

    static func clip(
        _ serial: Int,
        mediaID: MediaID,
        timelineStart: Int64,
        duration: Int64,
        sourceStart: Int64 = 0,
        volume: Int32 = FixedPointScalar.scale
    ) -> Clip {
        Clip(
            id: ClipID(rawValue: uuid("CCCCCCCC", serial)),
            timelineStart: DocumentTime(ticks: timelineStart),
            duration: DocumentTime(ticks: duration),
            source: .media(MediaSource(
                mediaID: mediaID,
                sourceStart: DocumentTime(ticks: sourceStart))),
            audio: Clip.AudioSettings(
                volume: FixedPointScalar(rawValue: volume),
                fadeIn: .zero,
                fadeOut: .zero))
    }

    /// The six fixture documents (부록 A-38 ①–④ plus two negative controls).
    /// Built through the model types and encoded by `GyeolCoding` only —
    /// no hand-written JSON, so the committed files cannot drift from what
    /// the decoder accepts.
    static func buildDocuments(media: [String: GeneratedMedia]) -> [(name: String, document: GyeolDocument)] {
        let const = media[toneConst.fileName]!
        let const44 = media[toneConst44100.fileName]!
        let envelope = media[toneEnvelope.fileName]!
        let envelopeLong = media[toneEnvelopeLong.fileName]!

        let constID = MediaID(rawValue: uuid("AAAAAAAA", 1))
        let const44ID = MediaID(rawValue: uuid("AAAAAAAA", 2))
        let envelopeID = MediaID(rawValue: uuid("AAAAAAAA", 3))
        let envelopeLongID = MediaID(rawValue: uuid("AAAAAAAA", 4))

        let thirtySeconds = 30 * ticksPerSecond

        // A — sound check ① and the click check ③'s POSITIVE side: one
        // uninterrupted clip has no boundary, so any click heard here is
        // the fixture's or the engine's, not a cut's.
        let a = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [constID: reference(const)],
            tracks: [audioTrack(1, clips: [
                clip(1, mediaID: constID, timelineStart: 0, duration: thirtySeconds),
            ])],
            duration: DocumentTime(ticks: thirtySeconds))

        // B — the 44100 branch of ①. Same shape, different sample rate, so
        // the resampling path is observed rather than assumed.
        let b = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [const44ID: reference(const44)],
            tracks: [audioTrack(2, clips: [
                clip(2, mediaID: const44ID, timelineStart: 0, duration: thirtySeconds),
            ])],
            duration: DocumentTime(ticks: thirtySeconds))

        // C — envelope check ②. sourceStart 0, so the drawn envelope and
        // the heard envelope must line up tick for tick.
        let c = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [envelopeID: reference(envelope)],
            tracks: [audioTrack(3, clips: [
                clip(3, mediaID: envelopeID, timelineStart: 0, duration: thirtySeconds),
            ])],
            duration: DocumentTime(ticks: thirtySeconds))

        // D — NEGATIVE control for ②. The source is entered 0.5 s late, so
        // every silence arrives 0.5 s EARLIER than fixture C. If the
        // drawing is derived from the media rather than from the clip's
        // source range, C and D look identical and only D exposes it.
        let d = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [envelopeID: reference(envelope)],
            tracks: [audioTrack(4, clips: [
                clip(4, mediaID: envelopeID,
                     timelineStart: 0,
                     duration: thirtySeconds - ticksPerSecond / 2,
                     sourceStart: ticksPerSecond / 2),
            ])],
            duration: DocumentTime(ticks: thirtySeconds - ticksPerSecond / 2))

        // E / E-weak — NEGATIVE controls for ③, as a PAIR. Two abutting
        // clips of the SAME continuous tone, cut at 15 s, with the right
        // clip entering the source a fraction of a period late.
        //
        // The right clip is never a full 15 s: sourceStart is 15 s + the
        // offset and the media is exactly 30 s, so a full 15 s would read
        // past the end of the asset. Its duration is whatever is left.
        let cutTicks = 15 * ticksPerSecond

        func clickControl(
            offsetTicks: Int64, trackSerial: Int, leftClip: Int, rightClip: Int
        ) -> GyeolDocument {
            let rightSourceStart = cutTicks + offsetTicks
            let rightDuration = thirtySeconds - rightSourceStart
            return GyeolDocument(
                schemaVersion: .current,
                settings: settings(),
                media: [constID: reference(const)],
                tracks: [audioTrack(trackSerial, clips: [
                    clip(leftClip, mediaID: constID, timelineStart: 0, duration: cutTicks),
                    clip(rightClip, mediaID: constID,
                         timelineStart: cutTicks,
                         duration: rightDuration,
                         sourceStart: rightSourceStart),
                ])],
                duration: DocumentTime(ticks: cutTicks + rightDuration))
        }

        // The audible one: the right clip enters at the waveform PEAK, so
        // the seam is a real amplitude step (measured 16853 counts, 51.4%
        // of full scale, against a natural delta of 471).
        let e = clickControl(
            offsetTicks: quarterPeriodTicks, trackSerial: 7, leftClip: 9, rightClip: 10)

        // The near-inaudible one, kept ON PURPOSE. Half a period is a
        // polarity flip at a zero crossing: no amplitude step, only a
        // slope reversal (measured 515 counts, 1.57%, against a natural
        // delta of 471 — an excess of 44 counts, 0.13%). Its IDs and byte
        // layout are unchanged from when it was the only control.
        let eWeak = clickControl(
            offsetTicks: halfPeriodTicks, trackSerial: 5, leftClip: 5, rightClip: 6)

        // F — mute check ④. The schema has NO per-clip mute field; the
        // only clip-level representation of silence is volume 0 (the
        // track-level `isMuted` flag would silence BOTH clips and so could
        // not show the two branches side by side). Reported to the PRD:
        // §5.3 leaves this undefined.
        let tenSeconds = 10 * ticksPerSecond
        let f = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [constID: reference(const)],
            tracks: [audioTrack(6, clips: [
                clip(7, mediaID: constID, timelineStart: 0, duration: tenSeconds),
                clip(8, mediaID: constID,
                     timelineStart: 12 * ticksPerSecond,
                     duration: tenSeconds,
                     volume: 0),
            ])],
            duration: DocumentTime(ticks: 22 * ticksPerSecond))

        // G — ②'s LONG form, for the M2.3.1 human session's twelve-segment
        // blind pass. Same shape as C (one clip, sourceStart 0, the drawn
        // envelope must line up with the heard one); the only difference is
        // that the document is 180 s, so a 12 × 12 s pass finishes with the
        // playhead still inside the document and every segment still has
        // sound under it. C stays as it is — the short form is right for a
        // two-value pass and is what A-43's valid first pass used.
        let oneEightySeconds = 180 * ticksPerSecond
        let g = GyeolDocument(
            schemaVersion: .current,
            settings: settings(),
            media: [envelopeLongID: reference(envelopeLong)],
            tracks: [audioTrack(8, clips: [
                clip(11, mediaID: envelopeLongID, timelineStart: 0, duration: oneEightySeconds),
            ])],
            duration: DocumentTime(ticks: oneEightySeconds))

        return [
            ("tone-const-a", a),
            ("tone-const-44100-a", b),
            ("tone-envelope-a", c),
            ("envelope-shifted-control", d),
            ("click-control", e),
            ("click-control-weak", eWeak),
            ("mute-one", f),
            ("tone-envelope-long-a", g),
        ]
    }
}
