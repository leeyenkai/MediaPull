import Foundation

/// Derives larger "original" variants from URLs found on a page (SPEC Appendix D). Every derived
/// URL is unverified until a range request confirms it.
public enum CDNRules {
    public struct Candidate: Equatable, Sendable {
        public var url: URL
        public var rule: String
    }

    static let signatureParameters: Set<String> = [
        "s", "sig", "signature", "token", "expires", "hmac", "oh", "oe", "x-amz-signature", "x-goog-signature",
        "policy", "key-pair-id", "hdnts", "_nc_sid", "efg", "stp", "se",
    ]
    static let sizeParameters: Set<String> = [
        "w", "h", "width", "height", "resize", "size", "quality", "q", "fit", "crop", "dpr", "auto", "fm", "format",
        "max-w", "max-h", "maxwidth", "maxheight", "im", "rect", "ar", "c", "imwidth", "impolicy", "downsize",
        "disable", "output-quality", "output-format",
    ]

    /// The rendition names in NYT image file names, each replaced by the larger renditions.
    private static let nytRenditions = [
        "articleLarge", "articleInline", "articleMedium", "superJumbo", "jumbo", #"master\d+"#, #"threeByTwo\w*"#, #"twoByThree\w*"#,
        #"verticalTwoByThree\d*"#, #"horizontal\w*"#, #"mediumSquare\w*"#, #"smallSquare\w*"#, #"square\d+"#, "thumbLarge", "thumbStandard",
        "thumbWide", "smallTwoByThree", #"mediumThreeByTwo\d*"#, #"largeHorizontal\d*"#, #"largeWidescreen\d*"#, #"videoSixteenByNine\w*"#,
        "videoLarge", #"videoFifteenBySeven\d*"#, "sfSpan", "hpLarge", "hpSmall", "popup", #"blog\d+"#, "facebookJumbo", "filmstrip",
        "moth", #"google\w+"#, #"watch\d+"#, "wide", #"mobileMaster\w*"#, "tmagArticle", "tmagSF", "slide", #"articleSixteenByNine\w*"#,
        "threeByTwoSmallAt2X", "threeByTwoLargeAt2X", "threeByTwoMediumAt2X",
    ]
    private static let nytRendition = try? NSRegularExpression(
        pattern: #"^(.+)-("# + nytRenditions.joined(separator: "|") + #")(-v\d+)?\.(jpg|jpeg|png|gif|webp)$"#
    )
    private static let wordpressSize = try? NSRegularExpression(pattern: #"-\d{2,5}x\d{2,5}(?=\.[A-Za-z0-9]{2,5}$)"#)
    private static let wordpressScaled = try? NSRegularExpression(pattern: #"-scaled(?=\.[A-Za-z0-9]{2,5}$)"#)
    private static let shopifySize = try? NSRegularExpression(
        pattern: #"_(\d{1,5}x\d{0,5}|\d{0,5}x\d{1,5}|pico|icon|thumb|small|compact|medium|large|grande)"#
            + #"(_crop_[a-z]+)?(@\dx)?(?=\.[A-Za-z0-9]{2,5}$)"#
    )
    /// A Cloudinary transformation segment: comma-separated parameters, each a known key such as w_, c_ or f_.
    private static let cloudinaryTransform = try? NSRegularExpression(
        // Possessive quantifiers: a hostile path cannot make the match backtrack exponentially.
        pattern:
            #"^(?:(?:w|h|c|g|q|f|e|r|a|o|b|x|y|z|t|l|u|d|ar|dpr|fl|bo|co|cs|dn|du|eo|so|ac|af|vc|vs|br|fps|ki|sp|pg|if)_[^,/]++,?+)++$"#
    )
    private static let pinterestSize = try? NSRegularExpression(pattern: #"^(\d+x\d*|\d+x\d+_RS)$"#)

    static let proxyParameters: Set<String> = [
        "src", "img", "image", "file", "url", "path", "u", "f", "source", "imgurl", "image_url", "imageurl", "photo", "pic", "picture",
    ]
    static let proxiedExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "jxl", "tif", "tiff", "bmp"]

    /// The image a resizing script or image proxy serves (`thumb.php?src=photos/a.jpg`, `/_next/image?url=…`),
    /// resolved against the proxy's own URL.
    public static func proxiedTarget(of url: URL) -> URL? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items where proxyParameters.contains(item.name.lowercased()) {
            guard let value = item.value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  let target = URL(string: value, relativeTo: url)?.absoluteURL,
                  target.scheme == "https" || target.scheme == "http", target != url,
                  proxiedExtensions.contains(target.pathExtension.lowercased())
            else { continue }
            return target
        }
        return nil
    }

    /// Candidate original-size URLs for `url`, best first. Signed URLs get none.
    public static func candidates(for url: URL) -> [Candidate] {
        guard let host = url.host?.lowercased(), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return []
        }
        let items = components.queryItems ?? []
        // Kept parameters stay exactly as encoded (R-909): decoding and re-encoding would turn "%2B" into "+".
        let encodedItems = components.percentEncodedQueryItems ?? []
        // preview.redd.it always signs its resized copies; the original on i.redd.it needs no query at all.
        if host == "preview.redd.it" {
            var copy = components
            copy.host = "i.redd.it"
            copy.queryItems = nil
            return copy.url.map { [Candidate(url: $0, rule: "reddit")] } ?? []
        }
        if items.contains(where: { signatureParameters.contains($0.name.lowercased()) }) { return [] }
        if host.hasSuffix("cdninstagram.com") || host.hasSuffix("fbcdn.net") { return [] }

        var results: [Candidate] = []
        func add(_ string: String?, _ rule: String) {
            guard let string, let candidate = URL(string: string), candidate != url,
                  !results.contains(where: { $0.url == candidate })
            else { return }
            results.append(Candidate(url: candidate, rule: rule))
        }
        let path = components.percentEncodedPath
        let last = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent

        if let target = proxiedTarget(of: url) {
            add(target.absoluteString, "proxy")
            for nested in candidates(for: target) { add(nested.url.absoluteString, nested.rule) }
            return results
        }

        if host == "pbs.twimg.com", path.hasPrefix("/media/") {
            // The original is served as JPEG or PNG; any other format (webp) is a transcode, so try jpg then png (Appendix D).
            var copy = components
            let served = items.first { $0.name == "format" }?.value?.lowercased()
                ?? (url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased())
            if items.first(where: { $0.name == "format" }) == nil { copy.percentEncodedPath = (path as NSString).deletingPathExtension }
            let kept = encodedItems.filter { $0.name != "name" && $0.name != "format" }
            // A webp copy is tried as jpg only: offering png too would win the lossless tie-break and save a PNG
            // decoded from a JPEG original.
            for format in ["jpg", "png"].contains(served) ? [served] : ["jpg"] {
                copy.percentEncodedQueryItems = kept + [
                    URLQueryItem(name: "format", value: format),
                    URLQueryItem(name: "name", value: "orig")
                ]
                add(copy.string, "twitter")
            }
            return results
        }

        if host.hasSuffix("nyt.com"), let regex = nytRendition,
           let match = regex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last))
        {
            let ns = last as NSString
            let stem = ns.substring(with: match.range(at: 1))
            let version = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
            let ext = ns.substring(with: match.range(at: 4))
            var copy = components
            copy.query = nil
            for rendition in ["superJumbo", "jumbo"] {
                copy.percentEncodedPath = folder + "/" + "\(stem)-\(rendition)\(version).\(ext)"
                add(copy.string, "nytimes")
                if !version.isEmpty {
                    copy.percentEncodedPath = folder + "/" + "\(stem)-\(rendition).\(ext)"
                    add(copy.string, "nytimes")
                }
            }
            copy.percentEncodedPath = path
            add(copy.string, "nytimes")
            return results
        }

        if path.contains("/wp-content/uploads/") || path.contains("/wp-content/blogs.dir/") {
            var changed = last
            for regex in [wordpressSize, wordpressScaled].compactMap({ $0 }) {
                changed = regex.stringByReplacingMatches(in: changed, range: NSRange(changed.startIndex..., in: changed), withTemplate: "")
            }
            var copy = components
            copy.percentEncodedPath = folder + "/" + changed
            copy.queryItems = nil
            add(copy.string, "wordpress")
        }
        if host.range(of: #"^i\d\.wp\.com$"#, options: .regularExpression) != nil {
            var copy = components
            let ssl = encodedItems.filter { $0.name == "ssl" }
            copy.percentEncodedQueryItems = ssl.isEmpty ? nil : ssl
            add(copy.string, "wordpress")
        }

        if host == "i.pinimg.com", let regex = pinterestSize {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if let first = parts.first, regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) != nil {
                for size in ["originals", "1200x"] {
                    var copy = components
                    copy.percentEncodedPath = "/" + ([size] + parts.dropFirst()).joined(separator: "/")
                    add(copy.string, "pinterest")
                }
            }
            return results
        }

        if host == "cdn.shopify.com" || path.contains("/cdn/shop/"), let regex = shopifySize {
            let changed = regex.stringByReplacingMatches(in: last, range: NSRange(last.startIndex..., in: last), withTemplate: "")
            var copy = components
            copy.percentEncodedPath = folder + "/" + changed
            let kept = encodedItems.filter { !["width", "height", "crop"].contains($0.name.lowercased()) }
            copy.percentEncodedQueryItems = kept.isEmpty ? nil : kept
            add(copy.string, "shopify")
        }

        if host == "res.cloudinary.com", let regex = cloudinaryTransform,
           let range = path.range(of: "/upload/")
        {
            let after = path[range.upperBound...].split(separator: "/").map(String.init)
            if !(after.first?.hasPrefix("s--") ?? false) {
                let kept = after.drop { segment in
                    regex.firstMatch(in: segment, range: NSRange(segment.startIndex..., in: segment)) != nil
                }
                if kept.count < after.count, !kept.isEmpty {
                    var copy = components
                    copy.percentEncodedPath = String(path[..<range.upperBound]) + kept.joined(separator: "/")
                    add(copy.string, "cloudinary")
                }
            }
        }

        if host.hasSuffix(".imgix.net") {
            let sizing: Set = ["w", "h", "q", "fit", "auto", "fm", "dpr", "crop", "max-w", "max-h", "rect"]
            let kept = encodedItems.filter { !sizing.contains($0.name.lowercased()) }
            if kept.count < encodedItems.count {
                var copy = components
                copy.percentEncodedQueryItems = kept.isEmpty ? nil : kept
                add(copy.string, "imgix")
            }
            return results
        }

        if host == "upload.wikimedia.org", path.contains("/thumb/") {
            var parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if let index = parts.firstIndex(of: "thumb"), parts.count > index + 2 {
                parts.remove(at: index)
                parts.removeLast()
                var copy = components
                copy.percentEncodedPath = parts.joined(separator: "/")
                copy.queryItems = nil
                add(copy.string, "wikimedia")
            }
            return results
        }

        if results.isEmpty, !items.isEmpty, items.contains(where: { sizeParameters.contains($0.name.lowercased()) }),
           MediaFormat.fromExtension(url.pathExtension)?.kind == .image
        {
            let kept = encodedItems.filter { !sizeParameters.contains($0.name.lowercased()) }
            components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
            add(components.string, "query")
        }
        return results
    }

    /// A small rendition for thumbnails, where the CDN offers one, so the grid does not download
    /// full originals just to show a preview.
    public static func thumbnailURL(for url: URL, width: Int) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "upload.wikimedia.org", !url.path.contains("/thumb/") {
            // The encoded path, so a name with "?" or "#" stays part of the path.
            let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            let parts = encoded.split(separator: "/").map(String.init)
            guard parts.count >= 4, let name = parts.last else { return nil }
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "gif", "webp", "tif", "tiff", "svg"].contains(ext) else { return nil }
            let suffix = ["svg", "tif", "tiff"].contains(ext) ? ".png" : ""
            let path = "/" + parts.dropLast().prefix(2).joined(separator: "/") + "/thumb/"
                + parts.dropLast().dropFirst(2).joined(separator: "/")
                + "/\(name)/\(width)px-\(name)\(suffix)"
            return URL(string: "https://upload.wikimedia.org" + path)
        }
        if host == "pbs.twimg.com", url.path.hasPrefix("/media/") {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            let items = (components.queryItems ?? []).filter { $0.name != "name" }
            components.queryItems = items + [URLQueryItem(name: "name", value: "small")]
            return components.url
        }
        if host == "i.pinimg.com" {
            let parts = url.path.split(separator: "/").dropFirst()
            return URL(string: "https://i.pinimg.com/474x/" + parts.joined(separator: "/"))
        }
        return nil
    }

    /// A key shared by all sizes of the same asset, so renditions found in different elements
    /// merge into one item.
    public static func assetKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path
        let last = (path as NSString).lastPathComponent
        if host.hasSuffix("nyt.com"), let regex = nytRendition,
           let match = regex.firstMatch(in: last, range: NSRange(last.startIndex..., in: last))
        {
            let stem = (last as NSString).substring(with: match.range(at: 1))
            return "nyt:" + (path as NSString).deletingLastPathComponent + "/" + stem
        }
        if host == "pbs.twimg.com", path.hasPrefix("/media/") {
            return "tw:" + (path as NSString).deletingPathExtension
        }
        if host == "i.pinimg.com" {
            let parts = path.split(separator: "/").dropFirst()
            return "pin:" + parts.joined(separator: "/")
        }
        // The same renditions the candidate rule strips (-1024x683, -scaled), in both upload folders, so they merge (R-910).
        if path.contains("/wp-content/uploads/") || path.contains("/wp-content/blogs.dir/") {
            var base = last
            for regex in [wordpressSize, wordpressScaled].compactMap({ $0 }) {
                base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: "")
            }
            return "wp:" + host + (path as NSString).deletingLastPathComponent + "/" + base
        }
        if host == "cdn.shopify.com" || path.contains("/cdn/shop/"), let regex = shopifySize {
            let base = regex.stringByReplacingMatches(in: last, range: NSRange(last.startIndex..., in: last), withTemplate: "")
            return "shop:" + host + (path as NSString).deletingLastPathComponent + "/" + base
        }
        if host == "upload.wikimedia.org", path.contains("/thumb/") {
            var parts = path.split(separator: "/").map(String.init)
            if let index = parts.firstIndex(of: "thumb"), parts.count > index + 2 {
                parts.remove(at: index)
                parts.removeLast()
                return "wiki:" + parts.joined(separator: "/")
            }
        }
        if host == "upload.wikimedia.org" { return "wiki:" + path.split(separator: "/").joined(separator: "/") }
        return nil
    }
}

