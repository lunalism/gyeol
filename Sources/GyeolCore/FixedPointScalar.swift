import Foundation

public enum FixedPointScalarError: Error, Equatable {
    case nonFinite
    case outOfRange
}

/// A normalized parameter (volume, opacity, position, size, sensitivity)
/// stored as an integer at a fixed scale, because the schema forbids
/// floating point.
///
/// The type exists so the compiler catches a forgotten conversion: raw `Int`
/// and `Double` are both numeric, and the type checker cannot tell a scaled
/// value from an unscaled one. Wrapping the storage makes mixing them a
/// compile error instead of a silent factor-of-10000 bug.
///
/// This type is storage-only. It has no arithmetic operators on purpose:
/// adding or multiplying parameters belongs to the UI/render layer working
/// in `Double`, and keeping arithmetic out avoids Int32 overflow questions
/// entirely.
///
/// The range is deliberately not clamped to `0...10000`. Positions can be
/// negative or exceed 1 when an element sits partly off-screen; what range
/// is meaningful belongs to each individual parameter, not to this type.
public struct FixedPointScalar: Hashable, Comparable, Sendable {
    /// One unit of normalized value == `scale` ticks.
    ///
    /// Why 10000 and not 1000: at scale 1000 a normalized coordinate
    /// quantizes to 1.92px on 1080p (1920/1000) and 3.84px on 4K — too
    /// coarse to align a text overlay to the pixel. At 10000 the steps are
    /// 0.192px / 0.384px, below one pixel on both.
    public static let scale: Int32 = 10000

    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static func < (lhs: FixedPointScalar, rhs: FixedPointScalar) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Double conversion

/// Exactly two ways in from `Double`, and the lossy one is named so the loss
/// is visible at the call site. This mirrors the `RationalTime` rule: silent
/// rounding is what breaks preview/export agreement. There is deliberately
/// no unlabelled `init(_: Double)`.
extension FixedPointScalar {
    /// Lossy conversion. The label makes the rounding visible where it
    /// happens. The default rule is explicit so call sites reading
    /// `FixedPointScalar(rounding: x)` still have defined, symmetric
    /// behavior for negative values (away-from-zero, i.e. -2.5 ticks → -3).
    public init(
        rounding value: Double,
        rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) throws {
        guard value.isFinite else { throw FixedPointScalarError.nonFinite }
        let scaled = (value * Double(Self.scale)).rounded(rule)
        // Int32(exactly:) rather than Int32(_:): out-of-range input must
        // throw, not trap or clamp.
        guard let raw = Int32(exactly: scaled) else {
            throw FixedPointScalarError.outOfRange
        }
        self.init(rawValue: raw)
    }

    /// `nil` unless some raw value converts back to exactly this `Double` —
    /// i.e. the input already lies on the scale grid.
    public init?(exactly value: Double) {
        guard value.isFinite else { return nil }
        guard let raw = Int32(exactly: value * Double(Self.scale)),
              Double(raw) / Double(Self.scale) == value
        else { return nil }
        self.init(rawValue: raw)
    }

    /// For the render/UI side, which works in `Double`.
    public var doubleValue: Double {
        Double(rawValue) / Double(Self.scale)
    }
}

// MARK: - Codable

/// Encodes as a bare integer (`"volume": 7500`), not an object. Decoding
/// inherits Foundation's integer strictness: a fractional JSON number or a
/// number outside Int32 range throws.
extension FixedPointScalar: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int32.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
