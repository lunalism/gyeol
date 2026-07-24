import CryptoKit
import Foundation
import GyeolCore

/// App-layer media file resolution (PRD §5.1 triple reference, §5.6.8
/// self-healing). GyeolCore stores locators; this is the only place that
/// touches the filesystem to resolve them.
enum MediaResolver {
    enum Resolution: Equatable {
        case resolved(URL)
        /// A healed resolution: the file was found by relative path, the
        /// fingerprint MATCHED, and `freshBookmark` should replace the
        /// sidecar entry. The document body is untouched by this.
        case resolvedAndHealed(URL, freshBookmark: Data)
        /// Bookmark and relative path both failed (or the fingerprint did
        /// not match): the reconnect UI's case (S6).
        case needsReconnect
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
                       fingerprintMatches(fingerprint, at: url),
                       let fresh = try? url.bookmarkData() {
                        return .resolvedAndHealed(url, freshBookmark: fresh)
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
            return .needsReconnect
        }

        // Fingerprint gate. A reference without a fingerprint cannot prove
        // identity, so it cannot heal — resolve without writing anything.
        guard let fingerprint = reference.contentFingerprint else {
            return .resolved(candidate)
        }
        guard fingerprintMatches(fingerprint, at: candidate) else {
            return .needsReconnect
        }
        guard let fresh = try? candidate.bookmarkData() else {
            return .resolved(candidate)
        }
        return .resolvedAndHealed(candidate, freshBookmark: fresh)
    }

    // MARK: - Fingerprint

    /// The app layer owns the algorithm (Core only stores the value):
    /// SHA-256 over the first 4 MiB, plus the exact byte size. The prefix
    /// keeps fingerprinting a multi-GB source cheap; the size check catches
    /// same-prefix truncations.
    static let fingerprintPrefixLength = 4 * 1024 * 1024

    static func fingerprint(of url: URL) -> ContentFingerprint? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: fingerprintPrefixLength) else {
            return nil
        }
        return ContentFingerprint(value: Data(SHA256.hash(data: prefix)), byteSize: size)
    }

    static func fingerprintMatches(_ expected: ContentFingerprint, at url: URL) -> Bool {
        guard let actual = fingerprint(of: url) else { return false }
        return actual == expected
    }
}
