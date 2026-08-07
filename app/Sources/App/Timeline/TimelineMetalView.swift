import AppKit
import GyeolCore
import MetalKit

/// The single timeline `MTKView` (D28).
///
/// RENDER CADENCE (PRD §5.2 "놀고 있을 때 그리지 않는다"):
/// - Default: on-demand. `isPaused = true` + `enableSetNeedsDisplay = true`
///   — the view draws only when something marks it dirty (viewport change,
///   document change, scrub, async tile arrival).
/// - During playback ONLY: a `CADisplayLink` from
///   `NSView.displayLink(target:selector:)` drives continuous redraw.
///   HEADER-VERIFIED (M2.2 pre-work, AppKit NSView.h line 616): the method
///   is `-displayLinkWithTarget:selector:` / Swift
///   `displayLink(target:selector:)`, macOS 14.0+, returns a nonnull
///   `CADisplayLink` whose callback fires in sync with the display the
///   view is on and NOT while the view is hidden or off-screen. Per the
///   CADisplayLink header the link must be added to a run loop, is
///   implicitly retained by it, and RETAINS THE TARGET until
///   `invalidate()` — which makes the teardown in `viewWillMove(toWindow:)`
///   load-bearing for document deallocation (G5).
final class TimelineMetalView: MTKView {
    let renderer: TimelineRenderer
    private(set) var viewport = TimelineViewport.initial

    /// Frame index for the playhead. Supplied by PlaybackController —
    /// stopped: the authoritative playhead; playing: the display-only frame
    /// derived from the displayed frame's PTS. Never `currentTime()`
    /// (§7.4-8).
    var playheadFrameProvider: (() -> Int)?
    /// Called every display-link tick while playing, BEFORE the redraw, so
    /// the controller can refresh the display-only frame from the video
    /// output.
    var onPlaybackTick: (() -> Void)?
    var onScrubBegan: (() -> Void)?
    var onScrub: ((Int) -> Void)?
    var onScrubEnded: (() -> Void)?
    /// Click selection (M2.3): nil means clicked empty space (deselect).
    var onSelectClip: ((GyeolDocumentFile.SelectedClip?) -> Void)?
    var selectedClipID: ClipID? {
        didSet { if selectedClipID != oldValue { needsDisplay = true } }
    }

    private var lastDocument: GyeolDocument?
    private var lastMediaURLs: [MediaID: URL] = [:]
    private var projectRate: FrameRate?
    private var displayLinkHandle: CADisplayLink?
    private var scrubbing = false
    // nonisolated(unsafe): written once on MainActor in init, read once
    // more from the nonisolated deinit — the same narrow escape hatch
    // PlaybackController uses for its observers.
    nonisolated(unsafe) private var waveformObserver: (any NSObjectProtocol)?

