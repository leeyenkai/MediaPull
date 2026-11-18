import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import Observation

/// Shared state and services for every window.
@Observable
final class AppModel {
    static let shared = AppModel()

    let preferences = Preferences()
    let jobs = JobCenter()
    let gate = NetworkGate.shared
    let enginePaths: EnginePaths?
    let engineManager: EngineManager?
    let ffmpeg: FFmpeg?
    let index: FingerprintIndex
    let prober: MediaProber
    let thumbnails: ThumbnailLoader
    private(set) var store: AppStore?
    var roots: [LibraryRootInfo] = []
    var engineVersions: EngineVersions?
    var engineProblems: [String] = []
    var engineUpdates: [EngineUpdate] = []
    var engineMessage: String?
    var isCheckingEngines = false
    var userAgent: String?
    var ruleList: UploadRules?
    /// The rules finished compiling (or failed to); tabs wait for this before loading their first page.
    var ruleListSettled = false
    /// Library folders whose bookmark finds nothing (deleted, or on a disk that is not connected).
    var missingRoots: Set<UUID> = []
    /// Bumped after every journaled file change, undo and redo, in any window (History lists and panes refresh).
    var fileChangeRevision = 0 {
        didSet { libraryRevision += 1 }
    }
    /// The walkthrough (SPEC 7.2): on first run with the setup steps, or the tour alone from Settings or Help.
    var walkthrough: WalkthroughMode?
    let browsing = BrowsingStore(persistent: !SelfTestRunner.isActive)
    let notes = NotesStore(folder: SelfTestRunner.isActive ? nil : NotesStore.defaultFolder)
    /// Duplicate detection for the Library pane (SPEC section 33); hashes are cached between launches.
    let duplicates: DuplicateFinder
    /// On-device analysis for search, sorting, Organise and people (SPEC sections 36 to 39).
    let analysis = AnalysisService()
    /// Undo history for Organise (D-63).
    let journal = OperationJournal(folder: SelfTestRunner.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-selftest-journal-\(UUID().uuidString)")
        : OperationJournal.defaultFolder)
    /// What MediaPull remembers about each Instagram account folder (D-79).
    let accountFolders = AccountFolderStore(folder: SelfTestRunner.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-selftest-accounts-\(UUID().uuidString)")
        : AccountFolderStore.defaultFolder)
    /// What each Saved posts folder remembers of the posts saved into it, so one deleted from it is not fetched again (D-106).
    /// Kept apart from account folders: Saved posts is not an account to update.
    let savedPostsMemory = AccountFolderStore(folder: SelfTestRunner.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-selftest-saved-\(UUID().uuidString)")
        : AccountFolderStore.defaultFolder.deletingLastPathComponent().appendingPathComponent("SavedPosts", isDirectory: true))
    /// An address sent from another app while no window was open, for the next window that opens (R-1111c).
    @ObservationIgnored var pendingDownloadAddress: String?
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// The remembered account folders, for the Library's Update actions (D-80); refreshed after pulls and moves.
    var accountFolderList: [AccountFolderRecord] = []
    var libraryRevision = 0
    @ObservationIgnored private var windowRefs: [UUID: WeakWindow] = [:]
    @ObservationIgnored lazy var engines = EngineService(app: self)
    /// Every site the bundled gallery-dl supports, with names, sign-in and media switches (SPEC R-1111b).
    @ObservationIgnored lazy var sites = SiteCatalogue.load(from: Bundle.main.url(forResource: "SiteCatalogue", withExtension: "json"))

    struct WeakWindow {
        weak var model: WindowModel?
    }

