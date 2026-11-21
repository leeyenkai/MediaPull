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
    @ObservationIgnored private var boundary: Any?

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
        if let boundary { player.removeTimeObserver(boundary) }
    }

    /// The stop point Play Selection set, gone once it is reached or another file is loaded.
    private func clearBoundary() {
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = nil
    }

    func load(_ url: URL) {
        clearBoundary()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        time = 0
    }

    func load(_ item: AVPlayerItem, at seconds: Double = 0) {
        clearBoundary()
        player.replaceCurrentItem(with: item)
        seek(seconds)
    }

    func seek(_ seconds: Double) {
        time = max(0, seconds)
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Plays from `start` and stops at `end`.
    func play(from start: Double, to end: Double) {
        clearBoundary()
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
                                                  queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.clearBoundary()
            }
        }
        seek(start)
        player.play()
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
    }

    func stop() {
        clearBoundary()
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
