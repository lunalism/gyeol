import AVFoundation
import CoreMedia
import GyeolCore
import Observation

/// App-layer playback state for M1 step 2: one file, one preview, a playhead.
///
/// AVFoundation lives HERE and never in GyeolCore (PRD §5.6.5; the only
/// CoreMedia surface in Core is `CMTimeAdapter`, D19).
///
/// The playhead is a FRAME INDEX (PRD §7.4-8). It changes in exactly two
/// ways: stepping (±1) and the single snap that happens at pause. During
/// playback AVPlayer owns the clock and everything it reports is
/// display-only — none of it is written back into `playheadFrame`.
@MainActor
@Observable
final class PlaybackController {
    enum LoadState: Equatable {
        case empty, loading, ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .empty
    let player = AVPlayer()
    private(set) var projectRate: FrameRate?
    /// nil when the asset duration is not exactly representable in document
    /// ticks (e.g. a 90000-timescale container) — stepping is then unclamped
    /// at the top end. Reported in the UI rather than silently rounded:
    /// `DocumentTime(rounding:)` is off-limits on frame-accuracy paths
    /// (PRD §6.2).
    private(set) var frameCount: Int?
    /// Authoritative playhead. A frame index, not a time (PRD §7.4-8).
    private(set) var playheadFrame = 0
    private(set) var isPlaying = false
    /// What the player's clock says while playing. Display-only; seconds as
    /// Double is acceptable here precisely because nothing consumes it.
    private(set) var clockDisplay = "—"
    /// Diagnostics from the last pause handoff — the residual is surfaced,
    /// never swallowed (PRD §7.4-6).
    private(set) var lastPauseReport: String?

    private var videoOutput: AVPlayerItemVideoOutput?
    private var timeObserver: Any?

    // MARK: - Open

    func open(url: URL) async {
        loadState = .loading
        lastPauseReport = nil
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                loadState = .failed("no video track in \(url.lastPathComponent)")
                return
            }
            let nominal = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)
            guard let rate = Self.nearestSupportedRate(toNominal: nominal) else {
                loadState = .failed("unsupported frame rate \(nominal)")
                return
            }
            projectRate = rate

            // Exact conversion only. If the container timescale does not
            // divide 120000 the duration is off-grid; we skip the upper
            // clamp instead of rounding (see `frameCount` doc).
            if duration.isNumeric, duration.timescale > 0,
               let durationTime = try? RationalTime(value: duration.value, timescale: duration.timescale),
               let docDuration = DocumentTime(exactly: durationTime) {
                frameCount = FrameMapping.frameCount(for: docDuration, rate: rate)
            } else {
                frameCount = nil
            }

            let item = AVPlayerItem(asset: asset)
            // The video output exists for the pause handoff: it is the only
            // API that reports WHICH frame is displaying (a PTS — a
            // boundary time the adapter's snap is built for). currentTime()
            // is a wall clock and lands mid-frame.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)
            videoOutput = output
            player.replaceCurrentItem(with: item)

            playheadFrame = 0
            await seekToPlayhead()
            loadState = .ready
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    // MARK: - Transport

    func togglePlayPause() async {
        guard loadState == .ready else { return }
        if isPlaying {
            await pauseAndSnap()
        } else {
            installClockObserverIfNeeded()
            isPlaying = true
            player.play()
        }
    }

    func step(by delta: Int) async {
        guard loadState == .ready, !isPlaying, projectRate != nil else { return }
        var target = max(0, playheadFrame + delta)
        if let count = frameCount {
            target = min(target, max(0, count - 1))
        }
        playheadFrame = target
        await seekToPlayhead()
    }

    // MARK: - The principle-8 handoff

    /// Pause, then: snap what the player reports to a frame ONCE, take that
    /// index as truth, and seek back to the CMTime derived from the index so
    /// player and app agree again.
    ///
    /// "What the player reports" is the displayed frame's PTS from
    /// `AVPlayerItemVideoOutput`, not `currentTime()`. The wall clock sits
    /// mid-frame almost always, and a mid-frame time is more than 1/4 frame
    /// from the nearest boundary half the time — the snap would trip its
    /// threshold constantly and could land on the NEXT frame's boundary
    /// while the previous frame is still displaying. The displayed frame's
    /// PTS is a boundary time, which is the input shape the adapter's snap
    /// was measured against (docs/m1-asset-timescale-probe.md).
    private func pauseAndSnap() async {
        player.pause()
        isPlaying = false
        guard let rate = projectRate, let output = videoOutput else { return }

        let itemTime = player.currentTime()
        var reported = itemTime
        var timeSource = "currentTime (fallback — display PTS unavailable)"
        var displayPTS = CMTime.invalid
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayPTS) != nil,
           displayPTS.isNumeric {
            reported = displayPTS
            timeSource = "display PTS \(displayPTS.value)/\(displayPTS.timescale)"
        }

        guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: reported, projectRate: rate) else {
            lastPauseReport = "snap failed: non-numeric time from player"
            return
        }
        // Frame index via L1 only — never time.ticks / ticksPerFrame
        // (PRD §6.2: compiles, usually right, still wrong).
        playheadFrame = FrameMapping.frameIndex(at: snap.time, rate: rate)
        lastPauseReport = """
        \(timeSource) → frame \(playheadFrame), residual \
        \(snap.residualTickNumerator)/\(snap.residualTickDenominator) ticks\
        \(snap.exceedsQuarterFrameThreshold ? " — EXCEEDS 1/4 frame" : "")
        """
        await seekToPlayhead()
    }

    // MARK: - Helpers

    private func seekToPlayhead() async {
        guard let rate = projectRate else { return }
        // Zero tolerance both ways (PRD §5.6.1): the frame-centre target
        // plus a tolerance would reintroduce the neighbour-frame risk the
        // centre offset exists to remove.
        await player.seek(
            to: CMTimeAdapter.cmTimeForSeek(toFrame: playheadFrame, projectRate: rate),
            toleranceBefore: .zero, toleranceAfter: .zero)
        clockDisplay = "frame \(playheadFrame)"
    }

    private func installClockObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            // queue: .main makes MainActor assumption sound.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.clockDisplay = String(format: "%.3f s (display only)", time.seconds)
            }
        }
    }

    /// The closed FrameRate set, matched on nominal rate. Same tolerance the
    /// timescale probe used; a file outside the supported set is refused,
    /// not approximated.
    private static func nearestSupportedRate(toNominal fps: Float) -> FrameRate? {
        let candidates: [(FrameRate, Float)] = [
            (.fps23_976, 23.976), (.fps24, 24), (.fps25, 25), (.fps29_97, 29.97),
            (.fps30, 30), (.fps50, 50), (.fps59_94, 59.94), (.fps60, 60),
        ]
        guard let best = candidates.min(by: { abs($0.1 - fps) < abs($1.1 - fps) }) else { return nil }
        return abs(best.1 - fps) < 0.05 ? best.0 : nil
    }
}
