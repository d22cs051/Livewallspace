import AVFoundation
import SwiftUI

struct VideoPlayerView: NSViewRepresentable {
    @ObservedObject var engine: WallpaperPlaybackEngine

    func makeNSView(context: Context) -> PlayerLayerHostingView {
        let view = PlayerLayerHostingView()
        view.playerLayer.videoGravity = engine.videoGravity
        view.playerLayer.player = engine.player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerHostingView, context: Context) {
        if nsView.playerLayer.player !== engine.player {
            nsView.playerLayer.player = engine.player
        }
        if nsView.playerLayer.videoGravity != engine.videoGravity {
            nsView.playerLayer.videoGravity = engine.videoGravity
        }
    }
}

final class PlayerLayerHostingView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        playerLayer.needsDisplayOnBoundsChange = true
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
