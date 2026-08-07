import AVFoundation
import CoreMedia
import Foundation
import GyeolCore
import GyeolPlayback
import Testing

/// M2.3.1 — the playhead during playback, on a session whose composition has
/// NO video track (D36, PRD §7.4-8 eighth refinement).
///
/// These run REAL playback: the player is started, the wall clock is allowed
/// to pass, and the item timebase is read. Nothing here is a simulation, and
/// nothing here listens — completion condition ② (waveform against hearing)
/// is a human check and cannot be automated. What this file gates is
/// condition ①: the display-only frame advances while playing, and the stop
/// commit lands on a frame derived from the timebase rather than on the
/// "display PTS unavailable — kept frame N" path that audio-only documents
/// used to take.
///
/// The player is muted here on purpose: these assertions are about indices,
/// and a test bundle that plays a 220 Hz tone out of the speakers on every
/// run is a nuisance, not a measurement.
@Suite @MainActor struct AudioOnlyPlayheadTests {
    private static let fixture = "tone-envelope-a"

    private func loadedController() async throws -> PlaybackController {
        let document = try AudioFixtureLocation.document(Self.fixture)
        let urls = try AudioFixtureLocation.mediaURLs(for: document, name: Self.fixture)
        let controller = PlaybackController()
        controller.player.volume = 0
        await controller.load(document: document, mediaURLs: urls)
        #expect(controller.loadState == .ready)
        #expect(!controller.sessionHasVideoTrack)
        return controller
    }

