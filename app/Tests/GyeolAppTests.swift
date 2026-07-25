import AppKit
import Foundation
import GyeolCore
import Testing

// M1 step 3 tests: the .gyeol package adapter and the sidecar's cache
// property. The deletion test is the load-bearing one (PRD §5.6.8): it is
// what keeps the sidecar a cache.

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("gyeol-doc-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func docTime(_ ticks: Int64) -> DocumentTime {
    DocumentTime(exactly: try! RationalTime(value: ticks, timescale: 120_000))!
}

/// A dummy media file plus a document whose single pool entry references it
/// by relative path and fingerprint — enough for resolution and healing.
@MainActor
private struct FixtureWorld {
    let root: URL
    let packageURL: URL
    let mediaURL: URL
    let mediaID: MediaID
    let document: GyeolDocument

    init() throws {
        root = try tempDir()
        mediaURL = root.appendingPathComponent("media.mov")
        try Data((0..<256).map { UInt8($0 % 251) } + Array(repeating: 7, count: 4096))
            .write(to: mediaURL)
        packageURL = root.appendingPathComponent("Project.gyeol")
        mediaID = MediaID()
        let fingerprint = MediaResolver.fingerprint(of: mediaURL)!
        document = GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps30, renderWidth: 1920, renderHeight: 1080),
            media: [mediaID: MediaReference(
                relativePath: "media.mov",
                contentFingerprint: fingerprint,
                displayName: "media.mov",
                duration: docTime(120_000))])
    }

    /// Writes the package the way NSDocument does (wrapper → disk).
    func writePackage(bookmarks: [MediaID: Data] = [:]) throws {
        let file = GyeolDocumentFile()
        file.replaceDocument(document)
        for (id, data) in bookmarks { file.storeBookmark(data, for: id) }
        let wrapper = try file.fileWrapper(ofType: "gyeol")
        try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)
    }

    func openPackage() throws -> GyeolDocumentFile {
        let file = GyeolDocumentFile()
        try file.read(from: try FileWrapper(url: packageURL), ofType: "gyeol")
        return file
    }
}

@Suite @MainActor struct GyeolPackageTests {
    @Test func packageRoundTripKeepsBodyByteIdentical() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        let bodyBefore = try Data(contentsOf: world.packageURL.appendingPathComponent("document.json"))

        let reopened = try world.openPackage()
        #expect(reopened.document == world.document)

