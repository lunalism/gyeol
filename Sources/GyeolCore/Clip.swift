import Foundation

/// Identity of a clip on the timeline. Distinct from `MediaID` so the two
/// cannot be confused at compile time.
public struct ClipID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Encodes as a bare UUID string, not an object.
extension ClipID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One clip on the timeline.
///
/// The end time is deliberately NOT stored: it is derivable from
/// `timelineStart + duration`, and a stored copy is a place for the two to
/// disagree. No editing operations (overlap checks, trimming, splitting)
/// live on this value type — those are a later step.
public struct Clip: Hashable, Sendable {
    /// Preserved exactly through decode — never regenerated. Undo snapshots
    /// and selection restoration depend on the identity surviving a
    /// load/save cycle.
    public let id: ClipID
    /// Non-negative. A negative start would mean the clip's head is silently
    /// dropped — nothing before timeline zero renders or exports. Strict now
    /// on purpose: loosening later is safe (no existing file has negatives),
    /// tightening later would make already-saved files unopenable.
    public var timelineStart: DocumentTime {
        didSet {
            precondition(timelineStart.time >= .zero, "timelineStart must be non-negative")
        }
    }
    /// Strictly positive. The didSet guard exists because a public setter
    /// would otherwise bypass the initializer's precondition and let an
    /// undecodable clip reach autosave. (didSet does not fire during init;
    /// the initializers keep their own checks.)
    public var duration: DocumentTime {
        didSet {
            precondition(duration.time > .zero, "clip duration must be strictly positive")
        }
    }
    public var source: ClipSource
    public var effects: [EffectInstance]
    public var audio: AudioSettings

    /// The editing layer must clamp a trim to a minimum duration BEFORE
    /// constructing a `Clip` — a trim drag past the clip's own start would
    /// otherwise build an invalid clip that encodes without complaint, gets
    /// autosaved to disk by `NSDocument` with no user action, and then
    /// refuses to decode. Core fails loudly here rather than storing an
    /// impossible state.
    public init(
        id: ClipID,
        timelineStart: DocumentTime,
        duration: DocumentTime,
        source: ClipSource,
        effects: [EffectInstance] = [],
        audio: AudioSettings = .default
    ) {
        precondition(duration.time > .zero, "clip duration must be strictly positive")
        precondition(timelineStart.time >= .zero, "timelineStart must be non-negative")
        self.id = id
        self.timelineStart = timelineStart
        self.duration = duration
        self.source = source
        self.effects = effects
        self.audio = audio
    }

    /// The one derived quantity: `timelineStart + duration`. Throws only on
    /// `Int64` overflow of the exact sum.
    public func timelineEnd() throws -> DocumentTime {
        let (sum, overflow) = timelineStart.ticks.addingReportingOverflow(duration.ticks)
        guard !overflow else { throw RationalTimeError.overflow }
        return DocumentTime(ticks: sum)
    }
}

// MARK: - AudioSettings

extension Clip {
    /// Per-clip audio: volume plus fade-in/out durations (PRD §5.3 — volume
    /// and fades are the entire v1 audio feature set; EQ/compressor/ducking
    /// are out of scope).
    public struct AudioSettings: Hashable, Sendable {
        public var volume: FixedPointScalar
        /// Non-negative; guarded on every path (init, didSet, decode) so an
        /// invalid fade can never reach autosave.
        public var fadeIn: DocumentTime {
            didSet { precondition(fadeIn.time >= .zero, "fadeIn must be non-negative") }
        }
        public var fadeOut: DocumentTime {
            didSet { precondition(fadeOut.time >= .zero, "fadeOut must be non-negative") }
        }

        /// Same contract as `Clip.init`: the editing layer clamps fades to
        /// zero before constructing; an invalid value here would be
        /// autosaved into an unopenable file.
        public init(volume: FixedPointScalar, fadeIn: DocumentTime, fadeOut: DocumentTime) {
            precondition(fadeIn.time >= .zero, "fadeIn must be non-negative")
            precondition(fadeOut.time >= .zero, "fadeOut must be non-negative")
            self.volume = volume
            self.fadeIn = fadeIn
            self.fadeOut = fadeOut
        }

        /// Unity gain (10000 = 1.0), no fades: a freshly placed clip plays
        /// its source audio untouched.
        public static let `default` = AudioSettings(
            volume: FixedPointScalar(rawValue: FixedPointScalar.scale),
            fadeIn: .zero,
            fadeOut: .zero)
    }
}

// MARK: - Codable

/// Decoding validates what an external file can get wrong; in-memory
/// construction trusts the caller (editing code works on already-valid
/// values). `encode(to:)` is synthesized from the same `CodingKeys` the
/// manual decoders use.
extension Clip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timelineStart, duration, source, effects, audio
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try container.decode(DocumentTime.self, forKey: .duration)
        guard duration.time > .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .duration, in: container,
                debugDescription: "clip duration must be strictly positive, got \(duration.time)")
        }
        let timelineStart = try container.decode(DocumentTime.self, forKey: .timelineStart)
        guard timelineStart.time >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .timelineStart, in: container,
                debugDescription: "timelineStart must be non-negative, got \(timelineStart.time)")
        }
        self.id = try container.decode(ClipID.self, forKey: .id)
        self.timelineStart = timelineStart
        self.duration = duration
        self.source = try container.decode(ClipSource.self, forKey: .source)
        self.effects = try container.decode([EffectInstance].self, forKey: .effects)
        self.audio = try container.decode(AudioSettings.self, forKey: .audio)
    }
}

extension Clip.AudioSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case volume, fadeIn, fadeOut
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fadeIn = try container.decode(DocumentTime.self, forKey: .fadeIn)
        let fadeOut = try container.decode(DocumentTime.self, forKey: .fadeOut)
        guard fadeIn.time >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .fadeIn, in: container,
                debugDescription: "fadeIn must be non-negative, got \(fadeIn.time)")
        }
        guard fadeOut.time >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .fadeOut, in: container,
                debugDescription: "fadeOut must be non-negative, got \(fadeOut.time)")
        }
        self.volume = try container.decode(FixedPointScalar.self, forKey: .volume)
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}
