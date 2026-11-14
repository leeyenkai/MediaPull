import AppKit
import AVKit
import SwiftUI

/// The video editor's player: the system player view with frame stepping and its built-in trim bar
/// (SPEC section 34). Local files only; remote videos are downloaded through the gate first.
@MainActor
final class VideoStage {
    let view = AVPlayerView()
    let player: AVPlayer

    init(file: URL) {
        player = AVPlayer(url: file)
        view.player = player
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
    }

    /// Seconds from the start of the video at the frame being shown.
    var currentTime: Double {
        let time = player.currentTime()
        return time.isNumeric ? max(0, time.seconds) : 0
    }

    var canTrim: Bool { view.canBeginTrimming }

    /// Shows the trim bar; returns the kept range in seconds, or nil when cancelled.
    func trim(duration: Double) async -> ClosedRange<Double>? {
        guard view.canBeginTrimming else { return nil }
        player.pause()
        let result: AVPlayerViewTrimResult = await withCheckedContinuation { continuation in
            view.beginTrimming { continuation.resume(returning: $0) }
        }
        guard result == .okButton, let item = player.currentItem else { return nil }
        let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
        let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : duration
        guard end > start else { return nil }
        return max(0, start) ... min(duration, end)
    }

    func stop() {
        player.pause()
        view.player = nil
    }
}

struct VideoStageView: NSViewRepresentable {
    let stage: VideoStage

    func makeNSView(context _: Context) -> AVPlayerView { stage.view }

    func updateNSView(_: AVPlayerView, context _: Context) {}
}