        let rewrapped = try reopened.fileWrapper(ofType: "gyeol")
        let bodyAfter = rewrapped.fileWrappers?["document.json"]?.regularFileContents
        // The S4 property carried through the package layer: the body is
        // GyeolCoding output and nothing else, so it round-trips byte-for-byte.
        #expect(bodyAfter == bodyBefore)
    }

    @Test func sidecarIsBinaryPlistNotJSON() throws {
        let data = try GyeolDocumentFile.encodeSidecar([MediaID(): Data([1, 2, 3])])
        #expect(data.prefix(8) == Data("bplist00".utf8))
    }

    /// THE deletion test (PRD §5.6.8): the project must work with the
    /// sidecar gone entirely. This is what protects the cache property —
    /// if anything but bookmarks ever leaks into the sidecar, this breaks.
    @Test func deletingTheSidecarChangesNothingThatMatters() throws {
        let world = try FixtureWorld()
        let bookmark = try world.mediaURL.bookmarkData()
        try world.writePackage(bookmarks: [world.mediaID: bookmark])
        #expect(FileManager.default.fileExists(
            atPath: world.packageURL.appendingPathComponent("bookmarks.plist").path))

        // Kill the sidecar.
        try FileManager.default.removeItem(
            at: world.packageURL.appendingPathComponent("bookmarks.plist"))

        // Open: no error, full document, no bookmarks.
        let reopened = try world.openPackage()
        #expect(reopened.document == world.document)
        #expect(reopened.bookmarks.isEmpty)

        // Resolution still works via relative path + fingerprint, and heals.
        let reference = reopened.document.media[world.mediaID]!
        let resolution = MediaResolver.resolve(
            reference: reference, bookmark: nil, packageURL: world.packageURL)
        guard case .resolvedAndHealed(let url, let fresh) = resolution else {
            Issue.record("expected healed resolution, got \(resolution)")
            return
        }
        #expect(url.standardizedFileURL == world.mediaURL.standardizedFileURL)

        // The healed entry persists through a save — and the document body
        // is untouched by the healing.
        let bodyBefore = try Data(contentsOf: world.packageURL.appendingPathComponent("document.json"))
        reopened.storeBookmark(fresh, for: world.mediaID)
        let wrapper = try reopened.fileWrapper(ofType: "gyeol")
        try wrapper.write(to: world.packageURL, options: .atomic, originalContentsURL: world.packageURL)
        #expect(FileManager.default.fileExists(
            atPath: world.packageURL.appendingPathComponent("bookmarks.plist").path))
        let bodyAfter = try Data(contentsOf: world.packageURL.appendingPathComponent("document.json"))
        #expect(bodyAfter == bodyBefore)
    }

    @Test func corruptSidecarIsTreatedAsEmptyNotAsAnError() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        try Data("not a plist at all".utf8).write(
            to: world.packageURL.appendingPathComponent("bookmarks.plist"))
        let reopened = try world.openPackage()
        #expect(reopened.document == world.document)
        #expect(reopened.bookmarks.isEmpty)
    }

    /// G7: the dialog-facing error for a corrupt body must carry GyeolCore's
    /// field-and-reason diagnostic, not just "couldn't be read".
    @Test func corruptBodySurfacesTheCoreDiagnostic() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        let bodyURL = world.packageURL.appendingPathComponent("document.json")
        // A hand-edit that GyeolCore rejects with a precise reason: a
        // fractional document time.
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bodyURL)) as! [String: Any]
        json["markers"] = [["id": "EEEEEEEE-0000-4000-8000-000000000001",
                            "label": "x", "time": 1.5]]
        try JSONSerialization.data(withJSONObject: json).write(to: bodyURL)

        do {
            _ = try world.openPackage()
            Issue.record("expected a throw")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadCorruptFile)
            let reason = error.userInfo[NSLocalizedFailureReasonErrorKey] as? String
            #expect(reason?.contains("fractional") == true,
                    "diagnostic lost: \(reason ?? "nil")")
        } catch {
            Issue.record("expected CocoaError, got \(error)")
        }
    }

    @Test func newerMajorRefusesToOpen() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        let bodyURL = world.packageURL.appendingPathComponent("document.json")
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bodyURL)) as! [String: Any]
        json["schemaVersion"] = ["major": 99, "minor": 0]
        try JSONSerialization.data(withJSONObject: json).write(to: bodyURL)
        #expect(throws: (any Error).self) { try world.openPackage() }
    }

    @Test func newerMinorOpensWithLossFlag() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        let bodyURL = world.packageURL.appendingPathComponent("document.json")
        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: bodyURL)) as! [String: Any]
        json["schemaVersion"] = ["major": SchemaVersion.current.major,
                                 "minor": SchemaVersion.current.minor + 1]
        json["fieldFromTheFuture"] = "ignored by this build"
        try JSONSerialization.data(withJSONObject: json).write(to: bodyURL)
        let reopened = try world.openPackage()
        #expect(reopened.openedWithNewerMinor)
    }
}

