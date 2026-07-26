import AVFoundation
import Foundation
import GyeolCore
import Testing

// M2.2 timeline tests — the SYNCHRONOUS halves only. Async tile arrival and
// display-link behavior are exercised in the running app: PRD 부록 A-36
// measured headless xctest not running/cancelling main-queue work for
// windowless SwiftUI, and the same trap applies to anything awaiting a
// repaint here.

@Suite struct TimelineViewportTests {
    @Test func viewportRelativeXStaysSmallAtThreeHours() {
        // 3 h ≈ 1.296e9 ticks — far beyond float32's 1.67e7 exact-integer
        // range. The viewport-relative x must come out at screen magnitude
        // with the Int64 subtraction done BEFORE any floating point.
        let threeHoursTicks: Int64 = 10_800 * 120_000
        let viewport = TimelineViewport(
            visibleStartTicks: threeHoursTicks - 1_000, ticksPerPoint: 40)
        let x = viewport.x(ofTicks: threeHoursTicks)
        #expect(x == 25.0)
        // The Float the GPU sees is exact at this magnitude.
        #expect(Double(Float(x)) == x)
    }

    @Test func ticksAtXRoundTripsAndClampsAtZero() {
        let viewport = TimelineViewport(visibleStartTicks: 240_000, ticksPerPoint: 100)
        #expect(viewport.ticks(atX: 10) == 241_000)
        #expect(viewport.x(ofTicks: 241_000) == 10)
        // Pointer left of the timeline origin clamps to zero, not negative.
        #expect(viewport.ticks(atX: -10_000) == 0)
    }

    @Test func panClampsAtOrigin() {
        var viewport = TimelineViewport(visibleStartTicks: 500, ticksPerPoint: 100)
        viewport.pan(byPoints: -1_000)
        #expect(viewport.visibleStartTicks == 0)
        viewport.pan(byPoints: 3)
        #expect(viewport.visibleStartTicks == 300)
    }

    @Test func zoomKeepsAnchorStationary() {
        var viewport = TimelineViewport(visibleStartTicks: 1_000_000, ticksPerPoint: 1_000)
        let anchorX = 300.0
        let anchorTicksBefore = viewport.ticks(atX: anchorX)
        viewport.zoom(by: 0.5, anchorX: anchorX)
        let anchorTicksAfter = viewport.ticks(atX: anchorX)
        // Within one tick of rounding.
        #expect(abs(anchorTicksAfter - anchorTicksBefore) <= 1)
    }

    @Test func zoomClampsToBounds() {
        var viewport = TimelineViewport(visibleStartTicks: 0, ticksPerPoint: 100)
        viewport.zoom(by: 1e-9, anchorX: 0)
        #expect(viewport.ticksPerPoint == TimelineViewport.minTicksPerPoint)
        viewport.zoom(by: 1e12, anchorX: 0)
        #expect(viewport.ticksPerPoint == TimelineViewport.maxTicksPerPoint)
    }
}

@Suite @MainActor struct WaveformStoreTests {
    private func makeMeta(peakCount: Int) -> WaveformStore.Meta {
        WaveformStore.Meta(
            sampleRate: 48_000,
            sampleCount: Int64(peakCount) * Int64(WaveformStore.samplesPerPeakBase),
            levelCount: 1)
    }

    @Test func tileAddressingReturnsTheRightSlice() {
        let store = WaveformStore()
        let peakCount = WaveformStore.peaksPerTile * 2 + 100
        let peaks = (0..<peakCount).map {
            WaveformStore.Peak(minValue: Int16(-($0 % 1_000)), maxValue: Int16($0 % 1_000))
        }
        store.injectForTesting(
            mediaKey: "test", meta: makeMeta(peakCount: peakCount), levelPeaks: [peaks])
        let url = URL(fileURLWithPath: "/dev/null")
        let tile1 = store.tile(mediaKey: "test", level: 0, index: 1, mediaURL: url)
        #expect(tile1?.count == WaveformStore.peaksPerTile)
        #expect(tile1?.first?.maxValue == Int16(WaveformStore.peaksPerTile % 1_000))
        let tail = store.tile(mediaKey: "test", level: 0, index: 2, mediaURL: url)
        #expect(tail?.count == 100)
    }

