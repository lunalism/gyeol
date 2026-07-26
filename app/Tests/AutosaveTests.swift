import AppKit
import Foundation
import GyeolCore
import Testing

// M1 finalization piece 3: the A-25 gap. The direct FileWrapper.write path
// was measured atomic; the path most saves actually take — NSDocument's
// safe-save orchestration with autosavesInPlace — was not. Measured here by
// observing the replacement mechanism (inode identity) across real
// save(to:) and autosave(withImplicitCancellability:) calls, plus reopen
// integrity. No fault injection: the mechanism, not a crash, is what is
// observable headlessly.

private func docTime(_ ticks: Int64) -> DocumentTime {
    DocumentTime(exactly: try! RationalTime(value: ticks, timescale: 120_000))!
}

private func makeDocument(markerCount: Int) -> GyeolDocument {
    GyeolDocument(
        schemaVersion: .current,
        settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080),
        markers: (0..<markerCount).map {
            Marker(id: MarkerID(), time: docTime(Int64($0) * 120_000), label: "M\($0)")
        })
}

private func inode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
}

@Suite @MainActor struct AutosavePathTests {
    @Test func autosaveInPlaceRoundTripIsIntactAndAtomicPerFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-autosave-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let packageURL = dir.appendingPathComponent("Autosave.gyeol")

        // Initial save through the REAL NSDocument save path (not a bare
        // wrapper write): establishes fileURL and fileModificationDate the
        // way the app does.
        let file = GyeolDocumentFile()
        file.applyEdit(makeDocument(markerCount: 1), actionName: "test edit")
        file.storeBookmark(try dir.bookmarkData(), for: MediaID())
        try await file.save(to: packageURL, ofType: GyeolDocumentFile.documentType, for: .saveAsOperation)

        let bodyPath = packageURL.appendingPathComponent("document.json").path
        let sidecarPath = packageURL.appendingPathComponent("bookmarks.plist").path
        let dirInodeBefore = inode(packageURL.path)
        let bodyInodeBefore = inode(bodyPath)
        let sidecarInodeBefore = inode(sidecarPath)

        // Edit, then drive the autosave machinery itself.
        let edited = makeDocument(markerCount: 2)
        file.applyEdit(edited, actionName: "test edit")
        #expect(file.hasUnautosavedChanges)
        try await file.autosave(withImplicitCancellability: false)
        #expect(!file.hasUnautosavedChanges)

        // Round trip: what autosave wrote must decode to the edited state.
        let reopened = GyeolDocumentFile()
        try reopened.read(from: try FileWrapper(url: packageURL), ofType: GyeolDocumentFile.documentType)
        #expect(reopened.document == edited)
        #expect(!reopened.bookmarks.isEmpty)

        // Mechanism: which of the three shapes did the in-place autosave
        // take? (dir swap > per-child rename > in-place rewrite)
        let dirInodeAfter = inode(packageURL.path)
        let bodyInodeAfter = inode(bodyPath)
        let sidecarInodeAfter = inode(sidecarPath)
        print("""
        A-25 autosave probe: package \(dirInodeBefore ?? -1)→\(dirInodeAfter ?? -1), \
        document.json \(bodyInodeBefore ?? -1)→\(bodyInodeAfter ?? -1), \
        bookmarks.plist \(sidecarInodeBefore ?? -1)→\(sidecarInodeAfter ?? -1)
        """)
        let wholePackageSwap = dirInodeBefore != dirInodeAfter
        let bodyReplacedByRename = bodyInodeBefore != bodyInodeAfter
        // The STOP condition from the step brief: if the body was rewritten
        // into the SAME inode, a crash mid-write can leave document.json
        // partial — that must fail loudly, not pass quietly.
        #expect(wholePackageSwap || bodyReplacedByRename,
                "document.json rewritten in place — partial-write damage is possible on the autosave path")

        // Steady state: a second autosave behaves the same way.
        file.applyEdit(makeDocument(markerCount: 3), actionName: "test edit")
        let bodyInodeBeforeSecond = inode(bodyPath)
        try await file.autosave(withImplicitCancellability: false)
        let secondReopen = GyeolDocumentFile()
        try secondReopen.read(from: try FileWrapper(url: packageURL), ofType: GyeolDocumentFile.documentType)
        #expect(secondReopen.document.markers.count == 3)
        let dirSwapSecond = inode(packageURL.path) != dirInodeAfter
        let bodyRenameSecond = inode(bodyPath) != bodyInodeBeforeSecond
        print("A-25 second autosave: dir swap \(dirSwapSecond), body rename \(bodyRenameSecond)")
        #expect(dirSwapSecond || bodyRenameSecond,
                "second autosave rewrote document.json in place")
    }

    /// M2.1 dirty-on-open regression: opening a pre-duration file derived
    /// the missing duration IN MEMORY (correct), but bookmark healing bumped
    /// the change count (wrong, §5.6.8) — autosave then wrote the derived
    /// field back into a file the user never edited. Opening must never
    /// modify the file: same rule as sidecar healing, verified by bytes.
    @Test func openingWithoutDurationFieldLeavesTheFileByteIdentical() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-dirty-open-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Old.gyeol"), withIntermediateDirectories: true)
        let packageURL = dir.appendingPathComponent("Old.gyeol")

        // A pre-duration document.json: encode the current schema, then
        // strip the key the old format did not have. JSONSerialization
        // round-trip is fine here — the bytes we write ARE the baseline.
        let encoded = try GyeolCoding.makeEncoder().encode(makeDocument(markerCount: 2))
        var json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        json.removeValue(forKey: "duration")
        let oldFormatBody = try JSONSerialization.data(
            withJSONObject: json, options: [.sortedKeys])
        let bodyURL = packageURL.appendingPathComponent(GyeolDocumentFile.bodyFilename)
        try oldFormatBody.write(to: bodyURL)

        // The REAL open path (reads, sets fileURL, arms autosave machinery).
        let file = try GyeolDocumentFile(
            contentsOf: packageURL, ofType: GyeolDocumentFile.documentType)
        // Derivation happened in memory: no clips (markers do not extend
        // the playable domain), so the derived duration is zero — the
        // derive-fallback's exact behavior is Core's test, the FILE is ours.
        #expect(file.document.duration == docTime(0))
        #expect(!file.isDocumentEdited)
        #expect(!file.hasUnautosavedChanges)

        // The open-path mutation that used to dirty: a §5.6.8 heal.
        file.storeBookmark(try dir.bookmarkData(), for: MediaID())
        #expect(!file.isDocumentEdited)
        #expect(!file.hasUnautosavedChanges)

        // Give autosave every chance it would have in the app.
        try await file.autosave(withImplicitCancellability: true)
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 20_000_000) }

        #expect(try Data(contentsOf: bodyURL) == oldFormatBody,
                "opening modified document.json")
        // The heal must not have materialized a sidecar either.
        #expect(!FileManager.default.fileExists(
            atPath: packageURL.appendingPathComponent(GyeolDocumentFile.sidecarFilename).path))
        file.close()
    }
}
