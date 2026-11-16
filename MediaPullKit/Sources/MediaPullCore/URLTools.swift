import Foundation

public enum URLNormalizer {
    /// Resolves `string` against `base`, lowercases scheme and host, drops the fragment and default
    /// port. Query strings are kept exactly as found because many CDN URLs are signed.
    public static func normalize(_ string: String, relativeTo base: URL?) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("blob:") { return URL(string: trimmed) }
        if lower.hasPrefix("javascript:") || lower.hasPrefix("about:") || lower.hasPrefix("mailto:") { return nil }
        guard let resolved = URL(string: trimmed, relativeTo: base)?.absoluteURL
            ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)) ?? "",
                   relativeTo: base)?.absoluteURL
        else { return nil }
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    public static func key(_ url: URL) -> String {
        url.absoluteString
    }

    public static func pathExtension(of url: URL) -> String {
        url.pathExtension.lowercased()
    }

    public static func formatFromExtension(of url: URL) -> MediaFormat? {
        MediaFormat.fromExtension(url.pathExtension)
    }

    /// A readable name for the file from the last path component, without extension.
    public static func baseName(of url: URL) -> String? {
        // Image proxies (thumb.php?src=…, /_next/image?url=…) are named after the image they serve.
        if ["php", "asp", "aspx", "jsp", "cgi", ""].contains(url.pathExtension.lowercased()), let target = CDNRules.proxiedTarget(of: url) {
            return baseName(of: target)
        }
        // lastPathComponent is already decoded; decoding again would turn a literal "100%25" into "100%" and then fail.
        let last = url.deletingPathExtension().lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" { return nil }
        if isGenericName(trimmed) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/", !isGenericName(parent) { return parent }
        }
        return trimmed
    }

    /// Names that say nothing about the content, typical of stream playlists.
    static func isGenericName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let generic: Set = [
            "index", "master", "playlist", "manifest", "chunklist", "video", "stream", "media", "prog_index", "main", "default",
            "image", "img", "photo", "file", "download", "original", "source", "hls", "dash", "init",
        ]
        if generic.contains(lower) { return true }
        return lower.range(of: #"^(index|master|playlist|chunklist|manifest)[-_]"#, options: .regularExpression) != nil
    }

    public static func isSameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = a?.host, let b = b?.host else { return false }
        return PublicSuffix.shared.registrableDomain(a) == PublicSuffix.shared.registrableDomain(b)
    }

    /// The Referer the browser would send under strict-origin-when-cross-origin.
    public static func referer(for target: URL, from page: URL?) -> String? {
        guard let page, page.scheme == "http" || page.scheme == "https" else { return nil }
        if page.scheme == "https", target.scheme == "http" { return nil }
        let sameOrigin = page.scheme == target.scheme && page.host == target.host && page.port == target.port
        if sameOrigin {
            var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            components?.user = nil
            components?.password = nil
            return components?.string
        }
        guard let scheme = page.scheme, let host = page.host else { return nil }
        let port = page.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }
}

/// The Public Suffix List, for registrable domains (eTLD+1).
public final class PublicSuffix: Sendable {
    public static let shared = PublicSuffix()

    private let rules: Set<String>
    private let wildcards: Set<String>
    private let exceptions: Set<String>

    init() {
        var rules = Set<String>()
        var wildcards = Set<String>()
        var exceptions = Set<String>()
        if let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
           let text = try? String(contentsOf: url, encoding: .utf8)
        {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("//") { continue }
                let rule = String(line.split(separator: " ").first ?? "").lowercased()
                if rule.hasPrefix("!") {
                    exceptions.insert(String(rule.dropFirst()))
                } else if rule.hasPrefix("*.") {
                    wildcards.insert(String(rule.dropFirst(2)))
                } else {
                    rules.insert(rule)
                }
            }
        }
        self.rules = rules
        self.wildcards = wildcards
        self.exceptions = exceptions
    }

    public func registrableDomain(_ host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.isEmpty || host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1 else { return host }
        var suffixLength = 1
        for index in 0 ..< labels.count {
            let candidate = labels[index...].joined(separator: ".")
            if exceptions.contains(candidate) {
                suffixLength = labels.count - index - 1
                break
            }
            if rules.contains(candidate) {
                suffixLength = labels.count - index
                break
            }
            if index + 1 < labels.count {
                let parent = labels[(index + 1)...].joined(separator: ".")
                if wildcards.contains(parent) {
                    suffixLength = labels.count - index
                    break
                }
            }
        }
        if suffixLength >= labels.count { return host }
        return labels[(labels.count - suffixLength - 1)...].joined(separator: ".")
    }
}
