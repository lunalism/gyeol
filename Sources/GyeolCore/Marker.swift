import Foundation

/// Identity of a timeline marker.
public struct MarkerID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Encodes as a bare UUID string, not an object.
extension MarkerID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A named point on the timeline.
public struct Marker: Hashable, Sendable {
    public let id: MarkerID
    /// Non-negative — nothing before timeline zero exists to mark.
    public var time: DocumentTime {
        didSet { precondition(time.time >= .zero, "marker time must be non-negative") }
    }
    public var label: String

    public init(id: MarkerID, time: DocumentTime, label: String) {
        precondition(time.time >= .zero, "marker time must be non-negative")
        self.id = id
        self.time = time
        self.label = label
    }
}

extension Marker: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, time, label
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let time = try container.decode(DocumentTime.self, forKey: .time)
        guard time.time >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .time, in: container,
                debugDescription: "marker time must be non-negative, got \(time.time)")
        }
        self.id = try container.decode(MarkerID.self, forKey: .id)
        self.time = time
        self.label = try container.decode(String.self, forKey: .label)
    }
}
