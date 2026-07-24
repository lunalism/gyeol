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

    public init(
        schemaVersion: SchemaVersion,
        settings: ProjectSettings,
        media: [MediaID: MediaReference] = [:],
        tracks: [Track] = [],
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
        self.schemaVersion = schemaVersion
        self.settings = settings
        self.media = media
        self.tracks = tracks
        self.subtitles = subtitles
        self.subtitleStyle = subtitleStyle
        self.markers = markers
    }

    /// An empty document at the current schema version. 1080p30 is the
    /// conventional starting point until the user changes settings.
    public static let empty = GyeolDocument(
        schemaVersion: .current,
        settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080))

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
        case schemaVersion, settings, media, tracks, subtitles, subtitleStyle, markers
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

        self.schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        self.settings = try container.decode(ProjectSettings.self, forKey: .settings)
        self.media = media
        self.tracks = tracks
        self.subtitles = subtitles
        self.subtitleStyle = try container.decode(SubtitleStyle.self, forKey: .subtitleStyle)
        self.markers = markers
    }
}
