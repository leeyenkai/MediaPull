import Foundation

/// One format a video page offers, as yt-dlp lists it (SPEC section 35).
public struct VideoFormatInfo: Codable, Hashable, Sendable {
    public var id: String
    public var ext: String
    public var height: Int?
    public var width: Int?
    public var fps: Double?
    public var vcodec: String
    public var acodec: String
    public var abr: Double?
    public var tbr: Double?
    public var size: Int64?
    public var drm: Bool

    public init(id: String, ext: String, height: Int? = nil, width: Int? = nil, fps: Double? = nil, vcodec: String, acodec: String,
                abr: Double? = nil, tbr: Double? = nil, size: Int64? = nil, drm: Bool = false)
    {
        self.id = id
        self.ext = ext
        self.height = height
        self.width = width
        self.fps = fps
        self.vcodec = vcodec
        self.acodec = acodec
        self.abr = abr
        self.tbr = tbr
        self.size = size
        self.drm = drm
    }

    public var hasVideo: Bool { vcodec != "none" && !vcodec.isEmpty }
    public var isAudioOnly: Bool { !hasVideo && acodec != "none" && !acodec.isEmpty }

    /// h264, hevc, vp9, av1 or other.
    public var codecFamily: String {
        let codec = vcodec.lowercased()
        if codec.hasPrefix("avc") || codec.hasPrefix("h264") { return "h264" }
        if codec.hasPrefix("hev") || codec.hasPrefix("hvc") || codec.hasPrefix("h265") { return "hevc" }
        if codec.hasPrefix("vp9") || codec.hasPrefix("vp09") { return "vp9" }
        if codec.hasPrefix("av01") || codec.hasPrefix("av1") { return "av1" }
        return "other"
    }
}

/// What a video page holds, from the bridge's `video_info` event.
public struct VideoInfo: Sendable, Equatable {
    public var title: String
    public var uploader: String?
    public var id: String?
    public var uploadDate: Date?
    public var webpageURL: URL
    public var extractor: String
    public var duration: Double?
    public var thumbnail: URL?
    public var description: String?
    public var formats: [VideoFormatInfo]

    public init(title: String, uploader: String?, id: String?, uploadDate: Date?, webpageURL: URL, extractor: String, duration: Double?,
                thumbnail: URL?, description: String?, formats: [VideoFormatInfo])
    {
        self.title = title
        self.uploader = uploader
        self.id = id
        self.uploadDate = uploadDate
        self.webpageURL = webpageURL
        self.extractor = extractor
        self.duration = duration
        self.thumbnail = thumbnail
        self.description = description
        self.formats = formats
    }

    /// yt-dlp's `upload_date` (YYYYMMDD) or `timestamp` (seconds since 1970).
    public static func date(uploadDate: String?, timestamp: Double?) -> Date? {
        if let timestamp { return Date(timeIntervalSince1970: timestamp) }
        guard let text = uploadDate, text.count == 8 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.date(from: text)
    }
}

/// The format a person chooses for a video download (SPEC R-3502).
public enum VideoDownloadFormat: String, CaseIterable, Sendable, Hashable {
    case bestMP4, h264MP4, originalMP4, webm, audioM4A

    public var label: String {
        switch self {
        case .bestMP4: "MP4, best quality"
        case .h264MP4: "MP4, H.264 (plays everywhere)"
        case .originalMP4: "MP4, original codec"
        case .webm: "WebM, original"
        case .audioM4A: "Audio only, M4A"
        }
    }

    public var detail: String {
        switch self {
        case .bestMP4: "Highest resolution. VP9 or AV1 video is converted to HEVC when needed, following Settings > Formats."
        case .h264MP4: "H.264 and AAC, never converted. Sites often offer H.264 only up to 1080p."
        case .originalMP4: "The best video exactly as the site sends it (often AV1 or VP9) in an MP4 file. May not play in QuickTime."
        case .webm: "VP9 or AV1 with Opus audio, exactly as sent. Saved without a metadata file in Archive folders."
        case .audioM4A: "The best AAC audio track, no video. Saved without a metadata file in Archive folders."
        }
    }

    public var isAudioOnly: Bool { self == .audioM4A }

    /// Formats whose file is kept exactly as downloaded; best quality follows the conversion settings.
    public var keepsDownloadedFile: Bool { self != .bestMP4 }

