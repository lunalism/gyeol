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
        guard let trackID = request.sourceTrackIDs.first,
              let frame = request.sourceFrame(byTrackID: trackID.int32Value) else {
            request.finish(with: CompositorError.noSourceFrame)
            return
        }
        request.finish(withComposedVideoFrame: frame)
        Self.recordRequest(seconds: { let c = start.duration(to: .now).components; return Double(c.seconds) + Double(c.attoseconds) * 1e-18 }())
    }

    enum CompositorError: Error {
        case noSourceFrame
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
