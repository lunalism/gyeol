import AppKit
import CoreText
import GyeolCore
import Metal
import MetalKit

/// The timeline's single-pass Metal renderer (D28: one `MTKView`, no layer
/// split, no static-content texture cache).
///
/// WHAT REBUILDS WHEN (PRD §5.2 "정점 버퍼 재생성은 뷰포트나 문서가 바뀔
/// 때만"):
///
/// - STATIC geometry (lanes, clips, waveforms, subtitles, markers, ruler)
///   and the text overlay rebuild only when the viewport, the view size,
///   the document, or an async waveform tile arrival changes them.
/// - The PLAYHEAD is the one thing that moves every frame during playback
///   and scrubbing; it is encoded per-draw via `setVertexBytes`, so a
///   scrub or playback tick re-encodes three draw calls and rebuilds
///   nothing.
///
/// The GPU only ever sees viewport-relative points (float32-safe); every
/// absolute tick computation stays in `TimelineViewport` / Int64 on the
/// CPU (§5.2 — see TimelineViewport's header for the failure this
/// prevents).
@MainActor
final class TimelineRenderer {
    struct FrameInputs {
        var viewport: TimelineViewport
        var sizePoints: CGSize
        var scale: CGFloat
        /// The frame index to draw the playhead at. Comes from
        /// `PlaybackController` — the stopped playhead or the display-only
        /// frame while playing — NEVER from `player.currentTime()`
        /// (§7.4-8: the player clock leaves the content domain).
        var playheadFrame: Int
    }

    struct DrawStats {
        var cpuMilliseconds: Double
        var gpuMilliseconds: Double
        var rebuiltStatic: Bool
        var staticVertexCount: Int
    }

    private struct Vertex {
        var x: Float
        var y: Float
        var r: Float
        var g: Float
        var b: Float
        var a: Float
    }

    private struct Color {
        var r: Float
        var g: Float
        var b: Float
        var a: Float
        init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
    }

    // MARK: - Layout constants

