import Foundation
import MediaPullCore

/// Where a save goes and what it is called.
public struct SaveTarget: Sendable {
    /// The folder the user chose, or a library root when `autoSubfolders` is on.
    public var folder: URL
    public var layout: SaveLayout
    /// Create `<username>/` or `<host>/` (and story or highlight folders) below `folder`.
    public var autoSubfolders: Bool
    /// The Instagram account a pull was started for, which owns the folder (D-11).
    public var accountUsername: String?
    /// Folders below `folder` for a pull that is not about one account, such as a hashtag (`Hashtags/<tag>`).
    public var collectionPath: [String]?
    /// An existing folder of the account (D-78): its files go there whatever it is called, and duplicates are looked for
    /// in all of it.
    public var accountFolder: URL?
    /// Whether that folder sorts by type (`posts/`, `reels/`), worked out from what it already holds; nil follows Settings.
    public var typeSubfolders: Bool?

    public init(folder: URL, layout: SaveLayout, autoSubfolders: Bool, accountUsername: String? = nil, collectionPath: [String]? = nil) {
        self.folder = folder
        self.layout = layout
        self.autoSubfolders = autoSubfolders
        self.accountUsername = accountUsername
        self.collectionPath = collectionPath
    }

    /// Folders that are not accounts. Instagram usernames cannot contain spaces, so these never clash with one (D-52).
    public static let savedFolder = "Saved posts"
    public static let tagsFolder = "Hashtags"
    public static let accountDetailsFolder = "Account details"
}

public struct SaveSettings: Sendable {
    public var conversion = ConversionPolicy()
    public var conflict: ConflictPolicy = .number
    public var setFileDates = true
    public var setWhereFroms = true
    /// Instagram media sorted into posts, reels and profile pictures folders (stories and highlights always are).
    public var typeSubfolders = true
    public var archiveEngineTemplate = NameTemplate.archiveEngine
    public var archiveWebTemplate = NameTemplate.archiveWeb
    public var plainTemplate = NameTemplate.plain
    public var appVersion = "1.0"
    public var extractorVersion: String?

    public init() {}
}

/// What is known about the final file when it is named and described.
public struct FinalFileInfo: Sendable {
    public var format: MediaFormat
    public var sha256: String
    public var pixelSize: PixelSize?
    public var duration: Double?
    public var sourceURL: URL?
    public var lastModified: Date?
    public var originalName: String?
    public var note: String?

    public init(format: MediaFormat, sha256: String, pixelSize: PixelSize?, duration: Double?, sourceURL: URL?, lastModified: Date?,
                originalName: String?, note: String?)
    {
        self.format = format
        self.sha256 = sha256
        self.pixelSize = pixelSize
        self.duration = duration
        self.sourceURL = sourceURL
        self.lastModified = lastModified
        self.originalName = originalName
        self.note = note
    }
}

