import Foundation

/// Lets `[MediaID: MediaReference]` encode as a JSON *object* keyed by UUID
/// string. Without this conformance, Codable serializes a dictionary with a
/// non-String key as a flat `[key, value, key, value]` array — unreadable
/// and undiffable.
extension MediaID: CodingKeyRepresentable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public var codingKey: any CodingKey {
        Key(stringValue: rawValue.uuidString)
    }

    public init?<T: CodingKey>(codingKey: T) {
        guard let uuid = UUID(uuidString: codingKey.stringValue) else { return nil }
        self.init(rawValue: uuid)
    }
}

/// The `.gyeol` document root — the value the whole app edits, snapshots
/// for undo, and hands to the render path.
public struct GyeolDocument: Hashable, Sendable {
    public var schemaVersion: SchemaVersion
    public var settings: ProjectSettings

    /// The media pool, keyed by `MediaID`.
    ///
    /// Encodes as a JSON object keyed by UUID string (via `MediaID`'s
    /// `CodingKeyRepresentable`), not as an array of entries. Under
    /// `.sortedKeys` the object has ONE canonical byte form for a given set
    /// of media, so adding an item produces a single localized diff at its
    /// sorted position. An array has no canonical order: two logically
    /// equal pools could serialize differently depending on insertion
    /// history, which breaks both diff stability and byte-identity.
    public var media: [MediaID: MediaReference]

    /// Variable-length on purpose: the fixed 3 video + 2 audio layout
    /// (PRD §5.2) is a UI constraint, not a schema one — v1.1 adds track
    /// management UI without touching this format. Each track validates its
    /// own clip ordering; cross-track overlap is legal.
    ///
    /// Cross-field invariant with `media`: every `.media` clip must
    /// reference a pool entry. Enforced at decode (throw) and init
    /// (precondition), but NOT on these setters: a per-assignment check
    /// would trap legitimate multi-step edits (add the clip then the pool
    /// entry, or the reverse order when removing) whichever order the
    /// caller picks. The M2 editing operations are the transaction boundary
    /// that enforces this on mutation (PRD §9 M2); until then callers must
    /// keep pool and tracks consistent themselves.
    public var tracks: [Track]

    /// Subtitles live at the document root, NOT as clips on a track:
    ///
    /// - A 3-hour project carries 1,000–3,600 segments (PRD 부록 C), which
    ///   would swamp the fixed track layout.
    /// - Their edit operations differ from clips' (text edit, split/merge
    ///   vs trim, ripple), so sharing `Clip` buys nothing.
    /// - SRT export iterates them directly.
    ///
    /// Sorted by `start` ascending (enforced like `Track.clips`), but
    /// overlap IS allowed — two simultaneous lines is legitimate. Only the
    /// ordering is an invariant.
    public var subtitles: [SubtitleSegment] {
        didSet {
            if let violation = Self.subtitleOrderingViolation(subtitles) {
                preconditionFailure(violation)
            }
        }
    }

    /// One style for the whole document; see `SubtitleStyle`.
    public var subtitleStyle: SubtitleStyle

    /// Sorted by `time` ascending (ties allowed).
    public var markers: [Marker] {
        didSet {
            if let violation = Self.markerOrderingViolation(markers) {
                preconditionFailure(violation)
            }
        }
    }

    /// The timeline's length — and therefore the playable domain of
    /// playback AND export (M2.1 decision, report target for the PRD).
    ///
    /// The PRD referenced a document `duration` (§4.1 L3, D20) without ever
    /// declaring it in the schema; the playable domain was silently "the
    /// last clip's end", which makes deliberate trailing space after the
    /// last clip vanish — a §7.4-6 violation. It is now document data:
    /// trailing empty region renders per the empty-region rule.
    ///
    /// Guards: non-negative here (didSet); the CROSS-FIELD invariant —
    /// `duration` ≥ every clip's end — is decode-throw + init-precondition
    /// only, like the dangling-media check: a didSet cannot order
    /// multi-step edits (§5.6.7), so the M2 editing transaction owns it on
    /// mutation. Decoding a document without the field (written before it
    /// existed) derives it from the last clip end — exactly the old
    /// behavior, so no existing file changes meaning.
    public var duration: DocumentTime {
        didSet { precondition(duration.time >= .zero, "duration must be non-negative") }
    }

    public init(
        schemaVersion: SchemaVersion,
        settings: ProjectSettings,
        media: [MediaID: MediaReference] = [:],
        tracks: [Track] = [],
        duration: DocumentTime? = nil,
        subtitles: [SubtitleSegment] = [],
        subtitleStyle: SubtitleStyle = .default,
        markers: [Marker] = []
    ) {
        if let violation = Self.subtitleOrderingViolation(subtitles) {
            preconditionFailure(violation)
        }
        if let violation = Self.markerOrderingViolation(markers) {
            preconditionFailure(violation)
        }
        for track in tracks {
            for clip in track.clips {
                if case .media(let source) = clip.source {
                    precondition(
                        media[source.mediaID] != nil,
                        "clip \(clip.id.rawValue.uuidString) references media absent from the pool")
                }
            }
        }
        let resolvedDuration = duration ?? Self.derivedDuration(of: tracks)
        if let violation = Self.durationViolation(resolvedDuration, tracks: tracks) {
            preconditionFailure(violation)
        }
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.media = media
        self.tracks = tracks
        self.duration = resolvedDuration
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.markers = markers
    }

