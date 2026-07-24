import Foundation

/// Payload of `ClipSource.media`. A struct rather than bare associated
/// values because an enum case has no initializer to hang a precondition
/// on — wrapping the payload lets it validate itself at construction, the
/// same pattern as `Clip`'s other validated fields, so an invalid `.media`
/// traps where it is built instead of minutes later inside an autosave.
public struct MediaSource: Hashable, Sendable {
    public var mediaID: MediaID
    /// Non-negative — media has no content before zero, so a negative
    /// offset is an impossible state.
    public var sourceStart: DocumentTime {
        didSet { precondition(sourceStart.time >= .zero, "sourceStart must be non-negative") }
    }

    public init(mediaID: MediaID, sourceStart: DocumentTime) {
        precondition(sourceStart.time >= .zero, "sourceStart must be non-negative")
        self.mediaID = mediaID
        self.sourceStart = sourceStart
    }
}

/// What a clip plays: a media asset or a generator (PRD §5.6).
///
/// `sourceStart` lives INSIDE the `.media` payload, not on `Clip`: a
/// generator has no source asset to offset into, so a `sourceStart` stored
/// on `Clip` would make an impossible state representable.
public enum ClipSource: Hashable, Sendable {
    /// Plays `media.mediaID` starting at `media.sourceStart` into the
    /// source asset.
    case media(MediaSource)
    /// Renders a generator (spectrum, text overlay, …) — no source asset.
    case generator(identifier: String, parameters: GyeolValue)
}

// MARK: - Codable

/// Encodes as a tagged object with a `"kind"` discriminator:
///
///     {"kind": "media", "mediaID": "…", "sourceStart": {…}}
///     {"kind": "generator", "identifier": "…", "parameters": {…}}
///
/// An unknown kind throws — silently decoding it as one of the known cases
/// would turn a future schema's clip into the wrong thing.
extension ClipSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, mediaID, sourceStart, identifier, parameters
    }

    private static let mediaKind = "media"
    private static let generatorKind = "generator"

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Self.mediaKind:
            // The throw must come before MediaSource's precondition would
            // fire: an external file gets an error, not a trap.
            let sourceStart = try container.decode(DocumentTime.self, forKey: .sourceStart)
            guard sourceStart.time >= .zero else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sourceStart, in: container,
                    debugDescription: "sourceStart must be non-negative, got \(sourceStart.time)")
            }
            self = .media(MediaSource(
                mediaID: try container.decode(MediaID.self, forKey: .mediaID),
                sourceStart: sourceStart))
        case Self.generatorKind:
            self = .generator(
                identifier: try container.decode(String.self, forKey: .identifier),
                parameters: try container.decode(GyeolValue.self, forKey: .parameters))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unknown clip source kind '\(kind)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .media(let media):
            try container.encode(Self.mediaKind, forKey: .kind)
            try container.encode(media.mediaID, forKey: .mediaID)
            try container.encode(media.sourceStart, forKey: .sourceStart)
        case .generator(let identifier, let parameters):
            try container.encode(Self.generatorKind, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
            try container.encode(parameters, forKey: .parameters)
        }
    }
}