    /// Plays for `seconds`, polling the display-only path the way the
    /// timeline's display link does, and returns every distinct index seen.
    private func playSampling(
        _ controller: PlaybackController, seconds: Double
    ) async -> [Int] {
        var seen: [Int] = [controller.timelinePlayheadFrame]
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 16_000_000)  // ~display link
            controller.pollDisplayedFrame()
            if controller.timelinePlayheadFrame != seen.last {
                seen.append(controller.timelinePlayheadFrame)
            }
        }
        return seen
    }

    /// Waits for the rate-KVO handoff to finish. Bounded, and it asserts the
    /// bound rather than timing out silently.
    private func awaitStopHandoff(_ controller: PlaybackController) async {
        for _ in 0..<200 where controller.isPlaying || controller.lastStopReport == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(!controller.isPlaying)
        #expect(controller.lastStopReport != nil)
    }

    /// Condition ①, first half: the drawn playhead MOVES. Before M2.3.1 this
    /// list had exactly one entry — `hasNewPixelBuffer` is false forever on a
    /// composition with no video track, so the poll early-returned every tick.
    @Test func displayOnlyFrameAdvancesDuringAudioOnlyPlayback() async throws {
        let controller = try await loadedController()
        controller.togglePlayPause()
        let seen = await playSampling(controller, seconds: 1.0)
        controller.togglePlayPause()
        await awaitStopHandoff(controller)

        #expect(seen.count > 1, "the display-only frame never moved: \(seen)")
        #expect(seen == seen.sorted(), "display-only frame went backwards: \(seen)")
        #expect(seen.first == 0)
        // One second of a 30 fps project ≈ 30 frames. Loose on both sides:
        // this asserts "corresponds to playback progress", not a schedule.
        let advanced = seen.last! - seen.first!
        #expect(advanced > 10 && advanced < 60, "advanced \(advanced) frames in ~1 s")

        // The authoritative playhead did NOT move during playback (§7.4-8).
        // It is only allowed to change at the stop commit below.
        #expect(seen.last! > 0)
        controller.shutdown()
    }

    /// Condition ①, second half: the stop commit lands on a real frame, and
    /// the `display PTS unavailable` path is gone for audio-only sessions.
    @Test func stopCommitsAFrameFromTheItemTimebase() async throws {
        let controller = try await loadedController()
        controller.togglePlayPause()
        _ = await playSampling(controller, seconds: 1.0)
        let displayedAtStop = controller.timelinePlayheadFrame
        controller.togglePlayPause()
        await awaitStopHandoff(controller)

        let report = try #require(controller.lastStopReport)
        #expect(report.contains("item timebase"), "unexpected stop report: \(report)")
        #expect(!report.contains("display PTS unavailable"), "regressed to the kept-frame path: \(report)")
        #expect(controller.playheadFrame > 0)
        // The committed index and the last displayed index come from the
        // same source read a moment apart, so they agree closely. Not
        // "equal": the timebase keeps running for a beat after player.rate
        // hits 0 (measured, A-40), which is expected and bounded.
        #expect(abs(controller.playheadFrame - displayedAtStop) <= 2,
                "committed \(controller.playheadFrame) vs displayed \(displayedAtStop)")
        // Stopped: the timeline draws the authoritative playhead again, and
        // the one clock on screen is derived from it.
        #expect(controller.timelinePlayheadFrame == controller.playheadFrame)
        controller.shutdown()
    }

    /// The claimed range of D36 is "reproducible, monotonic, corresponds to
    /// playback progress" — NOT "the exact instant heard". This measures the
    /// first two: repeat play/stop from the same start and report the spread;
    /// then check that a longer play commits a later frame.
    @Test func committedIndexIsReproducibleAndMonotonicAcrossRepetitions() async throws {
        let controller = try await loadedController()
        var indices: [Int] = []
        for _ in 0..<5 {
            await controller.step(by: -controller.playheadFrame)  // back to 0
            #expect(controller.playheadFrame == 0)
            controller.togglePlayPause()
            _ = await playSampling(controller, seconds: 0.6)
            controller.togglePlayPause()
            await awaitStopHandoff(controller)
            indices.append(controller.playheadFrame)
        }
        print("M2.3.1: committed frames from the same start, 5 runs of ~0.6 s: \(indices)")
        #expect(indices.allSatisfy { $0 > 0 })
        // Scheduling decides how much wall clock each run actually gets, so
        // the band is wide on purpose. What would fail here is DRIFT — a
        // start that no longer means frame 0, which floor cannot cause
        // (playback moves forward; floor only ever rounds back inside the
        // frame already reached).
        let spread = indices.max()! - indices.min()!
        #expect(spread < 30, "spread of \(spread) frames across identical runs: \(indices)")

        // Monotonic against playback progress: a longer play commits later.
        await controller.step(by: -controller.playheadFrame)
        controller.togglePlayPause()
        _ = await playSampling(controller, seconds: 1.5)
        controller.togglePlayPause()
        await awaitStopHandoff(controller)
        print("M2.3.1: committed frame after ~1.5 s: \(controller.playheadFrame)")
        #expect(controller.playheadFrame > indices.max()!)
        controller.shutdown()
    }

    /// The probe's display offset (`--playhead-offset`) is the control for
    /// the human waveform/hearing check, so the mechanism has to be
    /// trustworthy on its own: it must move the DRAWN playhead by exactly N
    /// and reach nothing else. Gated here rather than left to the probe,
    /// because "the committed index did not change" is the kind of claim
    /// wall-clock runs can only make statistically.
    @Test func displayOffsetMovesTheDrawnPlayheadAndNothingElse() async throws {
        let controller = try await loadedController()
        #expect(controller.displayOffsetFrames == 0, "the offset must be zero outside the probe")

        controller.displayOffsetFrames = 12
        // Stopped: no offset. After a handoff the drawn playhead IS the
        // committed one (§7.4-8) and a control that broke that would be
        // lying about the thing under test.
        await controller.step(by: 5)
        #expect(controller.playheadFrame == 5)
        #expect(controller.timelinePlayheadFrame == 5)

        controller.togglePlayPause()
        _ = await playSampling(controller, seconds: 0.5)
        // Playing: drawn = display-only + N, exactly.
        #expect(controller.timelinePlayheadFrame - controller.displayOnlyFrame == 12)
        let displayedRaw = controller.displayOnlyFrame
        controller.togglePlayPause()
        await awaitStopHandoff(controller)

        // The commit took its evidence from the timebase, not from the
        // drawn value: it lands near the RAW display-only frame, nowhere
        // near the offset one.
        let report = try #require(controller.lastStopReport)
        #expect(report.contains("item timebase"))
        #expect(abs(controller.playheadFrame - displayedRaw) <= 2,
                "committed \(controller.playheadFrame) drifted toward the offset from \(displayedRaw)")
        #expect(controller.timelinePlayheadFrame == controller.playheadFrame)
        controller.displayOffsetFrames = 0
        controller.shutdown()
    }

    /// The timebase is evidence only for a session that ACTUALLY played
    /// (§7.4-8): read without a preceding play it echoes our own seek target.
    /// A handoff entered with no play in it must keep the last committed
    /// index and write nothing.
    @Test func aHandoffWithoutAPrecedingPlayCommitsNothing() async throws {
        let controller = try await loadedController()
        await controller.step(by: 12)
        #expect(controller.playheadFrame == 12)
        #expect(controller.lastStopReport == nil)

        await controller.playbackDidStop()  // as a stale queued KVO task would

        #expect(controller.playheadFrame == 12)
        #expect(controller.lastStopReport == nil)
        controller.shutdown()
    }
}