    init() {
        guard let renderer = TimelineRenderer() else {
            // Apple Silicon-only product (§7.2): a Mac without a Metal
            // device is outside the support matrix entirely.
            fatalError("Metal is unavailable; Gyeol requires Apple Silicon")
        }
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = TimelineRenderer.clearColor
        isPaused = true
        enableSetNeedsDisplay = true
        // Async waveform tiles: redraw when one lands (§5.2 — drawn empty,
        // filled on a later frame; the render path never waits on IO).
        waveformObserver = NotificationCenter.default.addObserver(
            forName: WaveformStore.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.renderer.noteContentChanged()
                self.needsDisplay = true
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let waveformObserver {
            NotificationCenter.default.removeObserver(waveformObserver)
        }
    }

    // MARK: - Deterministic zoom (부록 A-43 ①)

    /// The outcome of a `--playhead-span` request. There is no `clamped`
    /// case ON PURPOSE: the zoom is a MEASUREMENT CONDITION for the
    /// waveform-against-hearing check (A-43 ①), and a silently clamped
    /// span is a condition the session log would report as the requested
    /// one while the screen showed something else. The probe refuses.
    enum SpanOutcome {
        case applied(ticksPerPoint: Double, widthPoints: Double)
        /// The view has not been laid out yet — nothing to divide by.
        case widthUnavailable
        /// The span is outside what `TimelineViewport`'s zoom limits allow
        /// at this width; the attainable range comes back so the refusal
        /// can name it.
        case unattainable(widthPoints: Double, minSeconds: Double, maxSeconds: Double)
    }

    /// Sets the visible time window to exactly `seconds`, anchored at the
    /// document origin.
    ///
    /// Expressed as a SPAN and not as ticks-per-point because the span is
    /// what the person can check against the ruler; ticks/point is an
    /// internal scale factor nobody can verify by looking.
    /// The arithmetic lives on `TimelineViewport` (a pure value type the
    /// test target can reach without a Metal device); this method is the
    /// view-state half — read the width, apply, mark dirty.
    func setVisibleSpan(seconds: Double) -> SpanOutcome {
        let width = Double(bounds.width)
        guard width > 0 else { return .widthUnavailable }
        guard let ticksPerPoint = TimelineViewport.ticksPerPoint(
            forSpanSeconds: seconds, width: width) else {
            let attainable = TimelineViewport.attainableSpanSeconds(width: width)
            return .unattainable(
                widthPoints: width,
                minSeconds: attainable.lowerBound,
                maxSeconds: attainable.upperBound)
        }
        viewport.ticksPerPoint = ticksPerPoint
        viewport.visibleStartTicks = 0
        needsDisplay = true
        return .applied(ticksPerPoint: ticksPerPoint, widthPoints: width)
    }

    /// The span currently on screen. Reported by the playhead probe whether
    /// or not `--playhead-span` was given, so a session log always states
    /// its own screen condition — A-43 ① was invisible precisely because
    /// the log did not.
    func currentVisibleSpan() -> (seconds: Double, widthPoints: Double, ticksPerPoint: Double)? {
        let width = Double(bounds.width)
        guard width > 0 else { return nil }
        return (TimelineViewport.spanSeconds(
                    ticksPerPoint: viewport.ticksPerPoint, width: width),
                width, viewport.ticksPerPoint)
    }

    // MARK: - Host inputs

    func apply(document: GyeolDocument, mediaURLs: [MediaID: URL], isPlaying: Bool) {
        // Value compare, only here: M2.2's document never mutates after
        // load, so this comparison is one full pass on open and cheap
        // short-circuits afterwards.
        if document != lastDocument || mediaURLs != lastMediaURLs {
            lastDocument = document
            lastMediaURLs = mediaURLs
            projectRate = document.settings.frameRate
            renderer.setDocument(document, mediaURLs: mediaURLs)
            needsDisplay = true
        }
        setContinuousRedraw(isPlaying)
    }

    // MARK: - Display link (playback only, D28)

    private func setContinuousRedraw(_ on: Bool) {
        if on {
            guard displayLinkHandle == nil else { return }
            let link = displayLink(target: self, selector: #selector(playbackTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLinkHandle = link
        } else {
            displayLinkHandle?.invalidate()
            displayLinkHandle = nil
        }
    }

    @objc private func playbackTick(_ sender: CADisplayLink) {
        onPlaybackTick?()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            // The link retains this view (header contract); a closing
            // window must break that or the view — and through its
            // closures, the controller — survives close (G5).
            setContinuousRedraw(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Draw

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0,
              let passDescriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable else { return }
        let inputs = TimelineRenderer.FrameInputs(
            viewport: viewport,
            sizePoints: bounds.size,
            scale: window?.backingScaleFactor ?? 2,
            playheadFrame: playheadFrameProvider?() ?? 0,
            selectedClipID: selectedClipID)
        renderer.draw(inputs: inputs, passDescriptor: passDescriptor) { commandBuffer in
            commandBuffer.present(drawable)
        }
    }

    // MARK: - Navigation events

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            let anchor = convert(event.locationInWindow, from: nil).x
            viewport.zoom(by: pow(1.01, -event.scrollingDeltaY), anchorX: anchor)
        } else {
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            viewport.pan(byPoints: -delta)
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil).x
        viewport.zoom(by: 1 / (1 + event.magnification), anchorX: anchor)
        needsDisplay = true
    }

    // MARK: - Scrubbing (M2.2 task 4)

    // Ruler drag scrubs (a transport operation); a click in the lanes
    // selects (M2.3). Pixel→time is viewport math HERE, pixel→track is the
    // shared lane layout, and "which clip is at this time" is Core's hit
    // test — the same binary search the visibility queries use (D28).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= TimelineRenderer.rulerHeight {
            scrubbing = true
            onScrubBegan?()
            onScrub?(frame(atX: point.x))
            needsDisplay = true
            return
        }
        guard let document = lastDocument else { return }
        let layout = TimelineLaneLayout(
            document: document, height: bounds.height,
            rulerHeight: TimelineRenderer.rulerHeight,
            subtitleLaneHeight: TimelineRenderer.subtitleLaneHeight)
        guard let trackIndex = layout.documentTrackIndex(atY: point.y) else {
            onSelectClip?(nil)
            return
        }
        let track = document.tracks[trackIndex]
        let time = DocumentTime(ticks: viewport.ticks(atX: point.x))
        if let clip = VisibleRange.clip(at: time, in: track) {
            onSelectClip?(.init(trackID: track.id, clipID: clip.id))
        } else {
            onSelectClip?(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard scrubbing else { return }
        onScrub?(frame(atX: convert(event.locationInWindow, from: nil).x))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard scrubbing else { return }
        scrubbing = false
        onScrubEnded?()
        needsDisplay = true
    }

    /// Pointer x → frame index: pixels→ticks is app-side viewport math,
    /// ticks→frame goes through FrameMapping — the one mapping, never
    /// `ticks / ticksPerFrame` (§6.2).
    private func frame(atX x: CGFloat) -> Int {
        guard let projectRate else { return 0 }
        let ticks = viewport.ticks(atX: x)
        return FrameMapping.frameIndex(at: DocumentTime(ticks: ticks), rate: projectRate)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}
