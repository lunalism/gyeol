import AVFoundation
import CoreMedia
import GyeolCore
import GyeolPlayback
import Observation
import os

/// Per-document playback state (M2.1): each document window owns one of
/// these, so observer teardown in `deinit` is now load-bearing (A-30 F6).
///
/// AVFoundation lives HERE and never in GyeolCore (PRD §5.6.5; the only
/// CoreMedia surface in Core is `CMTimeAdapter`, D19).
///
/// The playhead is a FRAME INDEX (PRD §7.4-8). It changes in exactly two
/// ways: stepping (±1) and the single snap that happens at stop. During
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
    /// Frames in the playable domain [0, timelineEnd). 0 for an empty
    /// document. Always exact: the timeline end is document arithmetic,
    /// never a container duration (M1's off-grid duration case is gone —
    /// the composition's length is ours by construction).
    private(set) var frameCount = 0
    /// Authoritative playhead. A frame index, not a time (PRD §7.4-8).
    private(set) var playheadFrame = 0
    private(set) var isPlaying = false
    /// What the player's clock says while playing. Display-only; seconds as
    /// Double is acceptable here precisely because nothing consumes it.
    private(set) var clockDisplay = "—"
    /// Diagnostics from the last stop handoff — the residual is surfaced,
    /// never swallowed (PRD §7.4-6).
    private(set) var lastStopReport: String?
    /// Task-4 diagnostic: stop handoffs that REJECTED an untrusted display
    /// PTS. The condition — a "display timestamp" off the frame grid,
    /// measured as AVFoundation echoing our own seek target under decoder
    /// failure — cannot occur in healthy playback, so a nonzero count is a
    /// signal (§7.4-6), not merely a quietly held frame.
    private(set) var untrustedDisplayPTSCount = 0

    private static let log = Logger(subsystem: "dev.gyeol.Gyeol", category: "Playback")

    private var videoOutput: AVPlayerItemVideoOutput?
    // nonisolated(unsafe): these two are written only from MainActor code
    // paths, and read once more from the nonisolated deinit below — the
    // narrow escape hatch that makes the teardown compile under Swift 6.
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?

    deinit {
        // Per-document controllers make this teardown load-bearing (F6):
        // every closed document would otherwise leave a periodic observer
        // and a KVO observation alive on a dead player. Apple requires
        // explicit removeTimeObserver for every periodic observer.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        rateObservation?.invalidate()
    }

    /// Transport generation counter. Every transport mutation — play, stop
    /// handoff, step, and REBUILD (document load, edit, undo: G1's new
    /// entry) — bumps it; any async continuation that finds a different
    /// epoch after an await has been superseded and must apply NOTHING.
    /// This is PRD 7.4-8's atomic-handoff rule implemented as one
    /// mechanism: guarding each interleaving separately would miss the
    /// next one nobody thought of. A rebuild arriving mid-handoff voids
    /// the handoff at its next epoch check; a handoff event arriving
    /// after a rebuild dies on the rate guard or the epoch.
    private var transportEpoch = 0

    // MARK: - Load (the composition rebuild path)

    /// Builds the document's composition and points the player at it.
    /// Called on open and on every document replacement (edits and undo
    /// route through here from M2.3 on) — possibly while playing, which is
    /// why the transport reset comes first.
    /// Set at the window's lifecycle edge; a shut-down controller accepts
    /// no further transport work, including a load that was already queued
    /// when the window closed.
    private var isShutDown = false

    /// Deterministic teardown at the lifecycle edge — called from the
    /// DOCUMENT's close() (view-side hooks lose races; see
    /// GyeolDocumentFile.playback). Shutdown is itself a transport
    /// operation: the epoch bump voids anything in flight, and the flag
    /// stops late arrivals from rebuilding. deinit stays as the backstop.
    func shutdown() {
        isShutDown = true
        transportEpoch += 1
        player.pause()
        isPlaying = false
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        rateObservation?.invalidate()
        rateObservation = nil
        loadState = .empty
    }

    func load(document: GyeolDocument, mediaURLs: [MediaID: URL]) async {
        // Runs inside the document view's `.task`, which SwiftUI cancels
        // when the window closes — but a task queued at close time can
        // also run UNCANCELLED after the window is gone (measured, G5).
        // Both gates: cancellation, and the shutdown flag.
        guard !Task.isCancelled, !isShutDown else { return }
        transportEpoch += 1
        let epoch = transportEpoch
        player.pause()
        isPlaying = false
        loadState = .loading
        lastStopReport = nil
        do {
            let built = try await CompositionBuilder.build(
                document: document, mediaURLs: mediaURLs)
            // Superseded by a newer rebuild, or cancelled by the window
            // going away: either way, apply nothing.
            guard epoch == transportEpoch, !Task.isCancelled else { return }

            let rate = document.settings.frameRate
            projectRate = rate
            frameCount = FrameMapping.frameCount(for: built.timelineEnd, rate: rate)
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            // The video output exists for the stop handoff: it is the only
            // API that reports WHICH frame is displaying (a PTS — a
            // boundary time the adapter's snap is built for). currentTime()
            // is a wall clock and lands mid-frame.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)

            // Commit point — all or nothing.
            videoOutput = output
            player.replaceCurrentItem(with: item)
            playheadFrame = min(playheadFrame, max(0, frameCount - 1))
            installRateObservationIfNeeded()
            if frameCount > 0 {
                await seekToPlayhead(epoch: epoch)
                guard epoch == transportEpoch, !Task.isCancelled else { return }
            } else {
                clockDisplay = "빈 타임라인"
            }
            loadState = .ready
        } catch {
            guard epoch == transportEpoch, !Task.isCancelled else { return }
            clearLoadedState(failure: String(describing: error))
        }
    }

    /// Entry point for failures that happen before `load` can run at all
    /// (unresolvable media, unsaved document with media references).
    func reportLoadFailure(_ message: String) {
        transportEpoch += 1
        player.pause()
        isPlaying = false
        clearLoadedState(failure: message)
    }

    /// A failed load leaves the controller empty-with-an-error, never a mix
    /// of the previous composition's state and the new one's (F5).
    private func clearLoadedState(failure: String) {
        player.replaceCurrentItem(with: nil)
        projectRate = nil
        frameCount = 0
        playheadFrame = 0
        videoOutput = nil
        loadState = .failed(failure)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard loadState == .ready, frameCount > 0 else { return }
        if isPlaying {
            // No handoff here. Stopping has more than one entry point —
            // user pause, reaching the end of the timeline, and M2's
            // additions (clip end, playback range end, edit interruption).
            // They all funnel through the rate observation below; hooking
            // actions one by one means missing whichever path gets added
            // next.
            player.pause()
        } else {
            // Resuming voids any in-flight stop handoff (F2) and any stop
            // event still queued behind us (F1): the former checks the
            // epoch, the latter checks player.rate.
            transportEpoch += 1
            installClockObserverIfNeeded()
            isPlaying = true
            player.play()
        }
    }

    func step(by delta: Int) async {
        guard loadState == .ready, !isPlaying, projectRate != nil, frameCount > 0 else { return }
        transportEpoch += 1
        let epoch = transportEpoch
        playheadFrame = min(max(0, playheadFrame + delta), frameCount - 1)
        await seekToPlayhead(epoch: epoch)
    }

    // MARK: - The principle-8 handoff

    /// "Stopping" is defined as the player's rate becoming zero — observed,
    /// not inferred from our own actions. This is the one signal every stop
    /// path shares: user pause, end of timeline, and M2's stop paths.
    private func installRateObservationIfNeeded() {
        guard rateObservation == nil else { return }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let newRate = change.newValue, newRate == 0 else { return }
            // KVO delivers on an arbitrary thread; state lives on MainActor.
            Task { @MainActor [weak self] in
                await self?.playbackDidStop()
            }
        }
    }

    // Internal (not private) so the F1 interleaving test can invoke the
    // handoff exactly the way a stale queued KVO task would.
    func playbackDidStop() async {
        // Seeks while paused also report rate 0 (first guard); and a stop
        // event that was queued behind a resume is stale — the player is
        // moving again, and player.rate is the ground truth the event
        // cannot fake. A stale handoff is VOID, not late (F1, PRD 7.4-8).
        guard isPlaying, player.rate == 0 else { return }
        isPlaying = false
        transportEpoch += 1
        await snapToReportedFrame(epoch: transportEpoch)
    }

    /// The stop handoff: snap what the player reports to a frame ONCE, take
    /// that index as truth, and seek back to the CMTime derived from the
    /// index so player and app agree again.
    ///
    /// "What the player reports" is the displayed frame's PTS from
    /// `AVPlayerItemVideoOutput`, not `currentTime()`: the wall clock sits
    /// mid-frame — after our own seeks, exactly ON the frame centre —
    /// where nearest-boundary snapping is ambiguous by definition.
    private func snapToReportedFrame(epoch: Int) async {
        guard let rate = projectRate, let output = videoOutput else { return }

        // Poll briefly: with no renderer draining it, AVPlayerItemVideoOutput
        // can be dormant at the moment of the stop and needs a beat to vend.
        var displayPTS = CMTime.invalid
        for _ in 0..<10 {
            let itemTime = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayPTS) != nil,
               displayPTS.isNumeric {
                break
            }
            displayPTS = .invalid
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard epoch == transportEpoch else { return }
        }

        guard displayPTS.isNumeric else {
            // No frame evidence: the last confirmed index stays
            // authoritative (PRD 7.4-8); re-seek to it and say what
            // happened rather than guessing from a mid-frame wall clock.
            lastStopReport = "display PTS unavailable — kept frame \(playheadFrame)"
            await seekToPlayhead(epoch: epoch)
            return
        }

        // A resume that arrived while we were reading the player voids the
        // handoff entirely — it must not finish with a seek (F2).
        guard epoch == transportEpoch else { return }
        switch decideStopSnap(displayPTS: displayPTS) {
        case .adopt(let frameIndex, let report):
            // The adapter carried the L1 frame index (D23) — no second
            // mapping, no pull toward ticks / ticksPerFrame (PRD §6.2).
            playheadFrame = frameIndex
            lastStopReport = report
        case .reject(let report):
            lastStopReport = report
        case nil:
            return
        }
        await seekToPlayhead(epoch: epoch)
    }

    enum StopSnapDecision: Equatable {
        case adopt(frameIndex: Int, report: String)
        case reject(report: String)
    }

    /// The handoff's decision seam, internal so the untrusted-PTS path is
    /// testable (task 4): an over-threshold "display PTS" is not frame
    /// evidence — the last confirmed index stays authoritative — and the
    /// rejection is COUNTED and logged, not silently absorbed.
    func decideStopSnap(displayPTS: CMTime) -> StopSnapDecision? {
        guard let rate = projectRate else { return nil }
        guard let snap = CMTimeAdapter.documentTime(
            snappingToFrameGrid: displayPTS, projectRate: rate) else {
            return .reject(report: "snap failed: non-numeric display PTS")
        }
        guard !snap.exceedsQuarterFrameThreshold else {
            untrustedDisplayPTSCount += 1
            Self.log.warning("stop handoff rejected untrusted display PTS \(displayPTS.value)/\(displayPTS.timescale) (count \(self.untrustedDisplayPTSCount))")
            return .reject(report: "unreliable display PTS (\(snap)) — kept frame \(playheadFrame)")
        }
        return .adopt(
            frameIndex: min(snap.frameIndex, max(0, frameCount - 1)),
            report: "display PTS \(displayPTS.value)/\(displayPTS.timescale) → \(snap)")
    }

    // MARK: - Helpers

    private func seekToPlayhead(epoch: Int) async {
        guard let rate = projectRate else { return }
        let target = CMTimeAdapter.cmTimeForSeek(toFrame: playheadFrame, projectRate: rate)
        // Zero tolerance both ways (PRD §5.6.1): the frame-centre target
        // plus a tolerance would reintroduce the neighbour-frame risk the
        // centre offset exists to remove.
        //
        // The seek RESULT cannot be discarded (F7, now §6.2): false means
        // cancelled, and a cancelled seek leaves playheadFrame and the
        // player disagreeing. When our own newer transport op cancelled it,
        // that op owns the position and we drop out via the epoch.
        // Otherwise: one retry, then surface.
        var finished = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        guard epoch == transportEpoch else { return }
        if !finished {
            finished = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard epoch == transportEpoch else { return }
        }
        clockDisplay = finished
            ? "frame \(playheadFrame)"
            : "frame \(playheadFrame) — seek cancelled, player position unconfirmed"
    }

    private func installClockObserverIfNeeded() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            // ⚠️ `queue: .main` is LOAD-BEARING: the closure below enters
            // MainActor via assumeIsolated, which traps at runtime on any
            // other queue (F3). Change this argument and that call together.
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            // Sound ONLY because the observer above registers on .main —
            // see the queue argument's comment before touching either side.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.clockDisplay = String(format: "%.3f s (display only)", time.seconds)
            }
        }
    }
}
