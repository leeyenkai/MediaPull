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
        load(file, into: view)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.file != file else { return }
        context.coordinator.file = file
        load(file, into: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    final class Coordinator {
        var file: URL
        init(file: URL) { self.file = file }
    }

    /// A long GIF can be many megabytes: it is read off the main actor.
    private func load(_ file: URL, into view: NSImageView) {
        Task { [weak view] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value
            guard let view, let data else { return }
            view.image = NSImage(data: data)
        }
    }
}
