import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import Observation
import WebKit

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
    var ruleList: WKContentRuleList?
    /// The walkthrough (SPEC 7.2): on first run with the setup steps, or the tour alone from Settings or Help.
    var walkthrough: WalkthroughMode?
    let browsing = BrowsingStore(persistent: !SelfTestRunner.isActive)
    /// Duplicate detection for the Library pane (SPEC section 33); hashes are cached between launches.
    let duplicates: DuplicateFinder
    /// On-device analysis for search, sorting, Organise and people (SPEC sections 36 to 39).
    let analysis = AnalysisService()
    /// Undo history for Organise (D-63).
    let journal = OperationJournal(folder: SelfTestRunner.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-selftest-journal-\(UUID().uuidString)")
        : OperationJournal.defaultFolder)
    var libraryRevision = 0
    @ObservationIgnored private var windowRefs: [UUID: WeakWindow] = [:]
    @ObservationIgnored lazy var engines = EngineService(app: self)
    /// Every site the bundled gallery-dl supports, with names, sign-in and media switches (SPEC R-1111b).
    @ObservationIgnored lazy var sites = SiteCatalogue.load(from: Bundle.main.url(forResource: "SiteCatalogue", withExtension: "json"))

    struct WeakWindow {
        weak var model: WindowModel?
    }

    private init() {
        let paths = EnginePaths.locate()
        enginePaths = paths
        engineManager = paths.map { EngineManager(paths: $0) }
        ffmpeg = paths.map { FFmpeg(paths: $0) }
        let support = EnginePaths.defaultSupport
        index = FingerprintIndex(storeURL: support.appendingPathComponent("fingerprints.json"))
        duplicates = DuplicateFinder(storeURL: SelfTestRunner.isActive ? nil : support.appendingPathComponent("duplicates.json"))
        prober = MediaProber(gate: .shared)
        thumbnails = ThumbnailLoader(gate: .shared)
        jobs.notify = { [weak preferences] in preferences?.notifyWhenDone ?? false }
        if !preferences.onboardingDone, !SelfTestRunner.isActive { walkthrough = .firstRun }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        CookieFile.cleanUpAll()
        try? FileManager.default.removeItem(at: SavePipeline.defaultWorkDirectory)
        try? FileManager.default.removeItem(at: WindowModel.pdfCache)
        try? FileManager.default.removeItem(at: WindowModel.editsCache)
        try? FileManager.default.removeItem(at: WindowModel.previewCache)
        if let staging = enginePaths?.staging { try? FileManager.default.removeItem(at: staging) }
        enginePaths?.prepareFolders()
        ruleList = await WebViewSetup.uploadBlockingRules()
        for window in windows {
            for tab in window.tabs { tab.install(ruleList: ruleList) }
        }
        do {
            let store = try AppStore.make(inMemory: SelfTestRunner.isActive)
            self.store = store
            jobs.store = store
            await reloadRoots()
            if roots.isEmpty, preferences.onboardingDone, !SelfTestRunner.isActive {
                await addDefaultRoot()
            }
        } catch {
            engineMessage = "The library database could not be opened: \(error.localizedDescription)"
        }
        analysis.start(inMemory: SelfTestRunner.isActive)
        Task { await journal.prune(olderThan: preferences.undoHistoryDays) }
        await refreshEngineVersions()
        if preferences.weeklyEngineCheck, Date().timeIntervalSince(preferences.lastEngineCheck ?? .distantPast) > 7 * 86400 {
            await checkForEngineUpdates(automatic: true)
        }
        await engines.refreshSignIn()
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
        libraryRevision += 1
        analysis.updateWatch()
        analysis.schedule()
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
            return "This folder is in iCloud Drive. If Optimise Mac Storage is on, files can become cloud-only placeholders that other apps cannot read."
        }
        if values?.volumeIsLocal == false { return "This folder is on a network volume. Saving may be slower." }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path.hasPrefix(home + "/Desktop") || url.path.hasPrefix(home + "/Documents") {
            if FileManager.default.ubiquityIdentityToken != nil, FileManager.default.fileExists(atPath: home + "/Library/Mobile Documents/com~apple~CloudDocs/Desktop") {
                return "Desktop and Documents sync with iCloud on this Mac. Files may become cloud-only placeholders."
            }
        }
        return nil
    }

    // MARK: Cookies

    var cookieStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    func cookieJar() async -> CookieJar {
        CookieJar(cookies: await CookieBridge.allCookies(cookieStore))
    }

    func cookies(forDomain domain: String) async -> [CookieRecord] {
        await CookieBridge.cookies(cookieStore, registrableDomain: domain)
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
            let store = cookieStore
            fetcher = BridgeEngineFetcher(
                client: BridgeClient(paths: engineManager.paths), video: preferences.video, userAgent: userAgent,
                cookies: { domain in await CookieBridge.cookies(store, registrableDomain: domain) }, onCheckpoint: onCheckpoint
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
        window?.markQueued(items.map(\.id))
        job.retry = { [weak self, weak window, weak job] in
            guard let self, let job else { return }
            let failedIDs = Set(job.failures.map(\.id))
            let retryItems = items.filter { failedIDs.contains($0.id) }
            self.save(retryItems, from: window, to: folder, title: "Retrying \(retryItems.count) item\(retryItems.count == 1 ? "" : "s")")
        }
        let settings = saveSettings
        let pipeline = pipeline { [weak self] kind, url in
            Task { @MainActor in self?.engines.handleCheckpoint(kind: kind, url: url, message: "") }
        }
        let store = store
        job.task = Task { [weak self, weak window] in
            guard let self else { return }
            job.state = .running
            var inline: [String: Data] = [:]
            for item in items where item.best?.url.scheme == "blob" {
                if let window, let data = await window.tab(showing: item.source.pageURL).readBlob(item.best!.url) { inline[item.id] = data }
            }
            let context = SaveContext(cookies: await self.cookieJar(), userAgent: self.userAgent, inlineData: inline,
                                      nameOverrides: window?.customNames ?? [:])
            let outcomes = await pipeline.save(items, target: target, settings: settings, context: context,
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
                            job.skipped += 1
                            job.failures.append((id, reason))
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
            // Items a cancelled job never reached are no longer waiting.
            window?.clearQueued(items.map(\.id).filter { outcomes[$0] == nil })
            for item in items {
                guard let outcome = outcomes[item.id], let url = outcome.url, let engine = item.source.engine else { continue }
                await store?.recordArchive(key: engine.key, account: engine.username ?? engine.category, path: url.path, sha256: "")
            }
            self.libraryRevision += 1
            let failedCount = outcomes.values.filter { if case .failed = $0 { return true } else { return false } }.count
            if Task.isCancelled {
                self.jobs.finish(job, .cancelled)
            } else if failedCount == items.count, failedCount > 0 {
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
            let files = Self.expand(urls)
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
                    let stem = file.deletingPathExtension().lastPathComponent
                    var output = folder.appendingPathComponent(FileNaming.fileName(stem: stem, ext: result.format.fileExtension))
                    var counter = 2
                    while FileManager.default.fileExists(atPath: output.path) {
                        output = folder.appendingPathComponent(FileNaming.fileName(stem: "\(stem) \(counter)", ext: result.format.fileExtension))
                        counter += 1
                    }
                    try FileManager.default.moveItem(at: result.url, to: output)
                    job.saved += 1
                    onResult(file, "Saved \(output.lastPathComponent)")
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

    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
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
