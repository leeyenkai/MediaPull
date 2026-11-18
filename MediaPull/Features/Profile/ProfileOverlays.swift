import AppKit
import AVFoundation
import AVKit
import MediaPullCore
import MediaPullLibrary
import SwiftUI

/// What opens over a profile view, inside the pane (no sheets, D-69). Keys act only while it has the keyboard, so nothing
/// fires in a hidden section.
struct ProfileOverlayView: View {
    let overlay: ProfileOverlay
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(.black.opacity(0.85)).onTapGesture(perform: close)
            Group {
                switch overlay {
                case let .post(post, account): PostDetailView(post: post, account: account)
                case let .stories(items, title): StoryPlayerView(items: items, title: title, finished: close)
                case let .video(post): VideoDetailView(post: post)
                }
            }
            .padding(24)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(10)
            .accessibilityLabel("Close")
            .help("Close (Escape)")
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
    }
}

/// A post's media one at a time, beside its account, place, caption and date (R-4004).
struct PostDetailView: View {
    let post: ProfilePost
    let account: String
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                if post.media.indices.contains(index) {
                    FileMediaPreview(file: post.media[index].url).id(post.media[index].id)
                }
                if post.media.count > 1 {
                    HStack {
                        step(-1, "chevron.left.circle.fill", "Previous")
                        Spacer()
                        step(1, "chevron.right.circle.fill", "Next")
                    }
                    .padding(8)
                    VStack {
                        Spacer()
                        HStack(spacing: 5) {
                            ForEach(post.media.indices, id: \.self) { dot in
                                Circle().fill(dot == index ? Color.accentColor : .white.opacity(0.5)).frame(width: 6, height: 6)
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            details.frame(width: 280)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) {
            move(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            move(1)
            return .handled
        }
    }

    private func move(_ by: Int) {
        index = min(max(0, index + by), max(0, post.media.count - 1))
    }

    private func step(_ by: Int, _ symbol: String, _ label: String) -> some View {
        Button { move(by) } label: { Image(systemName: symbol).font(.title).foregroundStyle(.white.opacity(0.85)) }
            .buttonStyle(.plain)
            .opacity((by < 0 ? index > 0 : index < post.media.count - 1) ? 1 : 0)
            .accessibilityLabel(label)
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Initials(name: post.author ?? account, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.author ?? account).font(.headline)
                        if let place = post.place { Text(place).font(.caption).foregroundStyle(.secondary) }
                        if let community = post.community { Text(community).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Divider()
                if let title = post.title, title != post.text { Text(title).font(.headline) }
                if let text = post.text { Caption(text: text) }
                if let date = post.date {
                    Text(date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if post.media.count > 1 { Text("\(index + 1) of \(post.media.count)").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if let file = post.media[safe: index]?.url {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        Button("Open") { NSWorkspace.shared.open(file) }
                    }
                    if let link = post.link { Button("Copy Link") { ProfileFormat.copy(link) } }
                }
                .controlSize(.small)
            }
            .padding(12)
        }
    }
}

/// A caption with its hashtags in the accent colour.
struct Caption: View {
    let text: String

    var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let styled = words.enumerated().reduce(AttributedString()) { result, part in
            var word = AttributedString(String(part.element) + (part.offset < words.count - 1 ? " " : ""))
            if part.element.hasPrefix("#") || part.element.hasPrefix("@") { word.foregroundColor = .accentColor }
            return result + word
        }
        Text(styled).font(.callout).textSelection(.enabled)
    }
}

/// Stories and highlights, one after another with a bar per item: pictures for 5 seconds, videos for their length
/// (R-4004). Its timer runs only while it is shown.
struct StoryPlayerView: View {
    let items: [ProfileMedia]
    let title: String
    let finished: () -> Void
    @State private var index = 0
    @State private var progress = 0.0
    @State private var paused = false
    @FocusState private var focused: Bool
    static let pictureSeconds = 5.0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(items.indices, id: \.self) { bar in
                    GeometryReader { geometry in
                        Capsule().fill(.white.opacity(0.3))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white)
                                    .frame(width: geometry.size.width * (bar < index ? 1 : bar == index ? progress : 0))
                            }
                    }
                    .frame(height: 3)
                }
            }
            HStack {
                Text(title).font(.headline).foregroundStyle(.white)
                Spacer()
                if paused { Text("Paused").font(.caption).foregroundStyle(.white.opacity(0.7)) }
            }
            ZStack {
                if let item = items[safe: index] {
                    if item.isVideo {
                        StoryVideo(url: item.url, paused: paused) { progress = $0 } ended: { next() }
                            .id(item.id)
                    } else {
                        FileMediaPreview(file: item.url).id(item.id)
                    }
                }
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { back() }
                    Color.clear.contentShape(Rectangle()).onTapGesture { next() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: 520)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.space) {
            paused.toggle()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            back()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            next()
            return .handled
        }
        // Pictures advance on a clock that exists only while the player is shown, and stops when paused.
        .task(id: "\(index)|\(paused)") {
            guard let item = items[safe: index], !item.isVideo, !paused else { return }
            while !Task.isCancelled, progress < 1 {
                try? await Task.sleep(for: .milliseconds(50))
                progress = min(1, progress + 0.05 / Self.pictureSeconds)
            }
            if !Task.isCancelled { next() }
        }
    }

    private func next() {
        guard index + 1 < items.count else { return finished() }
        index += 1
        progress = 0
    }

    private func back() {
        index = max(0, index - 1)
        progress = 0
    }
}

/// A story's video, without controls, reporting how far it has played and when it ends.
private struct StoryVideo: NSViewRepresentable {
    let url: URL
    let paused: Bool
    let progress: (Double) -> Void
    let ended: () -> Void

    final class Coordinator {
        var player: AVPlayer?
        var observer: Any?
        var endObserver: NSObjectProtocol?

        isolated deinit {
            if let observer { player?.removeTimeObserver(observer) }
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            player?.pause()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        let player = AVPlayer(url: url)
        view.player = player
        context.coordinator.player = player
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { time in
            let total = player.currentItem?.duration.seconds ?? 0
            if total.isFinite, total > 0 { progress(min(1, time.seconds / total)) }
        }
        context.coordinator.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in ended() }
        if !paused { player.play() }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context _: Context) {
        if paused { view.player?.pause() } else if view.player?.timeControlStatus != .playing { view.player?.play() }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator _: Coordinator) {
        view.player?.pause()
    }
}

/// A saved video with its title, date, description and place in its playlist (R-4005).
struct VideoDetailView: View {
    let post: ProfilePost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let file = post.cover?.url {
                PlayerView(file: file).aspectRatio(16.0 / 9.0, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(post.title ?? "").font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 10) {
                        Text(ProfileFormat.date(post.date))
                        if let list = post.playlistTitle {
                            Text(post.playlistIndex.map { "\(list), number \($0)" } ?? list)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if let text = post.text { Text(text).font(.callout).textSelection(.enabled) }
                    HStack {
                        if let file = post.cover?.url {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        }
                        if let link = post.link { Button("Copy Link") { ProfileFormat.copy(link) } }
                    }
                    .controlSize(.small)
                }
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: 900)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
