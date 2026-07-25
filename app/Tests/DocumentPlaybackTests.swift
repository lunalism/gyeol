import AVFoundation
import Foundation
import GyeolCore
import GyeolPlayback
import Testing

// M2.1: a hand-written .gyeol fixture with a 30fps PROJECT holding a 24fps
// CLIP. §6.2's "never pass source rate and project rate through the same
// parameter" has had no consumer until this fixture: everything frame-
// related below must come from the PROJECT grid (d = 4000 ticks), and the
// source's 24fps (5005... no — 5000 ticks) must appear nowhere.

@MainActor
private func makeClip24(at url: URL, frames: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 180,
    ])
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = 24
    writer.movieTimeScale = 24
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
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
        let buffer = maybeBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + (n % 64)), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: 24)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

@MainActor
private struct MixedRateFixture {
    static let mediaIDString = "AAAAAAAA-2222-4222-8222-000000000001"
    let root: URL
    let packageURL: URL
    let mediaURL: URL
    let mediaID: MediaID

    /// The hand-written .gyeol body: 30fps project, one video track, one
    /// 24fps media clip starting at 0.5 s — the half second before it is
    /// the empty region the M2.1 render decision covers.
    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gyeol-m21-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        mediaURL = root.appendingPathComponent("clip24.mov")
        try await makeClip24(at: mediaURL, frames: 48)  // 2 s at 24fps
        mediaID = MediaID(rawValue: UUID(uuidString: Self.mediaIDString)!)

        let fingerprint = MediaResolver.fingerprint(of: mediaURL)!
        let body = """
        {
          "markers" : [],
          "media" : {
            "\(Self.mediaIDString)" : {
              "contentFingerprint" : {
                "byteSize" : \(fingerprint.byteSize),
                "value" : "\(fingerprint.value.base64EncodedString())"
              },
              "displayName" : "clip24.mov",
              "duration" : 240000,
              "relativePath" : "clip24.mov"
            }
          },
          "duration" : 360000,
          "schemaVersion" : { "major" : 1, "minor" : 0 },
          "settings" : { "frameRate" : "30", "renderHeight" : 180, "renderWidth" : 320 },
          "subtitleStyle" : {
            "fontSize" : 500,
            "outlineColor" : { "alpha" : 255, "blue" : 0, "green" : 0, "red" : 0 },
            "outlineWidth" : 40,
            "position" : { "x" : 5000, "y" : 9000 },
            "textColor" : { "alpha" : 255, "blue" : 255, "green" : 255, "red" : 255 }
          },
          "subtitles" : [],
          "tracks" : [
            {
              "clips" : [
                {
                  "audio" : { "fadeIn" : 0, "fadeOut" : 0, "volume" : 10000 },
                  "duration" : 240000,
                  "effects" : [],
                  "id" : "CCCCCCCC-2222-4222-8222-000000000001",
                  "source" : {
                    "kind" : "media",
                    "mediaID" : "\(Self.mediaIDString)",
                    "sourceStart" : 0
                  },
                  "timelineStart" : 60000
                }
              ],
              "id" : "BBBBBBBB-2222-4222-8222-000000000001",
              "isMuted" : false,
              "kind" : "video"
            }
          ]
        }
        """
        packageURL = root.appendingPathComponent("Mixed.gyeol")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: packageURL.appendingPathComponent("document.json"))
    }

    func open() throws -> GyeolDocumentFile {
        let file = GyeolDocumentFile()
        try file.read(from: try FileWrapper(url: packageURL), ofType: GyeolDocumentFile.documentType)
        return file
    }

    func resolvedURLs(for file: GyeolDocumentFile) throws -> [MediaID: URL] {
        var urls: [MediaID: URL] = [:]
        for (id, reference) in file.document.media {
            switch MediaResolver.resolve(reference: reference, bookmark: nil, packageURL: packageURL) {
            case .resolved(let url), .resolvedAndHealed(let url, _):
                urls[id] = url
            case .needsReconnect(let reason):
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "fixture media unresolvable: \(reason)"])
            }
        }
        return urls
    }
}

