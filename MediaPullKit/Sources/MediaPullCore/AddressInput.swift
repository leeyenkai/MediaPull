import Foundation

/// What the user typed in the address field, or what page the browser is on (SPEC R-803).
public enum AddressInput: Equatable, Sendable {
    case web(URL)
    case instagramProfile(username: String, url: URL)
    case instagramPost(shortcode: String, url: URL)
    case instagramStories(username: String, url: URL)
    case instagramHighlight(id: String, url: URL)
    case handle(String)
    case invalid

    public static let reservedInstagramPaths: Set<String> = [
        "accounts", "explore", "direct", "reels", "reel", "p", "tv", "stories", "about", "legal", "developer", "emails",
        "challenge", "graphql", "api", "web", "privacy", "terms", "session", "login", "signup", "directory", "nametag",
        "lite", "ar", "static", "oauth", "data", "download", "press", "blog", "help", "fragment", "your_activity", "settings",
    ]

    public static func parse(_ raw: String) -> AddressInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        if text.hasPrefix("@") {
            let name = String(text.dropFirst()).lowercased()
            return isValidUsername(name) ? .handle(name) : .invalid
        }
        var candidate = text
        if !candidate.contains("://") {
            guard looksLikeHost(candidate) else { return .invalid }
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate)
                  ?? URL(string: candidate.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return .invalid }
        return classify(url)
    }

    public static func classify(_ url: URL) -> AddressInput {
        guard let host = url.host?.lowercased(), host == "instagram.com" || host.hasSuffix(".instagram.com") else {
            return .web(url)
        }
        let parts = url.path.split(separator: "/").map(String.init)
        let clean = cleanInstagramURL(url)
        guard let first = parts.first else { return .web(clean) }
        switch first.lowercased() {
        case "p", "reel", "reels", "tv":
            if parts.count >= 2 { return .instagramPost(shortcode: parts[1], url: clean) }
        case "stories":
            if parts.count >= 3, parts[1] == "highlights" { return .instagramHighlight(id: parts[2], url: clean) }
            if parts.count >= 2 { return .instagramStories(username: parts[1].lowercased(), url: clean) }
        default:
            if parts.count >= 3, ["p", "reel", "tv"].contains(parts[1]) {
                return .instagramPost(shortcode: parts[2], url: clean)
            }
            let name = first.lowercased()
            if !reservedInstagramPaths.contains(name), isValidUsername(name) {
                return .instagramProfile(username: name, url: clean)
            }
        }
        return .web(clean)
    }

    public var url: URL? {
        switch self {
        case let .web(url): url
        case let .instagramProfile(_, url), let .instagramPost(_, url), let .instagramStories(_, url), let .instagramHighlight(_, url): url
        case let .handle(name): URL(string: "https://www.instagram.com/\(name)/")
        case .invalid: nil
        }
    }

    public var instagramUsername: String? {
        switch self {
        case let .instagramProfile(name, _), let .instagramStories(name, _), let .handle(name): name
        default: nil
        }
    }

    /// A bare Instagram username typed where only addresses and accounts are expected (the Downloads pane, R-1104); a
    /// word with a dot is read as a web address instead.
    public static func bareUsername(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.contains(".") && isValidUsername(name) ? name : nil
    }

    static func isValidUsername(_ name: String) -> Bool {
        guard (1 ... 30).contains(name.count) else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
    }

    static func looksLikeHost(_ text: String) -> Bool {
        let hostPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if hostPart.contains(" ") { return false }
        if hostPart.hasPrefix("localhost") { return true }
        let labels = hostPart.split(separator: ":").first?.split(separator: ".") ?? []
        if labels.count == 4, labels.allSatisfy({ Int($0).map { (0 ... 255).contains($0) } ?? false }) { return true }
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) || tld.allSatisfy(\.isNumber) else {
            return false
        }
        return true
    }

    /// Removes tracking parameters from Instagram links.
    public static func cleanInstagramURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = components.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !(name == "igsh" || name == "igshid" || name.hasPrefix("utm_") || name == "fbclid" || name == "img_index")
        }
        if components.queryItems?.isEmpty ?? false { components.queryItems = nil }
        components.fragment = nil
        components.host = "www.instagram.com"
        components.scheme = "https"
        return components.url ?? url
    }
}

public enum InstagramIDs {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    public static func id(fromShortcode code: String) -> String? {
        let code = code.count > 28 ? String(code.prefix(code.count - 28)) : code
        var value: UInt64 = 0
        for character in code {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 64)
            if overflow { return nil }
            value = shifted + UInt64(index)
        }
        return String(value)
    }

    public static func shortcode(fromID id: String) -> String? {
        guard var value = UInt64(id) else { return nil }
        if value == 0 { return "A" }
        var characters: [Character] = []
        while value > 0 {
            characters.append(alphabet[Int(value % 64)])
            value /= 64
        }
        return String(characters.reversed())
    }
}