@Suite @MainActor struct MediaResolverTests {
    @Test func fingerprintMismatchRefusesToHeal() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        // Same name, different content — a re-encode. Healing must refuse:
        // locking this in would suppress the reconnect UI forever.
        try Data("completely different bytes".utf8).write(to: world.mediaURL)
        let resolution = MediaResolver.resolve(
            reference: world.document.media[world.mediaID]!,
            bookmark: nil,
            packageURL: world.packageURL)
        #expect(resolution == .needsReconnect(.fingerprintMismatch))
    }

    @Test func missingFileNeedsReconnect() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        try FileManager.default.removeItem(at: world.mediaURL)
        let resolution = MediaResolver.resolve(
            reference: world.document.media[world.mediaID]!,
            bookmark: nil,
            packageURL: world.packageURL)
        #expect(resolution == .needsReconnect(.fileNotFound))
    }

    /// F8: an IO failure reading the candidate is NOT a fingerprint
    /// mismatch — the reason must survive to the caller.
    @Test func unreadableFileIsDistinctFromMismatch() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: world.mediaURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: world.mediaURL.path)
        }
        let resolution = MediaResolver.resolve(
            reference: world.document.media[world.mediaID]!,
            bookmark: nil,
            packageURL: world.packageURL)
        guard case .needsReconnect(.fileUnreadable) = resolution else {
            Issue.record("expected fileUnreadable, got \(resolution)")
            return
        }
    }

    @Test func healedBookmarkResolvesToTheSameFile() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        let resolution = MediaResolver.resolve(
            reference: world.document.media[world.mediaID]!,
            bookmark: nil,
            packageURL: world.packageURL)
        guard case .resolvedAndHealed(let url, let fresh) = resolution else {
            Issue.record("expected healed resolution, got \(resolution)")
            return
        }
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: fresh, options: [],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(resolved.standardizedFileURL == url.standardizedFileURL)
    }

    @Test func bookmarkWinsOverRelativePath() throws {
        let world = try FixtureWorld()
        try world.writePackage()
        // Move the file away from its relative path; the bookmark tracks it.
        let movedURL = world.root.appendingPathComponent("moved.mov")
        let bookmark = try world.mediaURL.bookmarkData()
        try FileManager.default.moveItem(at: world.mediaURL, to: movedURL)
        let resolution = MediaResolver.resolve(
            reference: world.document.media[world.mediaID]!,
            bookmark: bookmark,
            packageURL: world.packageURL)
        // Moving the file makes the bookmark STALE: it still resolves to
        // the moved location, and the stale branch refreshes it after the
        // fingerprint check — so a heal here is correct, not a fallback.
        // (Measured: this is the 5.6.8 stale gap actually firing.)
        switch resolution {
        case .resolved(let url), .resolvedAndHealed(let url, _):
            #expect(url.standardizedFileURL == movedURL.standardizedFileURL)
        case .needsReconnect:
            Issue.record("bookmark should have tracked the moved file")
        }
    }
}

/// Appendix A-25: is a package save atomic across document.json and the
/// sidecar? Measured, not assumed — see the step report for interpretation.
@Suite @MainActor struct PackageAtomicityProbe {
    @Test func atomicWrapperWriteReplacesTheWholePackageDirectory() throws {
        let world = try FixtureWorld()
        try world.writePackage(bookmarks: [world.mediaID: try world.mediaURL.bookmarkData()])
        let inodeBefore = try FileManager.default
            .attributesOfItem(atPath: world.packageURL.path)[.systemFileNumber] as? Int

        // Second save over the existing package, the way our write path
        // does it (FileWrapper.write, .atomic, originalContentsURL set).
        let reopened = try world.openPackage()
        reopened.replaceDocument(reopened.document)  // dirty, same content
        let wrapper = try reopened.fileWrapper(ofType: "gyeol")
        try wrapper.write(to: world.packageURL, options: .atomic, originalContentsURL: world.packageURL)

        let inodeAfter = try FileManager.default
            .attributesOfItem(atPath: world.packageURL.path)[.systemFileNumber] as? Int
        // If the directory inode changed, the whole package was swapped in
        // one rename: a crash mid-save leaves either the old package or the
        // new one, never a mix. If it did NOT change, children were written
        // in place and a mixed state is possible — report either way.
        print("A-25 probe: package dir inode before \(inodeBefore ?? -1), after \(inodeAfter ?? -1) — \(inodeBefore == inodeAfter ? "IN-PLACE (mixed states possible)" : "whole-directory swap (atomic at rename)")")
        // Both children must exist after the save regardless.
        #expect(FileManager.default.fileExists(
            atPath: world.packageURL.appendingPathComponent("document.json").path))
        #expect(FileManager.default.fileExists(
            atPath: world.packageURL.appendingPathComponent("bookmarks.plist").path))
    }
}
