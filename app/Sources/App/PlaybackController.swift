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
    /// Diagnostics from the last stop handoff — the residual is surfaced,
    /// never swallowed (PRD §7.4-6).
    private(set) var lastStopReport: String?

    private var videoOutput: AVPlayerItemVideoOutput?
    // nonisolated(unsafe): these two are written only from MainActor code
    // paths, and read once more from the nonisolated deinit below — the
    // narrow escape hatch that makes the teardown compile under Swift 6.
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?

    deinit {
        // Both observers are registered on `player`, which the controller
        // owns for its whole life — harmless today, a leak the moment M2
        // makes the controller per-document (F6). Apple requires explicit
        // removeTimeObserver for every periodic observer. Stored-property
        // access is legal in a nonisolated deinit; neither call touches
        // MainActor state.
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        rateObservation?.invalidate()
    }

    /// Transport generation counter. Every transport mutation — play, stop
    /// handoff, step, open — bumps it; any async continuation that finds a
    /// different epoch after an await has been superseded and must apply
    /// NOTHING. This is PRD 7.4-8's atomic-handoff rule implemented as one
    /// mechanism: guarding each interleaving separately (pause-then-resume,
    /// handoff-interrupted, open-during-play, superseded seek) would miss
    /// the next interleaving nobody thought of.
    private var transportEpoch = 0

    // MARK: - Open

    func open(url: URL) async {
        // Transport reset FIRST: replacing the item under a playing player
        // fires the rate observation against the new item (F5).
        transportEpoch += 1
        let epoch = transportEpoch
        player.pause()
        isPlaying = false
        loadState = .loading
        lastStopReport = nil
        let asset = AVURLAsset(url: url)
        do {
            // Everything loads into locals; state is committed only after
            // the last throwing step, so a failed open can never leave a
            // half-populated mix of two files (F5).
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard epoch == transportEpoch else { return }  // superseded by a newer open
            guard let track = tracks.first else {
                clearLoadedState(failure: "no video track in \(url.lastPathComponent)")
                return
            }
            let nominal = try await track.load(.nominalFrameRate)
            let duration = try await asset.load(.duration)
            guard epoch == transportEpoch else { return }
            guard let rate = Self.nearestSupportedRate(toNominal: nominal) else {
                clearLoadedState(failure: "unsupported frame rate \(nominal)")
                return
            }

            // Exact conversion only. If the container timescale does not
            // divide 120000 the duration is off-grid; we skip the upper
            // clamp instead of rounding (see `frameCount` doc).
            var newFrameCount: Int?
            if duration.isNumeric, duration.timescale > 0,
               let durationTime = try? RationalTime(value: duration.value, timescale: duration.timescale),
               let docDuration = DocumentTime(exactly: durationTime) {
                newFrameCount = FrameMapping.frameCount(for: docDuration, rate: rate)
            }

            let item = AVPlayerItem(asset: asset)
            // The video output exists for the stop handoff: it is the only
            // API that reports WHICH frame is displaying (a PTS — a
            // boundary time the adapter's snap is built for). currentTime()
            // is a wall clock and lands mid-frame.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)

            // Commit point — all or nothing.
            projectRate = rate
            frameCount = newFrameCount
            videoOutput = output
            player.replaceCurrentItem(with: item)
            playheadFrame = 0
            installRateObservationIfNeeded()
            await seekToPlayhead(epoch: epoch)
            guard epoch == transportEpoch else { return }
            loadState = .ready
        } catch {
            guard epoch == transportEpoch else { return }
            clearLoadedState(failure: String(describing: error))
        }
    }

    /// A failed open leaves the controller empty-with-an-error, never a mix
    /// of the previous file's state and the new file's (F5).
    private func clearLoadedState(failure: String) {
        player.replaceCurrentItem(with: nil)
        projectRate = nil
        frameCount = nil
        videoOutput = nil
        playheadFrame = 0
        loadState = .failed(failure)
    }

    // MARK: - Transport

    func togglePlayPause() {
        guard loadState == .ready else { return }
        if isPlaying {
            // No handoff here. Stopping has more than one entry point —
            // user pause, reaching the end of the file, and whatever M2
            // adds (clip end, range end, edit interruption). They all
            // funnel through the rate observation below; hooking actions
            // one by one means missing whichever path gets added next.
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
        guard loadState == .ready, !isPlaying, projectRate != nil else { return }
        transportEpoch += 1
        let epoch = transportEpoch
        var target = max(0, playheadFrame + delta)
        if let count = frameCount {
            target = min(target, max(0, count - 1))
        }
        playheadFrame = target
        await seekToPlayhead(epoch: epoch)
    }

    // MARK: - The principle-8 handoff

    /// "Stopping" is defined as the player's rate becoming zero — observed,
    /// not inferred from our own actions. This is the one signal every stop
    /// path shares: user pause, end of file, and future M2 stops.
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
    /// `AVPlayerItemVideoOutput`, not `currentTime()`. The wall clock sits
    /// mid-frame almost always, and a mid-frame time is more than 1/4 frame
    /// from the nearest boundary half the time — the snap would trip its
    /// threshold constantly and could land on the NEXT frame's boundary
    /// while the previous frame is still displaying. The displayed frame's
    /// PTS is a boundary time, which is the input shape the adapter's snap
    /// was measured against (docs/m1-asset-timescale-probe.md).
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
            // No frame evidence. The wall clock is NOT a substitute: it sits
            // mid-frame — after our own seeks, exactly ON the frame centre,
            // where nearest-boundary snapping is ambiguous by definition
            // (that fallback was a debug-assert crash found by the F1 test).
            // Without evidence the last confirmed index stays authoritative
            // (PRD 7.4-8); re-seek to it and say what happened.
            lastStopReport = "display PTS unavailable — kept frame \(playheadFrame)"
            await seekToPlayhead(epoch: epoch)
            return
        }

        guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: displayPTS, projectRate: rate) else {
            lastStopReport = "snap failed: non-numeric display PTS"
            return
        }
        // A resume that arrived while we were reading the player voids the
        // handoff entirely — it must not finish with a seek (F2).
        guard epoch == transportEpoch else { return }
        // Frame index via L1 only — never time.ticks / ticksPerFrame
        // (PRD §6.2: compiles, usually right, still wrong).
        playheadFrame = FrameMapping.frameIndex(at: snap.time, rate: rate)
        lastStopReport = """
        display PTS \(displayPTS.value)/\(displayPTS.timescale) → frame \(playheadFrame), residual \
        \(snap.residualTickNumerator)/\(snap.residualTickDenominator) ticks\
        \(snap.exceedsQuarterFrameThreshold ? " — EXCEEDS 1/4 frame" : "")
        """
        await seekToPlayhead(epoch: epoch)
    }

    // MARK: - Helpers

    private func seekToPlayhead(epoch: Int) async {
        guard let rate = projectRate else { return }
        let target = CMTimeAdapter.cmTimeForSeek(toFrame: playheadFrame, projectRate: rate)
        // Zero tolerance both ways (PRD §5.6.1): the frame-centre target
        // plus a tolerance would reintroduce the neighbour-frame risk the
        // centre offset exists to remove.
        //
        // The seek RESULT cannot be discarded (F7): false means cancelled,
        // and a cancelled seek leaves playheadFrame and the player
        // disagreeing — the exact split principle 8 forbids. When our own
        // newer transport op cancelled it, that op owns the position and we
        // drop out via the epoch. Otherwise: one retry, then surface.
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
