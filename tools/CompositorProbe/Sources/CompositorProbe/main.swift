import AVFoundation
import CoreVideo
import Foundation
import GyeolCore
import GyeolPlayback

// M1.4: (1) L2 skeleton — hash render output through the preview and export
// configurations, compare bit-for-bit. (2) Does 1080p hold 60fps through
// the custom compositor, and where does the time go?

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer even when redirected

/// Forces the async (completion-awaiting) seek overload: in top-level code
/// the unused-result call binds to the synchronous fire-and-forget seek,
/// which poisons per-frame attribution.
@discardableResult
func preciseSeek(_ player: AVPlayer, to time: CMTime) async -> Bool {
    await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
}

func seconds(_ d: Duration) -> Double {
    // components.attoseconds is only the FRACTIONAL part — dropping
    // .seconds turned the realtime loop's clock into a sawtooth under 1s
    // and it never terminated. Both parts, always.
    Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
}

struct RateSpec {
    let label: String
    let rate: FrameRate
    let frameDuration: CMTime
    let frameCount: Int
}

let specs: [RateSpec] = [
    .init(label: "60",    rate: .fps60,    frameDuration: CMTime(value: 1, timescale: 60),        frameCount: 240),
    .init(label: "29.97", rate: .fps29_97, frameDuration: CMTime(value: 1001, timescale: 30_000), frameCount: 120),
]