public enum ArchivePlanner {
    /// The folder a file goes in.
    public static func folder(for item: MediaItem, target: SaveTarget, settings: SaveSettings) -> URL {
        guard target.autoSubfolders else { return target.folder }
        switch item.source {
        case let .web(context):
            let host = context.pageURL.isFileURL ? "PDF" : (context.pageURL.host ?? item.host)
            return target.folder.appendingPathComponent(FileNaming.safeTopFolder(host.isEmpty ? "web" : host), isDirectory: true)
        case let .engine(context):
            if let path = target.collectionPath, !path.isEmpty {
                return path.enumerated().reduce(target.folder) { folder, part in
                    folder.appendingPathComponent(part.offset == 0 ? FileNaming.safeTopFolder(part.element)
                        : FileNaming.sanitize(part.element, maxBytes: 80), isDirectory: true)
                }
            }
            if context.isInstagram, ["saved", "collection"].contains(context.subcategory) {
                return target.folder.appendingPathComponent(SaveTarget.savedFolder, isDirectory: true)
            }
            // Stories from followed accounts belong to each account, not to the account the pull started from.
            // Unless the pull has already found that account's own folder for it (audit 2, A2-m3).
            let ownFolder = target.accountUsername != nil && target.accountUsername == context.username?.lowercased()
            let pinnedOwner = context.subcategory == "stories-tray" && !ownFolder ? nil : target.accountUsername
            let owner = pinnedOwner ?? (context.isInstagram ? context.username : nil)
                ?? context.sourceURL?.host ?? context.category
            let intoAccountFolder = context.isInstagram && pinnedOwner != nil ? target.accountFolder : nil
            var folder = intoAccountFolder ?? target.folder.appendingPathComponent(FileNaming.safeTopFolder(owner), isDirectory: true)
            let byType = target.typeSubfolders ?? settings.typeSubfolders
            // Another account's post that tags or was reposted by this one; in its own poster's folder it is just a post.
            if context.isInstagram, ["tagged", "reposts"].contains(context.subcategory),
               target.accountUsername == nil || target.accountUsername != context.username?.lowercased()
            {
                return folder.appendingPathComponent(context.subcategory, isDirectory: true)
            }
            if context.isInstagram {
                switch context.instagramSection {
                case "stories":
                    folder.appendPathComponent("stories", isDirectory: true)
                case "highlights":
                    folder.appendPathComponent("highlights", isDirectory: true)
                    folder.appendPathComponent(FileNaming.sanitize(context.highlightTitle ?? context.postID ?? "highlight", maxBytes: 80),
                                               isDirectory: true)
                case "reels" where byType:
                    folder.appendPathComponent("reels", isDirectory: true)
                case "avatar" where byType:
                    folder.appendPathComponent("profile pictures", isDirectory: true)
                case "posts" where byType:
                    folder.appendPathComponent("posts", isDirectory: true)
                default:
                    break
                }
            }
            return folder
        }
    }

