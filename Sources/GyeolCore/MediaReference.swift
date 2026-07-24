import Foundation

/// Identity of a media asset in the document. A distinct type (not a bare
/// `UUID`) so a media identifier cannot be passed where a `ClipID` belongs,
/// or vice versa — the compiler tells them apart.
public struct MediaID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.rawValue = UUID()
    }
}

/// Encodes as a bare UUID string, not an object.
extension MediaID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An opaque fingerprint of the media file's bytes, plus the byte size it
/// was computed over. What the fingerprint algorithm is belongs to the app
/// layer; Core only stores it.
public struct ContentFingerprint: Codable, Hashable, Sendable {
    public var value: Data
    public var byteSize: Int64

    public init(value: Data, byteSize: Int64) {
        self.value = value
        self.byteSize = byteSize
    }
}

/// A reference to a media file via three independent locators (PRD §5.1:
/// bookmark + relative path + content fingerprint), so the reconnection UI
/// can find a file that moved or was renamed.
///
/// GyeolCore does NOT compute fingerprints, resolve bookmarks, or touch the
/// filesystem in any way — no file IO happens in this module. It only stores
/// and serializes what the app layer supplies. Under `GyeolCoding`, binary
/// fields (`bookmarkData`, `ContentFingerprint.value`) encode as base64
/// strings — a strategy `GyeolCoding` pins explicitly as part of the wire
/// format contract.
public struct MediaReference: Codable, Hashable, Sendable {
    /// Opaque security-plain bookmark bytes from the app layer; absent when
    /// the app has not (or cannot have) created one.
    public var bookmarkData: Data?
    /// Path relative to the document package. The one locator that is always
    /// present.
    public var relativePath: String
    public var contentFingerprint: ContentFingerprint?
    public var displayName: String
    public var duration: DocumentTime

    public init(
        bookmarkData: Data? = nil,
        relativePath: String,
        contentFingerprint: ContentFingerprint? = nil,
        displayName: String,
        duration: DocumentTime
    ) {
        self.bookmarkData = bookmarkData
        self.relativePath = relativePath
        self.contentFingerprint = contentFingerprint
        self.displayName = displayName
        self.duration = duration
    }
}
