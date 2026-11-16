import Foundation

/// One candidate as reported by extract.js (SPEC Appendix B).
public struct RawCandidate: Decodable, Sendable {
    public var u: String
    public var k: String
    public var d: String?
    public var w: Int?
    public var h: Int?
    public var dw: Int?
    public var dh: Int?
    public var alt: String?
    public var g: Int?
    public var t: String?
    public var drm: Bool?
    public var dur: Double?
}

public struct RawBatch: Decodable, Sendable {
    public var v: Int
    public var seq: Int?
    public var page: String?
    public var title: String?
    public var items: [RawCandidate]
}

public struct FrameInfo: Sendable {
    public var frameURL: URL?
    public var isMainFrame: Bool
    public var origin: String?
    public var pageURL: URL
    public var pageTitle: String?

    public init(frameURL: URL?, isMainFrame: Bool, origin: String?, pageURL: URL, pageTitle: String?) {
        self.frameURL = frameURL
        self.isMainFrame = isMainFrame
        self.origin = origin
        self.pageURL = pageURL
        self.pageTitle = pageTitle
    }
}

/// An item reported by an engine scan (Instagram or a site extractor).
public struct EngineItemInput: Sendable {
    public var context: EngineContext
    public var kind: MediaKind
    public var engineURL: String
    public var thumbURL: URL?
    public var width: Int?
    public var height: Int?
    public var isDash: Bool
    public var fallbackURL: URL?

    public init(context: EngineContext, kind: MediaKind, engineURL: String, thumbURL: URL?,
                width: Int?, height: Int?, isDash: Bool, fallbackURL: URL?)
    {
        self.context = context
        self.kind = kind
        self.engineURL = engineURL
        self.thumbURL = thumbURL
        self.width = width
        self.height = height
        self.isDash = isDash
        self.fallbackURL = fallbackURL
    }
}

/// What a probe learned about one variant.
public struct ProbeResult: Sendable, Equatable {
    public var format: MediaFormat?
    public var pixelSize: PixelSize?
    public var byteCount: Int64?
    public var duration: Double?
    public var isMarkup: Bool
    public var failedStatus: Int?

    public init(format: MediaFormat? = nil, pixelSize: PixelSize? = nil, byteCount: Int64? = nil, duration: Double? = nil,
                isMarkup: Bool = false, failedStatus: Int? = nil)
    {
        self.format = format
        self.pixelSize = pixelSize
        self.byteCount = byteCount
        self.duration = duration
        self.isMarkup = isMarkup
        self.failedStatus = failedStatus
    }
}

public struct IngestSnapshot: Sendable {
    public var items: [MediaItem]
    public var generation: Int
    /// PDF documents linked from the pages in this session, in the order found.
    public var documents: [URL] = []
}

/// An image taken out of a PDF.
public struct DocumentImageInput: Sendable {
    public var file: URL
    public var documentURL: URL
    public var documentTitle: String
    public var page: Int
    public var index: Int
    public var width: Int
    public var height: Int
    public var format: MediaFormat
    public var bytes: Int64

    public init(file: URL, documentURL: URL, documentTitle: String, page: Int, index: Int, width: Int, height: Int, format: MediaFormat,
                bytes: Int64)
    {
        self.file = file
        self.documentURL = documentURL
        self.documentTitle = documentTitle
        self.page = page
        self.index = index
        self.width = width
        self.height = height
        self.format = format
        self.bytes = bytes
    }
}

