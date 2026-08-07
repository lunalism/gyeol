import GyeolCore
import SwiftUI

/// SwiftUI bridge for the timeline `MTKView`. All wiring, no logic: the
/// playhead comes from the controller's frame index (§7.4-8), scrub events
/// go back to the controller's transport, and document changes flow into
/// the renderer.
struct TimelineHostView: NSViewRepresentable {
    // Strong `file`, matching DocumentView's documented G5 stance: the
    // bridged struct is part of the window chain NSDocument.close() tears
    // down. (M2.2's g5 rounds briefly indicted this reference; the leaks
    // reference tree exonerated it — the residual holder was AppKit's own
    // window caching. See the milestone report.)
    let file: GyeolDocumentFile
    let playback: PlaybackController
    let mediaURLs: [MediaID: URL]

    func makeNSView(context: Context) -> TimelineMetalView {
        let view = TimelineMetalView()
        // weak playback in every closure: the VIEW must not keep the
        // controller (and through it the player) alive past document
        // close (G5); ownership flows document → controller, never
        // timeline → controller.
        view.playheadFrameProvider = { [weak playback] in
            playback?.timelinePlayheadFrame ?? 0
        }
        // The display link → controller wire. `--playhead-gate-cut-link` is
        // the playhead gate's SELF-TEST (same role as `--menu-gate-drop-save`
        // and `--g5-leak`): with this wire cut the display-only frame can
        // never advance, and `--playhead-probe` must end in FAIL / exit 1.
        // The app test suite stays GREEN with it cut — the tests call
        // `pollDisplayedFrame()` themselves and never build this view, which
        // is the whole reason the probe exists.
        if !CommandLine.arguments.contains("--playhead-gate-cut-link") {
            view.onPlaybackTick = { [weak playback] in
                playback?.pollDisplayedFrame()
            }
        }
        view.onScrubBegan = { [weak playback] in playback?.beginScrub() }
        view.onScrub = { [weak playback] frame in playback?.scrub(toFrame: frame) }
        view.onScrubEnded = { [weak playback] in playback?.endScrub() }
        // weak file, same G5 rationale: selection is a write into app
        // state, not a reason for the view to own the document.
        view.onSelectClip = { [weak file] selection in
            file?.selectedClip = selection
        }
        return view
    }

    func updateNSView(_ view: TimelineMetalView, context: Context) {
        view.selectedClipID = file.selectedClip?.clipID
        view.apply(
            document: file.document,
            mediaURLs: mediaURLs,
            isPlaying: playback.isPlaying)
        // Any observed transport change (step, stop snap, scrub) redraws;
        // on-demand mode coalesces this into at most one draw per frame.
        view.needsDisplay = true
    }
}
