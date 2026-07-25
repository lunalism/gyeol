import CoreVideo
import CryptoKit
import Foundation

/// L2's hash (PRD §4.1): SHA-256 over the IMAGE bytes only.
///
/// Row by row, consuming exactly the bytes that carry pixels: bytesPerRow
/// padding is allocator-dependent and DOES differ between the preview and
/// export configurations. Hashing whole rows would make L2 fail on
/// alignment, not on render-path state — the false positive that would
/// push someone toward a tolerance, which §4.1 forbids.
public enum PixelBufferHash {
    /// nil for any format other than the compositor's pinned 420v — a
    /// different format arriving here means a configuration leaked around
    /// the compositor's IO contract, which is itself an L2 failure worth
    /// seeing, not papering over.
    public static func hash(_ buffer: CVPixelBuffer) -> Data? {
        guard CVPixelBufferGetPixelFormatType(buffer) == PassthroughCompositor.pixelFormat else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var hasher = SHA256()
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            // 420v: plane 0 is 1-byte luma; plane 1 is interleaved CbCr —
            // widthOfPlane counts subsampled elements at 2 bytes each.
            let meaningfulBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<height {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: base + row * rowBytes, count: meaningfulBytes))
            }
        }
        return Data(hasher.finalize())
    }
}