/// Merges extraction candidates into media items off the main thread and publishes throttled
/// snapshots (SPEC R-907 to R-910).
public actor ExtractionIngestor {
    private var items: [String: MediaItem] = [:]
    private var variantOwner: [String: String] = [:]
    private var groupOwner: [String: String] = [:]
    private var assetOwner: [String: String] = [:]
    private var nextIndex = 0
    private var generation = 0
    private var documents: [URL] = []
    private var documentSet = Set<String>()
    private var publishScheduled = false
    private let interval: Duration
    private let continuation: AsyncStream<IngestSnapshot>.Continuation
    public nonisolated let snapshots: AsyncStream<IngestSnapshot>

    public init(interval: Duration = .milliseconds(250)) {
        self.interval = interval
        (snapshots, continuation) = AsyncStream.makeStream(of: IngestSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
    }

    public var count: Int { items.count }

    public func snapshot() -> IngestSnapshot {
        IngestSnapshot(items: items.values.sorted { $0.discoveryIndex < $1.discoveryIndex }, generation: generation, documents: documents)
    }

    public func item(_ id: String) -> MediaItem? { items[id] }

    public func clear() {
        items.removeAll()
        documents.removeAll()
        documentSet.removeAll()
        variantOwner.removeAll()
        groupOwner.removeAll()
        assetOwner.removeAll()
        changed()
    }

    public func remove(_ ids: Set<String>) {
        for id in ids {
            items[id] = nil
        }
        variantOwner = variantOwner.filter { !ids.contains($0.value) }
        groupOwner = groupOwner.filter { !ids.contains($0.value) }
        assetOwner = assetOwner.filter { !ids.contains($0.value) }
        changed()
    }

    // MARK: Web candidates

    @discardableResult
    public func ingest(json: String, frame: FrameInfo) -> Int {
        guard let data = json.data(using: .utf8), let batch = try? JSONDecoder().decode(RawBatch.self, from: data) else { return 0 }
        // The page the batch says it came from (location.href when it was sent): a late batch from the previous page,
        // arriving after the tab's address changed, still belongs to that page; pushState addresses are kept too.
        var frame = frame
        if frame.isMainFrame, let page = batch.page.flatMap(URL.init(string:)), page.scheme == "https" || page.scheme == "http" {
            frame.pageURL = page
        }
        var count = 0
        let base = frame.frameURL ?? frame.pageURL
        let frameKey = frame.frameURL?.absoluteString ?? frame.pageURL.absoluteString
        var title = frame.pageTitle
        if frame.isMainFrame, let batchTitle = batch.title?.nonEmpty { title = batchTitle }
        for candidate in batch.items where ingest(candidate, base: base, frameKey: frameKey, frame: frame, title: title) {
            count += 1
        }
        if count > 0 { changed() }
        return count
    }

    private func ingest(_ candidate: RawCandidate, base: URL, frameKey: String, frame: FrameInfo, title: String?) -> Bool {
        let raw = candidate.u
        let lower = raw.prefix(8).lowercased()
        let url: URL
        var origin = VariantOrigin(rawValue: candidate.k) ?? .img
        var flags = Set<MediaFlag>()
        if lower.hasPrefix("data:") {
            guard raw.count >= 4096, let parsed = URL(string: raw) else { return false }
            url = parsed
            origin = .data
            flags.insert(.dataURI)
        } else if lower.hasPrefix("blob:") {
            guard let parsed = URL(string: raw) else { return false }
            url = parsed
            flags.insert(.blobOnly)
        } else {
            guard let normalized = URLNormalizer.normalize(raw, relativeTo: base) else { return false }
            url = normalized
        }
        if candidate.k == "document" || (url.pathExtension.lowercased() == "pdf" && origin != .network) {
            if url.scheme == "https" || url.scheme == "http", documentSet.insert(url.absoluteString).inserted, documents.count < 500 {
                documents.append(url)
                return true
            }
            return false
        }

        if Self.nonMediaExtensions.contains(url.pathExtension.lowercased()),
           ![.img, .srcset, .picture].contains(origin), CDNRules.proxiedTarget(of: url) == nil
        { return false }
        var format = candidate.t.flatMap(MediaFormat.fromMIME) ?? URLNormalizer.formatFromExtension(of: url)
        // The type ends at ";" (data:image/png;base64,…) or at "," (data:image/svg+xml,<svg…).
        if format == nil, origin == .data, let mime = raw.dropFirst(5).split(whereSeparator: { $0 == ";" || $0 == "," }).first {
            format = MediaFormat.fromMIME(String(mime))
        }
        let kind = Self.kind(origin: origin, format: format)
        guard let kind else { return false }

        if url.scheme == "http" { flags.insert(.insecure) }
        if !frame.isMainFrame { flags.insert(.inIframe) }
        if candidate.drm == true { flags.insert(.protected) }
        if origin == .icon || Self.looksLikeIcon(url) || Self.isTracker(url) { flags.insert(.icon) }

        var variant = MediaVariant(id: url.absoluteString, url: url, format: format, origin: origin)
        if let width = candidate.w, let height = candidate.h, width > 0, height > 0 {
            variant.pixelSize = PixelSize(width: width, height: height)
        }
        if let descriptor = candidate.d?.trimmingCharacters(in: .whitespaces).lowercased() {
            if descriptor.hasSuffix("w"), let width = Int(descriptor.dropLast()) { variant.declaredWidth = width }
            if descriptor.hasSuffix("x"), let density = Double(descriptor.dropLast()) { variant.density = density }
        }
        if let duration = candidate.dur, duration.isFinite, duration > 0 { variant.duration = duration }

        let groupKey = (candidate.g ?? 0) > 0 ? "\(frameKey)#\(candidate.g ?? 0)" : nil
        let assetKey = CDNRules.assetKey(for: url)
        var owners: [String] = []
        if let owner = variantOwner[variant.id] { owners.append(owner) }
        if let groupKey, let owner = groupOwner[groupKey], let item = items[owner], Self.compatible(item.kind, kind) {
            owners.append(owner)
        }
        if let assetKey, let owner = assetOwner[assetKey], let item = items[owner], Self.compatible(item.kind, kind) {
            owners.append(owner)
        }
        owners = Array(Set(owners)).sorted { (items[$0]?.discoveryIndex ?? 0) < (items[$1]?.discoveryIndex ?? 0) }

        let itemID: String
        if let first = owners.first, var item = items[first] {
            itemID = first
            for other in owners.dropFirst() {
                merge(other, into: &item)
            }
            add(variant, to: &item)
            item.flags.formUnion(flags.subtracting([.icon]))
            if flags.contains(.icon), item.variants.count == 1 { item.flags.insert(.icon) }
            if item.alt == nil, let alt = candidate.alt?.nonEmpty { item.alt = alt }
            items[itemID] = item
        } else {
            itemID = "w:" + variant.id
            let context = WebContext(
                pageURL: frame.pageURL,
                pageTitle: title,
                frameURL: frame.frameURL,
                frameOrigin: frame.origin,
                isMainFrame: frame.isMainFrame
            )
            let item = MediaItem(
                id: itemID, kind: kind, variants: [variant], source: .web(context), discoveryIndex: nextIndex,
                group: frame.pageURL.absoluteString, groupTitle: title ?? frame.pageURL.host ?? "Page",
                alt: candidate.alt?.nonEmpty, flags: flags
            )
            nextIndex += 1
            items[itemID] = item
        }
        if var item = items[itemID] {
            addDerived(for: variant, to: &item)
            item.bestID = VariantRanker.best(item.variants)
            items[itemID] = item
            for existing in item.variants {
                variantOwner[existing.id] = itemID
            }
        }
        if let groupKey { groupOwner[groupKey] = itemID }
        if let assetKey { assetOwner[assetKey] = itemID }
        return true
    }

    private func add(_ variant: MediaVariant, to item: inout MediaItem) {
        if let index = item.variants.firstIndex(where: { $0.id == variant.id }) {
            var existing = item.variants[index]
            if existing.pixelSize == nil { existing.pixelSize = variant.pixelSize }
            if existing.declaredWidth == nil { existing.declaredWidth = variant.declaredWidth }
            if existing.density == nil { existing.density = variant.density }
            if existing.duration == nil { existing.duration = variant.duration }
            if existing.format == nil { existing.format = variant.format }
            if existing.isDerived, !variant.isDerived {
                existing.origin = variant.origin
                existing.check = .verified
            }
            item.variants[index] = existing
        } else {
            item.variants.append(variant)
        }
    }

    private func addDerived(for variant: MediaVariant, to item: inout MediaItem) {
        guard !variant.isDerived, variant.url.scheme == "https" || variant.url.scheme == "http" else { return }
        guard item.kind == .image || item.kind == .animatedImage else { return }
        for candidate in CDNRules.candidates(for: variant.url) {
            let id = candidate.url.absoluteString
            if item.variants.contains(where: { $0.id == id }) { continue }
            item.variants.append(MediaVariant(
                id: id, url: candidate.url, format: URLNormalizer.formatFromExtension(of: candidate.url) ?? variant.format,
                origin: .cdnRewrite, rule: candidate.rule, check: .unverified
            ))
        }
    }

    private func merge(_ otherID: String, into item: inout MediaItem) {
        guard otherID != item.id, let other = items[otherID] else { return }
        for variant in other.variants {
            add(variant, to: &item)
        }
        item.flags.formUnion(other.flags)
        if item.alt == nil { item.alt = other.alt }
        items[otherID] = nil
        for (key, value) in variantOwner where value == otherID {
            variantOwner[key] = item.id
        }
        for (key, value) in groupOwner where value == otherID {
            groupOwner[key] = item.id
        }
        for (key, value) in assetOwner where value == otherID {
            assetOwner[key] = item.id
        }
    }

    static func kind(origin: VariantOrigin, format: MediaFormat?) -> MediaKind? {
        if let format {
            switch format.kind {
            case .stream: return .stream
            case .video: return .video
            case .audio: return .audio
            case .vector: return .vector
            default: return format == .gif ? .animatedImage : .image
            }
        }
        switch origin {
        case .video: return .video
        case .audio: return .audio
        case .svg: return .vector
        case .network: return nil
        default: return .image
        }
    }

    static func compatible(_ a: MediaKind, _ b: MediaKind) -> Bool {
        func family(_ kind: MediaKind) -> Int {
            switch kind {
            case .image, .animatedImage, .vector: 0
            case .video: 1
            case .stream: 2
            case .audio: 3
            }
        }
        return family(a) == family(b)
    }

    static let nonMediaExtensions: Set<String> = [
        "html", "htm", "php", "asp", "aspx", "jsp", "js", "mjs", "css", "json", "xml", "txt", "woff", "woff2", "ttf", "otf", "eot",
        "pdf", "zip", "map", "wasm",
    ]

    static let trackerHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "amazon-adsystem.com", "scorecardresearch.com", "facebook.net", "adnxs.com", "criteo.com",
        "criteo.net", "taboola.com", "outbrain.com", "rubiconproject.com", "pubmatic.com", "casalemedia.com", "openx.net",
        "quantserve.com", "chartbeat.net", "chartbeat.com", "bat.bing.com", "adsrvr.org", "moatads.com", "demdex.net", "krxd.net",
        "everesttech.net", "3lift.com", "sharethrough.com", "teads.tv", "yieldmo.com", "bidswitch.net", "indexww.com",
        "smartadserver.com", "lijit.com", "adform.net", "mathtag.com", "agkn.com", "rlcdn.com", "tapad.com", "pinimg.com/ct",
        "ads-twitter.com", "analytics.twitter.com", "px.ads.linkedin.com", "snap.licdn.com", "hotjar.com", "newrelic.com",
        "nr-data.net", "segment.io", "mixpanel.com", "sentry.io", "omtrdc.net", "2o7.net", "adroll.com", "zemanta.com",
    ]

    static func isTracker(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        // An entry is a domain (and its subdomains), optionally followed by a path prefix such as pinimg.com/ct.
        return trackerHosts.contains { entry in
            let parts = entry.split(separator: "/", maxSplits: 1)
            let domain = String(parts[0])
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            return parts.count == 1 || path.hasPrefix("/" + parts[1])
        } || (host.hasSuffix("facebook.com") && url.path.hasPrefix("/tr"))
    }

    static func looksLikeIcon(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("favicon") || path.contains("apple-touch-icon") || path.contains("/sprite") || path.hasSuffix(".ico")
            || path.contains("spacer.gif") || path.contains("pixel.gif") || path.contains("/1x1")
    }

    // MARK: Engine items

    public func ingest(engineItems inputs: [EngineItemInput]) {
        for input in inputs {
            ingest(engineItem: input)
        }
        if !inputs.isEmpty { changed() }
    }

    private func ingest(engineItem input: EngineItemInput) {
        let context = input.context
        if var existing = items[context.key] {
            // A refreshed listing replaces what the engine says about the item; an empty one keeps what was there.
            var fresh = input.makeItem(discoveryIndex: existing.discoveryIndex)
            guard !fresh.variants.isEmpty else { return }
            for variant in existing.variants where !fresh.variants.contains(where: { $0.id == variant.id }) {
                variantOwner[variant.id] = nil
            }
            fresh.group = existing.group
            existing = fresh
            items[context.key] = existing
            for variant in fresh.variants {
                variantOwner[variant.id] = context.key
            }
            return
        }
        let item = input.makeItem(discoveryIndex: nextIndex)
        guard !item.variants.isEmpty else { return }
        nextIndex += 1
        items[context.key] = item
        for variant in item.variants {
            variantOwner[variant.id] = context.key
        }
    }

    // MARK: PDF images

    public func ingest(documentImages inputs: [DocumentImageInput]) {
        for input in inputs {
            let id = "pdf:\(input.documentURL.absoluteString)#\(input.page)-\(input.index)"
            var variant = MediaVariant(id: input.file.absoluteString, url: input.file, format: input.format,
                                       pixelSize: PixelSize(width: input.width, height: input.height), byteCount: input.bytes,
                                       origin: .document)
            variant.check = .verified
            let context = WebContext(pageURL: input.documentURL, pageTitle: input.documentTitle, documentPage: input.page)
            var item = MediaItem(
                id: id, kind: .image, variants: [variant], source: .web(context), discoveryIndex: nextIndex,
                group: input.documentURL.absoluteString, groupTitle: "\(input.documentTitle) (PDF)",
                alt: "Page \(input.page) of \(input.documentTitle)"
            )
            if let existing = items[id] { item = MediaItem(id: id, kind: .image, variants: [variant], source: existing.source,
                                                           discoveryIndex: existing.discoveryIndex, group: existing.group,
                                                           groupTitle: existing.groupTitle, alt: existing.alt) } else { nextIndex += 1 }
            items[id] = item
            variantOwner[variant.id] = id
        }
        if !inputs.isEmpty { changed() }
    }

    // MARK: Updates

    public func apply(probe: ProbeResult, itemID: String, variantID: String) {
        guard var item = items[itemID], let index = item.variants.firstIndex(where: { $0.id == variantID }) else { return }
        var variant = item.variants[index]
        if let status = probe.failedStatus {
            variant.check = .failed(status)
        } else if probe.isMarkup {
            variant.check = .failed(0)
        } else {
            if let format = probe.format { variant.format = format }
            if let size = probe.pixelSize { variant.pixelSize = size }
            if let bytes = probe.byteCount { variant.byteCount = bytes }
            if let duration = probe.duration { variant.duration = duration }
            variant.check = .verified
            if variant.isDerived, let size = variant.pixelSize {
                let foundBest = item.variants.filter { !$0.isDerived }.compactMap(\.pixelSize).max { $0.pixels < $1.pixels }
                if let foundBest, size.pixels < foundBest.pixels { variant.check = .failed(1) }
            }
        }
        item.variants[index] = variant
        if let format = variant.format, variant.check == .verified, index == item.variants.firstIndex(where: { $0.id == item.bestID }) {
            if format == .gif, item.kind == .image { item.kind = .animatedImage }
        }
        item.bestID = VariantRanker.best(item.variants)
        items[itemID] = item
        changed()
    }

    public func markDuplicate(_ itemID: String) {
        guard var item = items[itemID] else { return }
        item.flags.insert(.duplicate)
        items[itemID] = item
        changed()
    }

    private func changed() {
        generation += 1
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { [interval] in
            try? await Task.sleep(for: interval)
            self.publish()
        }
    }

    private func publish() {
        publishScheduled = false
        continuation.yield(snapshot())
    }

    /// Publishes immediately, for tests and for actions that must show at once.
    public func flush() {
        continuation.yield(snapshot())
    }
}

