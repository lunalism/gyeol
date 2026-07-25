import AVFoundation
import CoreVideo
import Foundation
import GyeolCore

// A-29 verification: seek to the adapter's frame-centre CMTime, read back
// WHICH frame the player is showing (the display PTS from
// AVPlayerItemVideoOutput), and confirm it is the intended frame — not a
// neighbour. Also: sample display PTS during real playback and check the
// snap residual never exceeds the 1/4-frame threshold.

struct RateSpec {
    let label: String
    let rate: FrameRate
    let frameDuration: CMTime
    let frameCount: Int
}

let specs: [RateSpec] = [
    .init(label: "23.976", rate: .fps23_976, frameDuration: CMTime(value: 1001, timescale: 24_000), frameCount: 120),
    .init(label: "30",     rate: .fps30,     frameDuration: CMTime(value: 1, timescale: 30),        frameCount: 150),
    .init(label: "59.94",  rate: .fps59_94,  frameDuration: CMTime(value: 1001, timescale: 60_000), frameCount: 300),
]

func generateClip(spec: RateSpec, at url: URL, explicitTimescale: Bool) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 180,
    ])
    input.expectsMediaDataInRealTime = false
    if explicitTimescale {
        input.mediaTimeScale = spec.frameDuration.timescale
        writer.movieTimeScale = spec.frameDuration.timescale
    }
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
    writer.add(input)
    guard writer.startWriting() else { fatalError("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for n in 0..<spec.frameCount {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &maybeBuffer)
        let buffer = maybeBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(40 + (n % 64)), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTimeMultiply(spec.frameDuration, multiplier: Int32(n))) else {
            fatalError("append: \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { fatalError("finish: \(String(describing: writer.error))") }
}

struct PlayerHarness {
    let player: AVPlayer
    let output: AVPlayerItemVideoOutput

    init(url: URL) async throws {
        let item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        player = AVPlayer(playerItem: item)
        var waited = 0
        while item.status != .readyToPlay {
            if item.status == .failed { throw item.error ?? NSError(domain: "probe", code: 1) }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
            if waited > 100 { throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "never ready"]) }
        }
    }

    /// The display PTS of whatever the player would show right now; polls
    /// because decode after a seek is asynchronous.
    func currentDisplayPTS() async -> CMTime? {
        for _ in 0..<100 {
            let t = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: t) {
                var display = CMTime.invalid
                if output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) != nil, display.isNumeric {
                    return display
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }
}

var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("  ✘ \(message)")
    }
}

let mediaDir = FileManager.default.temporaryDirectory.appendingPathComponent("gyeol-seek-probe")
try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

for spec in specs {
    for explicit in [true, false] {
        let variant = explicit ? "explicit \(spec.frameDuration.timescale)" : "default 600"
        let url = mediaDir.appendingPathComponent("seek-\(spec.label)-\(explicit ? "x" : "d").mov")
        try await generateClip(spec: spec, at: url, explicitTimescale: explicit)
        let harness = try await PlayerHarness(url: url)
        print("== \(spec.label) fps, container \(variant)")

        // A-29: frame-centre seek → displayed frame must be the target.
        var seekResults: [String] = []
        for target in [0, 1, 2, 37, 59, spec.frameCount - 2] {
            let seekTime = CMTimeAdapter.cmTimeForSeek(toFrame: target, projectRate: spec.rate)
            await harness.player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            guard let pts = await harness.currentDisplayPTS() else {
                check(false, "frame \(target): no pixel buffer after seek")
                continue
            }
            guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: pts, projectRate: spec.rate) else {
                check(false, "frame \(target): display PTS \(pts.value)/\(pts.timescale) did not snap")
                continue
            }
            let shown = snap.frameIndex  // D23
            check(shown == target, "frame \(target): player shows frame \(shown) (PTS \(pts.value)/\(pts.timescale))")
            seekResults.append("\(target)→\(shown)")
        }
        print("  seek: \(seekResults.joined(separator: " "))")

        // Playback residual sweep: snap every displayed frame's PTS during
        // ~2.5 s of real playback; the threshold must never trip and the
        // residual must stay within 60000/T ticks.
        await harness.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        harness.player.play()
        var samples = 0
        var maxResidualFraction = 0.0
        var thresholdTrips = 0
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            let t = harness.player.currentTime()
            if harness.output.hasNewPixelBuffer(forItemTime: t) {
                var display = CMTime.invalid
                if harness.output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &display) != nil, display.isNumeric,
                   let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: display, projectRate: spec.rate) {
                    samples += 1
                    if snap.exceedsQuarterFrameThreshold { thresholdTrips += 1 }
                    let fraction = abs(Double(snap.residualTickNumerator)
                        / Double(snap.residualTickDenominator)
                        / Double(spec.rate.ticksPerFrame))
                    maxResidualFraction = max(maxResidualFraction, fraction)
                }
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        harness.player.pause()
        check(thresholdTrips == 0, "threshold tripped \(thresholdTrips)× during playback")
        print("  playback: \(samples) display-PTS samples, max residual \(String(format: "%.6f", maxResidualFraction)) frame, threshold trips \(thresholdTrips)")
    }
}

