import AppKit
import GyeolCore
import Metal
import os

/// M2.2 measurement harness: `Gyeol --timeline-probe <package.gyeol>
/// [--probe-minutes N]`, run in a RELEASE build (a Debug number would be
/// measuring the wrong thing, and Malloc Stack Logging must be off — the
/// probe checks and says so).
///
/// Follows the `--g5-probe` precedent (A-36): the running app process is
/// the only environment whose numbers mean anything; headless xctest has
/// twice disagreed with it.
///
/// What it measures, and which decision consumes each number:
/// - timeline DRAW time under scrub and pan — §4 S2 (provisional pass on
///   this machine: ≤ half the 60fps budget, 8.3 ms, per D3)
/// - visible-range binary search cost — D26's statelessness condition
/// - resident memory with the 3-hour fixture — D3 (8GB floor) vs 부록 C
/// - CoW sharing of document value copies — D27 / 부록 C's 120 MB estimate
/// - sustained load — fanless dev hardware throttles; first-minute numbers
///   flatter (D3's 여유율 rationale)
@MainActor
enum TimelineProbe {
    static func arguments() -> (packageURL: URL, minutes: Double)? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--timeline-probe"),
              args.indices.contains(flag + 1) else { return nil }
        var minutes = 0.0
        if let m = args.firstIndex(of: "--probe-minutes"), args.indices.contains(m + 1),
           let value = Double(args[m + 1]) {
            minutes = value
        }
        return (URL(fileURLWithPath: args[flag + 1]), minutes)
    }

    static func run(packageURL: URL, minutes: Double) async {
        // App Nap defense (measured): a windowless GUI process gets napped
        // ~30 s in, and every sustained bucket after the first read ~4-5×
        // slower with thermal still nominal — the numbers were measuring
        // the scheduler, not the renderer. The activity assertion keeps the
        // process at interactive priority for the probe's lifetime.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "M2.2 timeline measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        print("M2.2-probe: package \(packageURL.path)")
        #if DEBUG
        print("M2.2-probe: ⚠️ DEBUG build — numbers are not the milestone's numbers")
        #else
        print("M2.2-probe: Release build")
        #endif
        for variable in ["MallocStackLogging", "MallocStackLoggingNoCompact"] {
            if getenv(variable) != nil {
                print("M2.2-probe: ⚠️ \(variable) is SET — memory numbers are distorted; unset it")
            }
        }
        print("M2.2-probe: machine \(sysctlString("hw.model") ?? "?"), \(sysctlString("machdep.cpu.brand_string") ?? "?"), thermal \(thermalStateName())")

        // ---- Load the document (Core decode; measured for context only).
        let footprintAtStart = footprintMB()
        let bodyURL = packageURL.appendingPathComponent(GyeolDocumentFile.bodyFilename)
        let document: GyeolDocument
        do {
            let data = try Data(contentsOf: bodyURL)
            let decodeStart = CFAbsoluteTimeGetCurrent()
            document = try GyeolCoding.makeDecoder().decode(GyeolDocument.self, from: data)
            let decodeMs = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
            print(String(format: "M2.2-probe: decode %.1f ms, %d bytes", decodeMs, data.count))
        } catch {
            print("M2.2-probe: FAILED to load document: \(error)")
            return
        }
        let clipTotal = document.tracks.map(\.clips.count).reduce(0, +)
        print("M2.2-probe: \(document.tracks.count) tracks, \(clipTotal) clips, \(document.subtitles.count) subtitles, \(document.markers.count) markers, duration \(document.duration.ticks) ticks")

        // Media next to the package (relative path; the probe skips the
        // bookmark/fingerprint machinery on purpose — resolution is not
        // what M2.2 measures).
        var mediaURLs: [MediaID: URL] = [:]
        for (id, reference) in document.media {
            mediaURLs[id] = packageURL.deletingLastPathComponent()
                .appendingPathComponent(reference.relativePath)
        }

        guard let renderer = TimelineRenderer() else {
            print("M2.2-probe: FAILED — no Metal device")
            return
        }
        renderer.setDocument(document, mediaURLs: mediaURLs)

        // Offscreen target: 1600×340 pt at 2x — a plausible timeline strip
        // of a full-screen 1080p-class window.
        let sizePoints = CGSize(width: 1_600, height: 340)
        let scale = 2.0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(sizePoints.width * scale), height: Int(sizePoints.height * scale),
            mipmapped: false)
        descriptor.usage = [.renderTarget]
        // Shared, not private: unified memory makes readback free, and the
        // --probe-dump PNGs read these bytes directly.
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
            print("M2.2-probe: FAILED — render target allocation")
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = TimelineRenderer.clearColor
        pass.colorAttachments[0].storeAction = .store

        // `--probe-dump <dir>`: write PNGs of what was rendered, because a
        // sandboxed shell cannot screencapture the GUI — this is the
        // visual verification artifact for the offscreen path.
        let dumpDir: URL? = {
            let args = CommandLine.arguments
            guard let flag = args.firstIndex(of: "--probe-dump"),
                  args.indices.contains(flag + 1) else { return nil }
            return URL(fileURLWithPath: args[flag + 1])
        }()

        let totalTicks = document.duration.ticks
        let rate = document.settings.frameRate
        let frameCount = FrameMapping.frameCount(for: document.duration, rate: rate)
        // Mid zoom: ~160 s visible; full zoom-out: the whole 3 h in view —
        // every subtitle is a candidate, the worst rebuild.
        let midZoom = TimelineViewport(visibleStartTicks: totalTicks / 3, ticksPerPoint: 12_000)
        let fullZoomOut = TimelineViewport(
            visibleStartTicks: 0,
            ticksPerPoint: (Double(totalTicks) / sizePoints.width)
                .clamped(to: TimelineViewport.minTicksPerPoint...TimelineViewport.maxTicksPerPoint))

        func draw(_ viewport: TimelineViewport, playhead: Int) -> TimelineRenderer.DrawStats? {
            renderer.draw(
                inputs: .init(
                    viewport: viewport, sizePoints: sizePoints, scale: scale,
                    playheadFrame: playhead),
                passDescriptor: pass, waitUntilCompleted: true)
        }

        // ---- Waveform warm-up: first draws schedule computation + tile
        // loads; wait for the async pipeline to settle so later phases
        // measure steady state, not first-touch IO.
        _ = draw(midZoom, playhead: 0)
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            renderer.noteContentChanged()
            _ = draw(midZoom, playhead: 0)
            if WaveformStore.shared.residentTileBytesForTesting > 0 { break }
        }
        print("M2.2-probe: waveform resident \(WaveformStore.shared.residentTileBytesForTesting) bytes after warm-up")

        if let dumpDir {
            try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
            _ = draw(midZoom, playhead: FrameMapping.frameIndex(
                at: docTimeStandalone(midZoom.visibleStartTicks + 400 * 12_000), rate: rate))
            writePNG(texture: target, to: dumpDir.appendingPathComponent("timeline-mid-zoom.png"))
            _ = draw(fullZoomOut, playhead: frameCount / 2)
            writePNG(texture: target, to: dumpDir.appendingPathComponent("timeline-zoom-out.png"))
            // Below the subtitle-text threshold: the Core Text overlay must
            // actually render text here.
            let textZoom = TimelineViewport(visibleStartTicks: totalTicks / 3, ticksPerPoint: 4_000)
            _ = draw(textZoom, playhead: FrameMapping.frameIndex(
                at: docTimeStandalone(textZoom.visibleStartTicks + 300 * 4_000), rate: rate))
            writePNG(texture: target, to: dumpDir.appendingPathComponent("timeline-text-zoom.png"))
            print("M2.2-probe: dumped renders to \(dumpDir.path)")
        }

        // ---- Phase 1: scrub draw. Fixed viewport, playhead sweeps — the
        // static buffer must NOT rebuild (checked); the number is timeline
        // draw only, no preview decode (that path is not exercised here at
        // all).
        func scrubPhase(name: String, viewport: TimelineViewport, draws: Int) -> [Double] {
            _ = draw(viewport, playhead: 0)  // settle static buffer
            var totals: [Double] = []
            var rebuilds = 0
            let visibleFrames = max(
                1, FrameMapping.frameCount(
                    for: DocumentTime(ticks: viewport.visibleEndTicks(width: sizePoints.width)
                        - viewport.visibleStartTicks),
                    rate: rate))
            let baseFrame = FrameMapping.frameIndex(
                at: DocumentTime(ticks: viewport.visibleStartTicks), rate: rate)
            for i in 0..<draws {
                let playhead = min(baseFrame + (i * visibleFrames) / draws, frameCount - 1)
                guard let stats = draw(viewport, playhead: playhead) else { continue }
                totals.append(stats.cpuMilliseconds + stats.gpuMilliseconds)
                if stats.rebuiltStatic { rebuilds += 1 }
            }
            report(name: name, samples: totals, extra: "static rebuilds \(rebuilds) (expected 0)")
            return totals
        }
        _ = scrubPhase(name: "scrub draw (mid zoom)", viewport: midZoom, draws: 600)
        _ = scrubPhase(name: "scrub draw (full zoom-out)", viewport: fullZoomOut, draws: 600)

        // ---- Phase 2: pan draw — every frame shifts the viewport, so
        // every frame pays query + geometry rebuild + upload. This is the
        // worst per-frame path a user can hold down.
        func panPhase(name: String, start: TimelineViewport, deltaPoints: Double, draws: Int) {
            var viewport = start
            var totals: [Double] = []
            var vertexCount = 0
            for _ in 0..<draws {
                viewport.pan(byPoints: deltaPoints)
                guard let stats = draw(viewport, playhead: frameCount / 2) else { continue }
                totals.append(stats.cpuMilliseconds + stats.gpuMilliseconds)
                vertexCount = max(vertexCount, stats.staticVertexCount)
            }
            report(name: name, samples: totals, extra: "max static vertices \(vertexCount)")
        }
        panPhase(name: "pan draw (mid zoom, rebuild each frame)", start: midZoom, deltaPoints: 6, draws: 600)
        panPhase(name: "pan draw (full zoom-out, 3,600 subtitles visible)", start: fullZoomOut, deltaPoints: 2, draws: 300)

        // ---- Phase 3: visible-range query cost (D26). Query-only, no
        // rendering: the statelessness decision hangs on this number.
        let heaviestTrack = document.tracks.max(by: { $0.clips.count < $1.clips.count })!
        let maxSubtitleTicks = document.subtitles.lazy.map(\.duration.ticks).max() ?? 0
        func docTime(_ t: Int64) -> DocumentTime { DocumentTime(ticks: t) }
        func queryPhase(name: String, iterations: Int, body: (Int64) -> Int) {
            var sink = 0
            let spanTicks = Int64(sizePoints.width * midZoom.ticksPerPoint)
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<iterations {
                // Deterministic pseudo-random windows across the 3 hours.
                let t0 = (Int64(i) &* 2_654_435_761) % max(1, totalTicks - spanTicks)
                sink &+= body(t0)
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            print(String(
                format: "M2.2-probe: %@ — %.3f µs/query (%d iterations, sink %d)",
                name, elapsed / Double(iterations) * 1_000_000, iterations, sink % 1_000))
        }
        let spanTicks = Int64(sizePoints.width * midZoom.ticksPerPoint)
        queryPhase(name: "visibleClips (\(heaviestTrack.clips.count)-clip track)", iterations: 200_000) { t0 in
            VisibleRange.visibleClips(in: heaviestTrack, from: docTime(t0), to: docTime(t0 + spanTicks)).count
        }
        queryPhase(name: "visibleSubtitles (3,600 segments, mid window)", iterations: 200_000) { t0 in
            var n = 0
            for _ in VisibleRange.visibleSubtitles(
                in: document.subtitles, from: docTime(t0), to: docTime(t0 + spanTicks),
                maxSubtitleDuration: docTime(maxSubtitleTicks)) { n += 1 }
            return n
        }
        queryPhase(name: "visibleMarkers", iterations: 200_000) { t0 in
            VisibleRange.visibleMarkers(
                in: document.markers, from: docTime(t0), to: docTime(t0 + spanTicks)).count
        }

        // ---- Phase 4: CoW sharing on document value copies (D27, 부록 C).
        let sharedSubtitles = document.subtitles.withUnsafeBufferPointer { a in
            { (copy: GyeolDocument) in
                copy.subtitles.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress }
            }(document)
        }
        let before = footprintMB()
        var undoStack: [GyeolDocument] = []
        undoStack.reserveCapacity(100)
        for _ in 0..<100 { undoStack.append(document) }
        let after = footprintMB()
        print(String(
            format: "M2.2-probe: CoW — subtitle storage shared on copy: %@; 100 value copies cost %.2f MB (부록 C no-sharing estimate: 120 MB)",
            sharedSubtitles ? "YES" : "NO", after - before))
        _ = undoStack.count

        // ---- Phase 4.6: Equatable cost (M2.3 r2 task 7). DocumentView
        // binds `.task(id: file.document)`, so every SwiftUI body
        // re-evaluation compares the whole document value; while playing,
        // observable transport state (transportReport, displayOnlyFrame
        // per drained frame) re-evaluates the body, so this comparison
        // runs at roughly the playback tick rate.
        do {
            let identical = document
            var oneClipChanged = document
            if let heaviest = oneClipChanged.tracks.indices.max(
                by: { oneClipChanged.tracks[$0].clips.count < oneClipChanged.tracks[$1].clips.count }) {
                var clips = oneClipChanged.tracks[heaviest].clips
                let middle = clips.count / 2
                clips[middle].audio.volume = FixedPointScalar(rawValue: 9_999)
                oneClipChanged.tracks[heaviest].clips = clips
            }
            var sink = 0
            var start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<10_000 where document == identical { sink += 1 }
            let identicalUs = (CFAbsoluteTimeGetCurrent() - start) / 10_000 * 1_000_000
            start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<1_000 where document == oneClipChanged { sink += 1 }
            let differingUs = (CFAbsoluteTimeGetCurrent() - start) / 1_000 * 1_000_000
            print(String(
                format: "M2.2-probe: Equatable — identical value %.3f µs/compare (storage identity), one-clip-diff %.1f µs/compare (deep walk to the difference); budget 8.3 ms (sink %d)",
                identicalUs, differingUs, sink % 7))
        }

        // ---- Phase 5: resident memory.
        print(String(
            format: "M2.2-probe: resident footprint %.1f MB (at launch %.1f MB); waveform tiles %d bytes",
            footprintMB(), footprintAtStart, WaveformStore.shared.residentTileBytesForTesting))

        // ---- Phase 6: sustained load (fanless hardware throttles; D3).
        if minutes > 0 {
            print("M2.2-probe: sustained load for \(minutes) min…")
            let bucketSeconds = 30.0
            let end = CFAbsoluteTimeGetCurrent() + minutes * 60
            var viewport = midZoom
            var bucketSamples: [Double] = []
            var bucketStart = CFAbsoluteTimeGetCurrent()
            var bucketIndex = 0
            var playhead = 0
            while CFAbsoluteTimeGetCurrent() < end {
                viewport.pan(byPoints: 6)
                if viewport.visibleEndTicks(width: sizePoints.width) >= totalTicks {
                    viewport.visibleStartTicks = 0
                }
                playhead = (playhead + 7) % max(1, frameCount)
                if let stats = draw(viewport, playhead: playhead) {
                    bucketSamples.append(stats.cpuMilliseconds + stats.gpuMilliseconds)
                }
                if CFAbsoluteTimeGetCurrent() - bucketStart >= bucketSeconds {
                    bucketIndex += 1
                    report(
                        name: "sustained bucket \(bucketIndex) (\(Int(bucketSeconds))s)",
                        samples: bucketSamples,
                        extra: "thermal \(thermalStateName()), footprint \(String(format: "%.1f", footprintMB())) MB")
                    bucketSamples.removeAll(keepingCapacity: true)
                    bucketStart = CFAbsoluteTimeGetCurrent()
                }
                // Yield so waveform/main-queue tasks are not starved.
                await Task.yield()
            }
        }
        print("M2.2-probe: done")
    }

    // MARK: - Reporting helpers

    private static func docTimeStandalone(_ ticks: Int64) -> DocumentTime {
        DocumentTime(ticks: ticks)
    }

    private static func writePNG(texture: MTLTexture, to url: URL) {
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            let image = context.makeImage() else {
            print("M2.2-probe: PNG dump failed for \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    private static func report(name: String, samples: [Double], extra: String) {
        guard !samples.isEmpty else {
            print("M2.2-probe: \(name) — no samples")
            return
        }
        let sorted = samples.sorted()
        let avg = samples.reduce(0, +) / Double(samples.count)
        func pct(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        print(String(
            format: "M2.2-probe: %@ — avg %.3f ms, p50 %.3f, p95 %.3f, max %.3f (n=%d, budget 8.3 ms) — %@",
            name, avg, pct(0.5), pct(0.95), sorted.last!, samples.count, extra))
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
