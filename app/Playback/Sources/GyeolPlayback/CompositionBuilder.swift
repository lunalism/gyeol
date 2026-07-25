import AVFoundation
import CoreMedia
import GyeolCore

/// Document → AVComposition. THE ONLY FILE that touches
/// `AVMutableComposition` / `AVMutableVideoComposition` (§10 isolation):
/// the deprecation replacement `AVVideoComposition.Configuration` does not
/// exist in the MacOSX26.5 SDK (appendix A-35), so we build on the current
/// API and, when the migration comes, it touches exactly this file.
public enum CompositionBuilder {
    public struct Built {
        public let composition: AVComposition
        public let videoComposition: AVVideoComposition
        /// The end of the playable domain: the last clip's end across all
        /// video tracks (0 for an empty document).
        public let timelineEnd: DocumentTime
    }

    public enum BuildError: Error, CustomStringConvertible {
        case missingMediaURL(MediaID)
        case sourceHasNoVideoTrack(MediaID)

        public var description: String {
            switch self {
            case .missingMediaURL(let id): "no resolved URL for media \(id.rawValue.uuidString)"
            case .sourceHasNoVideoTrack(let id): "media \(id.rawValue.uuidString) has no video track"
            }
        }
    }

    /// EMPTY REGIONS — two layers, not one rule (M2.1 revised; PRD report
    /// target). Both explicit so render(document, time) is total on its
    /// domain (§7.4-3) and no default is silent (§7.4-6):
    ///
    /// 1. PER TRACK: where a track has no clip it contributes ABSENCE, not
    ///    black. A track never paints what it does not have — §5.8 puts
    ///    background image, spectrum and title text on separate video
    ///    tracks, and a per-track black would let an upper track hide the
    ///    background, making S9 impossible.
    /// 2. FINAL FRAME: only when NO track contributes at a time is the
    ///    composed frame opaque black — video-range 420v, Y=16, CbCr=128,
    ///    deterministic bytes so L2 hashes empty frames like any other.
    ///    Produced by the compositor's no-source branch.
    ///
    /// Single-track M2.1 cannot tell the two rules apart; they diverge at
    /// M4, which is why the split is settled now.
    ///
    /// PLAYABLE DOMAIN (M2.1 decision): the composition's length is the
    /// DOCUMENT's stored `duration`, not the last clip's end — deliberate
    /// trailing space is document data and must not silently vanish from
    /// playback or export (§7.4-6). The trailing empty region renders per
    /// rule 2; beyond `duration` there is nothing — playback stops and
    /// stepping clamps to `frameCount(duration)`.
    ///
    /// LAYERING CONTRACT (settled now, implemented M4): tracks STACK BY
    /// INDEX, alpha-composited — a higher track index renders above a
    /// lower one, over rule 2's black base. Opacity is already a
    /// normalized fixed-point parameter (§5.6.2), so the schema is ready.
    /// Layer instructions encode the order TOP-FIRST (descending track
    /// index); until M4 the compositor takes the first available source,
    /// which for fully opaque sources is exactly "topmost wins" — the
    /// correct degenerate case of alpha stacking.
    public static func build(
        document: GyeolDocument,
        mediaURLs: [MediaID: URL]
    ) async throws -> Built {
        let composition = AVMutableComposition()

        struct PlacedClip {
            let track: AVMutableCompositionTrack
            /// Document-order index of the source track — the stacking
            /// order of the layering contract (higher = above).
            let trackIndex: Int
            let startTicks: Int64
            let endTicks: Int64
        }
        var placed: [PlacedClip] = []
        var boundaries: Set<Int64> = []
        var contentEndTicks: Int64 = 0

        for (trackIndex, track) in document.tracks.enumerated() where track.kind == .video {
            let mediaClips = track.clips.filter {
                if case .media = $0.source { return true } else { return false }
            }
            guard !mediaClips.isEmpty else { continue }
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                continue
            }
            for clip in mediaClips {
                guard case .media(let source) = clip.source else { continue }
                guard let url = mediaURLs[source.mediaID] else {
                    throw BuildError.missingMediaURL(source.mediaID)
                }
                let asset = AVURLAsset(url: url)
                guard let assetTrack = try await asset.loadTracks(withMediaType: .video).first else {
                    throw BuildError.sourceHasNoVideoTrack(source.mediaID)
                }
                // Every document time crosses to CMTime through the
                // boundary adapter — exact, no second rounding path
                // (§5.6.1). Note what is NOT converted here: nothing about
                // the SOURCE grid. Insertion is a time-span operation; the
                // project frame grid enters only at `frameDuration` below,
                // and the source grid never does (§6.2).
                try compositionTrack.insertTimeRange(
                    CMTimeRange(
                        start: CMTimeAdapter.cmTime(exactly: source.sourceStart),
                        duration: CMTimeAdapter.cmTime(exactly: clip.duration)),
                    of: assetTrack,
                    at: CMTimeAdapter.cmTime(exactly: clip.timelineStart))
                let start = clip.timelineStart.ticks
                let end = try clip.timelineEnd().ticks
                placed.append(PlacedClip(
                    track: compositionTrack, trackIndex: trackIndex,
                    startTicks: start, endTicks: end))
                boundaries.insert(start)
                boundaries.insert(end)
                contentEndTicks = max(contentEndTicks, end)
            }
            // Generator clips are skipped, not silently substituted: their
            // render branch (the compositor's empty-source path drawing
            // from instruction parameters) is M4 work (§5.8).
        }

