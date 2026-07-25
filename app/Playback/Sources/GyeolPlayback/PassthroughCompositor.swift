import AVFoundation
import CoreVideo
import os

/// M1.4 risk probe: the smallest `AVVideoCompositing` that genuinely sits
/// in the render path. One video track, no effects, no transitions —
/// passthrough, but THROUGH the compositor, not around it.
///
/// THE COMPOSITOR IS A PURE FUNCTION (PRD §7.4-3). Output depends only on
/// the request — the composition (= the document) and the time. Nothing is
/// carried between calls; no cache is consulted at render time. A stateful
/// compositor still looks correct in preview and breaks at export in M5,
/// which is why L2 exists (PRD §4.1).
///
/// The pixel format is pinned to 420v on BOTH sides deliberately: preview
/// and export configurations default to different formats, and L2's
/// bit-identical contract needs the compositor to define its IO format
/// rather than inherit two.
///
/// §7.4-4 STRUCTURAL GUARANTEE: the renderer receives document VALUES,
/// never the document object. This module (GyeolPlayback) cannot even name
/// `GyeolDocumentFile` — it depends only on GyeolCore — so neither the
/// compositor AVFoundation instantiates from `customVideoCompositorClass`
/// nor any instruction the builder emits can hold a reference to or a
/// closure over the document. That makes the "compositor retains the
/// document" leak hypothesis impossible by construction, not by care.
///
/// Generators (§5.8, step 5): the shape here leaves room for them. A
/// custom instruction conforming to `AVVideoCompositionInstructionProtocol`
/// can report empty `requiredSourceTrackIDs`; `startRequest` then renders
/// from instruction parameters instead of `sourceFrame(byTrackID:)`,
/// drawing into `renderContext.newPixelBuffer()`. No `AVMutableComposition`
/// asset backing is needed for such an instruction — the branch plugs in
/// exactly where the guard below reads the first source track.
public final class PassthroughCompositor: NSObject, AVVideoCompositing {
    public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    public var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat]]
    }

    public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: [Self.pixelFormat]]
    }

    public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Stateless on purpose — nothing to carry over.
    }

    public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let start = ContinuousClock.now
        // Sources arrive TOP-FIRST (the builder's layering contract:
        // stacked by track index, alpha-composited at M4). Taking the
        // first AVAILABLE source is the fully-opaque degenerate case of
        // that stack — a missing source on a track is ABSENCE (empty-
        // region rule 1), so the next track down shows through.
        for trackID in request.sourceTrackIDs {
            if let frame = request.sourceFrame(byTrackID: trackID.int32Value) {
                request.finish(withComposedVideoFrame: frame)
                Self.recordRequest(seconds: elapsedSeconds(since: start))
                return
            }
        }
        // NO track contributes: empty-region rule 2 — the final frame is
        // opaque video-range black, deterministic bytes, L2-hashable.
        // This branch is also where M4's generators plug in — they render
        // from instruction parameters instead of filling black.
        guard let buffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noRenderBuffer)
            return
        }
        Self.fillVideoRangeBlack(buffer)
        request.finish(withComposedVideoFrame: buffer)
        Self.recordRequest(seconds: elapsedSeconds(since: start))
    }

    enum CompositorError: Error {
        case noRenderBuffer
    }

    private func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    /// 420v video-range black: luma 16, interleaved CbCr 128. Filling the
    /// full rows (padding included) keeps the buffer deterministic
    /// everywhere, though L2's hash only reads the image bytes.
    static func fillVideoRangeBlack(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            memset(luma, 16, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
                * CVPixelBufferGetHeightOfPlane(buffer, 0))
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
    }

    // MARK: - Probe instrumentation
    // Timing observation only — it never influences the composed output,
    // so purity (§7.4-3) is untouched. Read-and-reset by the probe.

    public struct Stats: Sendable {
        public var requestCount = 0
        public var totalSeconds = 0.0
        public var maxSeconds = 0.0
    }

    private static let statsLock = OSAllocatedUnfairLock(initialState: Stats())

    private static func recordRequest(seconds: Double) {
        statsLock.withLock {
            $0.requestCount += 1
            $0.totalSeconds += seconds
            $0.maxSeconds = max($0.maxSeconds, seconds)
        }
    }

    public static func snapshotAndResetStats() -> Stats {
        statsLock.withLock {
            let snapshot = $0
            $0 = Stats()
            return snapshot
        }
    }
}
