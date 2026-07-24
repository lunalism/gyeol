import Foundation

/// Identity of a track. Distinct from the other ID wrappers so the compiler
/// keeps them apart.
public struct TrackID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Encodes as a bare UUID string, not an object.
extension TrackID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Closed, string-encoded. The synthesized Codable throws on an unknown kind.
public enum TrackKind: String, Codable, Hashable, Sendable {
    case video
    case audio
}

/// One timeline track.
///
/// `clips` is stored sorted by `timelineStart` ascending, and clips on the
/// same track must not overlap:
///
/// - Viewport virtualization (PRD §5.2) binary-searches this array to find
///   the visible range; a 3-hour project cannot afford a linear scan per
///   frame, so sortedness is a schema invariant, not a courtesy.
/// - Overlap is rejected because the renderer would have to pick a winner
///   arbitrarily, which breaks render purity (§7.4-3).
///
/// Decode does NOT silently sort. Out-of-order input means the editing
/// layer has a bug, and quietly fixing it hides the signal.
///
/// No insert/remove/split methods here — editing operations come later.
public struct Track: Hashable, Sendable {
    public let id: TrackID
    public var kind: TrackKind
    public var isMuted: Bool
    public var clips: [Clip] {
        didSet {
            if let violation = Self.clipOrderingViolation(clips) {
                preconditionFailure(violation)
            }
        }
    }

    public init(id: TrackID, kind: TrackKind, clips: [Clip] = [], isMuted: Bool = false) {
        if let violation = Self.clipOrderingViolation(clips) {
            preconditionFailure(violation)
        }
        self.id = id
        self.kind = kind
        self.clips = clips
        self.isMuted = isMuted
    }

    /// Returns a description of the first ordering/overlap violation, or
    /// nil when the array is valid. Shared by init, didSet, and decode so
    /// the rule cannot drift between them.
    static func clipOrderingViolation(_ clips: [Clip]) -> String? {
        for index in clips.indices.dropFirst() {
            let previous = clips[index - 1]
            let next = clips[index]
            if next.timelineStart.time < previous.timelineStart.time {
                return "clips must be sorted by timelineStart ascending"
            }
            guard let previousEnd = try? previous.timelineEnd() else {
                return "clip \(previous.id.rawValue.uuidString) end time overflows"
            }
            // A clip starting exactly at the previous clip's end is a legal
            // hard cut; only a strictly earlier start overlaps.
            if next.timelineStart.time < previousEnd.time {
                return "clips on one track must not overlap"
            }
        }
        return nil
    }
}

extension Track: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, clips, isMuted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let clips = try container.decode([Clip].self, forKey: .clips)
        if let violation = Self.clipOrderingViolation(clips) {
            throw DecodingError.dataCorruptedError(
                forKey: .clips, in: container, debugDescription: violation)
        }
        self.id = try container.decode(TrackID.self, forKey: .id)
        self.kind = try container.decode(TrackKind.self, forKey: .kind)
        self.clips = clips
        self.isMuted = try container.decode(Bool.self, forKey: .isMuted)
    }
}
