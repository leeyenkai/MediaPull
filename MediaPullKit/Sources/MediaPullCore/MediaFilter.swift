import Foundation

public enum AspectFilter: String, Codable, Sendable, CaseIterable {
    case any, portrait, landscape, square, panorama

    public var label: String {
        switch self {
        case .any: "Any shape"
        case .portrait: "Portrait"
        case .landscape: "Landscape"
        case .square: "Square"
        case .panorama: "Panorama"
        }
    }
}

public enum SourceGroup: String, Codable, Sendable, CaseIterable {
    case imageTag, srcset, css, video, meta, link, network, iframe, pdf, siteExtractor, instagram

    public var label: String {
        switch self {
        case .imageTag: "Image tags"
        case .srcset: "srcset and picture"
        case .css: "CSS backgrounds"
        case .video: "Video and audio tags"
        case .meta: "Meta tags"
        case .link: "Links"
        case .network: "Network"
        case .iframe: "Iframes"
        case .pdf: "PDFs"
        case .siteExtractor: "Site extractor"
        case .instagram: "Instagram"
        }
    }
}

public enum SaveStateFilter: String, Codable, Sendable, CaseIterable {
    case notSaved, saved, failed

    public var label: String {
        switch self {
        case .notSaved: "Not saved"
        case .saved: "Saved"
        case .failed: "Failed"
        }
    }
}

public enum SortOrder: String, Codable, Sendable, CaseIterable {
    case discovery, resolution, fileSize, duration, type, domain, date

    public var label: String {
        switch self {
        case .discovery: "Order found"
        case .resolution: "Resolution"
        case .fileSize: "File size"
        case .duration: "Duration"
        case .type: "Type"
        case .domain: "Domain"
        case .date: "Post date"
        }
    }
}

public struct MediaFilter: Codable, Equatable, Sendable {
    public var kinds: Set<MediaKind> = []
    public var formats: Set<MediaFormat> = []
    public var minWidth: Int?
    public var minHeight: Int?
    public var maxWidth: Int?
    public var maxHeight: Int?
    public var minShortSide: Int?
    /// Minimum length of the longer side, set by the resolution slider.
    public var minLongSide: Int?
    public var minMegapixels: Double?
    public var minBytes: Int64?
    public var maxBytes: Int64?
    public var aspect: AspectFilter = .any
    public var minDuration: Double?
    public var maxDuration: Double?
    public var sources: Set<SourceGroup> = []
    public var includeDomains: String = ""
    public var excludeDomains: String = ""
    public var sameSiteOnly = false
    public var instagramSections: Set<String> = []
    public var states: Set<SaveStateFilter> = []
    public var text: String = ""
    public var hideTiny = true
    public var hideIcons = true
    public var hideDuplicates = true
    public var hideUnavailable = true
    public var excludeUnknown = false
    public var currentPageOnly = false
    public var sort: SortOrder = .discovery
    public var ascending = true

    public init() {}

    public static let tinyLimit = 64

    /// Number of narrowing criteria in use, for the filter button badge.
    public var activeCount: Int {
        var count = 0
        if !kinds.isEmpty { count += 1 }
        if !formats.isEmpty { count += 1 }
        if minWidth != nil || minHeight != nil || maxWidth != nil || maxHeight != nil || minShortSide != nil || minLongSide != nil {
            count += 1
        }
        if minMegapixels != nil { count += 1 }
        if minBytes != nil || maxBytes != nil { count += 1 }
        if aspect != .any { count += 1 }
        if minDuration != nil || maxDuration != nil { count += 1 }
        if !sources.isEmpty { count += 1 }
        if !includeDomains.isEmpty || !excludeDomains.isEmpty || sameSiteOnly { count += 1 }
        if !instagramSections.isEmpty { count += 1 }
        if !states.isEmpty { count += 1 }
        if !text.isEmpty { count += 1 }
        if currentPageOnly { count += 1 }
        return count
    }
}

public struct FilterContext: Sendable {
    public var currentPage: URL?
    public var stateOf: @Sendable (String) -> SaveStateFilter

    public init(currentPage: URL?, stateOf: @escaping @Sendable (String) -> SaveStateFilter) {
        self.currentPage = currentPage
        self.stateOf = stateOf
    }
}

public extension MediaFilter {
    static func sourceGroup(of item: MediaItem) -> Set<SourceGroup> {
        var groups = Set<SourceGroup>()
        if let engine = item.source.engine {
            groups.insert(engine.isInstagram ? .instagram : .siteExtractor)
            return groups
        }
        if item.flags.contains(.inIframe) { groups.insert(.iframe) }
        for variant in item.variants {
            switch variant.origin {
            case .img, .lazy, .data, .blob, .svg, .icon: groups.insert(.imageTag)
            case .srcset, .picture: groups.insert(.srcset)
            case .css: groups.insert(.css)
            case .video, .audio, .poster: groups.insert(.video)
            case .meta: groups.insert(.meta)
            case .link: groups.insert(.link)
            case .network: groups.insert(.network)
            case .document: groups.insert(.pdf)
            case .cdnRewrite, .engine, .engineDash, .engineThumbnail: break
            }
        }
        return groups
    }

