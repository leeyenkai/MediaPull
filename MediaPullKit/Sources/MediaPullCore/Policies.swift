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
}

/// Everything the save pipeline needs to know about conversions.
public struct ConversionPolicy: Codable, Equatable, Sendable {
    public var keepOriginalModernImages = false
    public var animated: AnimatedPolicy = .gif
    public var rasterizeSVGInArchive = true
    public var video: VideoCodecPolicy = .highestReencodeIfNeeded

    public init() {}
}

public enum InstagramContent: String, Codable, Sendable, CaseIterable, Hashable {
    case posts, reels, avatar, stories, highlights

    public var label: String {
        switch self {
        case .posts: "Posts and carousels"
        case .reels: "Reels"
        case .avatar: "Profile picture"
        case .stories: "Current stories"
        case .highlights: "Highlights"
        }
    }

    public var engineName: String { rawValue }
}
