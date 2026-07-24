import AVFoundation
import Foundation
import GyeolCore
import Testing

/// F1 — the interleaving that is hardest to hit by accident and easiest to
/// reintroduce: a stop event queued by KVO, with playback resuming before
/// the queued handoff task runs. The stale handoff must be VOID (PRD 7.4-8:
/// a handoff interrupted by playback resuming is void), not applied late.
@MainActor
private func makeClip(at url: URL, frames: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 180,
    ])
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 30
    writer.movieTimeScale = 30
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for n in 0..<frames {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
        let buffer = maybeBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + (n % 64)), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 30)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

@Suite @MainActor struct TransportRaceTests {
    /// Driven by direct invocation, not by waiting on real playback: the
    /// headless test host cannot sustain AVPlayer decode (FigFilePlayer
    /// -12860), so timing-based reproduction is environment-dependent.
    /// Calling `playbackDidStop()` while the player's rate is nonzero IS
    /// the stale queued task, byte for byte — the KVO closure does nothing
    /// but schedule exactly this call.
    @Test func staleStopEventIsVoidedWhenPlaybackResumes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-transport-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clip.mov")
        try await makeClip(at: url, frames: 120)  // 4 s at 30 fps

        let controller = PlaybackController()
        await controller.open(url: url)
        #expect(controller.loadState == .ready)

        // THE interleaving: pause queued a handoff, play resumed before it
        // ran. At the moment the stale handoff finally runs, the app is
        // playing again (isPlaying true, rate nonzero) — it must apply
        // NOTHING (PRD 7.4-8: a handoff interrupted by resume is void).
        controller.togglePlayPause()  // play: isPlaying = true, rate → 1
        #expect(controller.isPlaying)
        #expect(controller.player.rate != 0)
        let playheadBefore = controller.playheadFrame

        await controller.playbackDidStop()  // the stale queued task, running late

        #expect(controller.isPlaying, "stale stop handoff flipped state while playing")
        #expect(controller.player.rate != 0, "player was yanked out of playback")
        #expect(controller.playheadFrame == playheadBefore,
                "stale handoff moved the playhead")
        #expect(controller.lastPauseReport == nil, "stale handoff produced a report")

        // Contrast: a REAL stop (rate actually 0) still hands off end to end.
        controller.player.pause()  // what the pause action does
        await controller.playbackDidStop()  // the genuinely-queued task
        #expect(!controller.isPlaying)
        #expect(controller.lastPauseReport != nil)
    }
}
