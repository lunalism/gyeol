import Foundation

/// Identity of a subtitle segment.
public struct SubtitleID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Encodes as a bare UUID string, not an object.
extension SubtitleID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The one subtitle style for the whole document. v1 has presets, not
/// per-segment styling (PRD §5.4), so this lives at the document root and
/// segments carry text and timing only.
public struct SubtitleStyle: Codable, Hashable, Sendable {
    /// An sRGB color as integer channels — no floating point in the schema.
    public struct Color: Codable, Hashable, Sendable {
        public var red: UInt8
        public var green: UInt8
        public var blue: UInt8
        public var alpha: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }
    }

    /// A normalized screen position; interpretation (anchor, safe margins)
    /// belongs to the render layer.
    public struct NormalizedPosition: Codable, Hashable, Sendable {
        public var x: FixedPointScalar
        public var y: FixedPointScalar

        public init(x: FixedPointScalar, y: FixedPointScalar) {
            self.x = x
            self.y = y
        }
    }

    /// Font family name. `nil` — the default — means the system font, whose
    /// CJK fallback comes for free (PRD §5.4 rule 2). Font fallback is Core
    /// Text's job; Core never resolves or validates a font name, it only
    /// stores what the app layer chose. A name unknown on this machine is
    /// still stored verbatim.
    public var fontFamily: String?
    /// Normalized against render height (a fraction, not points).
    public var fontSize: FixedPointScalar
    public var textColor: Color
    public var outlineColor: Color
    public var outlineWidth: FixedPointScalar
    public var position: NormalizedPosition

    public init(
        fontFamily: String? = nil,
        fontSize: FixedPointScalar,
        textColor: Color,
        outlineColor: Color,
        outlineWidth: FixedPointScalar,
        position: NormalizedPosition
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.textColor = textColor
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.position = position
    }

    /// System font, white text with a black outline, lower-center position —
    /// the conventional subtitle look until the user picks a preset.
    public static let `default` = SubtitleStyle(
        fontSize: FixedPointScalar(rawValue: 500),        // 5% of render height
        textColor: Color(red: 255, green: 255, blue: 255),
        outlineColor: Color(red: 0, green: 0, blue: 0),
        outlineWidth: FixedPointScalar(rawValue: 40),
        position: NormalizedPosition(
            x: FixedPointScalar(rawValue: 5_000),
            y: FixedPointScalar(rawValue: 9_000)))
}

/// One subtitle line: timing plus text. Style lives on the document.
public struct SubtitleSegment: Hashable, Sendable {
    /// Preserved exactly through decode — never regenerated.
    public let id: SubtitleID
    /// Non-negative — a negative start silently drops the head of the
    /// segment (nothing before timeline zero renders). Strict now on
    /// purpose: loosening later is safe, tightening later would make
    /// already-saved files unopenable.
    public var start: DocumentTime {
        didSet {
            precondition(start.time >= .zero, "subtitle start must be non-negative")
        }
    }
    /// Strictly positive; guarded on every construction path and at decode.
    public var duration: DocumentTime {
        didSet {
            precondition(duration.time > .zero, "subtitle duration must be strictly positive")
        }
    }
    public var text: String

    public init(id: SubtitleID, start: DocumentTime, duration: DocumentTime, text: String) {
        precondition(duration.time > .zero, "subtitle duration must be strictly positive")
        precondition(start.time >= .zero, "subtitle start must be non-negative")
        self.id = id
        self.start = start
        self.duration = duration
        self.text = text
    }
}

extension SubtitleSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, start, duration, text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try container.decode(DocumentTime.self, forKey: .duration)
        guard duration.time > .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .duration, in: container,
                debugDescription: "subtitle duration must be strictly positive, got \(duration.time)")
        }
        let start = try container.decode(DocumentTime.self, forKey: .start)
        guard start.time >= .zero else {
            throw DecodingError.dataCorruptedError(
                forKey: .start, in: container,
                debugDescription: "subtitle start must be non-negative, got \(start.time)")
        }
        self.id = try container.decode(SubtitleID.self, forKey: .id)
        self.start = start
        self.duration = duration
        self.text = try container.decode(String.self, forKey: .text)
    }
}