    /// Video formats this choice can use.
    public func videoFormats(in formats: [VideoFormatInfo]) -> [VideoFormatInfo] {
        let video = formats.filter { $0.hasVideo && !$0.drm && $0.height != nil }
        switch self {
        case .bestMP4, .originalMP4: return video
        case .h264MP4: return video.filter { $0.codecFamily == "h264" }
        case .webm: return video.filter { $0.ext == "webm" }
        case .audioM4A: return []
        }
    }

    /// Resolutions (heights) offered for this choice, highest first.
    public func heights(in formats: [VideoFormatInfo]) -> [Int] {
        Array(Set(videoFormats(in: formats).compactMap(\.height))).sorted(by: >)
    }

    /// The yt-dlp format selector, sort order and merge container for a resolution (nil: the best there is).
    public func selector(height: Int?) -> (format: String, sort: [String], merge: String?) {
        let limit = height.map { "[height<=\($0)]" } ?? ""
        switch self {
        case .bestMP4:
            return ("bv*\(limit)+ba/b\(limit)", ["res", "fps", "vcodec:h265", "acodec:aac"], "mp4")
        case .h264MP4:
            return ("bv*[vcodec^=avc1]\(limit)+ba[acodec^=mp4a]/b[vcodec^=avc1]\(limit)", ["res", "fps", "br"], "mp4")
        case .originalMP4:
            return ("bv*\(limit)+ba/b\(limit)", ["res", "fps", "br"], "mp4")
        case .webm:
            return ("bv*[ext=webm]\(limit)+ba[ext=webm]/b[ext=webm]\(limit)", ["res", "fps", "br"], "webm")
        case .audioM4A:
            return ("ba[ext=m4a]/ba[acodec^=mp4a]", ["abr"], nil)
        }
    }

    /// The file extension the saved file will have.
    public var fileExtension: String {
        switch self {
        case .webm: "webm"
        case .audioM4A: "m4a"
        default: "mp4"
        }
    }

    /// The video format yt-dlp would pick for a resolution: the tallest at or under it, then the highest frame rate and bitrate.
    public func chosenVideo(in formats: [VideoFormatInfo], height: Int?) -> VideoFormatInfo? {
        videoFormats(in: formats).filter { height == nil || ($0.height ?? 0) <= height! }.max { a, b in
            (a.height ?? 0, a.fps ?? 0, a.tbr ?? 0) < (b.height ?? 0, b.fps ?? 0, b.tbr ?? 0)
        }
    }

    /// The approximate size of the download: the reported size, or the bitrate times the duration.
    public func estimatedBytes(in formats: [VideoFormatInfo], height: Int?, duration: Double? = nil) -> Int64? {
        func bytes(_ format: VideoFormatInfo?) -> Int64? {
            guard let format else { return nil }
            if let size = format.size { return size }
            guard let duration, let rate = format.tbr ?? format.abr, rate > 0 else { return nil }
            return Int64(rate * 1000 / 8 * duration)
        }
        let audio = formats.filter { $0.isAudioOnly && !$0.drm && (self == .webm ? $0.ext == "webm" : $0.ext == "m4a") }
            .max { ($0.abr ?? 0) < ($1.abr ?? 0) }
        if isAudioOnly { return bytes(audio) }
        guard let videoSize = bytes(chosenVideo(in: formats, height: height)) else { return nil }
        return videoSize + (bytes(audio) ?? 0)
    }

    /// Whether best quality will have to convert the video, which takes a while.
    public func needsConversion(in formats: [VideoFormatInfo], height: Int?) -> Bool {
        guard self == .bestMP4, let video = chosenVideo(in: formats, height: height) else { return false }
        return !["h264", "hevc"].contains(video.codecFamily)
    }
}

/// Pages that very likely hold one video, where the browser shows a Save Video button.
public enum VideoPage {
    public static func isLikely(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch bare {
        case "youtube.com", "m.youtube.com", "music.youtube.com":
            return path == "/watch" || path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
        case "youtu.be":
            return path.count > 1
        case "vimeo.com":
            return path.split(separator: "/").contains { $0.allSatisfy(\.isNumber) }
        case "dailymotion.com":
            return path.hasPrefix("/video/")
        case "twitch.tv":
            return path.hasPrefix("/videos/") || path.contains("/clip/")
        case "tiktok.com":
            return path.contains("/video/")
        default:
            return false
        }
    }
}
