import Foundation

/// An untyped, JSON-shaped value tree for effect and generator parameters.
///
/// Parameters belonging to effects this version does not know about are
/// carried through a load/save cycle unchanged: the document layer decodes
/// them into `GyeolValue` and re-encodes them without interpreting anything.
///
/// There is deliberately no floating-point case. This enum is the enforcement
/// point for the schema-wide no-Double rule: a fractional quantity must be
/// expressed in integer units chosen by the effect (ticks, per-mille, …), and
/// a plugin that genuinely needs a rational nests an object — it does not get
/// a `.double` or `.rational` case here.
///
/// Encodes as plain JSON with no type tags:
///
///     {"barCount": 64, "sensitivity": 7500, "label": "bass"}
public enum GyeolValue: Hashable, Sendable {
    case int(Int64)
    case string(String)
    case bool(Bool)
    case array([GyeolValue])
    case object([String: GyeolValue])
    case null
}

// MARK: - Read accessors

/// Optional-returning accessors for callers walking a parameter tree.
/// These are read conveniences only; they play no part in decoding and
/// cannot weaken its strictness.
extension GyeolValue {
    public var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var arrayValue: [GyeolValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: GyeolValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// Key lookup. `nil` when self is not an object or the key is absent.
    public subscript(key: String) -> GyeolValue? {
        objectValue?[key]
    }

    /// Index lookup, bounds-checked. `nil` when self is not an array or the
    /// index is out of range — parameter trees come from documents we did not
    /// write, so trapping on a bad index is not acceptable.
    public subscript(index: Int) -> GyeolValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Codable

/// Number strictness — what Foundation's `JSONDecoder` actually enforces,
/// verified by experiment on macOS 26 / Swift 6.2:
///
/// - `1.5`  → decoding `Int64` throws ("Number 1.5 is not representable").
/// - `9223372036854775808` (Int64.max + 1) → throws likewise.
/// - `true` never decodes as `Int64`, and `1` never decodes as `Bool`; the
///   parser distinguishes the token kinds, so case order below is belt and
///   braces, not load-bearing.
/// - **`1.0`, `1e2`, and even `1.5e1` decode as `Int64` 1, 100, 15.**
///   `JSONDecoder` accepts any number token whose mathematical value is
///   exactly representable in the target integer type, regardless of how it
///   is written. It never exposes the raw token, so this type cannot reject
///   integral-valued float notation without replacing the parser. We document
///   the behavior rather than pretend to reject it: a fractional *value* is
///   always rejected; a fractional *notation* of an integer is accepted and
///   normalizes to `.int` (and therefore re-encodes as `100`, not `1e2` —
///   such input is not byte-identity round-trippable, which the document
///   layer already does not promise for foreign bytes).
extension GyeolValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            // Reached only when Int64 decoding failed but the token is still
            // a number: a genuinely fractional value, or an integer outside
            // Int64 range. Distinguish the two for the error message.
            let reason = double == double.rounded()
                ? "integer out of Int64 range"
                : "fractional number"
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: """
                GyeolValue rejects \(reason) \(double): the document schema \
                has no floating-point values and never truncates or rounds
                """))
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            // Every scalar token kind is exhausted above, so the token is a
            // compound. Compound decodes must use a real `try`: a `try?` here
            // would swallow the descriptive rejection thrown for a fractional
            // number nested somewhere inside, replacing it with a vague
            // top-level error. Only "this token is not an array" (a type
            // mismatch at exactly this depth) may fall through to the object
            // attempt; anything deeper is a genuine nested failure.
            do {
                self = .array(try container.decode([GyeolValue].self))
            } catch let error as DecodingError {
                guard case .typeMismatch(_, let context) = error,
                      context.codingPath.count == decoder.codingPath.count
                else { throw error }
                self = .object(try container.decode([String: GyeolValue].self))
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}