        // The playable domain AUTHORITY is the document's stored duration
        // (validated by GyeolCore to be ≥ every clip end): frameCount and
        // stepping derive from `timelineEnd` below, so trailing space is
        // never silently lost from the DOCUMENT or the transport domain.
        //
        // MEASURED LIMITATION (PRD report target): AVFoundation discards
        // trailing emptiness — insertEmptyTimeRange at the tail is a no-op
        // at BOTH the composition and the track level (duration stays at
        // the content end; Apple's docs say as much for the composition).
        // So the trailing region cannot RENDER through AVComposition until
        // it contains content; the natural owner is M4's generator branch
        // (a blank/background source is content). Until then the player's
        // item ends at `contentEndTicks` while the transport domain runs to
        // `timelineEnd` — stepping into the trailing region holds the last
        // frame rather than showing rule-2 black. Recorded, not hidden.
        let timelineEndTicks = document.duration.ticks
        boundaries.insert(0)
        boundaries.insert(contentEndTicks)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = PassthroughCompositor.self
        // PROJECT grid, never the source grid: a 24fps clip in a 30fps
        // project previews on the 30fps grid. This is the §6.2 line the
        // M2.1 fixture exists to test.
        let projectFrame = document.settings.frameRate.frameDuration
        videoComposition.frameDuration = CMTime(
            value: CMTimeValue(projectFrame.value), timescale: projectFrame.timescale)
        videoComposition.renderSize = CGSize(
            width: Int(document.settings.renderWidth),
            height: Int(document.settings.renderHeight))

        // Instructions must cover [0, timelineEnd] with no gaps: each
        // segment between consecutive boundaries is either "these tracks
        // are active" or explicitly empty (zero layer instructions → the
        // compositor's black branch).
        var instructions: [AVMutableVideoCompositionInstruction] = []
        let sortedBoundaries = boundaries.sorted()
        for (segmentStart, segmentEnd) in zip(sortedBoundaries, sortedBoundaries.dropFirst())
        where segmentStart < segmentEnd {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(
                start: CMTime(value: segmentStart, timescale: DocumentTime.timescale),
                end: CMTime(value: segmentEnd, timescale: DocumentTime.timescale))
            // TOP-FIRST (descending track index) — the layering contract's
            // order, and what makes the compositor's first-available pick
            // the correct opaque degenerate case until M4's alpha pass.
            instruction.layerInstructions = placed
                .filter { $0.startTicks <= segmentStart && segmentEnd <= $0.endTicks }
                .sorted { $0.trackIndex > $1.trackIndex }
                .map { AVMutableVideoCompositionLayerInstruction(assetTrack: $0.track) }
            instructions.append(instruction)
        }
        videoComposition.instructions = instructions

        // GyeolPlayback sits outside GyeolCore, so the internal tick
        // initializer is out of reach; the labeled exact path cannot fail
        // for ticks that came FROM DocumentTime arithmetic.
        let timelineEnd = DocumentTime(
            exactly: try! RationalTime(value: timelineEndTicks, timescale: DocumentTime.timescale))!
        return Built(
            composition: composition,
            videoComposition: videoComposition,
            timelineEnd: timelineEnd)
    }
}
