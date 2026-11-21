import AppKit
import AVKit
import ImageIO
import MediaPullCore
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

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(file, into: view, flag: context.coordinator.stopFlag)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.file != file else { return }
        context.coordinator.file = file
        context.coordinator.stop()
        context.coordinator.stopFlag = StopFlag()
        load(file, into: view, flag: context.coordinator.stopFlag)
    }

    func makeCoordinator() -> Coordinator { Coordinator(file: file) }

    static func dismantleNSView(_: NSImageView, coordinator: Coordinator) { coordinator.stop() }

    final class Coordinator {
        var file: URL
        /// Set to stop an image sequence the system's animator is playing.
        var stopFlag = StopFlag()
        init(file: URL) { self.file = file }
        func stop() { stopFlag.stopped = true }
    }

    final class StopFlag: @unchecked Sendable {
        var stopped = false
    }

    /// A long GIF can be many megabytes: it is read off the main actor. HEIF image sequences are played by the system's
    /// animator, frame by frame (R-4204).
    private func load(_ file: URL, into view: NSImageView, flag: StopFlag) {
        if MediaFormat.fromExtension(file.pathExtension) == .heic {
            CGAnimateImageAtURLWithBlock(file as CFURL, nil) { [weak view] _, image, stop in
                guard let view, !flag.stopped else {
                    stop.pointee = true
                    return
                }
                view.image = NSImage(cgImage: image, size: .zero)
            }
            return
        }
        Task { [weak view] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: file) }.value // lint:allow main-io detached
            guard let view, let data else { return }
            view.image = NSImage(data: data)
        }
    }
}
