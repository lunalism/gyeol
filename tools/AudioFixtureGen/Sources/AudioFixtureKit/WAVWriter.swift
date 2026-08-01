import Foundation

/// Minimal canonical RIFF/WAVE writer: 16-bit signed PCM, little-endian,
/// 44-byte header, no extra chunks.
///
/// Why hand-written and not `AVAssetWriter`/`AVAudioFile`:
///
/// - **Lossy encoding is forbidden for these fixtures.** AAC quantization
///   smears segment boundaries and injects its own transients, and the
///   human listener would attribute those to our split code — the fixture
///   would fabricate the defect it is meant to detect.
/// - **Determinism.** The gate compares SHA-256 of the produced files
///   across two runs. Media containers written by AVFoundation carry
///   creation timestamps and encoder metadata, so the same signal produces
///   different bytes on every run. These 44 header bytes carry nothing but
///   the format.
public enum WAVWriter {
    /// Header size of the canonical form: RIFF(12) + fmt (24) + data(8).
    public static let headerByteCount = 44

    public static func data(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let dataByteCount = samples.count * MemoryLayout<Int16>.size

        var out = Data(capacity: headerByteCount + dataByteCount)
        func ascii(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { out.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { out.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + dataByteCount)  // everything after this field
        ascii("WAVE")
        ascii("fmt ")
        u32(16)                              // PCM fmt chunk size
        u16(1)                               // format tag: PCM
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * blockAlign)         // byte rate
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(dataByteCount)
        // Int16 is written little-endian explicitly rather than by copying
        // the array's memory: the byte order of the file is a format
        // contract, not a property of the host we happen to build on.
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }
}
