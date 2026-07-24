import AVFoundation
import SwiftUI

/// Minimal AVPlayerLayer host. AVKit's VideoPlayer brings its own transport
/// controls, and M1's transport must be frame-index driven — so the layer
/// is hosted bare and the controls live in SwiftUI.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerBackedView {
        let view = PlayerBackedView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerBackedView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerBackedView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