    static let rulerHeight = 26.0
    static let subtitleLaneHeight = 24.0
    static let clearColor = MTLClearColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)

    // MARK: - State

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let solidPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState

    private var document: GyeolDocument?
    private var mediaURLs: [MediaID: URL] = [:]
    /// Held by the app, passed to Core's subtitle query (§5.2): derived
    /// data, not stored in the document, not recomputed per call.
    private var maxSubtitleDurationTicks: Int64 = 0
    private var documentRevision = 0
    private var contentRevision = 0

    private struct StaticKey: Equatable {
        var viewport: TimelineViewport
        var sizePoints: CGSize
        var scale: CGFloat
        var documentRevision: Int
        var contentRevision: Int
    }
    private var builtKey: StaticKey?
    private var staticBuffer: MTLBuffer?
    private var staticVertexCount = 0
    private var textTexture: MTLTexture?
    private var lastGPUMilliseconds = 0.0

    private let waveforms: WaveformStore

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), waveforms: WaveformStore = .shared) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.waveforms = waveforms
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let solid = MTLRenderPipelineDescriptor()
            solid.vertexFunction = library.makeFunction(name: "timeline_vertex")
            solid.fragmentFunction = library.makeFunction(name: "timeline_fragment")
            solid.colorAttachments[0].pixelFormat = .bgra8Unorm
            solid.colorAttachments[0].isBlendingEnabled = true
            solid.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            solid.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            solid.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            solid.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            solidPipeline = try device.makeRenderPipelineState(descriptor: solid)

            let overlay = MTLRenderPipelineDescriptor()
            overlay.vertexFunction = library.makeFunction(name: "overlay_vertex")
            overlay.fragmentFunction = library.makeFunction(name: "overlay_fragment")
            overlay.colorAttachments[0].pixelFormat = .bgra8Unorm
            overlay.colorAttachments[0].isBlendingEnabled = true
            // The text bitmap is premultiplied (CGContext), so source is .one.
            overlay.colorAttachments[0].sourceRGBBlendFactor = .one
            overlay.colorAttachments[0].sourceAlphaBlendFactor = .one
            overlay.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            overlay.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            overlayPipeline = try device.makeRenderPipelineState(descriptor: overlay)
        } catch {
            return nil
        }
    }

    // MARK: - Inputs

    /// Called by the host only when the document value actually changed;
    /// bumping the revision is what invalidates the static geometry.
    func setDocument(_ document: GyeolDocument, mediaURLs: [MediaID: URL]) {
        self.document = document
        self.mediaURLs = mediaURLs
        // Computed ONCE per document change, held by the app, handed to the
        // query (§5.2's second correction).
        maxSubtitleDurationTicks = document.subtitles.lazy.map(\.duration.ticks).max() ?? 0
        documentRevision += 1
    }

    /// Async content arrival (waveform tiles): geometry must rebuild on the
    /// next draw, the document did not change.
    func noteContentChanged() {
        contentRevision += 1
    }

    // MARK: - Draw

    /// Encodes one frame. Returns nil when the pass could not start.
    /// `present` is handed the command buffer before commit so an MTKView
    /// can schedule its drawable; the probe passes nil and waits.
    @discardableResult
    func draw(
        inputs: FrameInputs,
        passDescriptor: MTLRenderPassDescriptor,
        present: ((MTLCommandBuffer) -> Void)? = nil,
        waitUntilCompleted: Bool = false
    ) -> DrawStats? {
        let cpuStart = CFAbsoluteTimeGetCurrent()
        let key = StaticKey(
            viewport: inputs.viewport, sizePoints: inputs.sizePoints, scale: inputs.scale,
            documentRevision: documentRevision, contentRevision: contentRevision)
        var rebuilt = false
        if key != builtKey {
            rebuildStatic(inputs: inputs)
            builtKey = key
            rebuilt = true
        }

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return nil
        }
        var viewSize = SIMD2<Float>(Float(inputs.sizePoints.width), Float(inputs.sizePoints.height))
        encoder.setRenderPipelineState(solidPipeline)
        encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        if let staticBuffer, staticVertexCount > 0 {
            encoder.setVertexBuffer(staticBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: staticVertexCount)
        }

        // Playhead: the per-frame dynamic path — small enough for
        // setVertexBytes, so scrubbing allocates nothing.
        let playheadVertices = buildPlayhead(inputs: inputs)
        if !playheadVertices.isEmpty {
            playheadVertices.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: playheadVertices.count)
        }

        if let textTexture {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setFragmentTexture(textTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        present?(commandBuffer)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Task { @MainActor [weak self] in
                self?.lastGPUMilliseconds = gpuMs
            }
        }
        commandBuffer.commit()
        let cpuMs = (CFAbsoluteTimeGetCurrent() - cpuStart) * 1000
        var gpuMs = lastGPUMilliseconds
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
            gpuMs = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        }
        return DrawStats(
            cpuMilliseconds: cpuMs,
            gpuMilliseconds: gpuMs,
            rebuiltStatic: rebuilt,
            staticVertexCount: staticVertexCount)
    }

    // MARK: - Static geometry

    private struct LabelRequest {
        var text: String
        var x: Double
        var y: Double
        var color: NSColor
        var maxWidth: Double?
    }

    private func rebuildStatic(inputs: FrameInputs) {
        var vertices: [Vertex] = []
        vertices.reserveCapacity(1 << 15)
        var labels: [LabelRequest] = []
        let width = inputs.sizePoints.width
        let height = inputs.sizePoints.height
        let viewport = inputs.viewport

        // Ruler + subtitle strip backgrounds.
        addQuad(&vertices, x0: 0, y0: 0, x1: width, y1: Self.rulerHeight, color: Color(0.145, 0.145, 0.155))
        addQuad(&vertices, x0: 0, y0: Self.rulerHeight, x1: width,
                y1: Self.rulerHeight + Self.subtitleLaneHeight, color: Color(0.125, 0.12, 0.10))

        guard let document else {
            uploadStatic(vertices)
            textTexture = nil
            return
        }

        let startTicks = viewport.visibleStartTicks
        let endTicks = viewport.visibleEndTicks(width: width)
        let visibleStart = docTime(startTicks)
        let visibleEnd = docTime(endTicks)

        // Track lanes: video tracks stack by document index, higher index
        // ABOVE (§5.8's compositing order, mirrored visually), audio below.
        let videoTracks = document.tracks.enumerated().filter { $0.element.kind == .video }
        let audioTracks = document.tracks.enumerated().filter { $0.element.kind == .audio }
        let laneTop = Self.rulerHeight + Self.subtitleLaneHeight
        let laneCount = max(1, videoTracks.count + audioTracks.count)
        let laneHeight = max(10, (height - laneTop) / Double(laneCount))
        let orderedTracks = Array(videoTracks.reversed()) + audioTracks

        for (laneIndex, entry) in orderedTracks.enumerated() {
            let y0 = laneTop + Double(laneIndex) * laneHeight
            let y1 = y0 + laneHeight
            addQuad(&vertices, x0: 0, y0: y0, x1: width, y1: y1,
                    color: laneIndex.isMultiple(of: 2) ? Color(0.135, 0.135, 0.145) : Color(0.12, 0.12, 0.13))
            addQuad(&vertices, x0: 0, y0: y1 - 0.5, x1: width, y1: y1, color: Color(0.09, 0.09, 0.10))

            let track = entry.element
            let isVideo = track.kind == .video
            let body = isVideo ? Color(0.23, 0.40, 0.60) : Color(0.20, 0.42, 0.28)
            let border = isVideo ? Color(0.38, 0.56, 0.76) : Color(0.32, 0.58, 0.42)

            // Core's stateless visible-range query — the one binary search
            // (D26/D28), never a per-frame full scan.
            for clip in VisibleRange.visibleClips(in: track, from: visibleStart, to: visibleEnd) {
                let cx0 = viewport.x(ofTicks: clip.timelineStart.ticks)
                let clipEndTicks = clip.timelineStart.ticks + clip.duration.ticks
                let cx1 = viewport.x(ofTicks: clipEndTicks)
                let x0 = max(cx0, -2)
                let x1 = min(cx1, width + 2)
                guard x1 > x0 else { continue }
                addQuad(&vertices, x0: x0, y0: y0 + 2, x1: x1, y1: y1 - 2.5, color: border)
                if x1 - x0 > 2 {
                    addQuad(&vertices, x0: x0 + 1, y0: y0 + 3, x1: x1 - 1, y1: y1 - 3.5, color: body)
                }
                if !isVideo {
                    addWaveform(
                        &vertices, clip: clip, document: document, viewport: viewport,
                        x0: x0, x1: x1, laneY0: y0 + 3, laneY1: y1 - 3.5)
                }
            }
        }

        // Subtitles: rectangles always; text only when the zoom makes it
        // legible (§5.2 — no Core Text for 3,600 unreadable strings).
        let subtitleY0 = Self.rulerHeight + 3
        let subtitleY1 = Self.rulerHeight + Self.subtitleLaneHeight - 3
        let drawSubtitleText = viewport.ticksPerPoint <= TimelineViewport.maxTicksPerPointForSubtitleText
        for segment in VisibleRange.visibleSubtitles(
            in: document.subtitles, from: visibleStart, to: visibleEnd,
            maxSubtitleDuration: docTime(maxSubtitleDurationTicks)) {
            let sx0 = max(viewport.x(ofTicks: segment.start.ticks), -2)
            let sx1 = min(viewport.x(ofTicks: segment.start.ticks + segment.duration.ticks), width + 2)
            guard sx1 > sx0 else { continue }
            addQuad(&vertices, x0: sx0, y0: subtitleY0, x1: sx1, y1: subtitleY1,
                    color: Color(0.74, 0.60, 0.22, 0.42))
            if drawSubtitleText, sx1 - sx0 > 24 {
                labels.append(LabelRequest(
                    text: segment.text, x: sx0 + 3, y: subtitleY0 + 2,
                    color: NSColor(calibratedWhite: 0.95, alpha: 1), maxWidth: sx1 - sx0 - 6))
            }
        }

        // Markers: fixed-width flags in the ruler area.
        for marker in VisibleRange.visibleMarkers(in: document.markers, from: visibleStart, to: visibleEnd) {
            let mx = viewport.x(ofTicks: marker.time.ticks)
            addQuad(&vertices, x0: mx - 1, y0: 4, x1: mx + 1, y1: Self.rulerHeight,
                    color: Color(0.95, 0.56, 0.16))
            addQuad(&vertices, x0: mx - 1, y0: 4, x1: mx + 5, y1: 10, color: Color(0.95, 0.56, 0.16))
        }

        addRuler(&vertices, labels: &labels, viewport: viewport, width: width)

        uploadStatic(vertices)
        rebuildTextTexture(labels: labels, sizePoints: inputs.sizePoints, scale: inputs.scale)
    }

    private func addWaveform(
        _ vertices: inout [Vertex], clip: Clip, document: GyeolDocument,
        viewport: TimelineViewport, x0: Double, x1: Double, laneY0: Double, laneY1: Double
    ) {
        guard case .media(let source) = clip.source,
              let url = mediaURLs[source.mediaID],
              let fingerprint = document.media[source.mediaID]?.contentFingerprint else { return }
        let mediaKey = fingerprint.value.map { String(format: "%02x", $0) }.joined()
        guard let meta = waveforms.meta(mediaKey: mediaKey, mediaURL: url) else { return }

        // Pick the mipmap level with ≥ 1 peak per point.
        let samplesPerPoint = viewport.ticksPerPoint / Double(DocumentTime.timescale) * meta.sampleRate
        let rawLevel = samplesPerPoint <= Double(WaveformStore.samplesPerPeakBase)
            ? 0
            : Int(log2(samplesPerPoint / Double(WaveformStore.samplesPerPeakBase)).rounded(.down))
        let level = min(max(rawLevel, 0), meta.levelCount - 1)
        let samplesPerPeak = Double(WaveformStore.samplesPerPeakBase * (1 << level))

        let midY = (laneY0 + laneY1) / 2
        let halfSpan = (laneY1 - laneY0) / 2 - 0.5
        let waveColor = Color(0.62, 0.88, 0.70, 0.9)
        let clipStartTicks = clip.timelineStart.ticks
        let sourceStartTicks = source.sourceStart.ticks

        var x = x0.rounded(.down)
        while x < x1 {
            defer { x += 1 }
            let ticksAtColumn = viewport.ticks(atX: x)
            let sourceTicks = sourceStartTicks + (ticksAtColumn - clipStartTicks)
            guard sourceTicks >= 0 else { continue }
            let sample = Double(sourceTicks) / Double(DocumentTime.timescale) * meta.sampleRate
            let peakIndex = Int(sample / samplesPerPeak)
            guard peakIndex >= 0, peakIndex < meta.peakCount(level: level) else { continue }
            let tileIndex = peakIndex / WaveformStore.peaksPerTile
            // A missing tile draws NOTHING here — never blocks (§5.2). The
            // store schedules the load; onUpdate → contentRevision bump →
            // this geometry rebuilds with the tile filled in.
            guard let tile = waveforms.tile(
                mediaKey: mediaKey, level: level, index: tileIndex, mediaURL: url) else { continue }
            let peak = tile[peakIndex % WaveformStore.peaksPerTile]
            let lo = midY - Double(peak.maxValue) / 32_768 * halfSpan
            let hi = midY - Double(peak.minValue) / 32_768 * halfSpan
            addQuad(&vertices, x0: x, y0: min(lo, hi), x1: x + 1, y1: max(lo, hi, min(lo, hi) + 0.5),
                    color: waveColor)
        }
    }

    private func addRuler(
        _ vertices: inout [Vertex], labels: inout [LabelRequest],
        viewport: TimelineViewport, width: Double
    ) {
        // Major tick ≥ 90 pt apart from a set of round steps.
        let candidates: [Int64] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600]
        let ticksPerSecond = Int64(DocumentTime.timescale)
        let step = candidates.first {
            Double($0 * ticksPerSecond) / viewport.ticksPerPoint >= 90
        } ?? 3_600
        let stepTicks = step * ticksPerSecond
        let minorTicks = stepTicks / 5

        var t = (viewport.visibleStartTicks / stepTicks) * stepTicks
        let endTicks = viewport.visibleEndTicks(width: width)
        while t <= endTicks {
            defer { t += stepTicks }
            guard t >= 0 else { continue }
            let x = viewport.x(ofTicks: t)
            addQuad(&vertices, x0: x, y0: Self.rulerHeight - 9, x1: x + 1, y1: Self.rulerHeight,
                    color: Color(0.55, 0.55, 0.58))
            let seconds = t / ticksPerSecond
            labels.append(LabelRequest(
                text: Self.timeLabel(seconds: seconds), x: x + 3, y: 3,
                color: NSColor(calibratedWhite: 0.75, alpha: 1), maxWidth: nil))
            if Double(minorTicks) / viewport.ticksPerPoint >= 10 {
                for k in 1..<5 {
                    let mx = viewport.x(ofTicks: t + Int64(k) * minorTicks)
                    if mx <= width {
                        addQuad(&vertices, x0: mx, y0: Self.rulerHeight - 4, x1: mx + 1,
                                y1: Self.rulerHeight, color: Color(0.34, 0.34, 0.36))
                    }
                }
            }
        }
    }

    static func timeLabel(seconds: Int64) -> String {
        let h = seconds / 3_600
        let m = (seconds % 3_600) / 60
        let s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func buildPlayhead(inputs: FrameInputs) -> [Vertex] {
        guard let document else { return [] }
        let rate = document.settings.frameRate
        // The one mapping (§4.1/§6.2): frame index → time via FrameMapping,
        // never ticks-arithmetic here.
        let ticks = FrameMapping.time(ofFrame: max(0, inputs.playheadFrame), rate: rate).ticks
        let x = inputs.viewport.x(ofTicks: ticks)
        guard x >= -8, x <= inputs.sizePoints.width + 8 else { return [] }
        var vertices: [Vertex] = []
        let color = Color(0.95, 0.29, 0.24)
        addQuad(&vertices, x0: x - 0.5, y0: 0, x1: x + 0.5, y1: inputs.sizePoints.height, color: color)
        // Head cap triangle.
        vertices.append(contentsOf: [
            Vertex(x: Float(x - 5), y: 0, r: color.r, g: color.g, b: color.b, a: color.a),
            Vertex(x: Float(x + 5), y: 0, r: color.r, g: color.g, b: color.b, a: color.a),
            Vertex(x: Float(x), y: 9, r: color.r, g: color.g, b: color.b, a: color.a),
        ])
        return vertices
    }

    private func addQuad(
        _ vertices: inout [Vertex],
        x0: Double, y0: Double, x1: Double, y1: Double, color: Color
    ) {
        let fx0 = Float(x0), fy0 = Float(y0), fx1 = Float(x1), fy1 = Float(y1)
        let v00 = Vertex(x: fx0, y: fy0, r: color.r, g: color.g, b: color.b, a: color.a)
        let v10 = Vertex(x: fx1, y: fy0, r: color.r, g: color.g, b: color.b, a: color.a)
        let v01 = Vertex(x: fx0, y: fy1, r: color.r, g: color.g, b: color.b, a: color.a)
        let v11 = Vertex(x: fx1, y: fy1, r: color.r, g: color.g, b: color.b, a: color.a)
        vertices.append(contentsOf: [v00, v10, v11, v00, v11, v01])
    }

    private func uploadStatic(_ vertices: [Vertex]) {
        staticVertexCount = vertices.count
        guard !vertices.isEmpty else {
            staticBuffer = nil
            return
        }
        let length = vertices.count * MemoryLayout<Vertex>.stride
        if let buffer = staticBuffer, buffer.length >= length {
            vertices.withUnsafeBytes { raw in
                buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        } else {
            staticBuffer = vertices.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
            }
        }
    }

    // MARK: - Text overlay

    /// Ruler labels and (zoomed-in) subtitle text rendered by Core Text
    /// into one premultiplied-BGRA bitmap, uploaded as a single texture and
    /// composited in the same pass. Rebuilt ONLY alongside the static
    /// geometry — never during playback ticks or scrubbing.
    private func rebuildTextTexture(labels: [LabelRequest], sizePoints: CGSize, scale: CGFloat) {
        guard !labels.isEmpty else {
            textTexture = nil
            return
        }
        let pixelWidth = max(1, Int(sizePoints.width * scale))
        let pixelHeight = max(1, Int(sizePoints.height * scale))
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight,
            bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else {
            textTexture = nil
            return
        }
        // Top-left origin in points.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        for label in labels {
            let attributed = NSAttributedString(string: label.text, attributes: [
                .font: font,
                .foregroundColor: label.color,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.saveGState()
            if let maxWidth = label.maxWidth {
                context.clip(to: CGRect(x: label.x, y: label.y - 2, width: maxWidth, height: 18))
            }
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: label.x, y: label.y + font.ascender)
            CTLineDraw(line, context)
            context.restoreGState()
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let data = context.data,
              let texture = device.makeTexture(descriptor: descriptor) else {
            textTexture = nil
            return
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0,
            withBytes: data, bytesPerRow: pixelWidth * 4)
        textTexture = texture
    }

    // MARK: - Helpers

    private func docTime(_ ticks: Int64) -> DocumentTime {
        DocumentTime(exactly: try! RationalTime(value: ticks, timescale: DocumentTime.timescale))!
    }

    // MARK: - Shaders

    /// Compiled at init. `packed_` layouts match the Swift `Vertex` struct
    /// byte-for-byte (24 bytes); the unpacked float4 would pad to 32 and
    /// silently shear every second vertex.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        packed_float2 position;
        packed_float4 color;
    };
    struct VertexOut {
        float4 position [[position]];
        float4 color;
    };
    vertex VertexOut timeline_vertex(
        const device VertexIn* vertices [[buffer(0)]],
        constant float2& viewSize [[buffer(1)]],
        uint vid [[vertex_id]]
    ) {
        VertexIn v = vertices[vid];
        VertexOut out;
        out.position = float4(
            v.position.x / viewSize.x * 2.0 - 1.0,
            1.0 - v.position.y / viewSize.y * 2.0,
            0.0, 1.0);
        out.color = v.color;
        return out;
    }
    fragment float4 timeline_fragment(VertexOut in [[stage_in]]) {
        return in.color;
    }

    struct OverlayOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex OverlayOut overlay_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        OverlayOut out;
        out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        out.uv = uv;
        return out;
    }
    fragment float4 overlay_fragment(
        OverlayOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        return tex.sample(s, in.uv);
    }
    """
}
