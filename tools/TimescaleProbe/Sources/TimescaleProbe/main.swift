import AVFoundation
import CoreVideo
import Foundation
import GyeolCore

// M1 kickoff measurement: what timescales does AVFoundation actually hand us,
// and what does a round trip through them do to 120000-tick frame boundaries?
// Disposable. Output is data (a markdown report), not a feature.

enum ProbeError: Error, CustomStringConvertible {
    case writerFailed(String)
    case noVideoTrack(String)
    case playerTimeout
    case message(String)

    var description: String {
        switch self {
        case .writerFailed(let m): "writer failed: \(m)"
        case .noVideoTrack(let m): "no video track in \(m)"
        case .playerTimeout: "player never became readyToPlay"
        case .message(let m): m
        }
    }
}

struct RateSpec {
    let label: String
    let gyeolRate: FrameRate
    let frameDuration: CMTime  // exact rational, never a Double-derived value
    let frameCount: Int        // ~5 seconds
}

let specs: [RateSpec] = [
    .init(label: "23.976", gyeolRate: .fps23_976, frameDuration: CMTime(value: 1001, timescale: 24_000), frameCount: 120),
    .init(label: "24",     gyeolRate: .fps24,     frameDuration: CMTime(value: 1, timescale: 24),        frameCount: 120),
    .init(label: "25",     gyeolRate: .fps25,     frameDuration: CMTime(value: 1, timescale: 25),        frameCount: 125),
    .init(label: "29.97",  gyeolRate: .fps29_97,  frameDuration: CMTime(value: 1001, timescale: 30_000), frameCount: 150),
    .init(label: "30",     gyeolRate: .fps30,     frameDuration: CMTime(value: 1, timescale: 30),        frameCount: 150),
    .init(label: "50",     gyeolRate: .fps50,     frameDuration: CMTime(value: 1, timescale: 50),        frameCount: 250),
    .init(label: "59.94",  gyeolRate: .fps59_94,  frameDuration: CMTime(value: 1001, timescale: 60_000), frameCount: 300),
    .init(label: "60",     gyeolRate: .fps60,     frameDuration: CMTime(value: 1, timescale: 60),        frameCount: 300),
]

func fmt(_ t: CMTime) -> String {
    guard t.isValid else { return "invalid" }
    return "\(t.value)/\(t.timescale)"
}

// MARK: - Clip generation

func generateClip(spec: RateSpec, at url: URL, explicitTimescale: Bool) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 640,
        AVVideoHeightKey: 360,
    ])
    input.expectsMediaDataInRealTime = false
    if explicitTimescale {
        // Without this, the first probe run showed AVAssetWriter quantizing
        // every track to the QuickTime default 600 — NTSC PTS (1001/24000)
        // do not survive that. This variant pins the media timescale to the
        // rate's exact denominator to separate "default" from "forced".
        input.mediaTimeScale = spec.frameDuration.timescale
        writer.movieTimeScale = spec.frameDuration.timescale
    }
    // sourcePixelBufferAttributes gives the adaptor a pool to vend buffers from.
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360,
        ])
    writer.add(input)
    guard writer.startWriting() else {
        throw ProbeError.writerFailed(writer.error.map(String.init(describing:)) ?? "startWriting")
    }
    writer.startSession(atSourceTime: .zero)

    for n in 0..<spec.frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else {
            throw ProbeError.writerFailed("no pixel buffer pool")
        }
        var maybeBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard let buffer = maybeBuffer else {
            throw ProbeError.writerFailed("pool returned no buffer")
        }
        // Content is irrelevant — the timestamps are the experiment. Vary the
        // gray per frame only so the encoder does not collapse everything
        // into a single I-frame with zero-size deltas.
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(40 + (n % 64)), CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // PTS = N * frameDuration in the rate's own exact timescale.
        let pts = CMTimeMultiply(spec.frameDuration, multiplier: Int32(n))
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw ProbeError.writerFailed(writer.error.map(String.init(describing:)) ?? "append")
        }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw ProbeError.writerFailed(writer.error.map(String.init(describing:)) ?? "status \(writer.status.rawValue)")
    }
}

// MARK: - Asset probing

