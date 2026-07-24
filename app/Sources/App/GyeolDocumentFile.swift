import AppKit
import GyeolCore
import UniformTypeIdentifiers

/// The `.gyeol` package adapter. GyeolCore ends at `Document ↔ Data`
/// (PRD §5.6.5); everything about NSDocument, FileWrapper, and the package
/// layout lives here in the app layer.
///
/// Package layout:
///
///     Project.gyeol/
///       document.json     — the document body, GyeolCoding and nothing else
///       bookmarks.plist   — the sidecar: MediaID → bookmark, binary plist
///
/// The sidecar is a CACHE (PRD §5.6.8). Its one invariant: the project works
/// correctly when it is gone entirely. Reading tolerates a missing or
/// corrupt sidecar by treating it as empty — never by failing the open.
final class GyeolDocumentFile: NSDocument {
    static let bodyFilename = "document.json"
    static let sidecarFilename = "bookmarks.plist"

    private(set) var document: GyeolDocument = .empty
    /// In-memory sidecar. Persisted on save; healing (MediaResolver)
    /// replaces entries here and never touches `document`.
    private(set) var bookmarks: [MediaID: Data] = [:]
    /// Set when the file carries a newer minor version than this build:
    /// readable, but saving will drop fields we do not know (PRD §5.6.3).
    private(set) var openedWithNewerMinor = false

    override class var autosavesInPlace: Bool { true }

    // MARK: - Write

    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let body = try GyeolCoding.makeEncoder().encode(document)
        var children: [String: FileWrapper] = [
            Self.bodyFilename: FileWrapper(regularFileWithContents: body)
        ]
        if !bookmarks.isEmpty {
            children[Self.sidecarFilename] = FileWrapper(
                regularFileWithContents: try Self.encodeSidecar(bookmarks))
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    // MARK: - Read

    override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        guard let body = fileWrapper.fileWrappers?[Self.bodyFilename]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(Self.bodyFilename) is missing from the package",
            ])
        }

        // Version verdict BEFORE the full decode (PRD §5.6.3): a newer-major
        // file would fail decoding with a confusing field-level error;
        // the verdict names the actual problem.
        let probe = try GyeolCoding.makeDecoder().decode(VersionProbe.self, from: body)
        switch SchemaVersion.current.compatibility(ofFileVersion: probe.schemaVersion) {
        case .compatible:
            openedWithNewerMinor = false
        case .readableWithLoss:
            openedWithNewerMinor = true
        case .migrationRequired:
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: """
                this project uses schema \(probe.schemaVersion.major).\(probe.schemaVersion.minor), \
                which needs migration before this version can open it
                """,
            ])
        case .unsupported:
            throw CocoaError(.fileReadUnknown, userInfo: [
                NSLocalizedDescriptionKey: """
                this project uses schema \(probe.schemaVersion.major).\(probe.schemaVersion.minor), \
                created by a newer version of Gyeol
                """,
            ])
        }

        document = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: body)

        // Sidecar: cache semantics. Missing, unreadable, or malformed all
        // mean the same thing — no bookmarks — and none of them is an error
        // (PRD §5.6.8: the worst outcome is a reconnect UI that need not
        // have appeared).
        if let sidecarData = fileWrapper.fileWrappers?[Self.sidecarFilename]?.regularFileContents,
           let decoded = try? Self.decodeSidecar(sidecarData) {
            bookmarks = decoded
        } else {
            bookmarks = [:]
        }
    }

    // MARK: - Mutation

    func replaceDocument(_ newDocument: GyeolDocument) {
        document = newDocument
        updateChangeCount(.changeDone)
    }

    /// Applies a healed bookmark (MediaResolver's output). Touches only the
    /// sidecar; the document body stays byte-identical on the next save.
    func storeBookmark(_ data: Data, for id: MediaID) {
        bookmarks[id] = data
        updateChangeCount(.changeDone)
    }

    // MARK: - Sidecar codec

    /// Binary property list, not JSON (PRD §5.6.8): bookmarks are not
    /// human-readable data, and a different format prevents the "shouldn't
    /// this use the document encoder?" discussion from recurring.
    static func encodeSidecar(_ bookmarks: [MediaID: Data]) throws -> Data {
        let plist = Dictionary(uniqueKeysWithValues: bookmarks.map {
            ($0.key.rawValue.uuidString, $0.value)
        })
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .binary, options: 0)
    }

    static func decodeSidecar(_ data: Data) throws -> [MediaID: Data] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Data] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var result: [MediaID: Data] = [:]
        for (key, value) in plist {
            // Cache semantics again: an entry we cannot interpret is an
            // entry we do not have. Skipping beats failing the open.
            guard let uuid = UUID(uuidString: key) else { continue }
            result[MediaID(rawValue: uuid)] = value
        }
        return result
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: SchemaVersion
    }
}
