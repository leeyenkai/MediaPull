import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case image
    case animatedImage
    case video
    case stream
    case audio
    case vector

    public var label: String {
        switch self {
        case .image: "Image"
        case .animatedImage: "Animated"
        case .video: "Video"
        case .stream: "Stream"
        case .audio: "Audio"
        case .vector: "Vector"
        }
    }
}

public enum MediaFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case jpeg, png, gif, webp, avif, heic, jxl, bmp, tiff, ico, svg
    /// Camera RAW of any make (R-4201): kept as it is, never converted or rewritten (R-4203).
    case raw
    case mp4, mov, webm, mkv
    case hls, dash
    case mp3, m4a, aac, ogg, opus, wav, flac, aiff

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .hls: "m3u8"
        case .dash: "mpd"
        default: rawValue
        }
    }

    public var label: String {
        switch self {
        case .jpeg: "JPEG"
        case .hls: "HLS"
        case .dash: "DASH"
        case .heic: "HEIC"
        case .jxl: "JPEG XL"
        case .raw: "RAW"
        default: rawValue.uppercased()
        }
    }

    public var kind: MediaKind {
        switch self {
        case .jpeg, .png, .webp, .avif, .heic, .jxl, .bmp, .tiff, .ico, .raw: .image
        case .gif: .image
        case .svg: .vector
        case .mp4, .mov, .webm, .mkv: .video
        case .hls, .dash: .stream
        case .mp3, .m4a, .aac, .ogg, .opus, .wav, .flac, .aiff: .audio
        }
    }

    /// Formats saved as they are, without conversion.
    public var isNormal: Bool {
        switch self {
        case .jpeg, .png, .gif, .mp4, .mov: true
        default: false
        }
    }

    public var isRaw: Bool { self == .raw }

    /// Formats the Converter and the Editor may turn into another file. RAW never is (R-4203); audio has no target.
    public var isConvertible: Bool {
        switch self {
        case .raw, .svg, .hls, .dash: false
        default: kind != .audio
        }
    }

    /// Camera RAW extensions (R-4201).
    public static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "dng", "pef", "srw", "x3f", "3fr", "iiq",
        "erf", "mos", "mrw",
    ]

    /// HEIF image sequences (bursts, short animations): listed as HEIC, played in the preview (R-4204).
    public static func isSequenceExtension(_ ext: String) -> Bool { ["heics", "heifs"].contains(ext.lowercased()) }

    /// Every extension `fromExtension` knows, for indexes that list files by name.
    public static var knownExtensions: Set<String> {
        let candidates = ["jpg", "jpeg", "jpe", "jfif", "pjpeg", "png", "apng", "gif", "webp", "avif", "heic", "heif", "hif", "heics",
                          "heifs", "avci", "jxl", "bmp", "tif", "tiff", "ico", "cur", "svg", "svgz", "mp4", "m4v", "mov", "qt", "webm",
                          "mkv", "m3u8", "m3u", "mpd", "mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "flac", "aif", "aiff", "aifc"]
        return Set(candidates).union(rawExtensions)
    }

    public var isLosslessImage: Bool {
        switch self {
        case .png, .gif, .bmp, .tiff: true
        default: false
        }
    }

    public static func fromExtension(_ ext: String) -> MediaFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif", "pjpeg": .jpeg
        case "png", "apng": .png
        case "gif": .gif
        case "webp": .webp
        case "avif": .avif
        case "heic", "heif", "hif", "heics", "heifs", "avci": .heic
        case "jxl": .jxl
        case "bmp": .bmp
        case "tif", "tiff": .tiff
        case "ico", "cur": .ico
        case "svg", "svgz": .svg
        case "mp4", "m4v": .mp4
        case "mov", "qt": .mov
        case "webm": .webm
        case "mkv": .mkv
        case "m3u8", "m3u": .hls
        case "mpd": .dash
        case "mp3": .mp3
        case "m4a": .m4a
        case "aac": .aac
        case "ogg", "oga": .ogg
        case "opus": .opus
        case "wav": .wav
        case "flac": .flac
        case "aif", "aiff", "aifc": .aiff
        case let ext where rawExtensions.contains(ext): .raw
        default: nil
        }
    }

    public static func fromMIME(_ mime: String) -> MediaFormat? {
        let type = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "image/jpeg", "image/jpg", "image/pjpeg": return .jpeg
        case "image/png", "image/apng": return .png
        case "image/gif": return .gif
        case "image/webp": return .webp
        case "image/avif": return .avif
        case "image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence", "image/avci": return .heic
        case "image/jxl": return .jxl
        case "image/bmp", "image/x-ms-bmp": return .bmp
        case "image/tiff": return .tiff
        case "image/x-icon", "image/vnd.microsoft.icon": return .ico
        case "image/svg+xml": return .svg
        case "video/mp4", "video/x-m4v": return .mp4
        case "video/quicktime": return .mov
        case "video/webm": return .webm
        case "video/x-matroska": return .mkv
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl": return .hls
        case "application/dash+xml": return .dash
        case "audio/mpeg", "audio/mp3": return .mp3
        case "audio/mp4", "audio/x-m4a": return .m4a
        case "audio/aac": return .aac
        case "audio/ogg": return .ogg
        case "audio/opus": return .opus
        case "audio/wav", "audio/x-wav", "audio/wave": return .wav
        case "audio/flac", "audio/x-flac": return .flac
        case "audio/aiff", "audio/x-aiff": return .aiff
        default: return nil
        }
    }
}

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    /// Dimensions come from pages, engines and file headers, so they are clamped to a sane range.
    public init(width: Int, height: Int) {
        self.width = min(max(width, 0), 1_000_000)
        self.height = min(max(height, 0), 1_000_000)
    }

    public var pixels: Int { width * height }
    public var shortSide: Int { min(width, height) }
    public var longSide: Int { max(width, height) }
    public var aspect: Double { height == 0 ? 0 : Double(width) / Double(height) }
    public var label: String { "\(width)×\(height)" }
}

