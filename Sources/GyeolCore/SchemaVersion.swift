import Foundation

/// The `.gyeol` document schema version. Encodes as an object:
/// `{"major": 1, "minor": 0}`.
///
/// Major bumps are breaking; minor bumps are additive within a major.
/// This type returns a verdict only — what the app does with it (alerts,
/// refusal, migration UI) is not Core's decision, so there is no UI
/// vocabulary here.
public struct SchemaVersion: Codable, Hashable, Comparable, Sendable {
    public var major: Int {
        didSet { precondition(major >= 0, "schema major must be non-negative") }
    }
    public var minor: Int {
        didSet { precondition(minor >= 0, "schema minor must be non-negative") }
    }

    /// Versions are written by code as literals, never built from runtime
    /// input, so a precondition suffices here; the decode boundary below is
    /// where foreign data gets validated with a thrown error.
    public init(major: Int, minor: Int) {
        precondition(major >= 0 && minor >= 0,
                     "schema version components must be non-negative")
        self.major = major
        self.minor = minor
    }

    // Explicit so the manual init(from:) and the synthesized encode(to:)
    // provably share the same key names.
    private enum CodingKeys: String, CodingKey {
        case major, minor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let major = try container.decode(Int.self, forKey: .major)
        let minor = try container.decode(Int.self, forKey: .minor)
        guard major >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .major, in: container,
                debugDescription: "schema major must be non-negative, got \(major)")
        }
        guard minor >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .minor, in: container,
                debugDescription: "schema minor must be non-negative, got \(minor)")
        }
        self.major = major
        self.minor = minor
    }

    /// The schema version this build writes.
    public static let current = SchemaVersion(major: 1, minor: 0)

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

// MARK: - Compatibility

extension SchemaVersion {
    public enum Compatibility: Hashable, Sendable {
        /// Same major, file minor <= ours: everything in the file is known.
        case compatible
        /// Same major, file minor > ours: additive fields we do not know may
        /// be present, and saving will drop them.
        case readableWithLoss
        /// File major < ours: a major bump is breaking, so this build's
        /// decoder cannot read the old shape as-is — the file must be
        /// converted first. Whether a migrator exists is the document
        /// layer's business; this value only reports the direction.
        case migrationRequired
        /// File major > ours: the file is from a newer schema than this
        /// build understands.
        case unsupported
    }

    /// Pure check of a file's version against this (the reader's) version.
    ///
    /// The two major-mismatch directions are distinct verdicts on purpose:
    /// collapsing them would force the document layer to re-compare majors
    /// itself to tell "convert this file" (`migrationRequired`) from
    /// "update your app" (`unsupported`), duplicating the comparison
    /// outside this type. (Today `migrationRequired` is unreachable in
    /// practice — major 1 is the first shipped major.)
    public func compatibility(ofFileVersion file: SchemaVersion) -> Compatibility {
        if file.major < major { return .migrationRequired }
        if file.major > major { return .unsupported }
        return file.minor <= minor ? .compatible : .readableWithLoss
    }
}
