/// Errors thrown by `RationalTime` operations.
public enum RationalTimeError: Error, Equatable, Sendable {
    /// The timescale was zero or negative. Timescales must be positive.
    case invalidTimescale(Int32)
    /// The exact result cannot be represented as `Int64` value / `Int32` timescale.
    case overflow
    /// The conversion target timescale cannot represent this time exactly.
    case lossyConversion
}

/// An exact rational point in time: `value / timescale` seconds.
///
/// Equality, ordering, and hashing are mathematical: `1/2 == 2/4`, and equal
/// times hash identically regardless of timescale. All arithmetic and
/// conversions are exact — an operation either returns a precise result or
/// throws; it never silently truncates or rounds.
public struct RationalTime: Sendable {
    public let value: Int64
    /// Always positive. Enforced at every construction site, including decoding.
    public let timescale: Int32

    public static let zero = RationalTime(unchecked: 0, timescale: 1)

    public init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else { throw RationalTimeError.invalidTimescale(timescale) }
        self.value = value
        self.timescale = timescale
    }

    /// Construction that bypasses validation. Callers must guarantee `timescale > 0`.
    init(unchecked value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }
}

// MARK: - Arithmetic

extension RationalTime {
    /// Exact sum. Preserves the least common timescale when it fits, reduces
    /// the fraction when that is required to fit, and throws
    /// `RationalTimeError.overflow` when the result is unrepresentable even
    /// in lowest terms.
    public func adding(_ other: RationalTime) throws -> RationalTime {
        try combined(with: other, sign: 1)
    }

    /// Exact difference. Same representability rules as `adding(_:)`.
    public func subtracting(_ other: RationalTime) throws -> RationalTime {
        try combined(with: other, sign: -1)
    }

    public static func + (lhs: RationalTime, rhs: RationalTime) throws -> RationalTime {
        try lhs.adding(rhs)
    }

    public static func - (lhs: RationalTime, rhs: RationalTime) throws -> RationalTime {
        try lhs.subtracting(rhs)
    }

    private func combined(with other: RationalTime, sign: Int128) throws -> RationalTime {
        let a = Int128(timescale)
        let b = Int128(other.timescale)
        let lcm = a / Self.gcd(a, b) * b
        // |value| ≤ 2^63 and lcm/a ≤ 2^31, so each term is ≤ 2^94: Int128 is exact here.
        let numerator = Int128(value) * (lcm / a) + sign * Int128(other.value) * (lcm / b)
        return try RationalTime(exactNumerator: numerator, denominator: lcm)
    }

    /// Builds a time from an exact 128-bit fraction. Keeps `denominator` as the
    /// timescale when representable; otherwise reduces to lowest terms before
    /// giving up with `.overflow`.
    private init(exactNumerator numerator: Int128, denominator: Int128) throws {
        precondition(denominator > 0)
        if let v = Int64(exactly: numerator), let t = Int32(exactly: denominator) {
            self.init(unchecked: v, timescale: t)
            return
        }
        let g = Int128(Self.gcd(numerator.magnitude, denominator.magnitude))
        guard let v = Int64(exactly: numerator / g), let t = Int32(exactly: denominator / g) else {
            throw RationalTimeError.overflow
        }
        self.init(unchecked: v, timescale: t)
    }
}

// MARK: - Timescale conversion

extension RationalTime {
    /// Re-expresses this time in `newTimescale` exactly.
    ///
    /// Throws `RationalTimeError.lossyConversion` if the time is not exactly
    /// representable at that timescale (this type never truncates), and
    /// `.overflow` if the exact converted value exceeds `Int64`.
    public func converted(to newTimescale: Int32) throws -> RationalTime {
        guard newTimescale > 0 else { throw RationalTimeError.invalidTimescale(newTimescale) }
        let numerator = Int128(value) * Int128(newTimescale)
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: Int128(timescale))
        guard remainder == 0 else { throw RationalTimeError.lossyConversion }
        guard let v = Int64(exactly: quotient) else { throw RationalTimeError.overflow }
        return RationalTime(unchecked: v, timescale: newTimescale)
    }

    /// Lowest-terms form of this time. `0` always reduces to `0/1`.
    public func reduced() -> RationalTime {
        guard value != 0 else { return .zero }
        let g = Self.gcd(value.magnitude, UInt64(timescale))
        return RationalTime(unchecked: value / Int64(g), timescale: timescale / Int32(g))
    }
}

// MARK: - Equatable, Comparable, Hashable

extension RationalTime: Equatable, Comparable, Hashable {
    /// Mathematical equality: `1/2 == 2/4`. Timescales are always positive,
    /// and Int64 × Int32 cannot overflow Int128, so cross-multiplying is exact.
    public static func == (lhs: RationalTime, rhs: RationalTime) -> Bool {
        Int128(lhs.value) * Int128(rhs.timescale) == Int128(rhs.value) * Int128(lhs.timescale)
    }

    public static func < (lhs: RationalTime, rhs: RationalTime) -> Bool {
        Int128(lhs.value) * Int128(rhs.timescale) < Int128(rhs.value) * Int128(lhs.timescale)
    }

    public func hash(into hasher: inout Hasher) {
        let canonical = reduced()
        hasher.combine(canonical.value)
        hasher.combine(canonical.timescale)
    }
}

// MARK: - Codable

/// Encoding contract:
///
/// - Encoding preserves the stored representation exactly. No normalization,
///   no reduction. Consequence: `1/2` and `2/4` are `==` but encode to
///   different bytes.
/// - Under a fixed, deterministic encoder configuration (e.g. `.sortedKeys`,
///   configured by the caller), model → `Data` → model → `Data` is
///   byte-identical. The default `JSONEncoder` does not order keys
///   deterministically, so it is not sufficient for byte-identity.
/// - Byte-identity starting from arbitrary `Data` is explicitly not a
///   contract: a decoder accepts any equivalent JSON (key order, whitespace),
///   and re-encoding such input may produce different bytes.
///
/// `RationalTime` deliberately does not configure the encoder (e.g.
/// `.sortedKeys`); encoder configuration belongs to the document layer.
extension RationalTime: Codable {
    private enum CodingKeys: String, CodingKey {
        case value, timescale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = try container.decode(Int64.self, forKey: .value)
        let timescale = try container.decode(Int32.self, forKey: .timescale)
        guard timescale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timescale, in: container,
                debugDescription: "timescale must be positive, got \(timescale)")
        }
        self.init(unchecked: value, timescale: timescale)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(timescale, forKey: .timescale)
    }
}

// MARK: - CustomStringConvertible

extension RationalTime: CustomStringConvertible {
    public var description: String { "\(value)/\(timescale)" }
}

// MARK: - Helpers

extension RationalTime {
    private static func gcd<T: BinaryInteger>(_ a: T, _ b: T) -> T {
        var a = a, b = b
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