public enum VariantOrigin: String, Codable, Sendable, Hashable {
    case img, srcset, picture, css, video, audio, poster, meta, link, lazy, network, data, blob, svg, icon
    case cdnRewrite
    case engine
    case engineDash
    case engineThumbnail
    case document

    public var label: String {
        switch self {
        case .img: "Image tag"
        case .srcset: "srcset"
        case .picture: "Picture source"
        case .css: "CSS background"
        case .video: "Video tag"
        case .audio: "Audio tag"
        case .poster: "Video poster"
        case .meta: "Meta tag"
        case .link: "Link"
        case .lazy: "Lazy-load attribute"
        case .network: "Network"
        case .data: "Inline data"
        case .blob: "Blob"
        case .svg: "Inline SVG"
        case .icon: "Icon"
        case .cdnRewrite: "Original size (derived)"
        case .engine: "Site extractor"
        case .engineDash: "Site extractor (DASH)"
        case .engineThumbnail: "Thumbnail"
        case .document: "PDF"
        }
    }
}

public enum VerifyState: Codable, Sendable, Hashable {
    case unverified
    case verified
    case failed(Int)
}

public struct MediaVariant: Identifiable, Hashable, Sendable {
    /// The normalized URL string.
    public var id: String
    public var url: URL
    public var format: MediaFormat?
    public var pixelSize: PixelSize?
    /// Width promised by a srcset `w` descriptor, used for ranking until the real size is known.
    public var declaredWidth: Int?
    public var density: Double?
    public var byteCount: Int64?
    public var duration: Double?
    public var origin: VariantOrigin
    public var rule: String?
    public var check: VerifyState
    public var expiresAt: Date?
    /// Variants that only an engine can download (DASH manifests, `ytdl:` URLs).
    public var requiresEngine: Bool
    public var codecs: [String]

