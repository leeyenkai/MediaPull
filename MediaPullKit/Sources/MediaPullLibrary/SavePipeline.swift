import Foundation
import MediaPullCore
import MediaPullEngines
import MediaPullMedia
import MediaPullNet

public enum SaveOutcome: Sendable, Equatable {
    case saved(URL)
    case duplicate(URL)
    case skipped(String)
    case failed(String)

    public var url: URL? {
        switch self {
        case let .saved(url), let .duplicate(url): url
        default: nil
        }
    }

    public var isSuccess: Bool { url != nil }
}

public enum SaveEvent: Sendable {
    case started(itemID: String)
    case progress(itemID: String, fraction: Double?)
    case finished(itemID: String, outcome: SaveOutcome, note: String?)
}

/// Downloads that only an engine can do: DASH video, HLS or DASH streams, refreshed Instagram URLs.
public protocol EngineFetching: Sendable {
    /// Downloads `variant` (or, when nil, a fresh copy of the item) and returns the local file.
    func fetch(_ item: MediaItem, variant: MediaVariant?, workDirectory: URL, progress: @escaping @Sendable (Double?) -> Void)
        async throws -> URL
}

public struct SaveContext: Sendable {
    public var cookies: CookieJar
    public var userAgent: String?
    /// Bytes read inside the page for `blob:` images, by item id.
    public var inlineData: [String: Data]
    /// File names chosen by the user, by item id (without extension).
    public var nameOverrides: [String: String]

    public init(cookies: CookieJar = CookieJar(), userAgent: String? = nil, inlineData: [String: Data] = [:],
                nameOverrides: [String: String] = [:])
    {
        self.cookies = cookies
        self.userAgent = userAgent
        self.inlineData = inlineData
        self.nameOverrides = nameOverrides
    }
}

public enum SaveFailure: LocalizedError {
    case allVariantsFailed(String)
    case protected
    case needsEngine

    public var errorDescription: String? {
        switch self {
        case let .allVariantsFailed(reason): reason
        case .protected: "This media is protected (DRM or encryption) and cannot be saved."
        case .needsEngine: "This item needs the download engine, which is not available."
        }
    }
}

/// The save pipeline (SPEC section 14): resolve, download, validate, convert, hash, deduplicate,
/// name, move into place, set dates, write the sidecar.
public final class SavePipeline: Sendable {
    public let gate: NetworkGate
    public let converter: MediaConverter
    public let index: FingerprintIndex
    public let workDirectory: URL
    public let engine: (any EngineFetching)?

    public init(gate: NetworkGate, converter: MediaConverter, index: FingerprintIndex, workDirectory: URL, engine: (any EngineFetching)?) {
        self.gate = gate
        self.converter = converter
        self.index = index
        self.workDirectory = workDirectory
        self.engine = engine
    }

