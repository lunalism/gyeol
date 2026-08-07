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
    /// What the transport last did and whether it landed. NOT a clock — the
    /// clock is `timecodeDisplay`, derived from the one playhead index, so
    /// the screen can never carry two times that disagree (M2.3.1, §9).
    private(set) var transportReport = "—"
    /// Diagnostics from the last stop handoff — the residual is surfaced,
    /// never swallowed (PRD §7.4-6).
    private(set) var lastStopReport: String?
    /// Task-4 diagnostic: stop handoffs that REJECTED an untrusted display
    /// PTS. The condition — a "display timestamp" off the frame grid,
    /// measured as AVFoundation echoing our own seek target under decoder
    /// failure — cannot occur in healthy playback, so a nonzero count is a
    /// signal (§7.4-6), not merely a quietly held frame.
    private(set) var untrustedDisplayPTSCount = 0

    /// The media URLs the current composition was built from (M2.2): the
    /// timeline's waveform loader reads these. They live HERE rather than
    /// in a view-side @State copy because they are part of the load's
    /// commit — set and cleared with the item they belong to, so the
    /// timeline can never pair a stale URL set with a new composition.
    private(set) var resolvedMediaURLs: [MediaID: URL] = [:]

    /// Display-only playhead while playing (M2.2): what the TIMELINE draws
    /// between stop handoffs. Derived from the displayed frame's PTS via
    /// the adapter — never `player.currentTime()` (§7.4-8: the player
    /// clock reports values outside the item duration) — and written to no
    /// document or transport state. When stopped, the authoritative
    /// `playheadFrame` is the answer.
    private(set) var displayOnlyFrame = 0

    /// DIAGNOSTIC ONLY (`--playhead-probe --playhead-offset`): shifts the
    /// DRAWN playhead by this many frames while playing, and nothing else.
    /// It exists so a human can be shown a deliberate mismatch and report
    /// the smallest one they can notice — the control that gives the
    /// waveform-against-hearing check a claim range (§4 rule 8).
    ///
    /// Applied HERE, at the display value, and never to the timebase read:
    /// the commit path takes its evidence straight from the timebase and
    /// never reads `timelinePlayheadFrame`, so the offset cannot reach
    /// `playheadFrame`. Shifting the timebase reading instead would move
    /// the commit with it and the control would be measuring a different
    /// system than the one it is a control for.
    ///
    /// While STOPPED the offset does not apply: after a handoff the drawn
    /// playhead must equal the committed one (§7.4-8), and a control that
    /// broke that invariant would be lying about the thing under test.
    /// Zero everywhere except inside the probe.
    var displayOffsetFrames = 0

    var timelinePlayheadFrame: Int {
        guard isPlaying else { return playheadFrame }
        guard displayOffsetFrames != 0 else { return displayOnlyFrame }
        return min(max(0, displayOnlyFrame + displayOffsetFrames), max(0, frameCount - 1))
    }

    /// The clock on screen, DERIVED from `timelinePlayheadFrame` — not a
    /// third stored value and not a second time source. Before M2.3.1 the
    /// status line showed a 30 Hz sample of the player clock next to a
    /// frozen `playheadFrame`, i.e. two times that disagreed all through
    /// playback; §7.4-8 rejects that clock as frame evidence anyway.
    ///
    /// Integer arithmetic on purpose: ticks/120 IS milliseconds exactly, so
    /// no Double enters a time path. The truncation is display formatting
    /// and feeds nothing back.
    var timecodeDisplay: String {
        guard let rate = projectRate, frameCount > 0 else { return "—" }
        let ticks = FrameMapping.time(ofFrame: timelinePlayheadFrame, rate: rate).ticks
        let milliseconds = ticks / 120
        return String(format: "%d.%03d s", milliseconds / 1000, milliseconds % 1000)
    }

    /// D36 / §7.4-8: does THIS session's composition carry a video track?
    /// Structural, decided by the builder from the composition it actually
    /// produced — never a runtime-failure fallback, and never a question
    /// about the document (the fixed 3+2 layout would make it always false).
    /// Re-evaluated on every rebuild; constant within a session because the
    /// document does not mutate while playing.
    private(set) var sessionHasVideoTrack = false
    /// The item this session is playing. Held so the timebase read is bound
    /// to the SESSION's item rather than to whatever the player happens to
    /// hold when a handoff completes.
    private var sessionItem: AVPlayerItem?
    /// The most recent PTS the timeline's polling DRAINED from the video
    /// output during this playback session. Kept because each vended
    /// buffer is consumable once: a stop arriving right after a drain
    /// would find the output empty, and this PTS is still genuine frame
    /// evidence for the handoff (unlike the wall clock, which never is).
    private var lastDrainedDisplayPTS: CMTime?

    private static let log = Logger(subsystem: "dev.gyeol.Gyeol", category: "Playback")

    private var videoOutput: AVPlayerItemVideoOutput?
    // nonisolated(unsafe): written only from MainActor code paths, and read
    // once more from the nonisolated deinit below — the narrow escape hatch
    // that makes the teardown compile under Swift 6.
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?

    init() {
        LifetimeProbe.attach(to: player, label: "AVPlayer")
    }

    deinit {
        // Per-document controllers make this teardown load-bearing (F6):
        // every closed document would otherwise leave a KVO observation
        // alive on a dead player.
        //
        // The periodic time observer that used to be removed here is GONE
        // (M2.3.1): its only consumer was the 30 Hz clock string, and the
        // clock is now derived from the playhead index. One fewer observer
        // is one fewer teardown that can be forgotten.
        rateObservation?.invalidate()
        LifetimeProbe.logDeinit("PlaybackController")
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
        sessionItem = nil
        sessionHasVideoTrack = false
        lastDrainedDisplayPTS = nil
        resolvedMediaURLs = [:]
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
            item.audioMix = built.audioMix
            // The video output exists for the stop handoff: it is the only
            // API that reports WHICH frame is displaying (a PTS — a
            // boundary time the adapter's snap is built for). currentTime()
            // is a wall clock and lands mid-frame.
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
            item.add(output)

            // Commit point — all or nothing.
            videoOutput = output
            sessionItem = item
            sessionHasVideoTrack = built.hasVideoTrack
            lastDrainedDisplayPTS = nil  // evidence never outlives its item
            resolvedMediaURLs = mediaURLs
            player.replaceCurrentItem(with: item)
            playheadFrame = min(playheadFrame, max(0, frameCount - 1))
            displayOnlyFrame = playheadFrame
            installRateObservationIfNeeded()
            if frameCount > 0 {
                await seekToPlayhead(epoch: epoch)
                guard epoch == transportEpoch, !Task.isCancelled else { return }
            } else {
                transportReport = "빈 타임라인"
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
        displayOnlyFrame = 0
        lastDrainedDisplayPTS = nil
        resolvedMediaURLs = [:]
        videoOutput = nil
        sessionItem = nil
        sessionHasVideoTrack = false
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
            displayOnlyFrame = playheadFrame
            lastDrainedDisplayPTS = nil  // this session's evidence only
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

    // MARK: - Scrubbing (M2.2 task 4)

    /// One scrub gesture = one transport operation with one epoch. The
    /// epoch is taken at gesture start: it voids any in-flight stop
    /// handoff, and anything that bumps the epoch mid-gesture (a rebuild,
    /// shutdown) kills the gesture's seek pump at its next check.
    private var scrubEpoch: Int?
    private var scrubPumpActive = false
    /// Diagnostic: seeks issued by scrubbing since load, for the M2.2
    /// measurement report.
    private(set) var scrubSeekCount = 0

    func beginScrub() {
        guard loadState == .ready, frameCount > 0 else { return }
        if isPlaying {
            // Scrubbing while playing is a stop path we own: with
            // isPlaying already false, the rate observation's queued stop
            // event dies on its guard, and the gesture's frame — not a
            // snap of a torn-down clock — is the authority (§7.4-8).
            isPlaying = false
            player.pause()
        }
        transportEpoch += 1
        scrubEpoch = transportEpoch
    }

    func scrub(toFrame frame: Int) {
        guard let epoch = scrubEpoch, epoch == transportEpoch,
              loadState == .ready, frameCount > 0 else { return }
        playheadFrame = min(max(0, frame), frameCount - 1)
        pumpScrubSeeks(epoch: epoch)
    }

    func endScrub() {
        scrubEpoch = nil
        // The pump keeps running until the player has landed on the final
        // playheadFrame; nothing to flush here.
    }

    /// Serialized seek pump: at most ONE seek in flight, always to the
    /// LATEST playheadFrame — a 60 Hz drag does not queue 60 seeks, it
    /// coalesces to "seek, then seek again if the target moved".
    ///
    /// Only the completion-result overload of `seek` is used (§6.2): the
    /// fire-and-forget overload cannot report cancellation and revives F7 —
    /// `playheadFrame` at N with the player quietly elsewhere.
    private func pumpScrubSeeks(epoch: Int) {
        guard !scrubPumpActive, let rate = projectRate else { return }
        scrubPumpActive = true
        Task { @MainActor in
            defer { scrubPumpActive = false }
            var landed = -1
            var retries = 0
            while epoch == transportEpoch {
                let target = playheadFrame
                if target == landed { break }
                let time = CMTimeAdapter.cmTimeForSeek(toFrame: target, projectRate: rate)
                scrubSeekCount += 1
                let finished = await player.seek(
                    to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                guard epoch == transportEpoch else { return }
                if finished {
                    landed = target
                    retries = 0
                    transportReport = "frame \(target)"
                } else if playheadFrame == target {
                    // Cancelled, no newer target of ours, no newer
                    // transport op (epoch held): retry, bounded, then
                    // surface rather than loop (§7.4-6).
                    retries += 1
                    if retries > 2 {
                        transportReport = "frame \(target) — seek cancelled, player position unconfirmed"
                        return
                    }
                }
                // Cancelled because the drag moved on: loop re-reads
                // playheadFrame and seeks to the newer target.
            }
        }
    }

    // MARK: - Display-only playhead polling (M2.2 task 2)

    /// Called from the timeline's display link each tick while playing.
    /// Vends the displayed frame from the video output and derives the
    /// display-only frame index through the adapter. `currentTime()`
    /// appears ONLY as the output's vend key — the API takes an item time
    /// to answer "what should be displaying now" — never as frame
    /// evidence.
    func pollDisplayedFrame() {
        guard isPlaying, let rate = projectRate else { return }

        // D36 — the STRUCTURAL branch (§7.4-8): a composition with no video
        // track vends no pixel buffers, so `hasNewPixelBuffer` is false for
        // every tick and the path below could only ever early-return. The
        // item timebase is this session's time source instead.
        //
        // No threshold and no rejection here, and none is missing: §7.4-8
        // governs the COMMIT at stop, and this value is display-only — it
        // is written to no document and to no transport state. `floor` is
        // the mapping because the timebase points at an arbitrary instant,
        // not at a frame boundary (§5.6.1's third entry).
        //
        // `player.currentTime()` is not used: it echoes the seek target and
        // goes NaN once the item detaches (A-36, A-40).
        guard sessionHasVideoTrack else {
            guard let timebase = sessionItem?.timebase,
                  let containing = CMTimeAdapter.frameIndexContaining(
                    CMTimebaseGetTime(timebase), projectRate: rate) else { return }
            displayOnlyFrame = min(containing.frameIndex, max(0, frameCount - 1))
            return
        }

        guard let output = videoOutput else { return }
        let itemTime = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else { return }
        var pts = CMTime.invalid
        guard output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &pts) != nil,
              pts.isNumeric else { return }
        lastDrainedDisplayPTS = pts
        // Over-threshold PTS: display-only path holds the last good frame.
        // No counter here — the counted diagnostic belongs to the stop
        // handoff, where an untrusted PTS would have corrupted the
        // AUTHORITATIVE frame; here it can only delay a cosmetic update.
        guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: pts, projectRate: rate),
              !snap.exceedsQuarterFrameThreshold else { return }
        displayOnlyFrame = min(snap.frameIndex, max(0, frameCount - 1))
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
        guard let rate = projectRate else { return }

        // D36 (§7.4-8, eighth refinement). Read at handoff ENTRY, before any
        // await, and decided against the composition of the session that
        // STARTED this handoff — a rebuild that lands mid-handoff must not
        // switch which rule applies. That is the handoff-atomicity clause
        // extended to rule selection, not a new mechanism.
        //
        // The timebase is evidence only for a session that ACTUALLY played:
        // read without a preceding play it merely echoes our own seek target
        // (measured, A-40) and is worth no more than `currentTime()`. The
        // `guard isPlaying` in `playbackDidStop()` is that gate — `isPlaying`
        // becomes true only in the play branch — so a handoff entered
        // without a play never reaches here and the last committed index
        // stands.
        if !sessionHasVideoTrack {
            guard let timebase = sessionItem?.timebase else {
                lastStopReport = "no item timebase — kept frame \(playheadFrame)"
                await seekToPlayhead(epoch: epoch)
                return
            }
            // A nonzero timebase rate here is EXPECTED, not a failure: the
            // player's rate and the item's timebase do not stop in the same
            // instant (measured: the timebase still read rate 1 one sample
            // after player.rate hit 0, ~0.4 ms, A-40). We do NOT wait for it
            // to settle — waiting adds an asynchronous step and collides
            // with handoff atomicity, and floor bounds the disagreement at
            // one frame, inside this rule's claimed range.
            let time = CMTimebaseGetTime(timebase)
            guard let containing = CMTimeAdapter.frameIndexContaining(time, projectRate: rate) else {
                lastStopReport = "unusable item timebase (\(time.value)/\(time.timescale)) — kept frame \(playheadFrame)"
                await seekToPlayhead(epoch: epoch)
                return
            }
            let index = min(containing.frameIndex, max(0, frameCount - 1))
            playheadFrame = index
            displayOnlyFrame = index
            lastStopReport = "item timebase \(time.value)/\(time.timescale) → \(containing) (audio-only session)"
            await seekToPlayhead(epoch: epoch)
            return
        }

        guard let output = videoOutput else { return }

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

        // M2.2: the timeline's display-link polling DRAINS the output (a
        // vended buffer is consumable once), so a stop can find the output
        // empty even though a frame is on screen. The drained PTS is that
        // frame's PTS — genuine frame evidence from THIS session — so it
        // substitutes before the kept-frame path. The wall clock still
        // never does (§7.4-8: 확정할 수 없으면 확정하지 않는다).
        var evidence = displayPTS
        var evidenceNote = ""
        if !evidence.isNumeric, let drained = lastDrainedDisplayPTS {
            evidence = drained
            evidenceNote = " (from drained display buffer)"
        }
        guard evidence.isNumeric else {
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
        switch decideStopSnap(displayPTS: evidence) {
        case .adopt(let frameIndex, let report):
            // The adapter carried the L1 frame index (D23) — no second
            // mapping, no pull toward ticks / ticksPerFrame (PRD §6.2).
            playheadFrame = frameIndex
            displayOnlyFrame = frameIndex
            lastStopReport = report + evidenceNote
        case .reject(let report):
            lastStopReport = report + evidenceNote
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
        transportReport = finished
            ? "frame \(playheadFrame)"
            : "frame \(playheadFrame) — seek cancelled, player position unconfirmed"
    }

}

/// G5 ground truth (M2.1): two measurements disagreed — the headless
/// lifetime table said the document survives close, the GUI memory graph
/// said it does not. Deinit logging in the RUNNING APP is the arbiter, and
/// it stays after the dispute is settled: silent deallocation is exactly
/// how a disagreement like this goes unnoticed.
final class LifetimeProbe {
    private static let log = Logger(subsystem: "dev.gyeol.Gyeol", category: "Lifetime")
    nonisolated(unsafe) private static var associationKey: UInt8 = 0
    private let label: String
    private init(_ label: String) { self.label = label }

    /// For classes that offer no deinit of their own to join (AVPlayer):
    /// the probe rides along as an associated object and logs when its
    /// host actually frees.
    static func attach(to object: AnyObject, label: String) {
        objc_setAssociatedObject(
            object, &associationKey, LifetimeProbe(label), .OBJC_ASSOCIATION_RETAIN)
    }

    static func logDeinit(_ label: String) {
        log.notice("\(label, privacy: .public) deinit")
        print("G5-app: \(label) deinit")
    }

    deinit { Self.logDeinit(label) }
}