    public init(
        id: String,
        url: URL,
        format: MediaFormat? = nil,
        pixelSize: PixelSize? = nil,
        declaredWidth: Int? = nil,
        density: Double? = nil,
        byteCount: Int64? = nil,
        duration: Double? = nil,
        origin: VariantOrigin,
        rule: String? = nil,
        check: VerifyState = .verified,
        expiresAt: Date? = nil,
        requiresEngine: Bool = false,
        codecs: [String] = []
    ) {
        self.id = id
        self.url = url
        self.format = format
        self.pixelSize = pixelSize
        self.declaredWidth = declaredWidth
        self.density = density
        self.byteCount = byteCount
        self.duration = duration
        self.origin = origin
        self.rule = rule
        self.check = check
        self.expiresAt = expiresAt
        self.requiresEngine = requiresEngine
        self.codecs = codecs
    }

    public var isDerived: Bool { origin == .cdnRewrite }
    public var hasFailed: Bool {
        if case .failed = check { return true }
        return false
    }
}

public enum MediaFlag: String, Codable, Sendable, Hashable {
    case icon
    case insecure
    case protected
    case blobOnly
    case dataURI
    case inIframe
    case pinned
    case duplicate
}

public struct WebContext: Codable, Hashable, Sendable {
    public var pageURL: URL
    public var pageTitle: String?
    public var frameURL: URL?
    public var frameOrigin: String?
    public var isMainFrame: Bool
    /// For images taken out of a PDF: the page they were on. `pageURL` is then the PDF itself.
    public var documentPage: Int?

    public init(pageURL: URL, pageTitle: String? = nil, frameURL: URL? = nil, frameOrigin: String? = nil, isMainFrame: Bool = true,
                documentPage: Int? = nil)
    {
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.frameURL = frameURL
        self.frameOrigin = frameOrigin
        self.isMainFrame = isMainFrame
        self.documentPage = documentPage
    }

    public var isDocument: Bool { documentPage != nil }
}

/// Metadata reported by an engine (Instagram or a site extractor) for one item.
public struct EngineContext: Codable, Hashable, Sendable {
    public var key: String
    public var category: String
    public var subcategory: String
    public var username: String?
    /// The numeric id of the account that posted it (Instagram), to tell a name's new owner from its old one.
    public var ownerID: String?
    public var fullName: String?
    public var shortcode: String?
    public var postShortcode: String?
    public var postID: String?
    public var mediaID: String?
    public var num: Int?
    public var count: Int?
    public var date: Date?
    public var description: String?
    public var title: String?
    public var postURL: URL?
    public var highlightTitle: String?
    public var productType: String?
    public var pinned: Bool
    public var originalWidth: Int?
    public var originalHeight: Int?
    public var fileName: String?
    public var headers: [String: String]
    /// The page or profile the scan started from.
    public var sourceURL: URL?
    /// A higher resolution the site offered only in a codec the policy did not take ("2160p"), for the sidecar (R-1607).
    public var higherResolutionAvailable: String?
    /// D-111: Instagram's place for a post (a name and its id, no coordinates).
    public var locationName: String?
    public var locationID: String?
    /// D-112: a highlight's cover image.
    public var highlightCover = false
    /// D-111: a subreddit or a Pinterest board.
    public var community: String?
    /// D-111: the playlist a video was saved from, and its channel.
    public var playlistTitle: String?
    public var playlistID: String?
    public var playlistIndex: Int?
    public var channelID: String?

    public init(key: String, category: String, subcategory: String) {
        self.key = key
        self.category = category
        self.subcategory = subcategory
        pinned = false
        headers = [:]
    }

    public var isInstagram: Bool { category == "instagram" }

    /// "posts", "reels", "stories", "highlights" or "avatar" for Instagram.
    public var instagramSection: String {
        switch subcategory {
        case "stories", "story", "stories-tray": return "stories"
        case "highlights", "highlight", "highlights-covers": return "highlights"
        case "avatar": return "avatar"
        case "reels", "reel": return "reels"
        default:
            if productType == "reel" || productType == "clips" { return "reels" }
            return "posts"
        }
    }
}

public enum MediaSource: Hashable, Sendable {
    case web(WebContext)
    case engine(EngineContext)

    public var web: WebContext? {
        if case let .web(context) = self { return context }
        return nil
    }

    public var engine: EngineContext? {
        if case let .engine(context) = self { return context }
        return nil
    }

