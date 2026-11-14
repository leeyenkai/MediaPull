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

    public init(folder: URL, layout: SaveLayout, autoSubfolders: Bool, accountUsername: String? = nil) {
        self.folder = folder
        self.layout = layout
        self.autoSubfolders = autoSubfolders
        self.accountUsername = accountUsername
    }
}

public struct SaveSettings: Sendable {
    public var conversion = ConversionPolicy()
    public var conflict: ConflictPolicy = .number
    public var setFileDates = true
    public var setWhereFroms = true
    public var reelsSubfolder = false
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
            let owner = target.accountUsername ?? (context.isInstagram ? context.username : nil)
                ?? context.sourceURL?.host ?? context.category
            var folder = target.folder.appendingPathComponent(FileNaming.safeTopFolder(owner), isDirectory: true)
            if context.isInstagram {
                switch context.instagramSection {
                case "stories":
                    folder.appendPathComponent("stories", isDirectory: true)
                case "highlights":
                    folder.appendPathComponent("highlights", isDirectory: true)
                    folder.appendPathComponent(FileNaming.sanitize(context.highlightTitle ?? context.postID ?? "highlight", maxBytes: 80),
                                               isDirectory: true)
                case "reels" where settings.reelsSubfolder:
                    folder.appendPathComponent("reels", isDirectory: true)
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
            if stem.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression) == nil || FileNaming.isForbiddenArchiveName(stem) {
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
            sidecar.sourceURL = info.sourceURL.flatMap { $0.isFileURL ? nil : $0.absoluteString }
            sidecar.width = info.pixelSize?.width
            sidecar.height = info.pixelSize?.height
            sidecar.duration = info.duration
            sidecar.sha256 = info.sha256
            sidecar.mediapullVersion = settings.appVersion
            return sidecar
        case let .engine(engine):
            let userCentric = ["user", "profile", "account", "artist", "blog", "channel", "creator", "posts", "favorite"]
                .contains { engine.subcategory.lowercased().contains($0) }
            let site = engine.sourceURL?.host?.lowercased() ?? engine.category
            let account = target.accountUsername ?? (engine.isInstagram || userCentric ? engine.username : nil) ?? site
            let subcategory = engine.isInstagram ? engine.instagramSection : engine.subcategory
            let postID = engine.postID ?? engine.mediaID ?? ShortHash.of(info.sourceURL?.absoluteString ?? engine.key)
            var sidecar = Sidecar(category: engine.category, subcategory: subcategory, username: account, postID: postID)
            sidecar.author = engine.fullName ?? (engine.username != account ? engine.username : nil)
            sidecar.postShortcode = engine.postShortcode
            if let count = engine.count, let num = engine.num { sidecar.num = num; sidecar.count = count }
            if engine.isInstagram, sidecar.num == nil { sidecar.num = 1; sidecar.count = 1 }
            sidecar.date = engine.date
            sidecar.description = engine.description ?? engine.title
            sidecar.postURL = engine.postURL?.absoluteString
            sidecar.sourceURL = engine.isInstagram ? nil : info.sourceURL?.absoluteString
            sidecar.width = info.pixelSize?.width
            sidecar.height = info.pixelSize?.height
            sidecar.originalWidth = engine.originalWidth
            sidecar.originalHeight = engine.originalHeight
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