    func matches(_ item: MediaItem, context: FilterContext) -> Bool {
        let size = item.displaySize
        let bytes = item.displayBytes
        let format = item.displayFormat

        if hideIcons, item.flags.contains(.icon) { return false }
        if hideUnavailable, !item.variants.isEmpty,
           item.variants.filter({ $0.origin != .engineThumbnail }).allSatisfy(\.hasFailed)
        {
            return false
        }
        if hideIcons, let size, size.width <= 32, size.height <= 32 { return false }
        if hideIcons, format == .svg, let bytes, bytes < 2048 { return false }
        if hideTiny, let size, size.width < Self.tinyLimit || size.height < Self.tinyLimit,
           item.kind == .image || item.kind == .animatedImage || item.kind == .vector
        {
            return false
        }
        if hideDuplicates, item.flags.contains(.duplicate) { return false }
        if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
        if !formats.isEmpty {
            guard let format, formats.contains(format) else { return false }
        }

        let needsSize = minWidth != nil || minHeight != nil || maxWidth != nil || maxHeight != nil || minShortSide != nil
            || minLongSide != nil || minMegapixels != nil || aspect != .any
        if needsSize {
            if let size {
                if let minWidth, size.width < minWidth { return false }
                if let minHeight, size.height < minHeight { return false }
                if let maxWidth, size.width > maxWidth { return false }
                if let maxHeight, size.height > maxHeight { return false }
                if let minShortSide, size.shortSide < minShortSide { return false }
                if let minLongSide, size.longSide < minLongSide { return false }
                if let minMegapixels, Double(size.pixels) / 1_000_000 < minMegapixels { return false }
                switch aspect {
                case .any: break
                case .portrait: if size.aspect >= 0.95 { return false }
                case .landscape: if size.aspect <= 1.05 { return false }
                case .square: if size.aspect < 0.95 || size.aspect > 1.05 { return false }
                case .panorama: if size.aspect < 2 && size.aspect > 0.5 { return false }
                }
            } else if excludeUnknown {
                return false
            }
        }
        if minBytes != nil || maxBytes != nil {
            if let bytes {
                if let minBytes, bytes < minBytes { return false }
                if let maxBytes, bytes > maxBytes { return false }
            } else if excludeUnknown {
                return false
            }
        }
        if minDuration != nil || maxDuration != nil {
            if let duration = item.duration {
                if let minDuration, duration < minDuration { return false }
                if let maxDuration, duration > maxDuration { return false }
            } else if excludeUnknown || ![.video, .audio, .stream].contains(item.kind) {
                // A length filter is about videos and audio; pictures and drawings have none (R-1006).
                return false
            }
        }
        if !sources.isEmpty, Self.sourceGroup(of: item).isDisjoint(with: sources) { return false }

        let host = item.host
        if !includeDomains.isEmpty {
            let tokens = Self.tokens(includeDomains)
            if !tokens.contains(where: { host.contains($0) }) { return false }
        }
        if !excludeDomains.isEmpty {
            let tokens = Self.tokens(excludeDomains)
            if tokens.contains(where: { host.contains($0) }) { return false }
        }
        if sameSiteOnly, let page = item.source.pageURL, let url = item.best?.url {
            if !URLNormalizer.isSameSite(page, url) { return false }
        }
        if !instagramSections.isEmpty {
            guard let engine = item.source.engine, engine.isInstagram, instagramSections.contains(engine.instagramSection) else {
                return false
            }
        }
        if !states.isEmpty, !states.contains(context.stateOf(item.id)) { return false }
        if currentPageOnly, let current = context.currentPage {
            guard let page = item.source.web?.pageURL, Self.samePage(page, current) else { return false }
        }
        if !text.isEmpty {
            let needle = text.lowercased()
            var haystack = [item.best?.url.absoluteString ?? "", item.alt ?? "", item.groupTitle]
            if let engine = item.source.engine {
                haystack += [engine.description ?? "", engine.title ?? "", engine.username ?? ""]
            }
            if !haystack.contains(where: { $0.lowercased().contains(needle) }) { return false }
        }
        return true
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    static func samePage(_ a: URL, _ b: URL) -> Bool {
        var ca = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var cb = URLComponents(url: b, resolvingAgainstBaseURL: false)
        ca?.fragment = nil
        cb?.fragment = nil
        return ca?.string == cb?.string
    }

    /// Items in the chosen order; `ascending` false puts the largest, longest or newest first.
    func sorted(_ items: [MediaItem]) -> [MediaItem] {
        // Items with the same value keep the order they were found in, whichever way the list is sorted.
        func by(_ key: (MediaItem) -> some Comparable) -> [MediaItem] {
            items.sorted { a, b in
                let first = key(a), second = key(b)
                if first != second { return ascending ? first < second : first > second }
                return a.discoveryIndex < b.discoveryIndex
            }
        }
        return switch sort {
        case .discovery: items.sorted { ascending ? $0.discoveryIndex < $1.discoveryIndex : $0.discoveryIndex > $1.discoveryIndex }
        case .resolution: by { $0.displaySize?.pixels ?? -1 }
        case .fileSize: by { $0.displayBytes ?? -1 }
        case .duration: by { $0.duration ?? -1 }
        case .type: by(\.kind.rawValue)
        case .domain: by(\.host)
        case .date: by { $0.source.engine?.date ?? .distantPast }
        }
    }
}