struct AssetProbe {
    var name: String
    var naturalTimeScale: CMTimeScale = 0
    var nominalFrameRate: Float = 0
    var minFrameDuration: CMTime = .invalid
    var duration: CMTime = .invalid
    var readerPTS: [CMTime] = []
    var pausedTimes: [CMTime] = []
    var pausedAfterPlayTimes: [CMTime] = []
    var playingTimes: [CMTime] = []
    var displayTimes: [(item: CMTime, display: CMTime)] = []
    var notes: [String] = []
}

func probeAsset(url: URL, name: String) async throws -> AssetProbe {
    var probe = AssetProbe(name: name)
    let asset = AVURLAsset(url: url)
    probe.duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw ProbeError.noVideoTrack(name) }
    let (naturalTimeScale, nominalFrameRate, minFrameDuration) =
        try await track.load(.naturalTimeScale, .nominalFrameRate, .minFrameDuration)
    probe.naturalTimeScale = naturalTimeScale
    probe.nominalFrameRate = nominalFrameRate
    probe.minFrameDuration = minFrameDuration

    // AVAssetReader: raw sample-buffer PTS, first 10 frames. outputSettings
    // nil = no decode, so the PTS come straight from the container.
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    reader.startReading()
    while probe.readerPTS.count < 10, let sample = output.copyNextSampleBuffer() {
        probe.readerPTS.append(CMSampleBufferGetPresentationTimeStamp(sample))
    }
    reader.cancelReading()

    // AVPlayer: timescale of currentTime() paused and playing, plus the
    // display timestamps AVPlayerItemVideoOutput reports with copied buffers.
    do {
        let item = AVPlayerItem(url: url)
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(videoOutput)
        let player = AVPlayer(playerItem: item)
        var waited = 0
        while item.status != .readyToPlay {
            if item.status == .failed {
                throw item.error ?? ProbeError.message("player item failed")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
            if waited > 100 { throw ProbeError.playerTimeout }
        }
        for _ in 0..<3 {
            probe.pausedTimes.append(player.currentTime())
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        player.play()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && probe.displayTimes.count < 6 {
            let itemTime = player.currentTime()
            probe.playingTimes.append(itemTime)
            if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) != nil {
                    probe.displayTimes.append((item: itemTime, display: displayTime))
                }
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        player.pause()
        // Paused-before-play reads 0/1 (the CMTime.zero constant), which
        // says nothing; the meaningful paused timescale is after playback.
        for _ in 0..<3 {
            probe.pausedAfterPlayTimes.append(player.currentTime())
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if probe.displayTimes.isEmpty {
            probe.notes.append("AVPlayerItemVideoOutput returned no pixel buffers in 2s of headless playback — display timestamps NOT measured for this asset")
        }
    } catch {
        probe.notes.append("player probe failed (\(error)) — player timescales NOT measured for this asset")
    }
    return probe
}

// MARK: - Boundary residuals

struct Residual {
    let n: Int
    let ticks: Int64        // N * d at 120000
    let down: CMTime        // converted to native timescale
    let backTicks: Int64    // converted back to 120000
    let residualTicks: Int64
    let frameFraction: Double  // display only; the measurement itself is integer
}

func residuals(rate: FrameRate, nativeTimescale: CMTimeScale) -> [Residual] {
    let d = rate.ticksPerFrame
    return [0, 1, 2, 100, 1000].map { n in
        let ticks = Int64(n) * d
        let original = CMTime(value: ticks, timescale: 120_000)
        // .default = round half away from zero — what AVFoundation applies
        // when itself converting between timescales.
        let down = CMTimeConvertScale(original, timescale: nativeTimescale, method: .default)
        let back = CMTimeConvertScale(down, timescale: 120_000, method: .default)
        let residual = back.value - ticks
        return Residual(
            n: n, ticks: ticks, down: down, backTicks: back.value,
            residualTicks: residual,
            frameFraction: Double(residual) / Double(d))
    }
}

// MARK: - Real media discovery

func findRealMedia() -> (files: [URL], inaccessible: [String]) {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    var files: [URL] = []
    var inaccessible: [String] = []
    for dirName in ["Movies", "Desktop", "Downloads"] {
        let dir = home.appendingPathComponent(dirName)
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            inaccessible.append(dirName)
            continue
        }
        for f in items where ["mov", "mp4", "m4v"].contains(f.pathExtension.lowercased()) {
            files.append(f)
        }
    }
    return (Array(files.prefix(6)), inaccessible)
}

// MARK: - Report

func reportSection(for probe: AssetProbe, rate: FrameRate?) -> String {
    var out = "### \(probe.name)\n\n"
    out += "| metric | value |\n|---|---|\n"
    out += "| naturalTimeScale | \(probe.naturalTimeScale) |\n"
    out += "| nominalFrameRate | \(probe.nominalFrameRate) |\n"
    out += "| minFrameDuration | \(fmt(probe.minFrameDuration)) |\n"
    out += "| asset duration | \(fmt(probe.duration)) |\n"
    let pausedScales = Set(probe.pausedTimes.map(\.timescale)).sorted()
    let pausedAfterScales = Set(probe.pausedAfterPlayTimes.map(\.timescale)).sorted()
    let playingScales = Set(probe.playingTimes.map(\.timescale)).sorted()
    out += "| AVPlayer currentTime timescale (paused, before play) | \(pausedScales.map(String.init).joined(separator: ", ")) |\n"
    out += "| AVPlayer currentTime timescale (paused, after play) | \(pausedAfterScales.map(String.init).joined(separator: ", ")) |\n"
    out += "| AVPlayer currentTime timescale (playing) | \(playingScales.map(String.init).joined(separator: ", ")) |\n"
    if probe.displayTimes.isEmpty {
        out += "| video output display timestamps | not captured |\n"
    } else {
        let shown = probe.displayTimes.prefix(4)
            .map { "\(fmt($0.display))" }.joined(separator: ", ")
        out += "| video output display timestamps | \(shown) |\n"
    }
    out += "| reader PTS (first 10) | \(probe.readerPTS.map(fmt).joined(separator: ", ")) |\n"
    out += "\n"

    if let rate {
        out += "Boundary round trip 120000 → \(probe.naturalTimeScale) → 120000 (d = \(rate.ticksPerFrame) ticks):\n\n"
        out += "| N | ticks@120000 | native | back@120000 | residual (ticks) | residual (frames) |\n|---|---|---|---|---|---|\n"
        for r in residuals(rate: rate, nativeTimescale: probe.naturalTimeScale) {
            out += "| \(r.n) | \(r.ticks) | \(fmt(r.down)) | \(r.backTicks) | \(r.residualTicks) | \(String(format: "%.6f", r.frameFraction)) |\n"
        }
        out += "\n"
    }
    if !probe.notes.isEmpty {
        out += probe.notes.map { "> ⚠️ \($0)" }.joined(separator: "\n") + "\n\n"
    }
    return out
}

func flags(for probe: AssetProbe, rate: FrameRate?) -> [String] {
    var flagged: [String] = []
    if let rate {
        for r in residuals(rate: rate, nativeTimescale: probe.naturalTimeScale) {
            if abs(r.frameFraction) > 0.25 {
                flagged.append("\(probe.name): N=\(r.n) residual \(r.residualTicks) ticks = \(String(format: "%.4f", r.frameFraction)) frames — EXCEEDS the 1/4-frame threshold")
            }
            if r.backTicks != r.ticks {
                flagged.append("\(probe.name): N=\(r.n) round trip through timescale \(probe.naturalTimeScale) does NOT return the original (\(r.ticks) → \(r.backTicks))")
            }
        }
    }
    var apiScales: [String: Set<CMTimeScale>] = [:]
    apiScales["track.naturalTimeScale"] = [probe.naturalTimeScale]
    apiScales["asset.duration"] = [probe.duration.timescale]
    if !probe.pausedAfterPlayTimes.isEmpty { apiScales["player.currentTime(pausedAfterPlay)"] = Set(probe.pausedAfterPlayTimes.map(\.timescale)) }
    if !probe.playingTimes.isEmpty { apiScales["player.currentTime(playing)"] = Set(probe.playingTimes.map(\.timescale)) }
    if !probe.readerPTS.isEmpty { apiScales["reader.PTS"] = Set(probe.readerPTS.map(\.timescale)) }
    if !probe.displayTimes.isEmpty { apiScales["videoOutput.displayTime"] = Set(probe.displayTimes.map(\.display.timescale)) }
    let allScales = apiScales.values.reduce(into: Set<CMTimeScale>()) { $0.formUnion($1) }
    if allScales.count > 1 {
        let detail = apiScales.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.sorted().map(String.init).joined(separator: "/"))" }
            .joined(separator: ", ")
        flagged.append("\(probe.name): APIs report DIFFERENT timescales for the same asset — \(detail)")
    }
    return flagged
}