public extension EngineItemInput {
    /// The media item for an engine-reported item: the best engine URL, a progressive fallback for
    /// DASH videos, and a thumbnail variant for display.
    func makeItem(discoveryIndex: Int) -> MediaItem {
        var variants: [MediaVariant] = []
        let size = (width ?? 0) > 0 && (height ?? 0) > 0 ? PixelSize(width: width ?? 0, height: height ?? 0) : nil
        if isDash || engineURL.hasPrefix("ytdl:") {
            let dashURL = URL(string: engineURL) ?? URL(string: "ytdl:item")!
            variants.append(MediaVariant(id: "engine:" + context.key, url: dashURL, format: .mp4, pixelSize: size, origin: .engineDash,
                                         requiresEngine: true))
            if let fallback = fallbackURL {
                variants.append(MediaVariant(id: fallback.absoluteString, url: fallback, format: .mp4, origin: .engine))
            }
        } else if let url = URL(string: engineURL) {
            let ext = context.fileName.map { ($0 as NSString).pathExtension } ?? ""
            let format = MediaFormat.fromExtension(ext) ?? URLNormalizer.formatFromExtension(of: url)
            variants.append(MediaVariant(id: url.absoluteString, url: url, format: format, pixelSize: size, origin: .engine))
        }
        if let thumb = thumbURL, !variants.contains(where: { $0.id == thumb.absoluteString }) {
            variants.append(MediaVariant(id: thumb.absoluteString, url: thumb, format: URLNormalizer.formatFromExtension(of: thumb),
                                         origin: .engineThumbnail))
        }
        let group = context.postID ?? context.postShortcode ?? context.key
        var title = context.username.map { "@\($0)" } ?? context.category.capitalized
        if let date = context.date { title += " · " + DateFormats.string(date, format: "d MMM yyyy") }
        if let highlight = context.highlightTitle { title += " · \(highlight)" }
        var flags = Set<MediaFlag>()
        if context.pinned { flags.insert(.pinned) }
        var item = MediaItem(
            id: context.key, kind: kind, variants: variants, source: .engine(context), discoveryIndex: discoveryIndex,
            group: group, groupTitle: title, alt: context.description?.nonEmpty.map { String($0.prefix(300)) }, flags: flags
        )
        item.posterURL = thumbURL
        return item
    }
}
