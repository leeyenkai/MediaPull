import Foundation
import MediaPullCore

// MARK: Profile views (D-113, SPEC section 40): what a folder of saved media shows, read from its files alone.

/// The kind of layout a folder is shown in.
public enum ProfileKind: String, Sendable, Hashable {
    /// Instagram accounts.
    case profile
    /// Video channels.
    case channel
    /// X, Bluesky and Reddit.
    case timeline
    /// Pinterest.
    case board
}

/// One account, channel, user, subreddit or board the view can show.
public struct ProfileRef: Sendable, Hashable, Identifiable {
    public var folder: URL
    /// The account, channel, user or community, as its files name it.
    public var name: String
    /// The site (`instagram`, `youtube`, `twitter`, …).
    public var site: String
    public var id: String { folder.standardizedFileURL.path }

    public init(folder: URL, name: String, site: String) {
        self.folder = folder
        self.name = name
        self.site = site
    }
}

/// What a folder can be shown as: one kind, one or more sources.
public struct ProfileSource: Sendable, Hashable {
    public var kind: ProfileKind
    public var sources: [ProfileRef]

    public init(kind: ProfileKind, sources: [ProfileRef]) {
        self.kind = kind
        self.sources = sources
    }
}

public enum ProfileDetector {
    static let timelineSites: Set<String> = ["twitter", "bluesky", "reddit"]
    static let boardSites: Set<String> = ["pinterest"]

    /// What `folder` can be shown as (R-4001): an Instagram account folder, a channel, a user, subreddit or board folder, or a
    /// folder holding several of one kind (two levels down at most); nil for anything else. Reads at most a sample of
    /// metadata files; metadata kept only in iCloud is never read.
    public static func detect(_ folder: URL) -> ProfileSource? {
        if let one = single(folder) { return ProfileSource(kind: one.kind, sources: [one.ref]) }
        var found: [(kind: ProfileKind, ref: ProfileRef)] = []
        for child in subfolders(folder).prefix(200) {
            if let one = single(child) {
                found.append(one)
            } else {
                for grandchild in subfolders(child).prefix(50) {
                    if let one = single(grandchild) { found.append(one) }
                }
            }
            if found.count >= 200 { break }
        }
        // The kind most of them are; a folder of mixed kinds shows its most common one.
        let counts = Dictionary(grouping: found, by: \.kind).mapValues(\.count)
        guard let kind = counts.max(by: { ($0.value, $0.key.rawValue) < ($1.value, $1.key.rawValue) })?.key else { return nil }
        let refs = found.filter { $0.kind == kind }.map(\.ref).sorted { $0.name.lowercased() < $1.name.lowercased() }
        return ProfileSource(kind: kind, sources: refs)
    }

    /// `folder` itself as one source.
    static func single(_ folder: URL) -> (kind: ProfileKind, ref: ProfileRef)? {
        if let match = AccountFolders.detect(folder, stopAt: folder),
           match.folder.standardizedFileURL.path == folder.standardizedFileURL.path
        {
            return (.profile, ProfileRef(folder: folder, name: match.account, site: "instagram"))
        }
        let sample = metadataSample(folder)
        guard !sample.isEmpty else { return nil }
        var votes: [String: Int] = [:]
        var kinds: [String: ProfileKind] = [:]
        for meta in sample {
            guard let site = meta["category"] as? String, site != "instagram" else { continue }
            let kind: ProfileKind? = ["video", "audio"].contains(meta["subcategory"] as? String ?? "") ? .channel
                : timelineSites.contains(site) ? .timeline : boardSites.contains(site) ? .board : nil
            guard let kind else { continue }
            let name = (kind == .channel ? nil : (meta["community"] as? String)?.nonEmpty) ?? (meta["username"] as? String)?.nonEmpty
            guard let name else { continue }
            let key = "\(site)\u{1F}\(name)"
            votes[key, default: 0] += 1
            kinds[key] = kind
        }
        // A user's files name the user; a subreddit's or board's files name the community.
        guard let best = votes.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }), best.value * 5 >= sample.count * 4,
              let kind = kinds[best.key] else { return nil }
        let parts = best.key.split(separator: "\u{1F}", maxSplits: 1).map(String.init)
        return (kind, ProfileRef(folder: folder, name: parts[1], site: parts[0]))
    }

    static func subfolders(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Up to 80 metadata files of the media in `folder` and below.
    static func metadataSample(_ folder: URL) -> [[String: Any]] {
        var sample: [[String: Any]] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var looked = 0
        while let url = walker?.nextObject() as? URL, sample.count < 80, looked < 400 {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
            looked += 1
            if let meta = ProfileBuilder.metadata(of: url) { sample.append(meta) }
        }
        return sample
    }
}

