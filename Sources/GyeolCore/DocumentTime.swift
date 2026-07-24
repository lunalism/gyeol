import Foundation

/// A `RationalTime` at the document boundary.
///
/// Every time written to a `.gyeol` document uses timescale 120000 — the
/// value where all supported frame rates yield integer ticks per frame.
/// `RationalTime` itself stays general-purpose; the restriction lives here,
/// in the ONE Codable implementation every document type shares by using
/// this as its field type. Do not re-implement the conversion per type — a
/// second copy is how the two drift apart.
///
/// Wire format: a bare Int64 tick count — `240000`, not
/// `{"value": 240000, "timescale": 120000}`. The timescale is 120000 by
/// definition, so storing it on every field would repeat a constant
/// thousands of times and — worse — make it look mutable, inviting a
/// hand-editor to change it. This mirrors `FixedPointScalar`:
/// `"volume": 10000` already means 1.0 by documented scale. A 3-hour
/// project has 1,000–3,600 subtitle segments; at four lines per time field
/// the document would run to tens of thousands of lines, making §5.6's
/// "human-readable, git-diffable" true only on paper.
///
/// - Decoding accepts a bare integer only, with `GyeolValue`-grade
///   strictness: a fractional number or one outside Int64 throws. The
///   legacy `{value, timescale}` object form is rejected with an explicit
///   message, not a confusing type error.
/// - Encoding converts exactly to 120000 and emits the tick count (throws
///   if the in-memory value cannot be represented — construct document
///   times at 120000-compatible timescales).
/// - `RationalTime`'s own object encoding and stored-representation
///   contract are untouched; only DocumentTime's wire format is bare.
public struct DocumentTime: Hashable, Sendable {
    public static let timescale: Int32 = 120_000

    public var time: RationalTime

    public init(_ time: RationalTime) {
        self.time = time
    }

    public static let zero = DocumentTime(.zero)
}

// MARK: - Codable

extension DocumentTime: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ticks = try? container.decode(Int64.self) {
            time = RationalTime(unchecked: ticks, timescale: Self.timescale)
            return
        }
        // Int64 failed — diagnose instead of surfacing a bare type error.
        if let double = try? container.decode(Double.self) {
            let reason = double == double.rounded()
                ? "integer out of Int64 range"
                : "fractional number"
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                document time rejects \(reason) \(double): times are bare \
                integer tick counts at timescale \(Self.timescale), never \
                rounded
                """))
        }
        if (try? RationalTime(from: decoder)) != nil {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                expected a bare integer tick count at timescale \
                \(Self.timescale), found the legacy {"value", "timescale"} \
                object form
                """))
        }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: """
            expected a bare integer tick count at timescale \(Self.timescale)
            """))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(time.converted(to: Self.timescale).value)
    }
}