    public var pageURL: URL? {
        switch self {
        case let .web(context): context.pageURL
        case let .engine(context): context.sourceURL ?? context.postURL
        }
    }
}

public struct MediaItem: Identifiable, Sendable {
    public let id: String
    public var kind: MediaKind
    public var variants: [MediaVariant]
    public var bestID: String?
    public var source: MediaSource
    public var firstSeen: Date
    public var discoveryIndex: Int
    public var alt: String?
    public var posterURL: URL?
    public var flags: Set<MediaFlag>
    /// Groups items for display: the page URL for web items, the post for engine items.
    public var group: String
    public var groupTitle: String

    public init(
        id: String,
        kind: MediaKind,
        variants: [MediaVariant],
        source: MediaSource,
        discoveryIndex: Int,
        group: String,
        groupTitle: String,
        alt: String? = nil,
        flags: Set<MediaFlag> = []
    ) {
        self.id = id
        self.kind = kind
        self.variants = variants
        self.source = source
        firstSeen = Date()
        self.discoveryIndex = discoveryIndex
        self.alt = alt
        self.flags = flags
        self.group = group
        self.groupTitle = groupTitle
        bestID = VariantRanker.best(variants)
    }

    public var best: MediaVariant? {
        if let bestID, let found = variants.first(where: { $0.id == bestID }) { return found }
        return variants.first
    }

    /// The best variant that is already known to exist (never an unverified derived URL).
    public var bestConfirmed: MediaVariant? {
        VariantRanker.best(variants.filter { !$0.isDerived || $0.check == .verified }).flatMap { id in
            variants.first { $0.id == id }
        }
    }

    /// Size to show and filter on: the largest size actually known for this item.
    public var displaySize: PixelSize? {
        if let size = best?.pixelSize { return size }
        return variants.compactMap(\.pixelSize).max { $0.pixels < $1.pixels }
    }

    public var displayBytes: Int64? {
        best?.byteCount ?? bestConfirmed?.byteCount
    }

    public var displayFormat: MediaFormat? {
        best?.format ?? bestConfirmed?.format ?? variants.compactMap(\.format).first
    }

    public var host: String {
        best?.url.host ?? variants.first?.url.host ?? ""
    }

    public var duration: Double? {
        variants.compactMap(\.duration).max()
    }

    /// The smallest variant that is at least `minimum` pixels on its long side, for thumbnails.
    public func thumbnailVariant(minimum: Int) -> MediaVariant? {
        let usable = variants.filter { !$0.hasFailed && !$0.requiresEngine && !($0.isDerived && $0.check != .verified) }
        let sized = usable.compactMap { variant -> (MediaVariant, Int)? in
            guard let size = variant.pixelSize else { return nil }
            return (variant, size.longSide)
        }
        if let fit = sized.filter({ $0.1 >= minimum }).min(by: { $0.1 < $1.1 }) { return fit.0 }
        if let largest = sized.max(by: { $0.1 < $1.1 }) { return largest.0 }
        return usable.first { $0.origin == .engineThumbnail } ?? usable.first
    }
}

public extension MediaItem {
    /// An edited or trimmed copy, or a frame grab: a file of its own under an id of its own. It never stands for the item
    /// it was made from: not as saved, not as in the library, and not as that Instagram item in an account folder (its
    /// metadata names no media of its own), so the original is still saved, shown and fetched as itself (audit 7, C7-M2).
    func madeCopy(_ variant: MediaVariant, kind: MediaKind? = nil, suffix: String = "edited") -> MediaItem {
        let mark = "#\(suffix)-\(UUID().uuidString)"
        var source = source
        if case var .engine(context) = source {
            context.key += mark
            context.mediaID = nil
            context.shortcode = nil
            context.postShortcode = nil
            context.postID = nil
            context.num = nil
            context.count = nil
            source = .engine(context)
        }
        var copy = MediaItem(id: id + mark, kind: kind ?? self.kind, variants: [variant], source: source, discoveryIndex: discoveryIndex,
                             group: group, groupTitle: groupTitle, alt: alt)
        copy.bestID = variant.id
        return copy
    }
}
