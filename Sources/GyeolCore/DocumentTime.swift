import Foundation

public enum DocumentTimeError: Error, Equatable, Sendable {
    /// The rounded tick count does not fit `Int64`.
    case outOfRange
}

/// A point in document time: an `Int64` tick count at timescale 120000 —
/// the value where all supported frame rates yield integer ticks per frame.
///
/// The storage IS the contract: PRD §5.6.1 says document time is "항상
/// 120000", and this type makes that literally true by normalizing at
/// construction. `1/2` becomes 60000 ticks the moment it enters; nothing
/// converts on read, so there is no conversion left to fail downstream.
/// (`RationalTime`'s "약분하지 않는다" representation-preserving rule
/// governs `RationalTime`, not this type — DocumentTime is a normalized
/// type by definition.)
///
/// Guards per §5.6.7: decode accepts only a bare integer (throws
/// otherwise), and the labeled initializers refuse (`exactly`) or round
/// visibly (`rounding`). There is no unlabeled initializer, mirroring
/// `FixedPointScalar` (§5.6.2). Assignment needs no guard at all — every
/// `Int64` tick count is on-grid, so invalid states are unrepresentable
/// rather than checked. The `time` setter (a `RationalTime` entry point)
/// still traps on off-grid input.
///
/// Wire format: the bare tick count — `240000`, not
/// `{"value": 240000, "timescale": 120000}`. The timescale is 120000 by
/// definition, so storing it on every field would repeat a constant
/// thousands of times and make it look mutable, inviting a hand-editor to
/// change it. A 3-hour project has 1,000–3,600 subtitle segments; the
/// object form would run the document to tens of thousands of lines.
public struct DocumentTime: Hashable, Sendable {
    public static let timescale: Int32 = 120_000

    /// Canonical storage. Any `Int64` is a valid tick count.
    public var ticks: Int64

    /// `RationalTime` view of this time. The getter is free (the stored
    /// ticks ARE the value); the setter is the assignment leg of §5.6.7's
    /// triple guard and traps on a value off the 120000 grid.
    public var time: RationalTime {
        get { RationalTime(unchecked: ticks, timescale: Self.timescale) }
        set {
            guard let converted = try? newValue.converted(to: Self.timescale) else {
                preconditionFailure(
                    "document time \(newValue) is not exactly representable at timescale \(Self.timescale)")
            }
            ticks = converted.value
        }
    }

    /// `nil` unless `time` lies exactly on the 120000 tick grid
    /// (`1/2` does — it becomes 60000 ticks; `1/44100` does not).
    /// Converts ONCE, here; the caller's representation is normalized away.
    public init?(exactly time: RationalTime) {
        guard let converted = try? time.converted(to: Self.timescale) else { return nil }
        self.ticks = converted.value
    }

    /// Lossy conversion onto the 120000 tick grid. The label makes the
    /// rounding visible at the call site; audio sample times (1/44100,
    /// 1/48000) are the expected customers.
    ///
    /// BOUNDARY — read before reaching for this: this initializer does NOT
    /// know about frame grids. It rounds to 120000 TICKS and nothing more.
    /// Snapping a time onto a frame boundary is `CMTimeAdapter`'s job and
    /// only its job. Using this on a path that requires frame accuracy is
    /// the failure PRD §10 names as "시각 반올림 API가 늘어남" — preview
    /// and export ending up with different rounding, which breaks S3.
    public init(
        rounding time: RationalTime,
        rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) throws {
        let rounded = Self.roundedTicks(
            numerator: Int128(time.value) * Int128(Self.timescale),
            denominator: Int128(time.timescale),
            rule: rule)
        guard let value = Int64(exactly: rounded) else { throw DocumentTimeError.outOfRange }
        self.ticks = value
    }

    /// Internal fast path for code that already has ticks (decode, frame
    /// mapping, adapter). Nothing is unchecked about it — every Int64 is a
    /// valid tick count.
    init(ticks: Int64) {
        self.ticks = ticks
    }

    public static let zero = DocumentTime(ticks: 0)

    /// Integer rounding of numerator/denominator (denominator > 0) under
    /// the same rules `FixedPointScalar` accepts, computed exactly.
    private static func roundedTicks(
        numerator: Int128, denominator: Int128, rule: FloatingPointRoundingRule
    ) -> Int128 {
        precondition(denominator > 0)
        let quotient = numerator / denominator  // truncates toward zero
        let remainder = numerator % denominator
        if remainder == 0 { return quotient }
        let steppedAway = numerator > 0 ? quotient + 1 : quotient - 1
        switch rule {
        case .towardZero:
            return quotient
        case .awayFromZero:
            return steppedAway
        case .down:
            return numerator < 0 ? steppedAway : quotient
        case .up:
            return numerator > 0 ? steppedAway : quotient
        case .toNearestOrAwayFromZero:
            return 2 * remainder.magnitude >= denominator.magnitude ? steppedAway : quotient
        case .toNearestOrEven:
            if 2 * remainder.magnitude != denominator.magnitude {
                return 2 * remainder.magnitude > denominator.magnitude ? steppedAway : quotient
            }
            // Exact half: of the two candidates, keep the even one.
            return quotient.isMultiple(of: 2) ? quotient : steppedAway
        @unknown default:
            preconditionFailure("unsupported rounding rule \(rule)")
        }
    }
}

// MARK: - Codable

extension DocumentTime: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let ticks = try? container.decode(Int64.self) {
            self.init(ticks: ticks)
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
        try container.encode(ticks)
    }
}