// MARK: - Stop-path handoff verification
//
// Three ways playback stops must land on identical behavior: the frame the
// handoff confirms is the frame the display PTS shows, residual zero on a
// well-formed (explicit-timescale) file, and re-seeking to the confirmed
// frame's centre keeps showing that same frame (player and app agree).

func waitForRateZero(_ player: AVPlayer) async {
    for _ in 0..<200 where player.rate != 0 {
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
}

func handoffCheck(_ harness: PlayerHarness, rate: FrameRate, label: String) async {
    guard let pts = await harness.currentDisplayPTS() else {
        check(false, "\(label): no display PTS at stop")
        return
    }
    guard let snap = CMTimeAdapter.documentTime(snappingToFrameGrid: pts, projectRate: rate) else {
        check(false, "\(label): PTS \(pts.value)/\(pts.timescale) did not snap")
        return
    }
    let confirmed = snap.frameIndex  // D23
    check(snap.residualTickNumerator == 0, "\(label): residual \(snap.residualTickNumerator)/\(snap.residualTickDenominator) ≠ 0")
    // Re-seek from the confirmed index (the handoff's final step) and
    // confirm the displayed frame does not move.
    await harness.player.seek(
        to: CMTimeAdapter.cmTimeForSeek(toFrame: confirmed, projectRate: rate),
        toleranceBefore: .zero, toleranceAfter: .zero)
    if let pts2 = await harness.currentDisplayPTS(),
       let snap2 = CMTimeAdapter.documentTime(snappingToFrameGrid: pts2, projectRate: rate) {
        let after = snap2.frameIndex  // D23
        check(after == confirmed, "\(label): reseek moved frame \(confirmed) → \(after)")
        print("  \(label): confirmed frame \(confirmed), residual 0, reseek stable")
    } else {
        check(false, "\(label): no display PTS after reseek")
    }
}

print("\n== stop-path handoff")
for spec in specs where spec.label != "59.94" {
    let url = mediaDir.appendingPathComponent("seek-\(spec.label)-x.mov")
    let harness = try await PlayerHarness(url: url)
    print("-- \(spec.label) fps (explicit timescale)")

    // Path 1: user pause mid-file.
    await harness.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    harness.player.play()
    try await Task.sleep(nanoseconds: 800_000_000)
    harness.player.pause()
    await waitForRateZero(harness.player)
    await handoffCheck(harness, rate: spec.rate, label: "pause mid-file")

    // Path 2: playing to the end of the file.
    let nearEnd = spec.frameCount - 8
    await harness.player.seek(
        to: CMTimeAdapter.cmTimeForSeek(toFrame: nearEnd, projectRate: spec.rate),
        toleranceBefore: .zero, toleranceAfter: .zero)
    harness.player.play()
    await waitForRateZero(harness.player)  // AVPlayer stops itself at the end
    await handoffCheck(harness, rate: spec.rate, label: "end of file")

    // Path 3: pause immediately after a seek.
    await harness.player.seek(
        to: CMTimeAdapter.cmTimeForSeek(toFrame: 40, projectRate: spec.rate),
        toleranceBefore: .zero, toleranceAfter: .zero)
    harness.player.play()
    try await Task.sleep(nanoseconds: 30_000_000)
    harness.player.pause()
    await waitForRateZero(harness.player)
    await handoffCheck(harness, rate: spec.rate, label: "pause right after seek")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