// MARK: What the views show

/// One saved file in a post.
public struct ProfileMedia: Sendable, Hashable, Identifiable {
    public var url: URL
    public var isVideo: Bool
    public var num: Int
    /// Seconds, from the metadata file.
    public var duration: Double?
    public var id: String { url.path }
}

/// A post, Reel, story, video, pin or timeline post, made of its files in order.
public struct ProfilePost: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable { case post, reel, tagged, repost, story, highlight, avatar, video, item }

    public var id: String
    public var kind: Kind
    public var media: [ProfileMedia]
    public var date: Date?
    /// The caption or post text.
    public var text: String?
    public var title: String?
    public var author: String?
    public var community: String?
    public var place: String?
    public var pinned = false
    public var link: String?
    public var highlightTitle: String?
    public var highlightCover = false
    public var playlistTitle: String?
    public var playlistIndex: Int?
    /// A video's thumbnail saved beside it.
    public var thumbnail: URL?

    public var cover: ProfileMedia? { media.first }
    public var duration: Double? { media.count == 1 ? media.first?.duration : nil }
}

public struct ProfileHighlight: Sendable, Hashable, Identifiable {
    public var title: String
    public var cover: ProfileMedia?
    public var items: [ProfileMedia]
    public var id: String { title }
}

public struct ProfileStoryDay: Sendable, Hashable, Identifiable {
    public var day: Date
    public var items: [ProfileMedia]
    public var id: Date { day }
}

public struct InstagramProfile: Sendable, Hashable {
    public var account: String
    public var fullName: String?
    /// Newest first.
    public var avatars: [ProfileMedia]
    /// Pinned first, then newest first.
    public var posts: [ProfilePost]
    public var reels: [ProfilePost]
    public var tagged: [ProfilePost]
    public var reposts: [ProfilePost]
    public var highlights: [ProfileHighlight]
    /// Newest day first; each day's stories oldest first, as they were posted.
    public var storyDays: [ProfileStoryDay]
}

public struct ChannelProfile: Sendable, Hashable {
    public var name: String
    public var site: String
    /// Newest first.
    public var videos: [ProfilePost]
    /// By title; each in its playlist's order.
    public var playlists: [(title: String, videos: [ProfilePost])]

    public static func == (a: ChannelProfile, b: ChannelProfile) -> Bool {
        a.name == b.name && a.site == b.site && a.videos == b.videos && a.playlists.map(\.title) == b.playlists.map(\.title)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(videos)
    }

    public var totalDuration: Double { videos.compactMap(\.duration).reduce(0, +) }
}

public struct FeedProfile: Sendable, Hashable {
    public var name: String
    public var site: String
    /// Newest first.
    public var posts: [ProfilePost]
}

public enum ProfileContent: Sendable, Hashable {
    case profile(InstagramProfile)
    case channel(ChannelProfile)
    case feed(FeedProfile)
}

public struct ProfileBuild: Sendable, Hashable {
    public var content: ProfileContent
    /// More media files than the limit: only the first were read (R-4002).
    public var limited: Bool
}

public enum ProfileBuilder {
    public static let limit = 50000

    /// Groups a source's files into what its view shows (R-4003 to R-4006). Off the main actor: it lists the folder and reads
    /// every metadata file.
    public static func build(_ ref: ProfileRef, kind: ProfileKind, limit: Int = ProfileBuilder.limit) -> ProfileBuild {
        let (files, limited) = list(ref.folder, limit: limit)
        let content: ProfileContent = switch kind {
        case .profile: .profile(instagram(ref, files: files))
        case .channel: .channel(channel(ref, files: files))
        case .timeline, .board: .feed(FeedProfile(name: ref.name, site: ref.site, posts: feed(files)))
        }
        return ProfileBuild(content: content, limited: limited)
    }

    /// A media file with its metadata, and its folders below the source's folder.
    struct File {
        var url: URL
        var meta: [String: Any]
        var folders: [String]
        var isVideo: Bool

        func string(_ key: String) -> String? {
            if let value = meta[key] as? String { return value.nonEmpty }
            if let value = meta[key] as? NSNumber, !(meta[key] is Bool) { return value.stringValue }
            return nil
        }

