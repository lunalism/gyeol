import AppKit
import GyeolCore
import SwiftUI
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
///
/// @Observable on an NSDocument subclass (G2): NSDocument predates
/// Observation, and the alternative — a parallel view model mirroring the
/// value-type document — is a second copy that can drift. The macro makes
/// `document` itself the tracked state; every mutation path already funnels
/// through the tracked property (`replaceDocument`, `read`), so SwiftUI
/// sees open, edit, revert and undo through one write site.
@Observable
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

    /// The per-document playback controller (G4), owned by the DOCUMENT,
    /// not the view. Measured (G5): every view-side teardown hook loses a
    /// race somewhere — `.onDisappear` never fires for a window closed
    /// before its content appeared, and a hook registered from the view's
    /// task arrives after `close()`. The document's `close()` is the one
    /// boundary every path crosses, and ownership is what guarantees the
    /// hook exists before close can happen.
    @ObservationIgnored private(set) lazy var playback = PlaybackController()

    override func close() {
        playback.shutdown()
        super.close()
    }

    deinit {
        LifetimeProbe.logDeinit("GyeolDocumentFile")
    }

    /// Mirrors the Info.plist registration so the type mapping also holds
    /// where no bundle plist exists (the headless test bundle).
    static let documentType = "dev.gyeol.project"

    override class var readableTypes: [String] { [documentType] }
    override class var writableTypes: [String] { [documentType] }

    override func fileNameExtension(
        forType typeName: String, saveOperation: NSDocument.SaveOperationType
    ) -> String? {
        "gyeol"
    }

    override func makeWindowControllers() {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: DocumentView(file: self, playback: playback)))
        window.setContentSize(NSSize(width: 480, height: 340))
        window.title = displayName
        addWindowController(NSWindowController(window: window))
    }

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
        let probe: VersionProbe
        do {
            probe = try GyeolCoding.makeDecoder().decode(VersionProbe.self, from: body)
        } catch {
            throw Self.corruptDocumentError(wrapping: error)
        }
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

        do {
            document = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: body)
        } catch {
            throw Self.corruptDocumentError(wrapping: error)
        }

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
    ///
    /// NO change-count bump, DELIBERATELY (§5.6.8, and the M2.1 dirty-on-open
    /// bug): healing runs during open, and a change count here marked a
    /// freshly opened document Edited, which triggered autosave, which
    /// REWROTE THE FILE the user only asked to look at. The sidecar is a
    /// cache — a healed entry rides along with the next genuine save, and
    /// losing it costs one re-heal on the next open, never data.
    func storeBookmark(_ data: Data, for id: MediaID) {
        bookmarks[id] = data
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

    /// G7 (principle 6): a DecodingError's dialog text is the generic
    /// "couldn't be read" — the field-and-reason diagnostic GyeolCore builds
    /// (which field, why it was rejected) never reaches the person editing
    /// the file by hand. Wrap it so the dialog's failure reason carries it.
    private static func corruptDocumentError(wrapping error: any Error) -> any Error {
        guard let decodingError = error as? DecodingError else { return error }
        let context: DecodingError.Context
        switch decodingError {
        case .dataCorrupted(let c), .keyNotFound(_, let c),
             .typeMismatch(_, let c), .valueNotFound(_, let c):
            context = c
        @unknown default:
            return error
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        let reason = path.isEmpty
            ? context.debugDescription
            : "\(path): \(context.debugDescription)"
        return CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedDescriptionKey: "\(bodyFilename) could not be read",
            NSLocalizedFailureReasonErrorKey: reason,
        ])
    }
}
