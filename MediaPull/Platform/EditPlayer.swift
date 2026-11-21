import AppKit
import AVKit
import SwiftUI

/// Edit/Frame's player (R-4609, R-4610): the system player view, with the playhead kept for the timeline and waveform.
@MainActor
@Observable
final class EditPlayer {
    @ObservationIgnored let view = AVPlayerView()
    @ObservationIgnored let player = AVPlayer()
    /// Seconds from the start of what is playing.
    private(set) var time: Double = 0
    private(set) var playing = false
    @ObservationIgnored private var observer: Any?

    init() {
        view.player = player
        view.controlsStyle = .inline
        view.showsFrameSteppingButtons = true
        view.videoGravity = .resizeAspect
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if time.isNumeric { self.time = max(0, time.seconds) }
                self.playing = self.player.rate != 0
            }
        }
    }

    isolated deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func load(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        time = 0
    }

    func load(_ item: AVPlayerItem, at seconds: Double = 0) {
        player.replaceCurrentItem(with: item)
        seek(seconds)
    }

    func seek(_ seconds: Double) {
        time = max(0, seconds)
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        time = 0
    }
}

struct EditPlayerView: NSViewRepresentable {
    let player: EditPlayer

    func makeNSView(context _: Context) -> AVPlayerView { player.view }

    func updateNSView(_: AVPlayerView, context _: Context) {}
}
