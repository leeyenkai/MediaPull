import AppKit
import MediaPullCore
import MediaPullLibrary
import SwiftUI

/// The Profile view of an Organise pane (D-113, SPEC section 40): a folder of saved media as its site showed it, from the
/// saved files only. Nothing is fetched; links are text to copy.
struct ProfilePane: View {
    let source: ProfileSource
    let revision: Int
    @State private var selected: String?
    @State private var build: ProfileBuild?
    @State private var header: AccountProfile?
    @State private var loading = false
    @State private var overlay: ProfileOverlay?
    private var app: AppModel { .shared }

    private var ref: ProfileRef? {
        source.sources.first { $0.id == selected } ?? source.sources.first
    }

    var body: some View {
        HStack(spacing: 0) {
            if source.sources.count > 1 {
                SourceRail(source: source, selected: Binding(get: { ref?.id }, set: { selected = $0 }))
                    .frame(width: 180)
                Divider()
            }
            ZStack {
                content
                if loading, build == nil { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if let overlay {
                ProfileOverlayView(overlay: overlay) { self.overlay = nil }
            }
        }
        .task(id: "\(ref?.id ?? "")|\(revision)") { await load() }
    }

    private func load() async {
        guard let ref else { return }
        loading = true
        defer { loading = false }
        let kind = source.kind
        let built = await Task.detached(priority: .userInitiated) { ProfileBuilder.build(ref, kind: kind) }.value
        guard !Task.isCancelled, ref.id == self.ref?.id else { return }
        build = built
        overlay = nil
        if kind == .profile {
            let key = AccountFolderStore.key(ref.folder.path)
            header = await app.accountFolders.all()
                .first { $0.account == ref.name.lowercased() && AccountFolderStore.key($0.path) == key }?.profile
        } else {
            header = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        if let build {
            VStack(spacing: 0) {
                if build.limited {
                    Text("Only the first \(ProfileBuilder.limit.formatted()) files are shown.")
                        .font(.caption).foregroundStyle(.orange).padding(6)
                }
                switch build.content {
                case let .profile(profile):
                    AccountProfileView(profile: profile, header: header, folder: ref?.folder) { overlay = $0 }
                case let .channel(channel):
                    ChannelView(channel: channel) { overlay = $0 }
                case let .feed(feed):
                    if source.kind == .board {
                        BoardView(feed: feed) { overlay = $0 }
                    } else {
                        FeedTimelineView(feed: feed) { overlay = $0 }
                    }
                }
            }
        }
    }
}

/// What opens over the view: a post with its media, a story or highlight, or a video.
enum ProfileOverlay: Identifiable {
    case post(ProfilePost, account: String)
    case stories([ProfileMedia], title: String)
    case video(ProfilePost)

    var id: String {
        switch self {
        case let .post(post, _): "post:\(post.id)"
        case let .stories(items, title): "stories:\(title):\(items.first?.id ?? "")"
        case let .video(post): "video:\(post.id)"
        }
    }
}

/// Accounts, channels or users of a folder that holds several.
private struct SourceRail: View {
    let source: ProfileSource
    @Binding var selected: String?

    var body: some View {
        List(source.sources, selection: $selected) { ref in
            HStack(spacing: 8) {
                Initials(name: ref.name, size: 24)
                Text(source.kind == .profile ? "@\(ref.name)" : ref.name).lineLimit(1)
            }
            .tag(ref.id)
        }
        .listStyle(.sidebar)
    }
}

/// A thumbnail of a saved file, read off the main actor at about twice the shown size.
struct ProfileThumb: View {
    let url: URL
    var pixel = 360
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) { image = await AppModel.shared.thumbnails.localThumbnail(for: url, maxPixel: pixel)?.image }
    }
}

/// A round picture with an optional accent ring (stories saved), or the first letter of a name.
struct RoundPicture: View {
    let url: URL?
    let name: String
    var size: CGFloat
    var ring = false

    var body: some View {
        Group {
            if let url {
                ProfileThumb(url: url, pixel: Int(size * 2)).clipShape(Circle())
            } else {
                Initials(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .padding(ring ? 3 : 0)
        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: ring ? 2 : 0))
    }
}

struct Initials: View {
    let name: String
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.25))
            .overlay(Text(String(name.first.map(String.init)?.uppercased() ?? "?")).font(.system(size: size * 0.45, weight: .semibold)))
            .frame(width: size, height: size)
    }
}

/// Small marks on a grid cell: several items, a video with its length, pinned.
struct CellMarks: View {
    let post: ProfilePost

    var body: some View {
        HStack(spacing: 4) {
            if post.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
            Spacer(minLength: 0)
            if post.media.count > 1 {
                Image(systemName: "square.on.square").accessibilityLabel("\(post.media.count) items")
            } else if post.media.first?.isVideo == true {
                HStack(spacing: 2) {
                    Image(systemName: "play.fill")
                    if let duration = post.duration { Text(ProfileFormat.length(duration)) }
                }
                .accessibilityLabel("Video")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(5)
    }
}

enum ProfileFormat {
    static func length(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func date(_ date: Date?) -> String {
        date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
