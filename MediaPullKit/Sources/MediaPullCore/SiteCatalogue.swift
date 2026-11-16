import Foundation

/// The sites the bundled gallery-dl supports (SPEC R-1111b), built by `scripts/build_site_catalogue.py`:
/// each site's name, how it signs in, and its own switches that choose what media to download.
public struct SiteCatalogue: Codable, Sendable {
    public enum SignIn: String, Codable, Sendable {
        /// Public pages work without an account.
        case none
        /// Works without an account; signing in shows more (private, age-restricted or followers-only posts).
        case optional
        /// Needs the browser signed in to the site.
        case cookies
        /// Needs an access token from the site's own sign-in flow.
        case oauth
        /// Needs an API key from the site.
        case key
        /// Needs an account.
        case required
    }

    public struct Site: Codable, Sendable, Equatable {
        public var name: String
        public var home: String
        public var auth: SignIn
    }

    public struct Switch: Codable, Sendable, Equatable, Hashable {
        public var key: String
        public var label: String
        public var `default`: Bool
    }

    public var galleryDL: String
    public var sites: [String: Site]
    public var options: [String: [Switch]]

    public init(galleryDL: String = "", sites: [String: Site] = [:], options: [String: [Switch]] = [:]) {
        self.galleryDL = galleryDL
        self.sites = sites
        self.options = options
    }

    public static func load(from url: URL?) -> SiteCatalogue {
        guard let url, let data = try? Data(contentsOf: url),
              let catalogue = try? JSONDecoder().decode(SiteCatalogue.self, from: data)
        else {
            return SiteCatalogue()
        }
        return catalogue
    }

    public func site(_ info: SiteInfoKey) -> Site? {
        sites[info.category] ?? sites[info.baseCategory]
    }

    /// The site's name as people know it ("Twitter", "DeviantArt"), or a tidy version of the category.
    public func name(_ info: SiteInfoKey) -> String {
        if let name = site(info)?.name { return name.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        return info.category.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? info.category
    }

    public func signIn(_ info: SiteInfoKey) -> SignIn {
        site(info)?.auth ?? .none
    }

    /// The site's media switches; a site of a shared engine (a Mastodon server, a Danbooru board) uses the engine's.
    public func switches(_ info: SiteInfoKey) -> [Switch] {
        options[info.category] ?? options[info.baseCategory.lowercased()] ?? []
    }

    /// Parts of a profile that hold no media of their own are not offered.
    public static func visibleChoices(_ choices: [String]) -> [String] {
        choices.filter { !["info", "user", "following", "followers"].contains($0) }
    }

    /// A readable name for a part of a profile ("with-replies" becomes "With Replies").
    public static func choiceLabel(_ choice: String) -> String {
        if let known = choiceLabels[choice] { return known }
        let words = choice.replacingOccurrences(of: "_", with: "-").split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.joined(separator: " ")
    }

    static let choiceLabels: [String: String] = [
        "timeline": "Timeline", "tweets": "Posts", "media": "Media", "with-replies": "Posts and Replies", "highlights": "Highlights",
        "likes": "Likes", "replies": "Replies", "avatar": "Profile Picture", "background": "Banner", "favorite": "Favourites",
        "favorites": "Favourites", "bookmark": "Bookmarks", "gallery": "Gallery", "scraps": "Scraps", "journal": "Journal",
        "journals": "Journals", "status": "Status Updates", "artworks": "Artworks", "sketch": "Sketches", "posts": "Posts",
        "video": "Videos", "videos": "Videos", "user-models": "Models", "user-posts": "Posts", "user-images": "Images",
        "user-videos": "Videos", "user-collections": "Collections", "highlights-covers": "Highlight Covers", "reels": "Reels",
        "stories": "Stories", "photos": "Photos", "tagged": "Tagged", "notes": "Notes", "art": "Art", "audio": "Audio",
        "movies": "Movies", "games": "Games", "uploads": "Uploads", "collections": "Collections", "feed": "Feed",
        "illustration": "Illustrations", "doujin": "Doujin", "works": "Works", "novel-bookmark": "Novel Bookmarks",
        "novel-user": "Novels", "following": "Following",
    ]
}

/// The two names a site is filed under: its own and, for sites of a shared engine, the engine's.
public struct SiteInfoKey: Sendable {
    public var category: String
    public var baseCategory: String