    public static var defaultWorkDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MediaPull/Partial", isDirectory: true)
    }

    /// Saves items with at most `concurrency` at a time. Returns outcomes by item id.
    @concurrent
    public func save(
        _ items: [MediaItem],
        target: SaveTarget,
        settings: SaveSettings,
        context: SaveContext,
        concurrency: Int = 4,
        events: @escaping @Sendable (SaveEvent) -> Void
    ) async -> [String: SaveOutcome] {
        var outcomes: [String: SaveOutcome] = [:]
        let saveDate = Date()
        await withTaskGroup(of: (String, SaveOutcome).self) { group in
            var next = 0
            func addNext() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    let outcome = await self.saveOne(item, index: item.discoveryIndex + 1, target: target, settings: settings,
                                                     context: context, saveDate: saveDate, events: events)
                    return (item.id, outcome)
                }
            }
            for _ in 0 ..< max(1, concurrency) {
                addNext()
            }
            for await (id, outcome) in group {
                outcomes[id] = outcome
                if Task.isCancelled { group.cancelAll(); break }
                addNext()
            }
        }
        await index.persist()
        return outcomes
    }

    @concurrent
    func saveOne(_ item: MediaItem, index: Int, target: SaveTarget, settings: SaveSettings, context: SaveContext, saveDate: Date,
                 events: @escaping @Sendable (SaveEvent) -> Void) async -> SaveOutcome
    {
        events(.started(itemID: item.id))
        let job = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: job) }
        func finish(_ outcome: SaveOutcome, _ note: String? = nil) -> SaveOutcome {
            events(.finished(itemID: item.id, outcome: outcome, note: note))
            return outcome
        }
        if item.flags.contains(.protected) { return finish(.failed(SaveFailure.protected.localizedDescription)) }
        let attempts = Self.attemptOrder(item, engineAvailable: engine != nil)
        guard !attempts.isEmpty else {
            return finish(.failed(item.variants.contains(where: \.requiresEngine) ? SaveFailure.needsEngine.localizedDescription
                : "No downloadable version was found."))
        }
        let knownBest = item.variants.filter { !$0.isDerived && $0.origin != .engineThumbnail }.compactMap(\.pixelSize)
            .max { $0.pixels < $1.pixels }
        var lastError: Error = SaveFailure.allVariantsFailed("No downloadable version was found.")
        var undecodable: (file: URL, source: URL?, modified: Date?)?
        let workDirectory = job.appendingPathComponent("convert", isDirectory: true)
        for variant in attempts {
            if Task.isCancelled { return finish(.failed("Cancelled.")) }
            do {
                let (file, source, modified) = try await acquire(variant, item: item, context: context, job: job) { fraction in
                    events(.progress(itemID: item.id, fraction: fraction))
                }
                if variant.isDerived, let knownBest, let analysis = ImageConversion.analyze(file),
                   analysis.width * analysis.height < knownBest.pixels
                {
                    continue
                }
                let conversion: ConversionResult
                do {
                    conversion = try await converter.convert(file, policy: settings.conversion, layout: target.layout,
                                                             workDirectory: workDirectory)
                } catch let issue as ConversionIssue {
                    if case .cannotDecode = issue, undecodable == nil { undecodable = (file, source, modified) }
                    lastError = issue
                    continue
                }
                let (outcome, note) = await finalize(conversion, item: item, sourceURL: source, lastModified: modified, target: target,
                                                     settings: settings, index: index, saveDate: saveDate,
                                                     nameOverride: context.nameOverrides[item.id])
                return finish(outcome, note)
            } catch {
                if error as? GateError == .cancelled || error is CancellationError { return finish(.failed("Cancelled.")) }
                lastError = error
            }
        }
        // Nothing converted cleanly: keep a video in its original codec rather than lose it.
        if let undecodable {
            var policy = settings.conversion
            policy.video = .keepOriginal
            if let conversion = try? await converter.convert(undecodable.file, policy: policy, layout: target.layout,
                                                             workDirectory: workDirectory)
            {
                var (outcome, note) = await finalize(conversion, item: item, sourceURL: undecodable.source,
                                                     lastModified: undecodable.modified, target: target, settings: settings, index: index,
                                                     saveDate: saveDate, nameOverride: context.nameOverrides[item.id])
                note = "Kept the original codec because this Mac cannot convert it" + (note.map { ". \($0)" } ?? "")
                return finish(outcome, note)
            }
        }
        if let issue = lastError as? ConversionIssue, issue.isSkip { return finish(.skipped(issue.localizedDescription)) }
        return finish(.failed(lastError.localizedDescription))
    }

    /// The formats the Archive layout's metadata files describe (SPEC R-1502).
    static let archiveFormats: Set<MediaFormat> = [.jpeg, .png, .gif, .mp4, .mov]

    /// Saves a file an engine already downloaded (Instagram pulls, SPEC R-1106).
    @concurrent
    public func saveStaged(_ file: URL, item: MediaItem, target: SaveTarget, settings: SaveSettings, index: Int,
                           nameOverride: String? = nil) async -> (SaveOutcome, String?)
    {
        let job = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: job) }
        let workDirectory = job.appendingPathComponent("convert", isDirectory: true)
        var conversion: ConversionResult
        do {
            conversion = try await converter.convert(file, policy: settings.conversion, layout: target.layout, workDirectory: workDirectory)
        } catch let issue as ConversionIssue {
            if case .cannotDecode = issue {
                var policy = settings.conversion
                policy.video = .keepOriginal
                guard let kept = try? await converter.convert(file, policy: policy, layout: target.layout, workDirectory: workDirectory)
                else {
                    return (.failed(issue.localizedDescription), nil)
                }
                conversion = kept
            } else {
                return (issue.isSkip ? .skipped(issue.localizedDescription) : .failed(issue.localizedDescription), nil)
            }
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        let result = await finalize(conversion, item: item, sourceURL: item.best?.url, lastModified: nil, target: target,
                                    settings: settings, index: index, saveDate: Date(), nameOverride: nameOverride)
        // Batched: rewriting the whole index after every file of a long pull wrote gigabytes (audit 3, A3-m8).
        await self.index.saveSoon()
        return result
    }

    // MARK: Acquire

    /// Downloads one version of an item, through the engine when only it can fetch it.
    func acquire(_ variant: MediaVariant, item: MediaItem, context: SaveContext, job: URL,
                 progress: @escaping @Sendable (Double?) -> Void) async throws -> (URL, URL?, Date?)
    {
        if variant.requiresEngine || variant.format?.kind == .stream {
            guard let engine else { throw SaveFailure.needsEngine }
            let file = try await engine.fetch(item, variant: variant, workDirectory: job, progress: progress)
            return (file, variant.url, nil)
        }
        let destination = job.appendingPathComponent("download-\(UUID().uuidString.prefix(8))")
        var modified: Date?
        if variant.url.scheme == "data" {
            guard let data = Self.decodeDataURI(variant.url.absoluteString) else { throw ConversionIssue.unknownFormat }
            try data.write(to: destination)
        } else if variant.url.isFileURL {
            try FileManager.default.copyItem(at: variant.url, to: destination)
        } else if variant.url.scheme == "blob" {
            guard let data = context.inlineData[item.id] else {
                throw SaveFailure.allVariantsFailed("This media only exists inside the page. Reload the page and try again.")
            }
            try data.write(to: destination)
        } else {
            do {
                let response = try await gate.download(request(for: variant, item: item, context: context),
                                                       to: destination) { received, total in
                    progress(total.map { Double(received) / Double(max($0, 1)) })
                }
                modified = (response.value(forHTTPHeaderField: "Last-Modified")).flatMap(Self.parseHTTPDate)
            } catch let GateError.http(status) where item.source.engine != nil && (status == 403 || status == 410) {
                // Signed engine URLs expire; let the engine fetch a fresh one.
                guard let engine else { throw GateError.http(status) }
                let file = try await engine.fetch(item, variant: nil, workDirectory: job, progress: progress)
                return (file, variant.url, nil)
            }
        }
        let sniff = Sniffer.sniff(MediaConverter.head(of: destination))
        if sniff.isMarkup { throw ConversionIssue.notMedia }
        guard let format = sniff.format else { throw ConversionIssue.unknownFormat }
        if format.kind == .stream {
            // A playlist served without a telling extension: hand it to the stream downloader.
            guard let engine else { throw SaveFailure.needsEngine }
            var stream = variant
            stream.format = format
            let file = try await engine.fetch(item, variant: stream, workDirectory: job, progress: progress)
            return (file, variant.url, nil)
        }
        return (destination, variant.url, modified)
    }

    /// Versions of an item to try, best first.
    public static func attemptOrder(_ item: MediaItem, engineAvailable: Bool = true) -> [MediaVariant] {
        var remaining = item.variants.filter { variant in
            guard !variant.hasFailed, variant.origin != .engineThumbnail else { return false }
            if !engineAvailable, variant.requiresEngine || variant.format?.kind == .stream { return false }
            return true
        }
        var order: [MediaVariant] = []
        while !remaining.isEmpty, order.count < 6 {
            guard let id = VariantRanker.best(remaining), let index = remaining.firstIndex(where: { $0.id == id }) else { break }
            order.append(remaining.remove(at: index))
        }
        if order.isEmpty, let thumb = item.variants.first(where: { $0.origin == .engineThumbnail }) { order.append(thumb) }
        return order
    }

    func request(for variant: MediaVariant, item: MediaItem, context: SaveContext) -> GatedRequest {
        var headers = RequestContext(
            accept: item.kind == .image || item.kind == .animatedImage ? RequestContext.imageAccept : RequestContext.anyAccept,
            userAgent: context.userAgent
        )
        switch item.source {
        case let .web(web):
            headers.referer = URLNormalizer.referer(for: variant.url, from: web.frameURL ?? web.pageURL)
            if URLNormalizer.mayCarryCookies(variant.url, page: web.pageURL, frame: web.frameURL) {
                headers.cookieHeader = context.cookies.header(for: variant.url)
            }
        case let .engine(engine):
            for (name, value) in engine.headers {
                if name.lowercased() == "user-agent" { headers.userAgent = value } else { headers.extraHeaders[name] = value }
            }
            if !engine.isInstagram, let source = engine.sourceURL {
                headers.referer = URLNormalizer.referer(for: variant.url, from: source)
            }
        }
        return .get(variant.url, purpose: .save, context: headers)
    }

    static func decodeDataURI(_ text: String) -> Data? {
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[..<comma]
        let payload = String(text[text.index(after: comma)...])
        if header.contains(";base64") { return Data(base64Encoded: payload, options: .ignoreUnknownCharacters) }
        return payload.removingPercentEncoding?.data(using: .utf8)
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: Finalize

    func finalize(_ conversion: ConversionResult, item: MediaItem, sourceURL: URL?, lastModified: Date?, target: SaveTarget,
                  settings: SaveSettings, index: Int, saveDate: Date, nameOverride: String? = nil) async -> (SaveOutcome, String?)
    {
        let manager = FileManager.default
        // A video or audio format chosen by hand is kept (without a metadata file); everything else follows the layout.
        let chosenByHand = settings.conversion.keepDownloadedMedia && [.video, .audio].contains(conversion.format.kind)
        guard target.layout.allows(conversion.format) || chosenByHand else {
            return (.skipped("\(conversion.format.label) files are not kept in the Archive layout."), nil)
        }
        let sha: String
        let size: Int64
        do {
            sha = try FileHasher.sha256(of: conversion.url)
            size = Int64((try manager.attributesOfItem(atPath: conversion.url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        guard size > 0 else { return (.failed("The downloaded file was empty."), nil) }

        // Only folders below the chosen save folder are created. A save folder that is gone (renamed or moved in the
        // Finder, a disk that is not connected) is never made again somewhere the person would not look (R-1702).
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: target.folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return (.failed("The folder “\(target.folder.lastPathComponent)” is missing. Choose it again in the Library."), nil)
        }
        if target.accountFolderExisted, let account = target.accountFolder,
           !manager.fileExists(atPath: account.path, isDirectory: &isFolder) || !isFolder.boolValue || FileFlags.isInTrash(account)
        {
            return (.failed("The folder “\(account.lastPathComponent)” was moved, renamed or moved to the Trash while saving."), nil)
        }
        let folder = ArchivePlanner.folder(for: item, target: target, settings: settings)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return (.failed("The folder could not be created: \(error.localizedDescription)"), nil)
        }
        var pixelSize = conversion.pixelSize
        var duration = conversion.duration
        if pixelSize == nil || duration == nil, conversion.format.kind == .video {
            let info = await LocalVideoInfo.load(conversion.url)
            pixelSize = pixelSize ?? info.size
            duration = duration ?? info.duration
        }
        var info = FinalFileInfo(format: conversion.format, sha256: sha, pixelSize: pixelSize, duration: duration, sourceURL: sourceURL,
                                 lastModified: lastModified, originalName: nil, note: conversion.note)
        if case .engine = item.source {} else {
            info.originalName = sourceURL.flatMap { URLNormalizer.baseName(of: $0) }
        }

        // Metadata files belong to the archive's formats only (R-1502); a WebM or audio file chosen by hand goes without one.
        let writesSidecar = target.layout == .archive && Self.archiveFormats.contains(info.format)
        // An existing account folder is searched whole in either layout (D-78): its files may sit in any subfolder.
        let (scope, scopeIsAccount) = Self.duplicateScope(of: folder, target: target)
        func existingCopy() async -> (SaveOutcome, String?)? {
            guard let existing = await self.index.duplicate(sha256: sha, size: size, in: scope, recursive: scopeIsAccount)
            else { return nil }
            if writesSidecar {
                let sidecarURL = Sidecar.sidecarURL(for: existing)
                if !manager.fileExists(atPath: sidecarURL.path) {
                    let sidecar = ArchivePlanner.sidecar(for: item, info: info, target: target, settings: settings)
                    // lint:allow silent-write filling in a missing metadata file for a copy that exists is best effort
                    try? sidecar.encoded().write(to: sidecarURL, options: .atomic)
                }
            }
            return (.duplicate(existing), "Already saved as \(existing.lastPathComponent)")
        }
        if let found = await existingCopy() { return found }
        while !(await self.index.reserve(sha256: sha, in: scope)) {
            // Identical content is being placed by another save right now; it becomes this one's original.
            try? await Task.sleep(for: .milliseconds(100))
            if let found = await existingCopy() { return found }
        }
        // Another save may have placed the same content and given back its reservation between the first check and this
        // one's reservation: look once more while holding it.
        if let found = await existingCopy() {
            await self.index.unreserve(sha256: sha, in: scope)
            return found
        }
        let outcome = await placeNew()
        await self.index.unreserve(sha256: sha, in: scope)
        return outcome

        func placeNew() async -> (SaveOutcome, String?) {
            let name = ArchivePlanner.fileName(for: item, info: info, layout: target.layout, settings: settings, index: index,
                                               saveDate: saveDate, override: nameOverride)
            let placed: URL
            do {
                guard let result = try place(conversion.url, in: folder, name: name, conflict: settings.conflict) else {
                    return (.skipped("A different file named \(name) already exists."), nil)
                }
                placed = result
            } catch {
                return (.failed("The file could not be written: \(error.localizedDescription)"), nil)
            }
            let date: Date? = switch item.source {
            case let .engine(engine): engine.date
            case .web: lastModified
            }
            if settings.setFileDates, let date {
                try? manager.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: placed.path)
            }
            if settings.setWhereFroms {
                var froms: [String] = []
                if let sourceURL, sourceURL.scheme == "https" || sourceURL.scheme == "http" { froms.append(sourceURL.absoluteString) }
                if let page = item.source.pageURL { froms.append(page.absoluteString) }
                Self.setWhereFroms(froms, on: placed)
            }
            if target.layout == .archive, !writesSidecar {
                await self.index.record(placed, sha256: sha)
                return (.saved(placed), "Saved without a metadata file: \(info.format.label) is outside the archive's formats.")
            }
            if writesSidecar {
                let sidecar = ArchivePlanner.sidecar(for: item, info: info, target: target, settings: settings)
                do {
                    try sidecar.encoded().write(to: Sidecar.sidecarURL(for: placed), options: .atomic)
                } catch {
                    return (.saved(placed), "Saved, but the metadata file could not be written.")
                }
            }
            await self.index.record(placed, sha256: sha)
            return (.saved(placed), conversion.note)
        }
    }

    /// Where a save into `folder` looks for a copy it already has: an account or site folder is searched whole, in
    /// either layout (D-78), any other folder by itself. The app asks the same before downloading (audit 5, B5-m2).
    public static func duplicateScope(of folder: URL, target: SaveTarget) -> (folder: URL, recursive: Bool) {
        if target.searchesWholeFolder {
            // Save As: the chosen folder (or the entry's folder inside it) and everything below it.
            return (target.autoSubfolders ? accountFolder(folder, target: target) : target.folder, true)
        }
        let scopeIsAccount = (target.layout == .archive && target.autoSubfolders) || target.accountFolder != nil
        return scopeIsAccount ? (accountFolder(folder, target: target), true) : (folder, false)
    }

    /// Whether a file saved earlier at `saved` is a copy a save of `item` would find (and so need not download again).
    public static func wouldFind(_ saved: URL, item: MediaItem, target: SaveTarget, settings: SaveSettings) -> Bool {
        let (scope, recursive) = duplicateScope(of: ArchivePlanner.folder(for: item, target: target, settings: settings), target: target)
        let top = scope.standardizedFileURL.path, parent = saved.deletingLastPathComponent().standardizedFileURL.path
        let key = { (path: String) in path.precomposedStringWithCanonicalMapping.lowercased() }
        return recursive ? key(parent + "/").hasPrefix(key(top + "/")) : key(parent) == key(top)
    }

    static func accountFolder(_ folder: URL, target: SaveTarget) -> URL {
        if let accountFolder = target.accountFolder {
            let base = accountFolder.standardizedFileURL.path, path = folder.standardizedFileURL.path
            if path == base || path.hasPrefix(base + "/") { return accountFolder }
        }
        // The first folder below the chosen root: the account or site folder.
        let rootComponents = target.folder.standardizedFileURL.pathComponents
        let components = folder.standardizedFileURL.pathComponents
        guard components.count > rootComponents.count else { return folder }
        return target.folder.appendingPathComponent(components[rootComponents.count], isDirectory: true)
    }

    /// "name 2.ext", shortening a name already at the length limit so the number always fits.
    static func numbered(stem: String, ext: String, attempt: Int) -> String {
        let suffix = " \(attempt)"
        var base = stem
        while !base.isEmpty {
            let name = FileNaming.fileName(stem: base + suffix, ext: ext)
            if (name as NSString).deletingPathExtension.hasSuffix(suffix) { return name }
            base.removeLast()
        }
        return FileNaming.fileName(stem: suffix.trimmingCharacters(in: .whitespaces), ext: ext)
    }

    /// Moves `file` into `folder` under `name` without ever overwriting. Returns nil when the
    /// conflict policy says to skip.
    func place(_ file: URL, in folder: URL, name: String, conflict: ConflictPolicy) throws -> URL? {
        let manager = FileManager.default
        let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? manager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(name)
        try manager.moveItem(at: file, to: staged)
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        // A name another shot in the folder holds is taken too (D-120, audit 2026-11-21-11, A11-4).
        let shots = FolderOperations.shotStems(in: folder, leaving: [], isFile: MediaUnits.takesPartInUnits(name))
        for attempt in 1 ... 500 {
            let candidateName = attempt == 1 ? name : Self.numbered(stem: stem, ext: ext, attempt: attempt)
            let candidate = folder.appendingPathComponent(candidateName)
            // A metadata file left behind by a deleted file is never overwritten either (R-1402).
            if manager.fileExists(atPath: candidate.path) || manager.fileExists(atPath: Sidecar.sidecarURL(for: candidate).path)
                || shots.contains((candidateName as NSString).deletingPathExtension.lowercased())
            {
                if conflict == .skip { return nil }
                continue
            }
            // Saves run in parallel, and moveItem replaces a file another save placed after the check above;
            // an exclusive rename fails instead, so two items with the same name both keep their files.
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            if code == EEXIST {
                if conflict == .skip { return nil }
                continue
            }
            // Another disk, or one without exclusive renames (exFAT, FAT): a move, which fails on a name taken since
            // (audit 2026-11-21-12, A12-m2).
            guard code == EXDEV || code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            do {
                try manager.moveItem(at: staged, to: candidate)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func setWhereFroms(_ urls: [String], on file: URL) {
        guard !urls.isEmpty,
              let data = try? PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        else { return }
        _ = data.withUnsafeBytes { buffer in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", buffer.baseAddress, data.count, 0, 0)
        }
    }
}