    /// An empty document at the current schema version. 1080p30 is the
    /// conventional starting point until the user changes settings.
    public static let empty = GyeolDocument(
        schemaVersion: .current,
        settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080))

    /// The last clip's end across all tracks — the pre-field playable
    /// domain, used as the default when `duration` is absent.
    static func derivedDuration(of tracks: [Track]) -> DocumentTime {
        var maxEndTicks: Int64 = 0
        for track in tracks {
            for clip in track.clips {
                if let end = try? clip.timelineEnd() {
                    maxEndTicks = max(maxEndTicks, end.ticks)
                }
            }
        }
        return DocumentTime(ticks: maxEndTicks)
    }

    static func durationViolation(_ duration: DocumentTime, tracks: [Track]) -> String? {
        guard duration.time >= .zero else {
            return "duration must be non-negative, got \(duration.time)"
        }
        for track in tracks {
            for clip in track.clips {
                guard let end = try? clip.timelineEnd() else {
                    return "clip \(clip.id.rawValue.uuidString) end time overflows"
                }
                if end.ticks > duration.ticks {
                    return """
                    clip \(clip.id.rawValue.uuidString) ends at \(end.ticks) ticks, \
                    beyond the document duration \(duration.ticks)
                    """
                }
            }
        }
        return nil
    }

    static func subtitleOrderingViolation(_ subtitles: [SubtitleSegment]) -> String? {
        for index in subtitles.indices.dropFirst()
        where subtitles[index].start.time < subtitles[index - 1].start.time {
            return "subtitles must be sorted by start ascending"
        }
        return nil
    }

    static func markerOrderingViolation(_ markers: [Marker]) -> String? {
        for index in markers.indices.dropFirst()
        where markers[index].time.time < markers[index - 1].time.time {
            return "markers must be sorted by time ascending"
        }
        return nil
    }
}

// MARK: - Codable

extension GyeolDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, settings, media, tracks, duration, subtitles, subtitleStyle, markers
    }

    private struct MediaPoolKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The media pool is decoded by hand, not via the synthesized
        // Dictionary path: `UUID(uuidString:)` normalizes letter case, so
        // two JSON keys differing only in case would collapse to one
        // MediaID and the Dictionary decode would silently drop an entry.
        // (Byte-identical duplicate keys are collapsed by the JSON parser
        // itself before we see them — that case is not detectable here.)
        let mediaContainer = try container.nestedContainer(keyedBy: MediaPoolKey.self, forKey: .media)
        var media = [MediaID: MediaReference](minimumCapacity: mediaContainer.allKeys.count)
        for key in mediaContainer.allKeys {
            guard let uuid = UUID(uuidString: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: mediaContainer,
                    debugDescription: "media pool key '\(key.stringValue)' is not a UUID")
            }
            let id = MediaID(rawValue: uuid)
            guard media[id] == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: mediaContainer,
                    debugDescription: """
                    duplicate media pool key \(uuid.uuidString) after UUID normalization
                    """)
            }
            media[id] = try mediaContainer.decode(MediaReference.self, forKey: key)
        }
        let tracks = try container.decode([Track].self, forKey: .tracks)
        let subtitles = try container.decode([SubtitleSegment].self, forKey: .subtitles)
        let markers = try container.decode([Marker].self, forKey: .markers)

        if let violation = Self.subtitleOrderingViolation(subtitles) {
            throw DecodingError.dataCorruptedError(
                forKey: .subtitles, in: container, debugDescription: violation)
        }
        if let violation = Self.markerOrderingViolation(markers) {
            throw DecodingError.dataCorruptedError(
                forKey: .markers, in: container, debugDescription: violation)
        }
        // A dangling media reference is unrenderable; catching it at load
        // beats a nil deref at render time.
        for track in tracks {
            for clip in track.clips {
                if case .media(let source) = clip.source, media[source.mediaID] == nil {
                    throw DecodingError.dataCorruptedError(
                        forKey: .tracks, in: container,
                        debugDescription: """
                        clip \(clip.id.rawValue.uuidString) references media \
                        \(source.mediaID.rawValue.uuidString) absent from the media pool
                        """)
                }
            }
        }

        // Absent in files written before the field existed: derive the old
        // playable domain (last clip end) so their meaning is unchanged.
        let duration = try container.decodeIfPresent(DocumentTime.self, forKey: .duration)
            ?? Self.derivedDuration(of: tracks)
        if let violation = Self.durationViolation(duration, tracks: tracks) {
            throw DecodingError.dataCorruptedError(
                forKey: .duration, in: container, debugDescription: violation)
        }
        self.duration = duration

        self.schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        self.settings = try container.decode(ProjectSettings.self, forKey: .settings)
        self.media = media
        self.tracks = tracks
        self.subtitles = subtitles
        self.subtitleStyle = try container.decode(SubtitleStyle.self, forKey: .subtitleStyle)
        self.markers = markers
    }
}
