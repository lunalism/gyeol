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
/// through the tracked property (`applyEdit`, `read`), so SwiftUI
/// sees open, edit, revert and undo through one write site.
@Observable
final class GyeolDocumentFile: NSDocument {
    static let bodyFilename = "document.json"
    static let sidecarFilename = "bookmarks.plist"

    private(set) var document: GyeolDocument = .empty
    /// Selection is APP state (D27): in the document it would dirty the
    /// file on a click and trigger autosave (§6.2). It rides in the undo
    /// payload so undo restores what was selected, but changing it alone
    /// creates no undo step. Both halves are stored so the split action
    /// never has to search which track holds the selected clip.
    var selectedClip: SelectedClip?

    struct SelectedClip: Equatable {
        let trackID: TrackID
        let clipID: ClipID
    }
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
        // A-33's forecast, now real (M2.3): registered undo actions target
        // self through the manager the document OWNS — document →
        // undoManager → registered handler target → document, a cycle
        // close() must break or the document survives close (measured: the
        // plain-window lifecycle test caught it the round undo arrived).
        undoManager?.removeAllActions(withTarget: self)
        playback.shutdown()
        super.close()
    }

    override init() {
        super.init()
        configureUndoManager()
    }

    /// D27's explicit-over-default rules, the same class as §5.5's writer
    /// timescale and §5.6.4's base64: `groupsByEvent`'s default groups by
    /// RUN LOOP CYCLE, our contract groups by TRANSACTION — today they
    /// happen to coincide, but a coincidence is not a contract. With it
    /// off, `applyEdit`'s explicit begin/end group is the only grouping
    /// there is.
    private func configureUndoManager() {
        undoManager?.groupsByEvent = false
        undoManager?.levelsOfUndo = 100
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
        window.setContentSize(NSSize(width: 960, height: 640))
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

    // MARK: - Mutation — THE single site (D27)

    /// The ONLY way the document value is replaced after load. Undo
    /// registration lives here and nowhere else: any second replacement
    /// path would be a place to forget registration, and an unregistered
    /// change silently desynchronizes the undo chain from the document
    /// (Apple's documented warning, §10 risk).
    ///
    /// `updateChangeCount` is NEVER called: NSDocument watches the undo
    /// manager's group notifications and maintains the edited state itself
    /// (D27/D7) — calling it manually double-counts.
    ///
    /// The explicit begin/end group IS the "one gesture = one transaction
    /// = one undo step" contract: `groupsByEvent` is false (see
    /// `configureUndoManager`), so no run-loop grouping exists to blur it,
    /// and there is no coalescing policy by design.
    func applyEdit(_ newDocument: GyeolDocument, actionName: String) {
        let previousDocument = document
        let previousSelection = selectedClip
        if let undoManager {
            undoManager.beginUndoGrouping()
            undoManager.setActionName(actionName)
            undoManager.registerUndo(withTarget: self) { target in
                // Applying the captured value re-registers symmetrically,
                // which is what makes redo work. Selection is restored to
                // what it was IMMEDIATELY BEFORE the edit (D27 payload);
                // the restored UUID structurally exists because the
                // document is back to the value that contained it.
                target.applyEdit(previousDocument, actionName: actionName)
                target.selectedClip = previousSelection
            }
            undoManager.endUndoGrouping()
        }
        document = newDocument
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

    // MARK: - Blade (M2.3's one editing operation)

    /// True when the blade can act right now: a clip is selected and the
    /// playhead sits inside its allowed split range. The range query is
    /// Core's; consulting it here is why the action below never throws on
    /// the normal path (D26's clamp split: Core computes, the app gates).
    var canSplitSelectionAtPlayhead: Bool {
        splitParameters() != nil
    }

    /// Splits the selected clip at the playhead. One gesture → one
    /// transaction → one undo step, through the single mutation site.
    /// Selection stays on the LEFT piece, which keeps the original ClipID
    /// by the split's identity rule — so the selection is untouched.
    func splitSelectedClipAtPlayhead() {
        guard let (selection, time) = splitParameters() else { return }
        do {
            let edited = try document.splittingClip(
                selection.clipID, inTrack: selection.trackID, at: time)
            applyEdit(edited, actionName: "클립 분할")
        } catch {
            // Unreachable while single-threaded on MainActor: the guard
            // above just verified the range. If it ever fires, surface it
            // rather than swallow (§7.4-6).
            Swift.print("split failed after range check: \(error)")
        }
    }

    private func splitParameters() -> (SelectedClip, DocumentTime)? {
        guard let selection = selectedClip else { return nil }
        let rate = document.settings.frameRate
        let time = FrameMapping.time(ofFrame: playback.playheadFrame, rate: rate)
        guard let range = document.allowedSplitRange(
                ofClip: selection.clipID, inTrack: selection.trackID),
              range.contains(time.ticks) else { return nil }
        return (selection, time)
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