public enum VariantRanker {
    /// The id of the variant MediaPull would save (SPEC R-914).
    public static func best(_ variants: [MediaVariant]) -> String? {
        let usable = variants.filter { !$0.hasFailed }
        guard !usable.isEmpty else { return variants.first?.id }
        let knownPixels = usable.compactMap { effectivePixels($0) }.max() ?? 0
        return usable.max { lhs, rhs in
            score(lhs, knownPixels: knownPixels).lexicographicallyPrecedes(score(rhs, knownPixels: knownPixels))
        }?.id
    }

    /// Why `best` won, in plain words, for the Preview pane (R-914, R-1009): the first rule that told it apart from the
    /// next best version.
    public static func reason(_ variants: [MediaVariant]) -> String? {
        let usable = variants.filter { !$0.hasFailed && $0.origin != .engineThumbnail }
        guard let bestID = best(variants), let chosen = usable.first(where: { $0.id == bestID }) else { return nil }
        let others = usable.filter { $0.id != bestID }
        guard !others.isEmpty else { return "The only version that can be saved." }
        let knownPixels = usable.compactMap { effectivePixels($0) }.max() ?? 0
        let mine = score(chosen, knownPixels: knownPixels)
        let runnerUp = others.map { score($0, knownPixels: knownPixels) }.max { $0.lexicographicallyPrecedes($1) } ?? mine
        let rule = mine.indices.first { mine[$0] != runnerUp[$0] } ?? 0
        switch rule {
        case 0:
            if chosen.isDerived, chosen.pixelSize == nil {
                return "Probably the full-size original (worked out from the address; checked before saving)."
            }
            if chosen.origin == .link, chosen.pixelSize == nil { return "The full-size file the page links to." }
            return "The most pixels."
        case 1: return "The highest-density version among those of the same size."
        case 2: return "Already in a normal format at the same size, so nothing is converted."
        case 3: return "Lossless at the same size."
        default: return "The largest file at the same size."
        }
    }

    static func effectivePixels(_ variant: MediaVariant) -> Int? {
        if let size = variant.pixelSize { return size.pixels }
        if let width = variant.declaredWidth {
            let clamped = min(max(width, 0), 100_000)
            return clamped * clamped * 2 / 3
        }
        return nil
    }

    private static func score(_ variant: MediaVariant, knownPixels: Int) -> [Double] {
        var pixels = Double(effectivePixels(variant) ?? 0)
        // Derived originals and links to media files (lightbox targets) are usually the full-size
        // image; they win until a probe shows otherwise.
        if variant.isDerived || variant.origin == .link, !variant.hasFailed, variant.pixelSize == nil {
            pixels = Double(knownPixels) + 1
        }
        if variant.requiresEngine, variant.pixelSize == nil { pixels = Double(knownPixels) + 0.5 }
        if variant.origin == .engineThumbnail { pixels = -1 }
        let density = variant.density ?? 0
        let normal: Double = (variant.format?.isNormal ?? false) ? 1 : 0
        let lossless: Double = (variant.format?.isLosslessImage ?? false) ? 1 : 0
        let bytes = Double(variant.byteCount ?? 0)
        return [pixels, density, normal, lossless, bytes]
    }
}
