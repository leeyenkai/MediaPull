import MediaPullCore
import MediaPullLibrary
import SwiftUI

/// An Instagram account as its profile showed it (R-4003).
struct AccountProfileView: View {
    let profile: InstagramProfile
    let header: AccountProfile?
    let folder: URL?
    let open: (ProfileOverlay) -> Void
    @State private var tab: Tab = .posts

    enum Tab: String, CaseIterable, Identifiable {
        case posts = "Posts", reels = "Reels", tagged = "Tagged", reposts = "Reposts"
        var id: String { rawValue }
    }

    private var tabs: [Tab] {
        Tab.allCases.filter { !items($0).isEmpty }
    }

    private func items(_ tab: Tab) -> [ProfilePost] {
        switch tab {
        case .posts: profile.posts
        case .reels: profile.reels
        case .tagged: profile.tagged
        case .reposts: profile.reposts
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerView
                if !profile.highlights.isEmpty { highlights }
                if tabs.count > 1 {
                    Picker("Show", selection: $tab) {
                        ForEach(tabs) { Text("\($0.rawValue) \(items($0).count)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                }
                grid(items(tabs.contains(tab) ? tab : tabs.first ?? .posts), tall: tab == .reels)
            }
            .padding(16)
        }
    }

    private var headerView: some View {
        HStack(alignment: .top, spacing: 20) {
            Button {
                if let day = profile.storyDays.first {
                    open(.stories(day.items, title: "Stories"))
                } else if profile.avatars.count > 1 {
                    open(.stories(profile.avatars, title: "Profile pictures"))
                }
            } label: {
                RoundPicture(url: profile.avatars.first?.url, name: profile.account, size: 96, ring: !profile.storyDays.isEmpty)
            }
            .buttonStyle(.plain)
            .help(profile.storyDays.isEmpty ? "Earlier profile pictures" : "Play the saved stories")
            .accessibilityLabel(profile.storyDays.isEmpty ? "Profile picture" : "Stories")
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.account).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 14) {
                    count(profile.posts.count, "posts")
                    count(profile.reels.count, "Reels")
                    count(profile.highlights.count, "highlights")
                    if !profile.storyDays.isEmpty { count(profile.storyDays.reduce(0) { $0 + $1.items.count }, "stories") }
                }
                Text("saved in this folder").font(.caption).foregroundStyle(.secondary)
                if let name = header?.fullName ?? profile.fullName { Text(name).font(.headline) }
                if let category = header?.category { Text(category).font(.callout).foregroundStyle(.secondary) }
                if let bio = header?.biography?.nonEmpty { Text(bio).font(.callout).textSelection(.enabled) }
                if let link = header?.externalURL?.nonEmpty {
                    HStack(spacing: 6) {
                        Text(link).font(.callout).foregroundStyle(Color.accentColor).lineLimit(1).truncationMode(.middle)
                        Button("Copy Link") { ProfileFormat.copy(link) }.buttonStyle(.link).font(.caption)
                    }
                }
                if let header { Text(shown(header)).font(.caption).foregroundStyle(.secondary) }
                if profile.avatars.count > 1 {
                    Button("Earlier Profile Pictures (\(profile.avatars.count - 1))") {
                        open(.stories(profile.avatars, title: "Profile pictures"))
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func count(_ value: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text("\(value)").fontWeight(.semibold)
            Text(label).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// What Instagram's own header said when it was last read (D-112).
    private func shown(_ header: AccountProfile) -> String {
        var parts: [String] = []
        if let posts = header.postCount { parts.append("\(posts.formatted()) posts") }
        if let followers = header.followerCount { parts.append("\(followers.formatted()) followers") }
        if let following = header.followingCount { parts.append("\(following.formatted()) following") }
        guard !parts.isEmpty else { return "Profile read on \(ProfileFormat.date(header.seen))" }
        return "Instagram showed " + parts.joined(separator: ", ") + " on \(ProfileFormat.date(header.seen))"
    }

    private var highlights: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(profile.highlights) { highlight in
                    Button {
                        let items = highlight.items.isEmpty ? highlight.cover.map { [$0] } ?? [] : highlight.items
                        open(.stories(items, title: highlight.title))
                    } label: {
                        VStack(spacing: 4) {
                            RoundPicture(url: highlight.cover?.url, name: highlight.title, size: 64, ring: true)
                            Text(highlight.title).font(.caption).lineLimit(1).frame(width: 76)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Highlight \(highlight.title)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func grid(_ posts: [ProfilePost], tall: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(posts) { post in
                Button { open(.post(post, account: profile.account)) } label: {
                    Color.clear
                        .aspectRatio(tall ? 9.0 / 16.0 : 1, contentMode: .fit)
                        .overlay { if let cover = post.cover { ProfileThumb(url: cover.url) } }
                        .overlay(alignment: .top) { CellMarks(post: post) }
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(post.text ?? ProfileFormat.date(post.date))
            }
        }
    }
}

/// A video channel (R-4005).
struct ChannelView: View {
    let channel: ChannelProfile
    let open: (ProfileOverlay) -> Void
    @State private var showPlaylists = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Initials(name: channel.name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.title2.weight(.semibold))
                        Text("\(channel.videos.count) video\(channel.videos.count == 1 ? "" : "s") saved, "
                            + "\(ProfileFormat.length(channel.totalDuration)) in all")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !channel.playlists.isEmpty {
                    Picker("Show", selection: $showPlaylists) {
                        Text("Videos").tag(false)
                        Text("Playlists").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                }
                if showPlaylists, !channel.playlists.isEmpty {
                    ForEach(channel.playlists, id: \.title) { list in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(list.title).font(.headline)
                            videoGrid(list.videos)
                        }
                    }
                } else {
                    videoGrid(channel.videos)
                }
            }
            .padding(16)
        }
    }

    private func videoGrid(_ videos: [ProfilePost]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 14) {
            ForEach(videos) { video in
                Button { open(.video(video)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Color.clear
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                if let file = video.thumbnail ?? video.cover?.url { ProfileThumb(url: file, pixel: 480) }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if let duration = video.duration {
                                    Text(ProfileFormat.length(duration)).font(.caption2.weight(.semibold)).padding(3)
                                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).foregroundStyle(.white)
                                        .padding(5)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(video.title ?? "").font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(ProfileFormat.date(video.date)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// X, Bluesky and Reddit posts, newest first (R-4006).
struct FeedTimelineView: View {
    let feed: FeedProfile
    let open: (ProfileOverlay) -> Void

    var body: some View {
        List(feed.posts) { post in
            HStack(alignment: .top, spacing: 10) {
                Initials(name: post.author ?? feed.name, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if feed.site == "reddit", let community = post.community { Text("r/\(community)").fontWeight(.semibold) }
                        Text(feed.site == "reddit" ? "u/\(post.author ?? "")" : post.author ?? feed.name)
                            .fontWeight(feed.site == "reddit" ? .regular : .semibold)
                            .foregroundStyle(feed.site == "reddit" ? .secondary : .primary)
                        Text(ProfileFormat.date(post.date)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    if let title = post.title, title != post.text { Text(title).font(.headline) }
                    if let text = post.text { Text(text).font(.body).textSelection(.enabled) }
                    pictures(post)
                }
            }
            .padding(.vertical, 6)
        }
        .listStyle(.inset)
    }

    private func pictures(_ post: ProfilePost) -> some View {
        let shown = Array(post.media.prefix(4))
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: shown.count > 1 ? 2 : 1), spacing: 3) {
            ForEach(shown) { media in
                Button { open(.post(post, account: feed.name)) } label: {
                    Color.clear
                        .aspectRatio(shown.count > 1 ? 1 : 16.0 / 10.0, contentMode: .fit)
                        .overlay { ProfileThumb(url: media.url, pixel: 600) }
                        .overlay { if media.isVideo { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white) } }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 520)
    }
}

/// Pinterest pins in columns of varying height (R-4006).
struct BoardView: View {
    let feed: FeedProfile
    let open: (ProfileOverlay) -> Void

    var body: some View {
        GeometryReader { geometry in
            let columns = max(2, min(6, Int(geometry.size.width / 200)))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(feed.name).font(.title2.weight(.semibold))
                    Text("\(feed.posts.count) pins saved").font(.callout).foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(0 ..< columns, id: \.self) { column in
                            LazyVStack(spacing: 10) {
                                ForEach(Array(feed.posts.enumerated()).filter { $0.offset % columns == column }.map(\.element)) { pin in
                                    PinCard(pin: pin) { open(.post(pin, account: feed.name)) }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct PinCard: View {
    let pin: ProfilePost
    let action: () -> Void
    @State private var ratio: CGFloat = 1

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { if let cover = pin.cover { ProfileThumb(url: cover.url, pixel: 400) } }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if let title = pin.title ?? pin.text { Text(title).font(.callout.weight(.medium)).lineLimit(2) }
                if let text = pin.text, pin.title != nil { Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: pin.id) {
            guard let cover = pin.cover?.url,
                  let image = await AppModel.shared.thumbnails.localThumbnail(for: cover, maxPixel: 400)?.image, image.height > 0
            else { return }
            ratio = max(0.4, min(2.5, CGFloat(image.width) / CGFloat(image.height)))
        }
    }
}