        func int(_ key: String) -> Int? { (meta[key] as? NSNumber).map(\.intValue) ?? string(key).flatMap(Int.init) }
        func bool(_ key: String) -> Bool { (meta[key] as? Bool) ?? false }
        var date: Date? { string("date").flatMap(DateFormats.parseEngineDate) }
        var media: ProfileMedia {
            ProfileMedia(url: url, isVideo: isVideo, num: int("num") ?? 1, duration: (meta["duration"] as? NSNumber)?.doubleValue)
        }
    }

    static func metadata(of file: URL) -> [String: Any]? {
        let sidecar = Sidecar.sidecarURL(for: file)
        guard !FileFlags.isDataless(sidecar), let data = try? Data(contentsOf: sidecar), data.count < 1 << 20 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func list(_ folder: URL, limit: Int) -> (files: [File], limited: Bool) {
        let base = folder.standardizedFileURL.pathComponents.count
        var files: [File] = []
        var limited = false
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", let format = MediaFormat.fromExtension(ext), format.kind == .image || format.kind == .video else {
                continue
            }
            guard files.count < limit else {
                limited = true
                break
            }
            let parts = url.standardizedFileURL.pathComponents
            let folders = Array(parts.dropFirst(base).dropLast()).map { $0.lowercased() }
            files.append(File(url: url, meta: metadata(of: url) ?? [:], folders: folders, isVideo: format.kind == .video))
        }
        return (files, limited)
    }

    /// Files of one post together, in their order in the post (never trusting `count`), the post's details from the first
    /// file that has them.
    static func group(_ files: [File], kind: (File) -> ProfilePost.Kind) -> [ProfilePost] {
        var order: [String] = []
        var byPost: [String: [File]] = [:]
        for file in files {
            let id = "\(kind(file).rawValue):" + (file.string("post_id") ?? file.string("post_shortcode") ?? file.url.path)
            if byPost[id] == nil { order.append(id) }
            byPost[id, default: []].append(file)
        }
        return order.map { id in
            let parts = (byPost[id] ?? []).sorted {
                ($0.int("num") ?? 0, $0.url.lastPathComponent) < ($1.int("num") ?? 0, $1.url.lastPathComponent)
            }
            let first = parts.first
            var post = ProfilePost(id: id, kind: first.map(kind) ?? .item, media: parts.map(\.media))
            post.date = parts.compactMap(\.date).min()
            post.text = parts.lazy.compactMap { $0.string("description") }.first
            post.title = parts.lazy.compactMap { $0.string("title") }.first
            post.author = parts.lazy.compactMap { $0.string("author") ?? $0.string("username") }.first
            post.community = parts.lazy.compactMap { $0.string("community") }.first
            post.place = parts.lazy.compactMap { $0.string("location_name") }.first
            post.pinned = parts.contains { $0.bool("pinned") }
            post.link = parts.lazy.compactMap { $0.string("post_url") ?? $0.string("source_url") }.first
            post.highlightTitle = parts.lazy.compactMap { $0.string("highlight_title") }.first
            post.playlistTitle = parts.lazy.compactMap { $0.string("playlist_title") }.first
            post.playlistIndex = parts.lazy.compactMap { $0.int("playlist_index") }.first
            return post
        }
    }

    static func newestFirst(_ a: ProfilePost, _ b: ProfilePost) -> Bool {
        (a.date ?? .distantPast, a.id) > (b.date ?? .distantPast, b.id)
    }

    // MARK: Instagram

    static func instagramKind(_ file: File) -> ProfilePost.Kind {
        let sub = file.string("subcategory") ?? ""
        let folders = Set(file.folders)
        switch sub {
        case "avatar": return .avatar
        case "stories", "stories-tray": return .story
        case "highlights": return .highlight
        case "reels": return .reel
        case "posts", "tagged", "reposts", "saved", "collection":
            if folders.contains("tagged") || sub == "tagged" { return .tagged }
            if folders.contains("reposts") || sub == "reposts" { return .repost }
            return file.string("product_type") == "clips" ? .reel : .post
        default:
            // No metadata: the folder says what it is.
            if folders.contains("profile pictures") { return .avatar }
            if folders.contains("stories") { return .story }
            if folders.contains("highlights") { return .highlight }
            if folders.contains("reels") { return .reel }
            if folders.contains("tagged") { return .tagged }
            if folders.contains("reposts") { return .repost }
            return .post
        }
    }

    static func instagram(_ ref: ProfileRef, files allFiles: [File]) -> InstagramProfile {
        // Account details are lists and the profile, not media; a file of another account in its folder is that account's.
        let files = allFiles.filter { !$0.folders.contains(SaveTarget.accountDetailsFolder.lowercased()) }
        let account = ref.name.lowercased()
        var byKind: [ProfilePost.Kind: [File]] = [:]
        for file in files {
            byKind[instagramKind(file), default: []].append(file)
        }
        func posts(_ kind: ProfilePost.Kind) -> [ProfilePost] { group(byKind[kind] ?? [], kind: { _ in kind }) }
        let mainPosts = posts(.post).sorted { a, b in a.pinned != b.pinned ? a.pinned : newestFirst(a, b) }
        let avatars = (byKind[.avatar] ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.map(\.media)
        // Highlights by title (or id when untitled), the cover the file marked as one, else the first item.
        var highlightOrder: [String] = []
        var highlightFiles: [String: [File]] = [:]
        for file in byKind[.highlight] ?? [] {
            let title = file.string("highlight_title") ?? file.folders.last.map { $0 == "highlights" ? "" : $0 }?.nonEmpty
                ?? file.string("post_id") ?? "Highlight"
            if highlightFiles[title] == nil { highlightOrder.append(title) }
            highlightFiles[title, default: []].append(file)
        }
        // Newest highlight first, as a profile lists them most recently added first.
        let latest = { (title: String) in (highlightFiles[title] ?? []).compactMap(\.date).max() ?? .distantPast }
        highlightOrder.sort { (latest($0), $1) > (latest($1), $0) }
        let highlights = highlightOrder.map { title -> ProfileHighlight in
            let all = (highlightFiles[title] ?? []).sorted { ($0.date ?? .distantPast, $0.url.lastPathComponent) <
                ($1.date ?? .distantPast, $1.url.lastPathComponent) }
            let cover = all.first { $0.bool("highlight_cover") || ($0.string("media_id") ?? "").hasSuffix("_cover") }
            let items = all.filter { $0.url != cover?.url }.map(\.media)
            return ProfileHighlight(title: title, cover: cover?.media ?? items.first, items: items)
        }
        // Stories by the day they were posted, newest day first.
        let calendar = Calendar(identifier: .gregorian)
        let days = Dictionary(grouping: byKind[.story] ?? []) { calendar.startOfDay(for: $0.date ?? .distantPast) }
        let storyDays = days.map { day, files in
            ProfileStoryDay(day: day, items: files.sorted { ($0.date ?? .distantPast, $0.url.lastPathComponent) <
                    ($1.date ?? .distantPast, $1.url.lastPathComponent) }.map(\.media))
        }.sorted { $0.day > $1.day }
        let fullName = files.lazy.compactMap { file -> String? in
            (file.string("username")?.lowercased() == account && file.string("owner_username") == nil) ? file.string("author") : nil
        }.first
        return InstagramProfile(account: ref.name, fullName: fullName, avatars: avatars, posts: mainPosts,
                                reels: posts(.reel).sorted(by: newestFirst), tagged: posts(.tagged).sorted(by: newestFirst),
                                reposts: posts(.repost).sorted(by: newestFirst), highlights: highlights, storyDays: storyDays)
    }

    // MARK: Channels and feeds

    static func channel(_ ref: ProfileRef, files: [File]) -> ChannelProfile {
        let videos = files.filter(\.isVideo)
        // A picture named after a video is its thumbnail, not a post.
        var thumbnails: [String: URL] = [:]
        for file in files where !file.isVideo {
            thumbnails[file.url.deletingPathExtension().path] = file.url
        }
        let posts = group(videos) { _ in .video }.map { post -> ProfilePost in
            var post = post
            if let video = post.media.first { post.thumbnail = thumbnails[video.url.deletingPathExtension().path] }
            // A video saved before D-111 has its title as its description.
            if post.title == nil { post.title = post.text ?? post.media.first?.url.deletingPathExtension().lastPathComponent }
            if post.text == post.title { post.text = nil }
            return post
        }.sorted(by: newestFirst)
        let lists = Dictionary(grouping: posts.filter { $0.playlistTitle != nil }) { $0.playlistTitle ?? "" }
            .map { (title: $0.key, videos: $0.value.sorted { ($0.playlistIndex ?? .max, $0.id) < ($1.playlistIndex ?? .max, $1.id) }) }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
        return ChannelProfile(name: ref.name, site: ref.site, videos: posts, playlists: lists)
    }

    static func feed(_ files: [File]) -> [ProfilePost] {
        group(files) { _ in .item }.sorted(by: newestFirst)
    }
}