func nearestRate(toNominal fps: Float) -> FrameRate? {
    let candidates: [(FrameRate, Float)] = [
        (.fps23_976, 23.976), (.fps24, 24), (.fps25, 25), (.fps29_97, 29.97),
        (.fps30, 30), (.fps50, 50), (.fps59_94, 59.94), (.fps60, 60),
    ]
    guard let best = candidates.min(by: { abs($0.1 - fps) < abs($1.1 - fps) }) else { return nil }
    return abs(best.1 - fps) < 0.05 ? best.0 : nil
}

// MARK: - Main

let mediaDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.temporaryDirectory.appendingPathComponent("gyeol-probe-media").path)
let reportPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "m1-asset-timescale-probe.md"

try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)

var report = """
# M1 Asset Timescale Probe

Measured on \(ProcessInfo.processInfo.operatingSystemVersionString), \
\(ProcessInfo.processInfo.machineHardwareName ?? "unknown hardware"). \
Generated clips: H.264 640×360, ~5 s, PTS written at N × exact frame duration \
(e.g. 1001/24000). Round-trip conversion uses `CMTimeConvertScale` with \
`.default` rounding (half away from zero).

Reading notes:

- Reader PTS come from `AVAssetReaderTrackOutput` with `outputSettings: nil`
  (no decode), so samples arrive in DECODE order — H.264 B-frames make the
  PTS non-monotonic. That is expected, not a defect.
- "paused, before play" reads `0/1` — the `CMTime.zero` constant, not a
  measurement.
- Two generated sets: **default** leaves `AVAssetWriterInput.mediaTimeScale`
  unset; **explicit** pins it (and `movieTimeScale`) to the rate's exact
  denominator (24000, 30000, …).

## Generated clips

"""