func generateClip(spec: RateSpec, at url: URL) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1080,
    ])
    input.expectsMediaDataInRealTime = false
    input.mediaTimeScale = spec.frameDuration.timescale
    writer.movieTimeScale = spec.frameDuration.timescale
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ])
    writer.add(input)
    guard writer.startWriting() else { fatalError("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for n in 0..<spec.frameCount {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
        let buffer = maybeBuffer!
        // Content must differ per frame so per-frame hashes discriminate —
        // ROBUSTLY. The original gray ramp (level = n) did not survive
        // H.264: quantization collapsed 31 of 240 adjacent pairs into
        // byte-identical decoded frames (measured when hashes became the
        // frame-identity oracle). Encode the index as 8 horizontal bands
        // of extreme-contrast bits instead; large flat blocks at 30/220
        // survive any reasonable encoder.
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bandHeight = height / 8
        for band in 0..<8 {
            let value: Int32 = (n >> band) & 1 == 1 ? 220 : 30
            let start = band * bandHeight
            let end = band == 7 ? height : start + bandHeight
            memset(base + start * bytesPerRow, value, (end - start) * bytesPerRow)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(spec.frameDuration, multiplier: Int32(n))) else {
            fatalError("append: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { fatalError("finish: \(String(describing: writer.error))") }
}

func makeVideoComposition(track: AVAssetTrack, spec: RateSpec, duration: CMTime) -> AVMutableVideoComposition {
    let composition = AVMutableVideoComposition()
    composition.customVideoCompositorClass = PassthroughCompositor.self
    composition.frameDuration = spec.frameDuration
    composition.renderSize = CGSize(width: 1920, height: 1080)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
    instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
    composition.instructions = [instruction]
    return composition
}

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("  ✘ \(message)")
    }
}

let mediaDir = FileManager.default.temporaryDirectory.appendingPathComponent("gyeol-compositor-probe")
try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

let onlyLabel = CommandLine.arguments.dropFirst().first
let activeSpecs = onlyLabel.map { label in specs.filter { $0.label == label } } ?? specs
for spec in activeSpecs {
    let url = mediaDir.appendingPathComponent("clip-\(spec.label).mov")
    print("== \(spec.label) fps 1080p: generating…")
    try await generateClip(spec: spec, at: url)

    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let track = try await asset.loadTracks(withMediaType: .video).first!
    let videoComposition = makeVideoComposition(track: track, spec: spec, duration: duration)

    // ---- Export configuration: AVAssetReader pulling every frame through
    // the compositor, exactly the M5 export path shape.
    _ = PassthroughCompositor.snapshotAndResetStats()
    var exportHashes: [Int: Data] = [:]
    let readerStart = ContinuousClock.now
    do {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: nil)
        output.videoComposition = videoComposition
        reader.add(output)
        reader.startReading()
        while let sample = output.copyNextSampleBuffer() {
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: pts, projectRate: spec.rate) else { continue }
            exportHashes[snap.frameIndex] = PixelBufferHash.hash(imageBuffer)
        }
        guard reader.status == .completed else { fatalError("reader: \(String(describing: reader.error))") }
    }
    let readerElapsed = seconds(readerStart.duration(to: .now))
    let exportStats = PassthroughCompositor.snapshotAndResetStats()
    print("  export path: \(exportHashes.count) frames in \(String(format: "%.2f", readerElapsed))s (\(String(format: "%.1f", Double(exportHashes.count) / readerElapsed)) fps offline)")
    check(exportHashes.count == spec.frameCount, "export produced \(exportHashes.count) frames, expected \(spec.frameCount)")

    // ---- Preview configuration: AVPlayerItem + video output, seeking to
    // frame centres through the adapter — the preview path shape.
    let item = AVPlayerItem(asset: asset)
    item.videoComposition = videoComposition
    let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: PassthroughCompositor.pixelFormat
    ])
    item.add(videoOutput)
    let player = AVPlayer(playerItem: item)
    var waited = 0
    while item.status != .readyToPlay {
        if item.status == .failed { fatalError("item failed: \(String(describing: item.error))") }
        try await Task.sleep(nanoseconds: 50_000_000)
        waited += 1
        if waited > 200 { fatalError("player never ready") }
    }

    // Principle 7.4-8 applies to the PROBE too: hashing whatever buffer the
    // poll happens to catch is confirming a frame without evidence it is
    // the right frame — under load the output can still be vending the
    // PREVIOUS seek's frame, and one stale buffer turns this gate into a
    // false failure people learn to rerun (measured: 1 of 7 runs, frames
    // 1–3, under concurrent GPU load).
    //
    // The evidence CANNOT be itemTimeForDisplay in this harness. Measured
    // while fixing this: with a paused zero-tolerance seek and no renderer
    // attached, the output vends buffers whose itemTimeForDisplay simply
    // ECHOES the requested item time — our own frame-centre seek target
    // (e.g. 2000/240000 for frame 0 at 60fps, our adapter's timescale).
    // The same echo A-36 recorded under decoder failure is this
    // configuration's NORMAL behavior, so the display time carries zero
    // information about which frame the bytes are.
    //
    // Identity therefore comes from CONTENT: the fixture writes a distinct
    // gray level per frame, and the export table is PTS-labeled by
    // AVAssetReader (an asset-timescale source §5.6.1 lists as reliable),
    // so a buffer's hash identifies its frame exactly. A stale vend is
    // rejected and re-sought; bytes that match NO export frame are the
    // real L2 signal and fail; a frame that never confirms fails loudly.
    // Nothing is hashed into the comparison unidentified.
    var frameForExportHash: [Data: Int] = [:]
    for (frame, hash) in exportHashes {
        if let duplicate = frameForExportHash[hash] {
            check(false, "fixture content does not discriminate frames \(duplicate) and \(frame)")
        }
        frameForExportHash[hash] = frame
    }

    var compared = 0
    var mismatches = 0
    var rejectedStaleVends = 0
    for index in stride(from: 0, to: spec.frameCount, by: 1) {
        enum PreviewOutcome {
            case match
            case divergent
            case unconfirmed
        }
        var outcome = PreviewOutcome.unconfirmed
        var seekAttempts = 0
        attempts: while seekAttempts < 3 {
            seekAttempts += 1
            await preciseSeek(player, to: CMTimeAdapter.cmTimeForSeek(toFrame: index, projectRate: spec.rate))
            for _ in 0..<100 {
                let t = player.currentTime()
                if videoOutput.hasNewPixelBuffer(forItemTime: t),
                   let buffer = videoOutput.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                    guard let bufferHash = PixelBufferHash.hash(buffer) else {
                        // Unhashable vend (lock failure): consumed without
                        // identification — same treatment as stale, retry.
                        rejectedStaleVends += 1
                        continue attempts
                    }
                    switch frameForExportHash[bufferHash] {
                    case index:
                        outcome = .match
                        break attempts
                    case .some:
                        // A stale vend of a DIFFERENT frame. (A systematic
                        // off-by-one compositor bug also lands here — and
                        // exhausts the attempts into the loud unconfirmed
                        // failure below, never a silent pass.)
                        rejectedStaleVends += 1
                        continue attempts
                    case nil:
                        // Bytes no export frame produced: the divergence
                        // L2 exists to catch.
                        outcome = .divergent
                        break attempts
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        switch outcome {
        case .match:
            compared += 1
        case .divergent:
            compared += 1
            mismatches += 1
            if mismatches <= 3 {
                print("  ✘ L2 mismatch at frame \(index): preview bytes match no export frame")
            }
        case .unconfirmed:
            check(false, """
            frame \(index): no buffer confirmed as frame \(index) after \
            \(seekAttempts) seeks (stale vends so far: \(rejectedStaleVends))
            """)
        }
    }
    check(mismatches == 0, "L2: \(mismatches)/\(compared) frames differ between configurations")
    print("  L2: \(compared) frames compared, \(mismatches) mismatches, \(rejectedStaleVends) stale vends rejected")

    // ---- Real-time: play and count distinct frames actually delivered.
    _ = PassthroughCompositor.snapshotAndResetStats()
    await preciseSeek(player, to: CMTimeAdapter.cmTimeForSeek(toFrame: 0, projectRate: spec.rate))
    var deliveredPTS = Set<CMTimeValue>()
    player.play()
    let playStart = ContinuousClock.now
    let playSeconds = 3.5
    while seconds(playStart.duration(to: .now)) < playSeconds {
        let t = player.currentTime()
        if videoOutput.hasNewPixelBuffer(forItemTime: t),
           let _ = videoOutput.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
            deliveredPTS.insert(t.value)  // ns-scale clock: unique per poll hit
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    player.pause()
    let playStats = PassthroughCompositor.snapshotAndResetStats()
    let requestRate = Double(playStats.requestCount) / playSeconds
    print("""
      realtime: compositor served \(playStats.requestCount) requests in \(playSeconds)s → \(String(format: "%.1f", requestRate)) fps \
    (target \(spec.label)); compositor time avg \(String(format: "%.3f", playStats.requestCount > 0 ? playStats.totalSeconds / Double(playStats.requestCount) * 1000 : 0))ms, \
    max \(String(format: "%.3f", playStats.maxSeconds * 1000))ms, total \(String(format: "%.1f", playStats.totalSeconds * 1000))ms
    """)
    let targetFPS = Double(spec.label) ?? 29.97
    check(requestRate > targetFPS * 0.95, "compositor request rate \(requestRate) below target \(targetFPS)")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
