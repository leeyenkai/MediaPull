import Foundation

public enum VideoCodecPolicy: String, Codable, Sendable, CaseIterable {
    case highestReencodeIfNeeded
    case highestCompatible
    case keepOriginal

    public var label: String {
        switch self {
        case .highestReencodeIfNeeded: "Highest resolution, re-encode only if needed"
        case .highestCompatible: "Highest compatible, never re-encode"
        case .keepOriginal: "Keep original codec"
        }
    }

    public var detail: String {
        switch self {
        case .highestReencodeIfNeeded:
            "Takes the highest resolution. If it only exists as VP9 or AV1, it is converted to HEVC so it plays everywhere on a Mac."
        case .highestCompatible:
            "Takes the best H.264 or HEVC version untouched, even if a higher resolution existed in another codec."
        case .keepOriginal:
            "Takes the highest resolution with no conversion. VP9 or AV1 files may not play in QuickTime or Photos."
        }
    }

    /// yt-dlp format selector and sort order for this policy (SPEC Appendix E).
    public func selector(av1Decodable: Bool) -> (format: String, sort: [String]) {
        switch self {
        case .highestCompatible:
            ("bv*[vcodec~='^(avc1|avc3|hvc1|hev1|h264|h265|hevc)']+ba/b[vcodec~='^(avc|hvc|hev|h26)']/bv*+ba/b",
             ["res", "vcodec:h265", "acodec:aac"])
        case .highestReencodeIfNeeded:
            (av1Decodable ? "bv*+ba/b" : "bv*[vcodec!^=av01]+ba/b[vcodec!^=av01]/bv*+ba/b", ["res", "vcodec:h265", "acodec:aac"])
        case .keepOriginal:
            ("bv*+ba/b", ["res", "vcodec:h265", "acodec:aac"])
        }
    }
}

public enum AnimatedPolicy: String, Codable, Sendable, CaseIterable {
    case gif, mp4, apng

    public var label: String {
        switch self {
        case .gif: "GIF"
        case .mp4: "MP4 video"
        case .apng: "Animated PNG"
        }
    }
}

public enum PacingPreset: String, Codable, Sendable, CaseIterable {
    case gentle, standard

    public var label: String {
        switch self {
        case .gentle: "Gentle (8 to 15 seconds between requests)"
        case .standard: "Standard (6 to 12 seconds between requests)"
        }
    }

    public var delay: [Double] {
        switch self {
        case .gentle: [8, 15]
        case .standard: [6, 12]
        }
    }

    /// Roughly how many Instagram requests listing a whole account of `posts` posts takes, and how long at this pace
    /// (R-1105): a page of 12 posts per request, plus the profile lookup; each request waits the average delay.
    public func estimate(posts: Int) -> (requests: Int, seconds: Double) {
        let requests = 1 + (max(posts, 0) + 11) / 12
        return (requests, Double(requests) * (delay[0] + delay[1]) / 2)
    }
}

/// Everything the save pipeline needs to know about conversions.
public struct ConversionPolicy: Codable, Equatable, Sendable {
    public var keepOriginalModernImages = false
    public var animated: AnimatedPolicy = .gif
    public var rasterizeSVGInArchive = true
    public var video: VideoCodecPolicy = .highestReencodeIfNeeded
    /// Keep a downloaded video or audio file exactly as it is, in its own container, because the person chose
    /// that format (SPEC R-3502).
    public var keepDownloadedMedia = false

    public init() {}
}

/// What to pull from Instagram (SPEC R-1105, R-1105a). Every choice needs a signed-in session.
public enum InstagramContent: String, Codable, Sendable, CaseIterable, Hashable {
    // Media from the account, in one listing.
    case posts, reels, stories, highlights, avatar, tagged, reposts
    case highlightCovers = "highlights-covers"
    // Details about the account; no media.
    case profileInfo = "info"
    case followers, following
    // From the signed-in person's own account.
    case saved
    case storiesTray = "stories-tray"

    public enum Group: String, CaseIterable, Sendable {
        case media, details, yours

        public var title: String {
            switch self {
            case .media: "From the account"
            case .details: "Account details"
            case .yours: "From your own account"
            }
        }
    }

    public var group: Group {
        switch self {
        case .posts, .reels, .stories, .highlights, .avatar, .tagged, .reposts, .highlightCovers: .media
        case .profileInfo, .followers, .following: .details
        case .saved, .storiesTray: .yours
        }
    }

    /// What a pull includes unless the person chooses otherwise.
    public static let defaults: Set<InstagramContent> = [.posts, .reels, .stories, .highlights, .avatar]

    public var label: String {
        switch self {
        case .posts: "Posts and carousels"
        case .reels: "Reels"
        case .stories: "Current stories"
        case .highlights: "Highlights"
        case .avatar: "Profile picture"
        case .tagged: "Posts the account is tagged in"
        case .reposts: "Reposts"
        case .highlightCovers: "Highlight covers"
        case .profileInfo: "Profile information"
        case .followers: "Followers list"
        case .following: "Following list"
        case .saved: "Your saved posts and collections"
        case .storiesTray: "Stories from accounts you follow"
        }
    }

    public var detail: String? {
        switch self {
        case .tagged: "Posted by other accounts; saved in a tagged folder"
        case .reposts: "Posts the account shared from others; saved in a reposts folder"
        case .profileInfo: "Name, biography, links and counts, saved as JSON in Account details"
        case .followers, .following: "Names only, saved as a CSV list in Account details; long lists take a while"
        case .saved: "Saved in a Saved posts folder"
        case .storiesTray: "Saved in each account's stories folder"
        default: nil
        }
    }

    /// The gallery-dl subcategory, used both for the profile's include list and as the page to open.
    public var engineName: String { rawValue }

    /// Media listed through the account's profile page; the rest are pages of their own.
    public var isProfileMedia: Bool { group == .media }
}

/// Which posts a pull includes by date (SPEC R-1105b).
public enum InstagramDateWindow: String, Codable, Sendable, CaseIterable, Hashable {
    case allTime, pastMonth, pastYear, custom

    public var label: String {
        switch self {
        case .allTime: "All Time"
        case .pastMonth: "Past Month"
        case .pastYear: "Past Year"
        case .custom: "Custom"
        }
    }

    /// The earliest and latest dates to include; nil means no limit on that side. A custom range covers
    /// whole days: from the start of `from` to the end of `to`.
    public func bounds(now: Date = Date(), from: Date, to: Date, calendar: Calendar = .current) -> (from: Date?, to: Date?) {
        switch self {
        case .allTime:
            return (nil, nil)
        case .pastMonth:
            return (calendar.date(byAdding: .month, value: -1, to: now), nil)
        case .pastYear:
            return (calendar.date(byAdding: .year, value: -1, to: now), nil)
        case .custom:
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: max(from, to)))
            return (start, end)
        }
    }
}
