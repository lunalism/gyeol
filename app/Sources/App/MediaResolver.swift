import CryptoKit
import Foundation
import GyeolCore
import os

/// App-layer media file resolution (PRD §5.1 triple reference, §5.6.8
/// self-healing). GyeolCore stores locators; this is the only place that
/// touches the filesystem to resolve them.
///
/// NOTE (F4, deliberate debt): everything here is synchronous IO plus a
/// 4 MiB hash. Fine while tests are the only caller; it becomes a real
/// MainActor stall the moment the document-open path calls it directly,
/// and it connects to the open decision of how fingerprints get computed
/// at import time. Revisit before wiring resolution into document open.
enum MediaResolver {
    private static let log = Logger(subsystem: "dev.gyeol.Gyeol", category: "MediaResolver")

    /// Why a reconnect is needed. An unreadable file is NOT the same
    /// situation as a different file (F8) — the distinction must survive
    /// up to whatever UI or log finally shows it.
    enum ReconnectReason: Equatable {
        case fileNotFound
        case fingerprintMismatch
        case fileUnreadable(String)
    }

    enum Resolution: Equatable {
        case resolved(URL)
        /// A healed resolution: the file was found, the fingerprint
        /// MATCHED, and `freshBookmark` should replace the sidecar entry.
        /// The document body is untouched by this.
        case resolvedAndHealed(URL, freshBookmark: Data)
        case needsReconnect(ReconnectReason)
    }

    /// Resolution order (PRD §5.6.8):
    /// 1. bookmark — the tracker for moved/renamed files
    /// 2. relative path — but ONLY with a fingerprint match. Skipping the
    ///    check would lock in a same-named different file (a re-encode, a
    ///    different take) and the reconnect UI would never appear again —
    ///    worse than the original failure.
    static func resolve(
        reference: MediaReference,
        bookmark: Data?,
        packageURL: URL
    ) -> Resolution {
        // 1. Bookmark. No security scope — the app is not sandboxed
        //    (PRD §7.3); plain bookmarks track moves and renames.
        if let bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: [],
                relativeTo: nil, bookmarkDataIsStale: &isStale),
                FileManager.default.fileExists(atPath: url.path) {
                if isStale {
                    // PRD §5.6.8 does not cover the stale-but-resolved case
                    // (reported as a gap). Conservative reading: refresh
                    // only under the same rule as healing — fingerprint
                    // first.
                    if let fingerprint = reference.contentFingerprint,
                       case .match = check(fingerprint, at: url) {
                        if let fresh = try? url.bookmarkData() {
                            return .resolvedAndHealed(url, freshBookmark: fresh)
                        }
                        // F9: correct to continue, wrong to be silent —
                        // the stale entry stays and will retry next open.
                        log.warning("stale bookmark refresh failed for \(url.path, privacy: .public); keeping stale entry")
                    }
                    return .resolved(url)
                }
                return .resolved(url)
            }
        }

        // 2. Relative path, against the package's parent directory.
        let candidate = packageURL.deletingLastPathComponent()
            .appendingPathComponent(reference.relativePath)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return .needsReconnect(.fileNotFound)
        }

        // Fingerprint gate. A reference without a fingerprint cannot prove
        // identity, so it cannot heal — resolve without writing anything.
        guard let fingerprint = reference.contentFingerprint else {
            return .resolved(candidate)
        }
        switch check(fingerprint, at: candidate) {
        case .match:
            guard let fresh = try? candidate.bookmarkData() else {
                // F9: healing failed but resolution succeeded. Surfaced in
                // the log rather than swallowed; the sidecar entry simply
                // stays absent and the relative path keeps working.
                log.warning("bookmark regeneration failed for \(candidate.path, privacy: .public); resolved without healing")
                return .resolved(candidate)
            }
            return .resolvedAndHealed(candidate, freshBookmark: fresh)
        case .mismatch:
            return .needsReconnect(.fingerprintMismatch)
        case .unreadable(let reason):
            // F8: an IO failure is not evidence of a different file. Keep
            // the distinction all the way up.
            log.error("cannot fingerprint \(candidate.path, privacy: .public): \(reason, privacy: .public)")
            return .needsReconnect(.fileUnreadable(reason))
        }
    }

    // MARK: - Fingerprint

    enum FingerprintCheck: Equatable {
        case match
        case mismatch
        case unreadable(String)
    }

    /// The app layer owns the algorithm (Core only stores the value):
    /// SHA-256 over the first 4 MiB, plus the exact byte size. The prefix
    /// keeps fingerprinting a multi-GB source cheap; the size check catches
    /// same-prefix truncations.
    static let fingerprintPrefixLength = 4 * 1024 * 1024

    static func check(_ expected: ContentFingerprint, at url: URL) -> FingerprintCheck {
        do {
            let actual = try readFingerprint(at: url)
            return actual == expected ? .match : .mismatch
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    static func fingerprint(of url: URL) -> ContentFingerprint? {
        try? readFingerprint(at: url)
    }

    private static func readFingerprint(at url: URL) throws -> ContentFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int64 else {
            throw CocoaError(.fileReadUnknown)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: fingerprintPrefixLength) ?? Data()
        return ContentFingerprint(value: Data(SHA256.hash(data: prefix)), byteSize: size)
    }
}