    public init(category: String, baseCategory: String = "") {
        self.category = category
        self.baseCategory = baseCategory
    }
}

/// gallery-dl's errors in plain words, with what to do next (SPEC R-1111b).
public enum GalleryError {
    /// `ownKey`: the site accepts the person's own API key, which usually gets past refusals and limits.
    public static func describe(_ message: String, site: String, ownKey: Bool = false) -> String {
        let text = message.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        // Status codes as whole numbers, so "/post/14031" in an address does not read as a 403.
        func code(_ codes: Int...) -> Bool {
            codes.contains { text.range(of: "(?<![0-9])\($0)(?![0-9])", options: .regularExpression) != nil }
        }
        if has("cloudflare", "challenge", "captcha", "anti-bot", "ddos-guard") {
            return "\(site) asked for a browser check. Open the page in the browser, let it load, then download again."
        }
        if has("refresh-token", "oauth:") {
            return "\(site) needs its own app sign-in for this, which MediaPull does not set up yet. Public pages may still work."
        }
        if has("api-key", "api key", "'token'", "no 'token'") {
            return "\(site) needs an API key or token for this page."
        }
        if has("username and password", "username & password", "logged-in", "login", "log in", "authenticat", "cookie required",
               "cookies set", "cookie set", "authenticated cookies", "phpsessid", "authrequired", "authorizationerror") {
            return "\(site) needs you signed in for this. Sign in to \(site) in the browser, then download again."
        }
        if code(429) || has("too many requests", "rate limit") {
            return ownKey ? "\(site) is limiting the shared key. Add your own \(site) API key below, or wait a while and try again."
                : "\(site) is limiting requests. Wait a while, then download again."
        }
        if code(403, 401) || has("forbidden", "unauthorized", "blocked by network security") {
            return ownKey ? "\(site) refused the request. Adding your own \(site) API key below usually fixes this."
                : "\(site) refused the request. Open the page in the browser (signed in if needed), then download again."
        }
        if code(404) || has("notfounderror", "could not be found", "not found") {
            return "Nothing was found at this address. It may be private, deleted or moved."
        }
        if code(502, 503, 504) || has("timed out", "connection", "max retries", "name resolution", "ssl", "5xx") {
            return "\(site) could not be reached. Try again later."
        }
        if has("unexpected error", "keyerror", "jsondecodeerror", "attributeerror", "typeerror") {
            return "\(site) may have changed. Check for engine updates in Settings."
        }
        return message
    }
}

/// Sites that accept the person's own API key (SPEC R-1111b): gallery-dl's option names, labels, and where to get one.
/// Keys are optional; they lift the limits of the shared keys gallery-dl ships with, or unlock the account's own settings.
public struct SiteKeys: Sendable, Equatable {
    public struct Field: Sendable, Equatable, Hashable {
        public var option: String
        public var label: String
    }

    public var fields: [Field]
    public var getKeyURL: URL?

    public static let optionNames: Set<String> = ["api-key", "api-secret", "client-id", "client-secret", "user-id", "access-token",
                                                  "api-token"]

    public static func forSite(_ category: String, baseCategory: String = "") -> SiteKeys? {
        table[category] ?? table[baseCategory.lowercased()]
    }

    private static func keys(_ page: String, _ fields: (String, String)...) -> SiteKeys {
        SiteKeys(fields: fields.map { Field(option: $0.0, label: $0.1) }, getKeyURL: URL(string: page))
    }

    static let table: [String: SiteKeys] = [
        "tumblr": keys("https://www.tumblr.com/oauth/apps", ("api-key", "OAuth consumer key"), ("api-secret", "Secret key")),
        "deviantart": keys("https://www.deviantart.com/developers/apps", ("client-id", "Client ID"), ("client-secret", "Client secret")),
        "flickr": keys("https://www.flickr.com/services/apps/create/", ("api-key", "API key"), ("api-secret", "Secret")),
        "reddit": keys("https://www.reddit.com/prefs/apps", ("client-id", "Client ID (installed app)")),
        "smugmug": keys("https://api.smugmug.com/api/developer/apply", ("api-key", "API key"), ("api-secret", "API secret")),
        "wallhaven": keys("https://wallhaven.cc/settings/account", ("api-key", "API key")),
        "weasyl": keys("https://www.weasyl.com/control/apikeys", ("api-key", "API key")),
        "gelbooru": keys("https://gelbooru.com/index.php?page=account&s=options", ("api-key", "API key"), ("user-id", "User ID")),
        "rule34": keys("https://rule34.xxx/index.php?page=account&s=options", ("api-key", "API key"), ("user-id", "User ID")),
        "civitai": keys("https://civitai.com/user/account", ("api-key", "API key")),
        "pixeldrain": keys("https://pixeldrain.com/user/api_keys", ("api-key", "API key")),
        "imgur": keys("https://api.imgur.com/oauth2/addclient", ("client-id", "Client ID")),
        "twibooru": keys("https://twibooru.org/users/edit", ("api-key", "API key")),
        "philomena": keys("https://derpibooru.org/registrations/edit", ("api-key", "API key")),
        "imagechest": keys("https://imgchest.com/profile/api", ("access-token", "Access token")),
        "gofile": keys("https://gofile.io/myProfile", ("api-token", "API token")),
    ]
}
