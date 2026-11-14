import AppKit
import AVKit
import SwiftUI

/// Plays a local video file with the system's inline controls. Remote media is downloaded through
/// the network gate first; AVFoundation never receives a remote URL (SPEC section 5).
struct PlayerView: NSViewRepresentable {
    var file: URL

    func makeNSView(context _: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: file)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        guard let current = (view.player?.currentItem?.asset as? AVURLAsset)?.url, current != file else { return }
        view.player?.pause()
        view.player = AVPlayer(url: file)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator _: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Shows an animated GIF with its animation, scaled to fit.
struct AnimatedImageView: NSViewRepresentable {
    var file: URL

    func makeNSView(context _: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.image = NSImage(contentsOf: file)
        return view
    }

    func updateNSView(_ view: NSImageView, context _: Context) {}
}