    private init() {
        var paths = EnginePaths.locate()
        // --selftest-update runs the update path offline: a stand-in bridge replays recorded events, and the engine folders
        // live in a temporary folder so Application Support is left alone.
        if SelfTestRunner.isActive, CommandLine.arguments.contains("--selftest-update") {
            paths?.bridgeDirectory = SelfTestRunner.replayBridge
            paths?.support = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaPull-selftest-engines-\(UUID().uuidString)")
        }
        enginePaths = paths
        engineManager = paths.map { EngineManager(paths: $0) }
        ffmpeg = paths.map { FFmpeg(paths: $0) }
        let support = EnginePaths.defaultSupport
        // The self-test keeps its checksums to itself, as it does its duplicates (audit 7, C7-m1).
        index = FingerprintIndex(storeURL: SelfTestRunner.isActive ? nil : support.appendingPathComponent("fingerprints.json"))
        duplicates = DuplicateFinder(storeURL: SelfTestRunner.isActive ? nil : support.appendingPathComponent("duplicates.json"))
        prober = MediaProber(gate: .shared)
        thumbnails = ThumbnailLoader(gate: .shared)
        jobs.notify = { [weak preferences] in preferences?.notifyWhenDone ?? false }
        if !preferences.onboardingDone, !SelfTestRunner.isActive { walkthrough = .firstRun }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        // First, before anything else at launch: tabs hold their first page until the rules are in place (R-508).
        do {
            ruleList = try await WebViewSetup.uploadBlockingRules()
        } catch {
            // The file-input, drop and paste guards still apply; say plainly that this layer is missing.
            engineMessage = "Upload blocking for web pages could not be turned on: \(error.localizedDescription)"
        }
        ruleListSettled = true
        for window in windows {
            for tab in window.tabs { tab.install(ruleList: ruleList) }
        }
        // Leftovers of the last session: cleared off the main actor, since caches can hold many files.
        let leftovers = [SavePipeline.defaultWorkDirectory, WindowModel.pdfCache, WindowModel.editsCache, WindowModel.previewCache]
            + [enginePaths?.staging].compactMap(\.self)
        // A self-test shares these folders with the installed app, which may be saving: it leaves them alone (C6-m4).
        if !SelfTestRunner.isActive { await Task.detached(priority: .utility) {
            CookieFile.cleanUpAll()
            for folder in leftovers {
                try? FileManager.default.removeItem(at: folder) // lint:allow silent-write a cache that may not exist
            }
        }.value }
        enginePaths?.prepareFolders()
        do {
            let store = try AppStore.make(inMemory: SelfTestRunner.isActive)
            self.store = store
            jobs.store = store
            await reloadRoots()
            await refreshAccountFolders()
            // Lifecycle (SPEC 6.3): forget saved-item records whose file is gone, and accounts nothing refers to.
            let keep = Set(accountFolderList.map(\.account))
            let journal = journal
            Task.detached(priority: .background) {
                let restorable = await journal.restorablePaths()
                await store.prune(keepAccounts: keep, restorable: restorable)
            }
            if roots.isEmpty, preferences.onboardingDone, !SelfTestRunner.isActive {
                await addDefaultRoot()
            }
        } catch {
            engineMessage = "The library database could not be opened: \(error.localizedDescription)"
        }
        analysis.start(inMemory: SelfTestRunner.isActive)
        Task {
            // Stranded changes first: an old one is taken back before the prune forgets it (audit 18, A18-m3).
            await takeBackStranded()
            await journal.prune(olderThan: preferences.undoHistoryDays)
        }
        await refreshEngineVersions()
        // A self-test never asks the network for engine updates nor changes when the installed app last asked (audit 6, C6-m4).
        if !SelfTestRunner.isActive, preferences.weeklyEngineCheck,
           Date().timeIntervalSince(preferences.lastEngineCheck ?? .distantPast) > 7 * 86400
        {
            await checkForEngineUpdates(automatic: true)
        }
        await engines.refreshSignIn()
        // The weekly check also happens in an app left open for weeks (R-1306): looked at every few hours.
        if !SelfTestRunner.isActive {
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(6 * 3600))
                    guard let self else { return }
                    if self.preferences.weeklyEngineCheck,
                       Date().timeIntervalSince(self.preferences.lastEngineCheck ?? .distantPast) > 7 * 86400
                    {
                        await self.checkForEngineUpdates(automatic: true)
                    }
                }
            }
        }
    }

    // MARK: Windows

    func register(_ window: WindowModel) {
        windowRefs[window.id] = WeakWindow(model: window)
        windowRefs = windowRefs.filter { $0.value.model != nil }
        for tab in window.tabs { tab.install(ruleList: ruleList) }
    }

    var windows: [WindowModel] { windowRefs.values.compactMap(\.model) }

    func window(_ id: UUID) -> WindowModel? { windowRefs[id]?.model }

    /// The window that shows the walkthrough, so it appears once rather than in every window.
    @ObservationIgnored private var walkthroughWindowID: UUID?
    var walkthroughWindow: WindowModel? { walkthroughWindowID.flatMap(window) ?? windows.first }

    func showWalkthrough(_ mode: WalkthroughMode) {
        walkthroughWindowID = frontWindow?.id
        walkthrough = mode
    }

    /// The main window in front, also while a sheet, popover, Settings or the Activity window is key.
    var frontWindow: WindowModel? {
        let models = windows
        let candidates = [NSApp.keyWindow, NSApp.keyWindow?.sheetParent, NSApp.mainWindow].compactMap(\.self) + NSApp.orderedWindows
        for candidate in candidates {
            if let model = models.first(where: { $0.hostWindow === candidate }) { return model }
        }
        return models.first
    }

    // MARK: Library roots

    var defaultRoot: LibraryRootInfo? { roots.first(where: \.isDefault) ?? roots.first }

    static var suggestedRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/MediaPull", isDirectory: true)
    }

    func reloadRoots() async {
        guard let store else { return }
        roots = await store.roots()
        await followRootLocations()
        libraryRevision += 1
        analysis.updateWatch()
        analysis.schedule()
    }

    /// The name a library folder shows in the list (R-1702); the folder on disk is not renamed.
    func renameRoot(_ id: UUID, to name: String) async {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        await store?.updateRoot(id, name: clean)
        await reloadRoots()
    }

    /// Points a library folder that could not be found at the folder the person chooses.
    func locateRoot(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL,
              let old = roots.first(where: { $0.id == id })?.url else { return }
        Task {
            let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
            await store?.updateRoot(id, path: url.path, bookmark: bookmark)
            // Left out of analysis stays left out where it is now (audit 3, B3-m3).
            if preferences.analysisExcludedRoots.remove(old.path) != nil { preferences.analysisExcludedRoots.insert(url.path) }
            noteMoved([(from: old.path, to: url.path)])
            for window in windows {
                    window.library.rootMoved(from: old, to: url)
                    window.organise.foldersMoved([(from: old.path, to: url.path)])
                }
            await reloadRoots()
        }
    }

    /// Library folders renamed or moved in the Finder are followed through their bookmarks (R-1702): the stored path,
    /// the records keyed by path and every window's selection move with them. A folder that cannot be found is listed
    /// as missing. Runs at launch and whenever MediaPull comes forward.
    @discardableResult
    func followRootLocations() async -> Bool {
        guard let store else { return false }
        let current = roots
        let resolved = await Task.detached(priority: .userInitiated) {
            current.map { root -> (UUID, URL?, Bool) in
                // A library folder moved to the Trash is not followed there: saves would land in the Trash. It shows as Not
                // Found until it is put back or located.
                guard let (url, stale) = root.resolvedURL(), FileManager.default.fileExists(atPath: url.path),
                      !FileFlags.isInTrash(url)
                else { return (root.id, nil, false) }
                return (root.id, url.standardizedFileURL, stale)
            }
        }.value
        var changed = false
        var missing = Set<UUID>()
        for (id, url, stale) in resolved {
            guard let index = roots.firstIndex(where: { $0.id == id }) else { continue }
            guard let url else { missing.insert(id); continue }
            let old = roots[index].url
            guard url.path != old.standardizedFileURL.path || stale else { continue }
            let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? roots[index].bookmark
            await store.updateRoot(id, path: url.path, bookmark: bookmark)
            roots[index].path = url.path
            roots[index].bookmark = bookmark
            if url.path != old.standardizedFileURL.path {
                // Left out of analysis stays left out under its new name.
                if preferences.analysisExcludedRoots.remove(old.path) != nil { preferences.analysisExcludedRoots.insert(url.path) }
                noteMoved([(from: old.path, to: url.path)])
                for window in windows {
                    window.library.rootMoved(from: old, to: url)
                    window.organise.foldersMoved([(from: old.path, to: url.path)])
                }
                changed = true
            }
        }
        if missing != missingRoots { missingRoots = missing; changed = true }
        return changed
    }

    func addDefaultRoot() async {
        let url = Self.suggestedRootURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await addRoot(url, makeDefault: true)
    }

    func addRoot(_ url: URL, layout: SaveLayout? = nil, makeDefault: Bool = false) async {
        guard let store else { return }
        _ = try? await store.addRoot(url: url, layout: layout ?? preferences.defaultLayout, makeDefault: makeDefault)
        await reloadRoots()
    }

    func removeRoot(_ id: UUID) async {
        await store?.removeRoot(id)
        await reloadRoots()
    }

    func root(containing url: URL) -> LibraryRootInfo? {
        let path = url.standardizedFileURL.path
        return roots.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// Whether a library root is in iCloud or on a volume that is not local (SPEC R-1506).
    static func locationWarning(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        if values?.isUbiquitousItem == true || url.path.contains("/Library/Mobile Documents/") {
            return """
                This folder is in iCloud Drive. If Optimise Mac Storage is on, files can become cloud-only placeholders that other apps \
                cannot read.
                """
        }
        if values?.volumeIsLocal == false { return "This folder is on a network volume. Saving may be slower." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home + "/Desktop") || url.path.hasPrefix(home + "/Documents") {
            if FileManager.default.ubiquityIdentityToken != nil,
               FileManager.default.fileExists(atPath: home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop")
            {
                return "Desktop and Documents sync with iCloud on this Mac. Files may become cloud-only placeholders."
            }
        }
        return nil
    }

    // MARK: Cookies

    func cookieJar() async -> CookieJar {
        CookieJar(cookies: await CookieBridge.allCookies())
    }

    func cookies(forDomain domain: String) async -> [CookieRecord] {
        await CookieBridge.cookies(registrableDomain: domain)
    }

    // MARK: Engines

    var enginesAvailable: Bool { engineManager != nil }

    func refreshEngineVersions() async {
        guard let engineManager else {
            engineProblems = ["The download engines are not included in this build."]
            return
        }
        do {
            engineVersions = try await engineManager.versions()
            engineProblems = []
        } catch {
            engineProblems = [error.localizedDescription]
        }
    }

    func checkForEngineUpdates(automatic: Bool) async {
        guard let engineManager else { return }
        isCheckingEngines = true
        defer { isCheckingEngines = false }
        do {
            engineUpdates = try await engineManager.checkForUpdates()
            preferences.lastEngineCheck = Date()
            if !automatic {
                engineMessage = engineUpdates.isEmpty ? "The engines are up to date." : nil
            }
        } catch {
            if !automatic { engineMessage = "Could not check for updates: \(error.localizedDescription)" }
        }
    }

    func installEngineUpdates() async {
        guard let engineManager else { return }
        // A running engine would load half-replaced files (R-1306).
        let engineKinds: Set<JobKind> = [.save, .pull, .scan, .stream, .engineUpdate]
        guard !jobs.jobs.contains(where: { engineKinds.contains($0.kind) && $0.state.isActive }) else {
            engineMessage = "Updates install once the current downloads finish."
            return
        }
        let job = Job(kind: .engineUpdate, title: "Updating download engines")
        job.state = .running
        jobs.add(job)
        var messages: [String] = []
        for update in engineUpdates where update.blockedReason == nil {
            job.currentItem = "\(update.name) \(update.available)"
            do {
                try await engineManager.install(update)
                messages.append("\(update.name) updated to \(update.available).")
            } catch {
                messages.append(error.localizedDescription)
            }
        }
        engineUpdates = []
        await refreshEngineVersions()
        engineMessage = messages.joined(separator: " ")
        job.notes = messages
        jobs.finish(job, .completed)
    }

    // MARK: Saving

    func pipeline(onCheckpoint: @escaping @Sendable (String, URL?) -> Void = { _, _ in }) -> SavePipeline {
        var fetcher: (any EngineFetching)?
        if let engineManager {
            fetcher = BridgeEngineFetcher(
                client: BridgeClient(paths: engineManager.paths), video: preferences.video, userAgent: userAgent,
                cookies: { domain in await CookieBridge.cookies(registrableDomain: domain) },
                cookiesUpdated: { updated, original in await CookieBridge.update(updated, existing: original) },
                onCheckpoint: onCheckpoint,
                instagramTurn: { [weak self] in await self?.engines.instagramTurn() },
                pacing: preferences.pacing.delay,
                siteSettings: { [weak self] category in await self?.siteSettings(for: category) ?? ([:], [:]) }
            )
        }
        return SavePipeline(gate: gate, converter: MediaConverter(ffmpeg: ffmpeg, svgRasterizer: SVGRasterizer.rasterize), index: index,
                            workDirectory: SavePipeline.defaultWorkDirectory, engine: fetcher)
    }

    var saveSettings: SaveSettings {
        preferences.saveSettings(extractorVersion: engineVersions?.galleryDL.map { "gallery-dl \($0)" })
    }

    /// The save target for a folder: inside a library root it uses the root's layout, and saving to
    /// the root itself creates site or account folders.
    func target(for folder: URL, accountUsername: String? = nil) -> SaveTarget {
        let root = root(containing: folder)
        let layout = root?.layout ?? preferences.defaultLayout
        let isRoot = root.map { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path } ?? false
        return SaveTarget(folder: folder, layout: layout, autoSubfolders: isRoot, accountUsername: accountUsername)
    }

    /// Recently used save folders that are not library folders and still exist.
    var recentSaveFolders: [URL] {
        preferences.recentSaveFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { url in !roots.contains { $0.path == url.path } && FileManager.default.fileExists(atPath: url.path) }
    }

    func destination(for folder: URL) -> SaveDestination {
        SaveDestination(url: folder, layout: root(containing: folder)?.layout ?? preferences.defaultLayout)
    }

    /// The folder the front window saves into (D-70).
    var saveFolder: URL? { frontWindow?.saveFolder ?? defaultRoot?.url }

    /// Files and folders moved or renamed in the Library or an editor: analysis results and the download archive follow
    /// them, as they do for Organise (R-3804), so an incremental pull still knows what it already saved.
    func noteMoved(_ moves: [(from: String, to: String)]) {
        guard !moves.isEmpty else { return }
        Task {
            await analysis.noteMoves(moves)
            await store?.moveArchivePaths(moves)
            await accountFolders.moveFolders(moves)
            LibraryModel.followQueuedDestinations(moves)
            await refreshAccountFolders(followJobs: false)
        }
    }

    /// The key an item is remembered under once saved: the engine's own key, or a hash of a web item's id (its address).
    nonisolated static func libraryKey(for item: MediaItem) -> String {
        if let engine = item.source.engine { return engine.key }
        return "web:" + FileHasher.sha256(of: Data(item.id.utf8))
    }

    /// A site's saved API key and its remembered switches, as a site download sends them (R-1111b).
    func siteSettings(for category: String) -> (keys: [String: String], switches: [String: Bool]) {
        let keys = engines.siteKeys(for: category).map { SiteKeychain.keys(for: category, fields: $0.fields) } ?? [:]
        return (keys, preferences.gallerySwitches[category] ?? [:])
    }

    /// `followJobs`: folders the records followed after a Finder rename move queued jobs' destinations too. A caller that
    /// already moved them for its own moves passes false, so a swap of two names is not applied twice (audit 8, B8-m6).
    func refreshAccountFolders(followJobs: Bool = true) async {
        let before = Dictionary(accountFolderList.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        accountFolderList = await accountFolders.all()
        // Folders followed after a Finder rename: queued and running jobs show where they are now (audit 7, A7-m9).
        let moved = accountFolderList.compactMap { record -> (from: String, to: String)? in
            guard let old = before[record.id], AccountFolderStore.key(old) != AccountFolderStore.key(record.path) else { return nil }
            return (old, record.path)
        }
        if followJobs, !moved.isEmpty { LibraryModel.followQueuedDestinations(moved) }
        // Each Library pane shows the account of its folder as it is now: renamed in the Finder, or made by a first pull
        // (audit 4, C4-m9).
        for window in windows { window.library.findAccount() }
    }

    /// The remembered account folder `folder` is, or is inside.
    func accountFolder(containing folder: URL) -> AccountFolderRecord? {
        let path = AccountFolderStore.key(folder.path)
        return accountFolderList.filter {
            let own = AccountFolderStore.key($0.path)
            return path == own || path.hasPrefix(own + "/")
        }.max { $0.path.count < $1.path.count }
    }

    /// The remembered account folders inside `folder` (not the folder itself).
    func accountFolders(inside folder: URL) -> [AccountFolderRecord] {
        let path = AccountFolderStore.key(folder.path)
        return accountFolderList.filter { AccountFolderStore.key($0.path).hasPrefix(path + "/") }
    }

    /// Starts a save job for items from a window (SPEC section 14).
    @discardableResult
    func save(_ items: [MediaItem], from window: WindowModel?, to folder: URL, title: String? = nil) -> Job? {
        guard !items.isEmpty else { return nil }
        let target = target(for: folder)
        let job = Job(kind: .save, title: title ?? "Saving \(items.count) item\(items.count == 1 ? "" : "s")")
        job.subtitle = folder.lastPathComponent
        job.total = items.count
        job.destination = folder
        jobs.add(job)
        if !SelfTestRunner.isActive {
            preferences.recentSaveFolders = Array(([folder.path] + preferences.recentSaveFolders.filter { $0 != folder.path }).prefix(10))
        }
        // Items this window already saved where this save would find them are not downloaded again only to find they are
        // copies (audit 4, S4-m2). Where that is depends on where each item goes (its account's folder, a site folder), so
        // it is decided per item with the pipeline's own rule once the job knows (audit 5, B5-m2, A5-m5).
        var savedEarlier: [String: URL] = [:]
        // An edited or trimmed copy keeps its item's id but is a new file on this Mac: always saved (audit 6, A6-M3).
        for item in items where !(item.best?.url.isFileURL ?? false) {
            switch window?.states[item.id] {
            case let .saved(url)?, let .duplicate(url)?: savedEarlier[item.id] = url
            default: break
            }
        }
        window?.markQueued(items.map(\.id).filter { savedEarlier[$0] == nil })
        let alreadySaved = savedEarlier
        // Retry saves where the folder is then, and takes the failures over from this job (audit 7, A7-m3, A7-m5).
        let followed = FollowedFolder(folder)
        job.retry = { [weak self, weak window, weak job] in
            guard let self, let job else { return }
            let failedIDs = Set(job.failures.map(\.id))
            let retryItems = items.filter { failedIDs.contains($0.id) }
            Task { [weak self, weak window] in
                guard let self else { return }
                defer { job.retryStarting = false }
                guard let now = await followed.now() else {
                    // The failures stay, so Retry Failed is still offered once the folder is back (audit 8, A8-m7); the row
                    // says why (audit 10, C10-m4).
                    self.jobs.finish(job, .failed(FollowedFolder.goneMessage(folder)), notify: false)
                    return
                }
                job.failed = 0
                job.failures = []
                self.save(retryItems, from: window, to: now, title: "Retrying \(retryItems.count) item\(retryItems.count == 1 ? "" : "s")")
            }
        }
        let settings = saveSettings
        let pipeline = pipeline { [weak self] kind, url in
            Task { @MainActor in self?.engines.handleCheckpoint(kind: kind, url: url, message: "") }
        }
        let store = store
        job.task = Task { [weak self, weak window] in
            guard let self else { return }
            job.state = .running
            let present = await Task.detached(priority: .userInitiated) {
                alreadySaved.filter { FileManager.default.fileExists(atPath: $0.value.path) }
            }.value
            let toSave = items
            let inline = await window?.blobData(for: toSave) ?? [:]
            let context = SaveContext(cookies: await self.cookieJar(), userAgent: self.userAgent, inlineData: inline,
                                      nameOverrides: window?.customNames ?? [:])
            // Instagram items go into their account's folder when the save folder is, holds or is inside one (D-78), as a
            // pull would place them, and are remembered there (D-79).
            let rootURL = self.root(containing: folder)?.url
            // Saved posts go to Saved posts, not to their owner's folder, and are not that folder's to remember (audit 3, C3-M5).
            let instagram = toSave.filter { item in
                guard let engine = item.source.engine, engine.isInstagram, engine.username != nil else { return false }
                return !["saved", "collection"].contains(engine.subcategory)
            }
            let byAccount = Dictionary(grouping: instagram,
                                       by: { $0.source.engine?.username?.lowercased() ?? "" })
            var batches: [(items: [MediaItem], target: SaveTarget, folder: URL?, account: String?)] = []
            var placed = Set<String>()
            // Items of an account with no folder, saved while another account's folder is the save folder: a new folder
            // beside that one, never loose inside it (D-78, audit 12, A12-M2).
            var beside: [(items: [MediaItem], target: SaveTarget)] = []
            for (account, group) in byAccount {
                // Looked for beside the save folder when it is another account's folder (A12-M2).
                let around = await self.engines.accountsBase(folder, except: account)
                // A remembered folder counts too: a Plain one has no metadata to find it by (audit 4, C4-M2).
                let recorded = await self.engines.recordedFolder(of: account, around: around)
                let found = await Task.detached(priority: .userInitiated) { () -> (URL, Bool?)? in
                    guard let existing = recorded
                        ?? AccountFolders.resolveTarget(account: account, saveFolder: around, root: rootURL).existing
                    else { return nil }
                    return (existing, AccountFolders.sortsByType(existing))
                }.value
                guard let (existing, byType) = found else {
                    if AccountFolderStore.key(around.path) != AccountFolderStore.key(folder.path) {
                        var besideTarget = target
                        besideTarget.folder = around
                        besideTarget.autoSubfolders = true
                        if let layout = self.root(containing: around)?.layout { besideTarget.layout = layout }
                        beside.append((group, besideTarget))
                        placed.formUnion(group.map(\.id))
                    }
                    continue
                }
                // Items of whoever has the name now never go into the folder of the account that had it (D-88, audit 6,
                // A6-M2): the folder's account id against each item's owner.
                // A folder with no id yet (from before 1.8) learns it at its first update (D-92).
                let existingKey = AccountFolderStore.key(existing.path)
                let record = await self.accountFolders.all().first {
                    AccountFolderStore.key($0.path) == existingKey && $0.account == account
                }
                let folderID = await self.engines.folderAccountID(record, account: account)
                var group = group
                if let folderID {
                    let others = group.filter { ($0.source.engine?.ownerID).map { $0 != folderID } ?? false }
                    let reason = "@\(account) is now a different Instagram account, so this was not saved into "
                        + "“\(existing.lastPathComponent)”."
                    for item in others {
                        // Skipped, not failed: Retry would refuse it again (audit 7, A7-m4); shown on the item too (C7-m3).
                        job.skipped += 1
                        window?.apply(.finished(itemID: item.id, outcome: .skipped(reason), note: nil))
                    }
                    if !others.isEmpty {
                        job.notes.append(reason)
                        placed.formUnion(others.map(\.id))
                        group.removeAll { item in others.contains { $0.id == item.id } }
                    }
                }
                var accountTarget = target
                // The account folder's own library decides the layout (D-70, audit 10, A10-m3).
                if let layout = self.root(containing: existing)?.layout { accountTarget.layout = layout }
                accountTarget.folder = existing.deletingLastPathComponent()
                accountTarget.autoSubfolders = true
                accountTarget.accountUsername = account
                accountTarget.accountFolder = existing
                accountTarget.accountFolderExisted = true
                accountTarget.typeSubfolders = byType
                batches.append((group, accountTarget, existing, account))
                placed.formUnion(group.map(\.id))
            }
            // Saved posts go into Saved posts beside an account folder, never loose inside it (D-88, audit 5, A5-m2).
            let savedPosts = toSave.filter { item in
                guard let engine = item.source.engine, engine.isInstagram else { return false }
                return ["saved", "collection"].contains(engine.subcategory)
            }
            if !savedPosts.isEmpty {
                let around = await Task.detached(priority: .userInitiated) {
                    AccountFolders.detect(folder, stopAt: rootURL)?.folder
                }.value ?? self.accountFolder(containing: folder).map { URL(fileURLWithPath: $0.path, isDirectory: true) }
                if let around {
                    var beside = target
                    // Beside it, but never outside the library (audit 6, A6-m3).
                    let isLibrary = rootURL.map { AccountFolderStore.key($0.path) == AccountFolderStore.key(around.path) } ?? false
                    beside.folder = isLibrary ? around : around.deletingLastPathComponent()
                    beside.autoSubfolders = true
                    batches.append((savedPosts, beside, nil, nil))
                    placed.formUnion(savedPosts.map(\.id))
                }
            }
            for group in beside { batches.append((group.items, group.target, nil, nil)) }
            batches.append((toSave.filter { !placed.contains($0.id) }, target, nil, nil))
            // Instagram items with no folder of their account get one made by this save (in a library folder): it records
            // their owner's id, as a pull's new folder does, so later items of whoever has the name are checked against
            // it (audit 9, A9-M3).
            let placedNow = placed
            let candidates = toSave.filter { !placedNow.contains($0.id) }.map { ($0, target) }
                + beside.flatMap { group in group.items.map { ($0, group.target) } }
            let newAccountFolders: [String: (folder: URL, owner: String)] = await Task.detached(priority: .userInitiated) {
                var made: [String: (folder: URL, owner: String)] = [:]
                for (item, target) in candidates {
                    guard let engine = item.source.engine, engine.isInstagram, let name = engine.username?.lowercased(),
                          let owner = engine.ownerID, made[name] == nil,
                          !["saved", "collection"].contains(engine.subcategory) else { continue }
                    // The folder below the save folder this item goes into, in either layout (audit 10, A10-M1).
                    // Compared as path keys: "/private" is dropped only from paths that exist, and the planned folder does
                    // not yet (audit 11).
                    let planned = ArchivePlanner.folder(for: item, target: target, settings: settings)
                    let baseKey = AccountFolderStore.key(target.folder.path), plannedKey = AccountFolderStore.key(planned.path)
                    guard plannedKey.hasPrefix(baseKey + "/") else { continue }
                    let below = plannedKey.dropFirst(baseKey.count + 1).split(separator: "/")
                    let parts = planned.pathComponents
                    guard let first = below.first, first == FileNaming.safeTopFolder(name).lowercased(), parts.count >= below.count
                    else { continue }
                    let top = target.folder.appendingPathComponent(parts[parts.count - below.count], isDirectory: true)
                    guard !FileManager.default.fileExists(atPath: top.path) else { continue }
                    made[name] = (top, owner)
                }
                return made
            }.value
            var skipped = 0
            for index in batches.indices {
                let batchTarget = batches[index].target
                let found = Set(batches[index].items.filter { item in
                    present[item.id].map { SavePipeline.wouldFind($0, item: item, target: batchTarget, settings: settings) } ?? false
                }.map(\.id))
                skipped += found.count
                batches[index].items.removeAll { found.contains($0.id) }
            }
            if skipped > 0 {
                job.duplicates += skipped
                job.notes.append("\(skipped) item\(skipped == 1 ? " was" : "s were") already in this folder, so "
                    + "\(skipped == 1 ? "it was" : "they were") not downloaded again.")
            }
            let downloading = batches.flatMap(\.items).map(\.id).filter { alreadySaved[$0] != nil }
            if !downloading.isEmpty { window?.markQueued(downloading) }
            var outcomes: [String: SaveOutcome] = [:]
            for batch in batches where !batch.items.isEmpty {
                let done = await pipeline.save(batch.items, target: batch.target, settings: settings, context: context,
                                               concurrency: self.preferences.saveConcurrency) { event in
                Task { @MainActor in
                    window?.apply(event)
                    switch event {
                    case let .started(id):
                        job.currentItem = items.first { $0.id == id }?.best?.url.lastPathComponent
                    case let .finished(id, outcome, note):
                        switch outcome {
                        case .saved: job.saved += 1
                        case .duplicate: job.duplicates += 1
                        case let .skipped(reason):
                            // Skipped is not failed (D-101, audit 18, A18-m1).
                            job.skipped += 1
                            if job.notes.count < 30 { job.notes.append(reason) }
                        case let .failed(reason):
                            job.failed += 1
                            job.failures.append((id, reason))
                        }
                        if let note, job.notes.count < 50 { job.notes.append(note) }
                    case .progress:
                        break
                    }
                }
                }
                outcomes.merge(done) { first, _ in first }
                if let accountFolder = batch.folder, let account = batch.account {
                    let keys = Set(batch.items.filter { done[$0.id]?.url != nil }.compactMap { $0.source.engine?.key })
                    if !keys.isEmpty {
                        let record = await self.accountFolders.record(account: account, folder: accountFolder)
                        // What an earlier version remembered of the folder comes first (audit 4, C4-m1).
                        await self.engines.adoptEarlierMemory(of: record, account: account)
                        await self.accountFolders.addKeys(keys, to: record.id)
                    }
                }
            }
            for (account, made) in newAccountFolders where FileManager.default.fileExists(atPath: made.folder.path) {
                let record = await self.accountFolders.record(account: account, folder: made.folder)
                if record.userID == nil { await self.accountFolders.update(record.id, userID: made.owner) }
                // And what it holds, so an item deleted from it never comes back at its first Update (D-79, audit 12,
                // A12-M1).
                // Only what went into it: never saved-collection items of the same name, which went to Saved posts (audit 13,
                // C13-m6).
                let inside = AccountFolderStore.key(made.folder.path) + "/"
                let keys = Set(toSave.filter { item in
                    guard let saved = outcomes[item.id]?.url else { return false }
                    return AccountFolderStore.key(saved.path).hasPrefix(inside)
                }.compactMap { $0.source.engine?.key })
                if !keys.isEmpty { await self.accountFolders.addKeys(keys, to: record.id) }
            }
            // Items a cancelled job never reached are no longer waiting.
            window?.clearQueued(items.map(\.id).filter { outcomes[$0] == nil })
            // Every saved item is remembered, so the next time it is extracted it shows as already in the library (R-1015).
            let keys = await Task.detached {
                Dictionary(items.map { ($0.id, Self.libraryKey(for: $0)) }, uniquingKeysWith: { a, _ in a })
            }.value
            for item in items {
                guard let outcome = outcomes[item.id], let url = outcome.url, let key = keys[item.id] else { continue }
                let account = item.source.engine.map { $0.username ?? $0.category } ?? (item.source.pageURL?.host ?? "web")
                await store?.recordArchive(key: key, account: account, path: url.path, sha256: "")
            }
            self.libraryRevision += 1
            let failedCount = outcomes.values.filter { if case .failed = $0 { return true } else { return false } }.count
            if Task.isCancelled {
                self.jobs.finish(job, .cancelled)
            } else if failedCount == toSave.count, failedCount > 0 {
                self.jobs.finish(job, .failed(job.failures.first?.message ?? "Nothing could be saved."))
            } else {
                self.jobs.finish(job, .completed)
            }
        }
        return job
    }

    // MARK: Converter

    func convertFiles(_ urls: [URL], destination: URL?, policy: ConversionPolicy, onResult: @escaping (URL, String) -> Void) {
        let job = Job(kind: .convert, title: "Converting \(urls.count) file\(urls.count == 1 ? "" : "s")")
        job.total = urls.count
        jobs.add(job)
        let converter = MediaConverter(ffmpeg: ffmpeg, svgRasterizer: SVGRasterizer.rasterize)
        job.task = Task {
            job.state = .running
            // A dropped folder can hold thousands of files: walk it off the main actor.
            let files = await Task.detached(priority: .userInitiated) { Self.expand(urls) }.value
            job.total = files.count
            let work = SavePipeline.defaultWorkDirectory.appendingPathComponent("convert-\(job.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            for file in files {
                if Task.isCancelled { break }
                job.currentItem = file.lastPathComponent
                do {
                    let result = try await converter.convert(file, policy: policy, layout: .archive, workDirectory: work)
                    if !result.converted {
                        job.skipped += 1
                        onResult(file, "Already a normal format")
                        continue
                    }
                    let folder = destination ?? file.deletingLastPathComponent()
                    let name = FileNaming.fileName(stem: file.deletingPathExtension().lastPathComponent, ext: result.format.fileExtension)
                    // A free name (an orphaned metadata file's name is taken too), with a copy of the original's metadata
                    // file, off the main actor (D-107).
                    let placed = try await LibraryModel.placeConverted(result, from: file, as: folder.appendingPathComponent(name))
                    let output = placed.url
                    job.saved += 1
                    onResult(file, "Saved \(output.lastPathComponent)"
                        + (placed.metadataProblem.map { "; its metadata file could not be written: \($0)" } ?? ""))
                } catch {
                    job.failed += 1
                    job.failures.append((file.path, error.localizedDescription))
                    onResult(file, error.localizedDescription)
                }
            }
            self.libraryRevision += 1
            self.jobs.finish(job, Task.isCancelled ? .cancelled : .completed)
        }
    }

    nonisolated static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // lint:allow main-io nonisolated, called from a detached task
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = enumerator?.nextObject() as? URL {
                    if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(next) }
                }
            } else {
                files.append(url)
            }
        }
        return files.filter { MediaFormat.fromExtension($0.pathExtension) != nil && $0.pathExtension.lowercased() != "json" }
    }
}