@Suite @MainActor struct DocumentPlaybackTests {
    /// The §6.2 consumer: everything on the project grid, nothing on the
    /// source grid.
    @Test func mixedRateFixtureBuildsOnTheProjectGrid() async throws {
        let fixture = try await MixedRateFixture()
        let file = try fixture.open()
        let urls = try fixture.resolvedURLs(for: file)

        // Sanity: the source really is 24fps…
        let sourceTrack = try await AVURLAsset(url: fixture.mediaURL)
            .loadTracks(withMediaType: .video).first!
        #expect(abs(try await sourceTrack.load(.nominalFrameRate) - 24) < 0.01)

        let built = try await CompositionBuilder.build(document: file.document, mediaURLs: urls)

        // …and the composition frames on the PROJECT grid: 1/30, not 1/24.
        #expect(built.videoComposition.frameDuration == CMTime(value: 1, timescale: 30))
        // The playable DOMAIN is the STORED duration (3 s) — trailing
        // space survives in the document and the transport domain. The
        // AVComposition itself ends at the content end (2.5 s): AVFoundation
        // discards trailing emptiness (measured at composition AND track
        // level) — rendering the trailing region needs content and lands on
        // M4's generator branch. See CompositionBuilder's comment.
        #expect(built.timelineEnd.ticks == 360_000)
        #expect(CMTimeCompare(built.composition.duration,
                              CMTime(value: 300_000, timescale: 120_000)) == 0)
        // Project-grid frame count: 3 s × 30 = 90. (On the source grid it
        // would be 72 — the wrong number this fixture exists to catch.)
        #expect(FrameMapping.frameCount(for: built.timelineEnd, rate: file.document.settings.frameRate) == 90)

        // Instruction coverage: [0, 0.5 s) empty then the clip — exactly
        // the composition's extent (instructions must cover the ASSET
        // domain; the trailing transport-only region has no asset to
        // instruct).
        let instructions = built.videoComposition.instructions
        #expect(instructions.count == 2)
        #expect(instructions[0].timeRange == CMTimeRange(
            start: .zero, end: CMTime(value: 60_000, timescale: 120_000)))
        #expect((instructions[0] as? AVVideoCompositionInstruction)?.layerInstructions.isEmpty == true)
        #expect((instructions[1] as? AVVideoCompositionInstruction)?.layerInstructions.count == 1)
    }

    @Test func fixtureLoadsAndStepsInThePlaybackController() async throws {
        let fixture = try await MixedRateFixture()
        let file = try fixture.open()
        let urls = try fixture.resolvedURLs(for: file)

        let controller = PlaybackController()
        await controller.load(document: file.document, mediaURLs: urls)
        #expect(controller.loadState == .ready)
        #expect(controller.projectRate == .fps30)
        #expect(controller.frameCount == 90)
        #expect(controller.playheadFrame == 0)

        await controller.step(by: 1)
        #expect(controller.playheadFrame == 1)
        await controller.step(by: 200)  // clamps to the stored duration
        #expect(controller.playheadFrame == 89)
    }

    @Test func emptyDocumentLoadsWithZeroFrames() async throws {
        let controller = PlaybackController()
        await controller.load(document: .empty, mediaURLs: [:])
        #expect(controller.loadState == .ready)
        #expect(controller.frameCount == 0)
    }

    /// Task 4: the untrusted-PTS rejection is counted and reaches the
    /// report — the condition (display PTS exactly on our own seek target,
    /// i.e. a frame CENTRE) cannot occur in healthy playback.
    @Test func untrustedDisplayPTSIsCountedAndReported() async throws {
        let controller = PlaybackController()
        // No media needed: a clipless document with a stored duration has a
        // playable domain (100 frames at 30fps).
        let document = GyeolDocument(
            schemaVersion: .current,
            settings: ProjectSettings(frameRate: .fps30, renderWidth: 320, renderHeight: 180),
            duration: DocumentTime(exactly: try RationalTime(value: 400_000, timescale: 120_000))!)
        await controller.load(document: document, mediaURLs: [:])
        #expect(controller.loadState == .ready)
        #expect(controller.untrustedDisplayPTSCount == 0)

        // The measured failure shape: the "display PTS" is our seek target
        // — frame 3's CENTRE, half a frame from any boundary.
        let echoedSeekTarget = CMTimeAdapter.cmTimeForSeek(toFrame: 3, projectRate: .fps30)
        let decision = controller.decideStopSnap(displayPTS: echoedSeekTarget)
        guard case .reject(let report) = decision else {
            Issue.record("expected rejection, got \(String(describing: decision))")
            return
        }
        #expect(report.contains("unreliable display PTS"))
        #expect(controller.untrustedDisplayPTSCount == 1)

        // A genuine frame boundary PTS is adopted and does not count.
        let boundary = CMTimeAdapter.cmTime(exactly: FrameMapping.time(ofFrame: 3, rate: .fps30))
        guard case .adopt(let frameIndex, _) = controller.decideStopSnap(displayPTS: boundary) else {
            Issue.record("expected adoption")
            return
        }
        #expect(frameIndex == 3)
        #expect(controller.untrustedDisplayPTSCount == 1)
    }

    /// Task 5 — SPEC DIVERGENCE, pinned deliberately. Empty-region rule 2
    /// says the trailing region (no track contributes) renders BLACK; but
    /// AVFoundation discards trailing emptiness, so the player's item ends
    /// at the CONTENT end and stepping into the trailing region HOLDS THE
    /// LAST FRAME today. M4's generator branch INVERTS this test: when
    /// trailing content exists, black must replace the hold — rewrite this
    /// test then, do not delete it.
    @Test func trailingRegionCurrentlyHoldsTheLastFrame_M4MustInvert() async throws {
        let fixture = try await MixedRateFixture()
        let file = try fixture.open()
        let urls = try fixture.resolvedURLs(for: file)
        let controller = PlaybackController()
        await controller.load(document: file.document, mediaURLs: urls)
        #expect(controller.loadState == .ready)

        // Step deep into the trailing region (content ends at frame 75,
        // domain runs to 90).
        await controller.step(by: 80)
        #expect(controller.playheadFrame == 80)
        // The divergence, in its measurable form: the transport domain
        // followed the document (90 frames), but the ITEM ends at the
        // content end (2.5 s) — there is nothing to decode past it, so the
        // display holds the last frame. (Measured note: currentTime()
        // reports the beyond-duration seek TARGET verbatim — the clock
        // walks off the end of the content, another reason it is never
        // frame evidence.)
        let contentEnd = CMTime(value: 300_000, timescale: 120_000)
        #expect(controller.frameCount == 90)
        let itemDuration = try #require(controller.player.currentItem).duration
        #expect(CMTimeCompare(itemDuration, contentEnd) == 0)
    }

    /// D25: the Swift constant is the authority; project.yml's anchored
    /// declaration must stay identical. This test is the enforcement the
    /// hand-synchronized comment never had (G13).
    @Test func utiDeclarationsShareOneValue() throws {
        let projectYML = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .appendingPathComponent("project.yml")
        let text = try String(contentsOf: projectYML, encoding: .utf8)
        let occurrences = text.components(separatedBy: GyeolDocumentFile.documentType).count - 1
        #expect(occurrences >= 1, "project.yml no longer declares \(GyeolDocumentFile.documentType)")
        // The anchor must be the one place the literal appears; the UTI
        // declaration references it (*gyeolUTI), so a SECOND literal means
        // the anchor discipline broke.
        #expect(occurrences == 1,
                "UTI literal appears \(occurrences)× in project.yml — the YAML anchor is being bypassed")
        #expect(text.contains("&gyeolUTI"), "the D25 anchor is gone")
        #expect(text.contains("*gyeolUTI"), "the D25 anchor reference is gone")
    }
}
