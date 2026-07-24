import Foundation

/// The single source of encoder/decoder configuration for document data.
///
/// No other code in GyeolCore may construct a `JSONEncoder` or `JSONDecoder`
/// for document data. Model types (`RationalTime`, `GyeolValue`, …)
/// deliberately do not configure encoders themselves; the byte-identity
/// round-trip guarantee (§4 S4) holds only under this configuration.
public enum GyeolCoding {
    /// Encoder for `.gyeol` document data.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // .sortedKeys — Foundation's default JSONEncoder does not order keys
        // deterministically, so byte-identity round-trip fails at random
        // without it.
        // .prettyPrinted / .withoutEscapingSlashes — the document is meant to
        // be read and diffed by humans; escaped slashes in relative paths
        // make diffs unreadable.
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        // Pinned explicitly even though Foundation's default is base64
        // today: the document format is a contract, and a default shifting
        // under us would silently change every bookmark on disk.
        encoder.dataEncodingStrategy = .base64
        return encoder
    }

    /// Decoder for `.gyeol` document data.
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        // Mirrors the encoder: the Data representation is pinned, not
        // inherited from Foundation's default.
        decoder.dataDecodingStrategy = .base64
        return decoder
    }
}