    /// The file name for `item` with the final format's extension.
    public static func fileName(for item: MediaItem, info: FinalFileInfo, layout: SaveLayout, settings: SaveSettings, index: Int,
                                saveDate: Date, override: String? = nil) -> String
    {
        var context = NameContext(date: saveDate, index: index)
        context.hash = info.sha256
        context.width = info.pixelSize?.width
        context.height = info.pixelSize?.height
        context.originalName = info.originalName ?? item.best.flatMap { URLNormalizer.baseName(of: $0.url) }
        let template: NameTemplate
        switch item.source {
        case let .web(web):
            context.host = web.pageURL.host
            context.title = web.pageTitle
            if let modified = info.lastModified, layout == .archive { context.date = modified }
            template = layout == .archive ? settings.archiveWebTemplate : settings.plainTemplate
        case let .engine(engine):
            context.date = engine.date ?? saveDate
            if let fileName = engine.fileName { context.originalName = (fileName as NSString).deletingPathExtension }
            context.code = engine.shortcode ?? engine.postShortcode ?? engine.mediaID
            context.postID = engine.postID
            context.mediaID = engine.mediaID
            context.num = engine.num
            context.count = engine.count
            context.username = engine.username
            context.title = engine.title
            context.host = engine.category
            if engine.isInstagram, engine.instagramSection == "avatar" {
                context.date = saveDate
                template = layout == .archive ? NameTemplate.archiveAvatar : NameTemplate("{username}_avatar_{yyyy}-{MM}-{dd}")
            } else if layout == .archive {
                let multi = (engine.count ?? 1) > 1
                template = engine.isInstagram ? settings.archiveEngineTemplate
                    : NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{orig_name}" + (multi ? "_{num:02}" : ""))
            } else {
                template = engine.isInstagram ? NameTemplate("{username}_{code}_{num:02}") : settings.plainTemplate
            }
        }
        var stem = template.render(context)
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            stem = (override as NSString).pathExtension.lowercased() == info.format.fileExtension
                ? (override as NSString).deletingPathExtension : override
            if layout == .archive, stem.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) == nil {
                stem = NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_").render(context) + stem
            }
        }
        if layout == .archive {
            // Checked on the name as it will be written: cleaning (":" to "_", zero-width spaces removed) can turn an
            // allowed name into the forbidden pattern (R-1504, R-1510).
            let written = FileNaming.sanitize(stem, maxBytes: 255)
            if written.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) == nil
                || FileNaming.isForbiddenArchiveName(written) {
                stem = NameTemplate("{yyyy}-{MM}-{dd}_{HH}{mm}{ss}_{hash8}").render(context) + "_" + stem
            }
        }
        if layout == .plain, stem.trimmingCharacters(in: .whitespaces).isEmpty {
            stem = NameTemplate("{host}_{index:04}").render(context)
        }
        return FileNaming.fileName(stem: stem, ext: info.format.fileExtension)
    }

    /// The sidecar for an Archive-layout file (SPEC 15.3).
    public static func sidecar(for item: MediaItem, info: FinalFileInfo, target: SaveTarget, settings: SaveSettings) -> Sidecar {
        switch item.source {
        case let .web(web):
            let host = web.pageURL.isFileURL ? "pdf" : (web.pageURL.host ?? item.host).lowercased()
            var sidecar = Sidecar(category: host, subcategory: web.isDocument ? "pdf" : "page", username: host,
                                  postID: ShortHash.of(web.pageURL.absoluteString))
            sidecar.date = info.lastModified
            sidecar.description = item.alt
            sidecar.pageURL = web.pageURL.isFileURL ? nil : web.pageURL.absoluteString
            // A web address only: never a file on this Mac, nor an inline data: image (its whole content as text).
            sidecar.sourceURL = info.sourceURL.flatMap {
                ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil
            }
            sidecar.width = info.pixelSize?.width
            sidecar.height = info.pixelSize?.height
            sidecar.duration = info.duration
            sidecar.sha256 = info.sha256
            sidecar.mediapullVersion = settings.appVersion
            return sidecar
        case let .engine(engine):
            // A video's account is its uploader (R-3503), as for the parts of a profile.
            let userCentric = ["user", "profile", "account", "artist", "blog", "channel", "creator", "posts", "favorite", "video"]
                .contains { engine.subcategory.lowercased().contains($0) }
            let site = engine.sourceURL?.host?.lowercased() ?? engine.category
            // Others' stories and saved posts name their own account, never the one the pull started from.
            let pinned = ["stories-tray", "saved", "collection"].contains(engine.subcategory) ? nil : target.accountUsername
            let account = pinned ?? (engine.isInstagram || userCentric ? engine.username : nil) ?? site
            let subcategory = engine.isInstagram ? engine.instagramSection : engine.subcategory
            // Only a web address is a source; a file an engine downloaded is in a working folder on this Mac, whose path
            // must never be written down (it names the person's home folder) and changes every run.
            let webSource = info.sourceURL.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let postID = engine.postID ?? engine.mediaID ?? ShortHash.of(webSource?.absoluteString ?? engine.key)
            var sidecar = Sidecar(category: engine.category, subcategory: subcategory, username: account, postID: postID)
            sidecar.author = engine.fullName ?? (engine.username != account ? engine.username : nil)
            sidecar.postShortcode = engine.postShortcode
            if engine.isInstagram { sidecar.mediaID = engine.mediaID }
            if let count = engine.count, let num = engine.num { sidecar.num = num; sidecar.count = count }
            if engine.isInstagram, sidecar.num == nil { sidecar.num = 1; sidecar.count = 1 }
            sidecar.date = engine.date
            sidecar.description = engine.description ?? engine.title
            sidecar.postURL = engine.postURL?.absoluteString
            sidecar.sourceURL = engine.isInstagram ? nil : webSource?.absoluteString
            sidecar.width = info.pixelSize?.width
            sidecar.height = info.pixelSize?.height
            sidecar.originalWidth = engine.originalWidth
            sidecar.originalHeight = engine.originalHeight
            sidecar.higherResolutionAvailable = engine.higherResolutionAvailable
            sidecar.duration = info.duration
            if let owner = engine.username, owner.lowercased() != account.lowercased() { sidecar.ownerUsername = owner }
            sidecar.highlightTitle = engine.highlightTitle
            if engine.isInstagram { sidecar.productType = subcategory == "reels" ? "clips" : nil }
            sidecar.sha256 = info.sha256
            sidecar.extractor = settings.extractorVersion
            sidecar.mediapullVersion = settings.appVersion
            return sidecar
        }
    }
}