var allFlags: [String] = []

for explicit in [false, true] {
    report += explicit
        ? "\n## Generated clips — explicit mediaTimeScale\n\n"
        : "\n## Generated clips — writer default mediaTimeScale\n\n"
    for spec in specs {
        let variant = explicit ? "explicit" : "default"
        let url = mediaDir.appendingPathComponent("gen-\(variant)-\(spec.label).mov")
        print("generating \(spec.label) (\(variant))…")
        try await generateClip(spec: spec, at: url, explicitTimescale: explicit)
        print("probing \(spec.label) (\(variant))…")
        let probe = try await probeAsset(url: url, name: "generated \(spec.label) fps (\(variant) timescale)")
        report += reportSection(for: probe, rate: spec.gyeolRate)
        allFlags.append(contentsOf: flags(for: probe, rate: spec.gyeolRate))
    }
}

report += "## Real local media\n\n"
let (realFiles, inaccessible) = findRealMedia()
for dir in inaccessible {
    report += "> ⚠️ ~/\(dir) was NOT readable from this process (TCC) — not measured.\n\n"
}
if realFiles.isEmpty {
    report += "No real camera/screen-recording files found in ~/Movies, ~/Desktop, ~/Downloads. NOT measured — rerun on a machine with real footage before trusting generated-only numbers.\n\n"
} else {
    for url in realFiles {
        do {
            let probe = try await probeAsset(url: url, name: "real: \(url.lastPathComponent)")
            let rate = nearestRate(toNominal: probe.nominalFrameRate)
            report += reportSection(for: probe, rate: rate)
            if rate == nil {
                report += "> ⚠️ nominal rate \(probe.nominalFrameRate) matches no supported FrameRate — residuals not computed.\n\n"
            }
            allFlags.append(contentsOf: flags(for: probe, rate: rate))
        } catch {
            report += "### real: \(url.lastPathComponent)\n\nNOT measured: \(error)\n\n"
        }
    }
}

report += "## Flags\n\n"
report += allFlags.isEmpty
    ? "None. No residual exceeded 1/4 frame, every round trip returned the original value, and no API disagreed on timescale beyond what is listed above.\n"
    : allFlags.map { "- ⚠️ \($0)" }.joined(separator: "\n") + "\n"

try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
print("report written to \(reportPath)")

extension ProcessInfo {
    var machineHardwareName: String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars, encoding: .utf8)
    }
}