    @Test func evictionHoldsTheMemoryBound() {
        let store = WaveformStore()
        // 9,000 full tiles ≈ 36.9 MB — past the 32 MiB bound.
        let tileCount = 9_000
        let peaks = [WaveformStore.Peak](
            repeating: WaveformStore.Peak(minValue: -1, maxValue: 1),
            count: tileCount * WaveformStore.peaksPerTile)
        store.injectForTesting(
            mediaKey: "big",
            meta: makeMeta(peakCount: peaks.count),
            levelPeaks: [peaks])
        #expect(store.residentTileBytesForTesting <= WaveformStore.memoryLimitBytes)
        // And the bound did not empty the cache — recent tiles survive.
        #expect(store.residentTileBytesForTesting > WaveformStore.memoryLimitBytes / 2)
    }
}

@Suite @MainActor struct ScrubTests {
    private func loadedController() async throws -> (PlaybackController, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-scrub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let clipURL = dir.appendingPathComponent("clip.mov")
        try await makeScrubClip(at: clipURL, frames: 90)

        let mediaID = MediaID()
        let document = GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps30, renderWidth: 320, renderHeight: 180),
            media: [mediaID: MediaReference(
                relativePath: "clip.mov", displayName: "clip.mov",
                duration: DocumentTime(ticks: 360_000))],
            tracks: [Track(id: TrackID(), kind: .video, clips: [
                Clip(
                    id: ClipID(),
                    timelineStart: .zero,
                    duration: DocumentTime(ticks: 360_000),
                    source: .media(MediaSource(mediaID: mediaID, sourceStart: .zero)))
            ])])
        let controller = PlaybackController()
        await controller.load(document: document, mediaURLs: [mediaID: clipURL])
        #expect(controller.loadState == .ready)
        return (controller, dir)
    }

    private func awaitScrubQuiescence(_ controller: PlaybackController, target: Int) async {
        // The pump serializes seeks; wait for the player to land. Bounded,
        // not timing-sensitive: each iteration yields to the pump task.
        for _ in 0..<200 where controller.clockDisplay != "frame \(target)" {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test func scrubMovesAndClampsThePlayhead() async throws {
        let (controller, dir) = try await loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.beginScrub()
        controller.scrub(toFrame: 10)
        controller.scrub(toFrame: -5)
        #expect(controller.playheadFrame == 0)
        controller.scrub(toFrame: 10_000)
        #expect(controller.playheadFrame == controller.frameCount - 1)
        controller.scrub(toFrame: 42)
        controller.endScrub()
        #expect(controller.playheadFrame == 42)
        // Stopped: the timeline draws the authoritative playhead.
        #expect(controller.timelinePlayheadFrame == 42)
        await awaitScrubQuiescence(controller, target: 42)
        #expect(controller.clockDisplay == "frame 42")
        controller.shutdown()
    }

    /// A 60 Hz drag must coalesce, not queue: the pump issues at most one
    /// seek at a time, always to the latest target, so the seek count
    /// stays far below the event count.
    @Test func scrubCoalescesSeeksUnderRapidEvents() async throws {
        let (controller, dir) = try await loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.beginScrub()
        for frame in 0..<60 {
            controller.scrub(toFrame: frame)
        }
        controller.endScrub()
        #expect(controller.playheadFrame == 59)
        await awaitScrubQuiescence(controller, target: 59)
        #expect(controller.clockDisplay == "frame 59")
        // 60 events → a handful of serialized seeks. The exact number is
        // scheduling-dependent; the CONTRACT is "far fewer than events".
        #expect(controller.scrubSeekCount < 30)
        controller.shutdown()
    }

    @Test func scrubWithoutALoadedDocumentIsANoOp() {
        let controller = PlaybackController()
        controller.beginScrub()
        controller.scrub(toFrame: 10)
        controller.endScrub()
        #expect(controller.playheadFrame == 0)
    }
}

@MainActor
private func makeScrubClip(at url: URL, frames: Int) async throws {
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
