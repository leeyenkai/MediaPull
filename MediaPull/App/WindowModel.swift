import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import Observation
import UniformTypeIdentifiers

enum ItemState: Equatable {
    case queued
    case saving(Double?)
    case saved(URL)
    case duplicate(URL)
    case skipped(String)
    case failed(String)

    var savedURL: URL? {
        switch self {
        case let .saved(url), let .duplicate(url): url
        default: nil
        }
    }
}

/// Everything one window shows: its browser tabs, its page session and the Library pane state.
/// Extracted Media collects from every tab in the window; "This Page" narrows it to the selected tab.
@Observable
final class WindowModel: Identifiable, MediaGridOwner {
    let id = UUID()
    private(set) var tabs: [BrowserController] = []
    private(set) var selectedTabID: UUID
    @ObservationIgnored private var closedTabs: [URL] = []

    /// The selected tab.
    var browser: BrowserController {
        tabs.first { $0.id == selectedTabID } ?? tabs[0]
    }
    let library: LibraryModel
    /// The Organise section of this window (SPEC section 38).
    let organise: OrganiseModel
    /// Which section the window shows: Collect (browser, extracted media, preview, library) or Organise (D-62).
    var section: WindowSection = .collect {
        didSet { if section == .organise { organise.updateAnalysisFolders() } }
    }
    @ObservationIgnored let ingestor = ExtractionIngestor()
    @ObservationIgnored weak var hostWindow: NSWindow?
    var items: [MediaItem] = []
    @ObservationIgnored var itemsByID: [String: MediaItem] = [:]
    var visible: [MediaItem] = []
    var sections: [GridSection] = []
    var filter = MediaFilter() {
        didSet {
            guard filter != oldValue else { return }
            refilter()
            rememberFilter()
        }
    }

    /// New windows start with the filters last used; the search text and This Page belong to the page in front (R-1008).
    private func rememberFilter() {
        guard !SelfTestRunner.isActive else { return }
        var kept = filter
        kept.text = ""
        kept.currentPageOnly = false
        if AppModel.shared.preferences.extractedFilter != kept { AppModel.shared.preferences.extractedFilter = kept }
    }

    var selection: Set<String> = []
    var states: [String: ItemState] = [:]
    var gridRevision = 0
    /// Thumbnail size in the Extracted grid, set by the zoom slider, pinch, ⌘+ and ⌘- (SPEC R-1001a).
    var cellSize: CGFloat = AppModel.shared.preferences.thumbnailSize {
        didSet { if cellSize != oldValue { app.preferences.thumbnailSize = cellSize } }
    }

    static let zoomRange: ClosedRange<CGFloat> = 80 ... 360
    var showBrowser = true
    var showExtracted = true
    var showLibrary = true
    var showPreview = true
    /// Downloads appears when asked for (toolbar, ⌥⌘4, a video or account page's button) and stays until closed.
    var showDownloads = false
    var showOrganiseSource = true
    var showOrganiseWork = true
    var showOrganiseTarget = true
    /// What the Preview pane shows: the last item or file selected on its own.
    var previewSubject: PreviewSubject?
    var showFilters = false
    var extractionEnabled = true
    var siteExtractorCategory: String?
    var pageKind: AddressInput = .invalid
    var autoScrolling = false
    var addressMessage: String?
    var focusAddressToken = 0
    var showBrowsingPanel = false
    var browsingPanelTab: BrowsingPanelTab = .bookmarks
    /// Bumped by ⌘D so the address field's star opens its editor.
    var bookmarkRequest = 0
    /// The Downloads pane (SPEC section 11.11).
    let downloads = DownloadsModel()
    /// Bumped to focus the Downloads pane's address field.
    var downloadsFocus = 0

    /// Shows the Downloads pane set up for `address` (an @account, #hashtag or page address), or for the current page.
    func showDownloads(_ address: String? = nil, video: Bool = false) {
        section = .collect
        setShowing(.downloads, true)
        if let address {
            downloads.use(address)
        } else if let url = browser.url {
            downloads.followsBrowser = true
            downloads.use(url.absoluteString, fromBrowser: true)
        }
        if video, let url = browser.url, address == nil { downloads.target = .video(url) }
        downloadsFocus += 1
    }

    func scanWithSiteExtractor() {
        guard let url = browser.url, let category = siteExtractorCategory else { return }
        app.engines.startSiteScan(url: url, category: category, window: self)
    }
    var engineScan: Job?
    var documents: [URL] = []
    var extractedDocuments = Set<String>()
    var customNames: [String: String] = [:]
    var editorRequest: EditorRequest?
    /// The editor shown in the Preview pane, if any; set by the pane.
    /// The image or video editor open in the Preview pane, so selecting another item does not discard its changes.
    @ObservationIgnored weak var activeEditor: (any UnsavedEditing)?
    @ObservationIgnored private var probing = Set<String>()
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var supportTask: Task<Void, Never>?
    @ObservationIgnored private var scrollTask: Task<Void, Never>?
    @ObservationIgnored private var scrollToken: UUID?
    @ObservationIgnored private var lastBackgroundTab: (anchor: UUID, tab: UUID)?
    @ObservationIgnored private var supportCache: [String: String] = [:]
    @ObservationIgnored private var cookieJar = CookieJar()
    @ObservationIgnored private let vectorThumbnails = NSCache<NSString, Thumbnail>()

    var app: AppModel { .shared }

    init() {
        library = LibraryModel()
        organise = OrganiseModel()
        let first = BrowserController()
        tabs = [first]
        selectedTabID = first.id
        library.window = self
        organise.window = self
        if !SelfTestRunner.isActive { filter = AppModel.shared.preferences.extractedFilter }
        wire(first)
        let stream = ingestor.snapshots
        listenTask = Task { [weak self] in
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
        AppModel.shared.register(self)
    }

    deinit {
        listenTask?.cancel()
        supportTask?.cancel()
        scrollTask?.cancel()
    }

    // MARK: Tabs

    private func wire(_ tab: BrowserController) {
        tab.onMessage = { [weak self, weak tab] message in
            guard let self, let tab else { return }
            self.receive(message, from: tab)
        }
        tab.onCommit = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.didCommit(url, in: tab)
        }
        tab.onURLChange = { [weak self, weak tab] url in
            guard let self, let tab, tab.id == self.selectedTabID else { return }
            self.updatePageState(for: url)
            if self.filter.currentPageOnly { self.refilter() }
        }
        tab.onFinish = { [weak self, weak tab] url in
            guard let self, let tab else { return }
            self.didFinish(url, in: tab)
        }
        tab.onChooseDownloadDestination = { [weak self] name in
            guard let self else { return nil }
            return await FolderPicker.chooseSaveLocation(suggestedName: name, start: self.saveFolder, window: self.hostWindow)
        }
        tab.onDownloadFinished = { [weak self] file, error in
            guard let self else { return }
            if let error {
                self.addressMessage = "The download did not finish: \(error)"
            } else if let file {
                self.addressMessage = "Downloaded \(file.lastPathComponent) to \(file.deletingLastPathComponent().lastPathComponent)."
                self.app.libraryRevision += 1
            }
        }
        tab.onPDF = { [weak self] url in
            // The PDF is the tab's own page (a top-level navigation), so it gets its own cookies and no referer from another tab.
            guard let self, self.extractionEnabled else { return }
            self.extractPDF(remote: url, linkedFrom: nil)
        }
        tab.onOpenInNewTab = { [weak self] url, select in self?.newTab(url, select: select) }
        tab.onTitle = { [weak self] url, title in self?.app.browsing.updateTitle(url, title: title) }
        tab.install(ruleList: app.ruleList)
        if SelfTestRunner.isActive, tab.webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            // Self-tests capture a window that is not in front; keep every tab painting.
            tab.webView.perform(NSSelectorFromString("_setWindowOcclusionDetectionEnabled:"), with: false)
        }
    }

    @discardableResult
    func newTab(_ url: URL? = nil, select: Bool = true, after source: UUID? = nil) -> BrowserController {
        let tab = BrowserController()
        wire(tab)
        let anchor = source ?? selectedTabID
        // Tabs opened in the background from one tab line up after each other, in the order they were opened.
        var position = tabs.firstIndex { $0.id == anchor }.map { $0 + 1 } ?? tabs.count
        if !select, let last = lastBackgroundTab, last.anchor == anchor, let index = tabs.firstIndex(where: { $0.id == last.tab }) {
            position = index + 1
        }
        tabs.insert(tab, at: min(position, tabs.count))
        lastBackgroundTab = select ? nil : (anchor, tab.id)
        if let url { tab.load(url) }
        if select { selectTab(tab.id) }
        if url == nil, select { focusAddressToken += 1 }
        return tab
    }

    func selectTab(_ id: UUID) {
        guard id != selectedTabID, tabs.contains(where: { $0.id == id }) else { return }
        stopAutoScroll()
        lastBackgroundTab = nil
        selectedTabID = id
        addressMessage = nil
        if let url = browser.url {
            updatePageState(for: url)
        } else {
            supportTask?.cancel()
            pageKind = .invalid
            siteExtractorCategory = nil
        }
        if filter.currentPageOnly { refilter() }
    }

    /// Closes a tab; closing the last one closes the window.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs.count > 1 else {
            hostWindow?.performClose(nil)
            return
        }
        let tab = tabs[index]
        if let url = tab.url { closedTabs.append(url) }
        tab.webView.stopLoading()
        tab.webView.loadHTMLString("", baseURL: nil)
        tab.onMessage = nil
        tabs.remove(at: index)
        if id == selectedTabID { selectTab(tabs[min(index, tabs.count - 1)].id) }
    }

    func reopenClosedTab() {
        guard let url = closedTabs.popLast() else { return }
        newTab(url)
    }

    var canReopenClosedTab: Bool { !closedTabs.isEmpty }

    func selectAdjacentTab(_ offset: Int) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    // MARK: Browser events

    private func receive(_ message: ExtractionMessage, from tab: BrowserController) {
        guard extractionEnabled, let page = tab.url ?? message.frameURL else { return }
        let frame = FrameInfo(frameURL: message.frameURL, isMainFrame: message.isMainFrame, origin: message.origin, pageURL: page,
                              pageTitle: tab.title.nonEmpty)
        let ingestor = ingestor
        let json = message.json
        Task.detached(priority: .userInitiated) {
            await ingestor.ingest(json: json, frame: frame)
        }
    }

    private func didCommit(_ url: URL, in tab: BrowserController) {
        guard tab.id == selectedTabID else { return }
        if filter.currentPageOnly { refilter() }
        addressMessage = nil
        if app.preferences.clearOnNavigation { clear() }
        updatePageState(for: url)
    }

    /// The page kind and whether a site extractor supports the page, for the selected tab's address.
    private func updatePageState(for url: URL) {
        pageKind = AddressInput.classify(url)
        siteExtractorCategory = nil
        supportTask?.cancel()
        // Instagram has its own options (an account, a post, a hashtag), never a site extractor button.
        guard let host = url.host, url.scheme == "https" || url.scheme == "http", !host.hasSuffix("instagram.com") else { return }
        let key = url.absoluteString
        if let cached = supportCache[key] {
            siteExtractorCategory = cached.isEmpty ? nil : cached
            return
        }
        supportTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            let category = await self.app.engines.supportedCategory(for: url)
            guard !Task.isCancelled else { return }
            self.supportCache[key] = category ?? ""
            if self.browser.url?.absoluteString == key { self.siteExtractorCategory = category }
        }
    }

    private func didFinish(_ url: URL, in tab: BrowserController) {
        app.browsing.recordVisit(url, title: tab.title)
        Task {
            cookieJar = await app.cookieJar()
            if app.userAgent == nil { app.userAgent = await tab.userAgent() }
            await app.engines.refreshSignIn()
        }
    }

    // MARK: Address field

    func submitAddress(_ text: String) {
        let input = AddressInput.parse(text)
        switch input {
        case .invalid:
            addressMessage = "Not a web address. Enter a URL such as example.com or an Instagram handle such as @nasa."
        default:
            if let url = input.url { browser.load(url) }
        }
    }

    // MARK: Snapshots and filtering

    /// Items already looked up in the library, so each is looked up once (R-1015).
    @ObservationIgnored private var libraryChecked: Set<String> = []

    /// Marks items that were saved before (by this or an earlier session) as saved, with the file they were saved as.
    private func markItemsInLibrary(_ items: [MediaItem]) {
        let fresh = items.filter { states[$0.id] == nil && !libraryChecked.contains($0.id) }
        guard !fresh.isEmpty, let store = app.store else { return }
        libraryChecked.formUnion(fresh.map(\.id))
        Task { [weak self] in
            let keys = await Task.detached(priority: .utility) {
                Dictionary(fresh.map { (AppModel.libraryKey(for: $0), $0.id) }, uniquingKeysWith: { a, _ in a })
            }.value
            let found = await store.archivedPaths(for: Array(keys.keys))
            guard let self, !found.isEmpty else { return }
            for (key, path) in found {
                if let id = keys[key], self.states[id] == nil { self.states[id] = .duplicate(URL(fileURLWithPath: path)) }
            }
            self.gridRevision += 1
            if !self.filter.states.isEmpty { self.refilter() }
        }
    }

    private func apply(_ snapshot: IngestSnapshot) {
        items = snapshot.items
        markItemsInLibrary(snapshot.items)
        if documents != snapshot.documents { documents = snapshot.documents }
        itemsByID = Dictionary(snapshot.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        refilter()
        if app.preferences.autoProbe, filterNeedsProbing { probeAllUnknown() }
    }

    private var filterNeedsProbing: Bool {
        filter.minWidth != nil || filter.minHeight != nil || filter.maxWidth != nil || filter.maxHeight != nil || filter.minShortSide != nil
            || filter.minLongSide != nil
            || filter.minMegapixels != nil || filter.minBytes != nil || filter.maxBytes != nil || filter.aspect != .any
            || filter.sort == .resolution || filter.sort == .fileSize
    }

    func refilter() {
        let states = states
        let context = FilterContext(currentPage: browser.url) { id in
            switch states[id] {
            case .saved, .duplicate: .saved
            case .failed: .failed
            default: .notSaved
            }
        }
        visible = filter.apply(items, context: context)
        if filter.sort == .discovery || filter.sort == .date {
            var order: [String] = []
            var groups: [String: (title: String, ids: [String])] = [:]
            for item in visible {
                if groups[item.group] == nil {
                    order.append(item.group)
                    groups[item.group] = (item.groupTitle, [])
                }
                groups[item.group]?.ids.append(item.id)
            }
            sections = order.map { GridSection(id: $0, title: groups[$0]?.title ?? "", ids: groups[$0]?.ids ?? []) }
        } else {
            sections = [GridSection(id: "all", title: "", ids: visible.map(\.id))]
        }
        let visibleIDs = Set(visible.map(\.id))
        if !selection.isSubset(of: visibleIDs) { selection.formIntersection(visibleIDs) }
        gridRevision += 1
    }

    var selectedItems: [MediaItem] {
        visible.filter { selection.contains($0.id) }
    }

    var inspectedItem: MediaItem? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return itemsByID[id]
    }

    func selectAll() {
        selection = Set(visible.map(\.id))
        gridRevision += 1
    }

    func deselectAll() {
        selection = []
        gridRevision += 1
    }

    func clear() {
        Task { await ingestor.clear() }
        // The PDFs' images go with the list, so opening a PDF again extracts it again.
        extractedDocuments.removeAll()
        states.removeAll()
        libraryChecked.removeAll()
        selection.removeAll()
        probing.removeAll()
    }

    func remove(_ ids: Set<String>) {
        Task { await ingestor.remove(ids) }
        selection.subtract(ids)
    }

    func hideDomain(of id: String) {
        guard let host = itemsByID[id]?.host, !host.isEmpty else { return }
        var tokens = MediaFilter.tokens(filter.excludeDomains)
        if !tokens.contains(host) { tokens.append(host) }
        filter.excludeDomains = tokens.joined(separator: ", ")
    }

    // MARK: Probing

    func requestContext(for url: URL, item: MediaItem) -> RequestContext {
        var context = RequestContext(
            accept: item.kind == .image || item.kind == .animatedImage ? RequestContext.imageAccept : RequestContext.anyAccept,
            userAgent: app.userAgent
        )
        if let web = item.source.web {
            context.referer = URLNormalizer.referer(for: url, from: web.frameURL ?? web.pageURL)
            if URLNormalizer.mayCarryCookies(url, page: web.pageURL, frame: web.frameURL) {
                context.cookieHeader = cookieJar.header(for: url)
            }
        } else if let engine = item.source.engine {
            if let agent = engine.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value { context.userAgent = agent }
            if !engine.isInstagram, let source = engine.sourceURL { context.referer = URLNormalizer.referer(for: url, from: source) }
        }
        return context
    }

    func ensureProbed(_ item: MediaItem) {
        guard let best = item.best else { return }
        var targets: [MediaVariant] = []
        let needsBest = (best.isDerived && best.check == .unverified) || best.pixelSize == nil || best.byteCount == nil
        if needsBest, !best.requiresEngine, best.origin != .engineThumbnail, !best.hasFailed { targets.append(best) }
        if let confirmed = item.bestConfirmed, confirmed.id != best.id, confirmed.pixelSize == nil, !confirmed.requiresEngine {
            targets.append(confirmed)
        }
        for variant in targets where !probing.contains(variant.id) {
            guard let scheme = variant.url.scheme, ["http", "https", "data"].contains(scheme) else { continue }
            probing.insert(variant.id)
            let context = requestContext(for: variant.url, item: item)
            let prober = app.prober
            let ingestor = ingestor
            let itemID = item.id
            Task.detached(priority: .utility) {
                let result = await prober.probe(variant, context: context)
                await ingestor.apply(probe: result, itemID: itemID, variantID: variant.id)
            }
        }
    }

    private func probeAllUnknown() {
        var count = 0
        for item in items where item.displaySize == nil || item.displayBytes == nil {
            ensureProbed(item)
            count += 1
            if count > 600 { break }
        }
    }

    // MARK: Engine items

    func ingestEngine(_ inputs: [EngineItemInput]) {
        let ingestor = ingestor
        Task { await ingestor.ingest(engineItems: inputs) }
    }

    func markSaved(_ id: String, url: URL) {
        states[id] = .saved(url)
        gridRevision += 1
    }

    // MARK: Saving

    func markQueued(_ ids: [String]) {
        for id in ids {
            states[id] = .queued
        }
        gridRevision += 1
    }

    /// The tab showing a page (blob media only exists in the page that made it), or the selected tab.
    func tab(showing page: URL?) -> BrowserController {
        guard let page else { return browser }
        return tabs.first { $0.url == page } ?? browser
    }

    func clearQueued(_ ids: [String]) {
        var changed = false
        for id in ids {
            if case .queued = states[id] {
                states[id] = nil
                changed = true
            }
        }
        if changed { gridRevision += 1 }
    }

    func apply(_ event: SaveEvent) {
        switch event {
        case let .started(id): states[id] = .saving(nil)
        case let .progress(id, fraction): states[id] = .saving(fraction)
        case let .finished(id, outcome, _):
            switch outcome {
            case let .saved(url): states[id] = .saved(url)
            case let .duplicate(url): states[id] = .duplicate(url)
            case let .skipped(reason): states[id] = .skipped(reason)
            case let .failed(reason): states[id] = .failed(reason)
            }
        }
        gridRevision += 1
    }

    // MARK: Save folder (D-70)

    /// Where Collect saves: the folder selected in the Library pane, the default library folder until another is chosen.
    var saveFolder: URL? { library.selectedFolder ?? app.defaultRoot?.url }

    var saveFolderName: String { saveFolder?.lastPathComponent ?? "Library" }

    /// Makes `folder` the save folder. A folder outside the library is shown in the Library pane without joining the library.
    func useSaveFolder(_ folder: URL) {
        if app.root(containing: folder) == nil { library.otherFolder = folder }
        library.selectedFolder = folder
    }

    func chooseSaveFolder(then action: (() -> Void)? = nil) {
        FolderPicker.chooseFolder(title: "Choose Where to Save", prompt: "Choose", start: saveFolder,
                                  window: hostWindow) { [weak self] url in
            guard let self, let url else { return }
            self.useSaveFolder(url)
            action?()
        }
    }

    /// Saves the items (the selection by default) into the save folder.
    func saveItems(_ items: [MediaItem]? = nil) {
        let chosen = items ?? selectedItems
        guard !chosen.isEmpty else { return }
        guard let folder = saveFolder else {
            chooseSaveFolder { [weak self] in self?.saveItems(chosen) }
            return
        }
        app.save(chosen, from: self, to: folder)
    }

    /// Picks any folder, makes it the save folder and saves there.
    func saveTo(_ items: [MediaItem]? = nil) {
        let chosen = items ?? selectedItems
        guard !chosen.isEmpty else { return }
        chooseSaveFolder { [weak self] in self?.saveItems(chosen) }
    }

    func save(_ ids: [String], to folder: URL) {
        let chosen = ids.compactMap { itemsByID[$0] }
        app.save(chosen, from: self, to: folder)
    }

    // MARK: Auto-scroll

    func stopAutoScroll() {
        scrollTask?.cancel()
        autoScrolling = false
    }

    func toggleAutoScroll() {
        if autoScrolling {
            scrollTask?.cancel()
            autoScrolling = false
            return
        }
        autoScrolling = true
        scrollTask?.cancel()
        let token = UUID()
        scrollToken = token
        scrollTask = Task { [weak self] in
            var quiet = 0
            var lastCount = -1
            while !Task.isCancelled {
                guard let self else { return }
                let step = await self.browser.scrollStep()
                try? await Task.sleep(for: .milliseconds(1100))
                let count = await self.ingestor.count
                if count == lastCount, step.atBottom || !step.moved { quiet += 1 } else { quiet = 0 }
                lastCount = count
                if quiet >= 3 { break }
            }
            // A cancelled run must not switch off a newer one.
            if self?.scrollToken == token { self?.autoScrolling = false }
        }
    }

    // MARK: Grid owner

    func gridInfo(_ id: String) -> GridCellInfo? {
        guard let item = itemsByID[id] else { return nil }
        var parts: [String] = []
        if let size = item.displaySize { parts.append(size.label) }
        if let format = item.displayFormat { parts.append(format.label) } else { parts.append(item.kind.label) }
        var secondary: [String] = []
        if let bytes = item.displayBytes { secondary.append(Format.bytes(bytes)) }
        if let duration = item.duration { secondary.append(Format.duration(duration)) }
        if secondary.isEmpty {
            secondary.append(item.source.engine.map { $0.isInstagram ? $0.instagramSection.capitalized : $0.category } ?? item.host)
        }
        var info = GridCellInfo(title: nil, detail: parts.joined(separator: " · "), secondary: secondary.joined(separator: " · "))
        switch item.kind {
        case .video: info.kindSymbol = "play.fill"; info.placeholderSymbol = "film"
        case .stream: info.kindSymbol = "dot.radiowaves.left.and.right"; info.placeholderSymbol = "film.stack"
        case .audio: info.kindSymbol = "music.note"; info.placeholderSymbol = "waveform"
        case .animatedImage: info.kindSymbol = "square.stack.3d.down.forward"
        case .vector: info.placeholderSymbol = "scribble.variable"
        case .image: break
        }
        if item.flags.contains(.protected) {
            info.stateSymbol = "lock.fill"
            info.stateColor = .secondaryLabelColor
            info.dimmed = true
        } else if item.best?.url.scheme == "http" {
            // R-1001: fetched over plain http (D-21), shown until a save state takes the corner.
            info.stateSymbol = "lock.open.fill"
            info.stateColor = .systemYellow
            info.secondary = [info.secondary, "insecure (http)"].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        switch states[id] {
        case .queued: info.stateSymbol = "clock.fill"; info.stateColor = .secondaryLabelColor
        case let .saving(fraction): info.progress = fraction ?? 0.05; info.stateSymbol = nil
        case .saved, .duplicate: info.stateSymbol = "checkmark.circle.fill"; info.stateColor = .systemGreen
        case .skipped: info.stateSymbol = "minus.circle.fill"; info.stateColor = .secondaryLabelColor
        case .failed: info.stateSymbol = "exclamationmark.triangle.fill"; info.stateColor = .systemOrange
        case nil: break
        }
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        guard let item = itemsByID[id] else { return nil }
        if item.kind == .vector {
            let key = "\(id)#\(maxPixel)" as NSString
            if let cached = vectorThumbnails.object(forKey: key) { return cached.image }
            guard let file = await previewFile(for: item) else { return nil }
            let image = await Task.detached(priority: .utility) { SVGRasterizer.rasterize(file, longSide: maxPixel) }.value
            if let image { vectorThumbnails.setObject(Thumbnail(image), forKey: key) }
            return image
        }
        let url: URL? = switch item.kind {
        case .video, .stream, .audio:
            item.posterURL ?? item.variants.first { $0.origin == .engineThumbnail }?.url
        default:
            item.thumbnailVariant(minimum: maxPixel)?.url
        }
        guard let url else { return nil }
        let context = requestContext(for: url, item: item)
        if let small = CDNRules.thumbnailURL(for: url, width: max(320, maxPixel)),
           let image = await app.thumbnails.thumbnail(for: small, maxPixel: maxPixel, context: context)?.image
        {
            return image
        }
        return await app.thumbnails.thumbnail(for: url, maxPixel: maxPixel, context: context)?.image
    }

    func gridMagnify(_ amount: CGFloat) {
        cellSize = min(max((cellSize * (1 + amount)).rounded(), Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    func gridSelectionChanged(_ ids: Set<String>) {
        selection = ids
        if ids.count == 1, let id = ids.first { showInPreview(.item(id)) }
    }

    func gridActivate(_ id: String) {
        selection = [id]
        showInPreview(.item(id))
        showPreview = true
    }

    var visiblePanes: Set<PaneID> {
        var panes = Set<PaneID>()
        if showBrowser { panes.insert(.source) }
        if showExtracted { panes.insert(.extracted) }
        if showPreview { panes.insert(.preview) }
        if showLibrary { panes.insert(.library) }
        if showDownloads { panes.insert(.downloads) }
        return panes
    }

    var organiseVisiblePanes: Set<PaneID> {
        var panes = Set<PaneID>()
        if showOrganiseSource { panes.insert(.organiseSource) }
        if showOrganiseWork { panes.insert(.organiseWork) }
        if showOrganiseTarget { panes.insert(.organiseTarget) }
        return panes
    }

    // MARK: Views (R-1708)

    func viewMode(for pane: PaneID) -> PaneViewMode {
        app.preferences.paneViewModes.mode(for: pane)
    }

    func setViewMode(_ mode: PaneViewMode, for pane: PaneID) {
        app.preferences.paneViewModes.set(mode, for: pane)
        focusedPane = pane
    }

    /// The pane last clicked or focused, so ⌘1 to ⌘3 change the pane the person is working in.
    var focusedPane: PaneID?
    /// Bumped for a pane when ⌘F should focus its search field.
    var searchFocusTokens: [PaneID: Int] = [:]

    /// The Library or Organise pane the keyboard is working in, or nil when it is the page or the Extracted pane: the
    /// pane last clicked, unless the web page has the keyboard now. In Organise, its Source by default.
    var keyboardFolderPane: PaneID? {
        if section == .organise {
            if let focusedPane, [.organiseSource, .organiseTarget].contains(focusedPane), isShowing(focusedPane) { return focusedPane }
            return .organiseSource
        }
        guard !ReadOnlyWebView.isTyping(in: hostWindow), focusedPane == .library, isShowing(.library) else { return nil }
        return .library
    }

    /// ⌘F (SPEC 21): the search field of the Library or Organise pane being worked in, else the Extracted filter bar.
    func find() {
        if let pane = keyboardFolderPane {
            setShowing(pane, true)
            searchFocusTokens[pane, default: 0] += 1
        } else {
            showFilters.toggle()
        }
    }

    /// ⌘R (SPEC 21): reveal the selection in the Finder in a Library or Organise pane, reload the page elsewhere.
    func revealOrReload() {
        switch keyboardFolderPane {
        case .library:
            let urls = library.selectedURLs
            NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [library.selectedFolder].compactMap(\.self) : urls)
        case .organiseSource, .organiseTarget:
            let pane = keyboardFolderPane == .organiseSource ? organise.source : organise.target
            let urls = pane.selectedURLs
            NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [pane.folder].compactMap(\.self) : urls)
        default:
            browser.reloadOrStop()
        }
    }

    /// ⌘. (SPEC 21): stop loading the page, or stop scrolling to its end.
    func stop() {
        if autoScrolling { toggleAutoScroll() }
        if browser.isLoading { browser.reloadOrStop() }
    }

    /// The pane the View menu's view commands act on: the focused one when it is on screen in this section, else the
    /// main pane of the section.
    var viewModeTarget: PaneID {
        let candidates: [PaneID] = section == .collect ? [.library, .extracted] : [.organiseSource, .organiseTarget]
        if let focusedPane, candidates.contains(focusedPane), isShowing(focusedPane) { return focusedPane }
        return candidates.first(where: isShowing) ?? candidates[0]
    }

    func isShowing(_ pane: PaneID) -> Bool {
        pane.group == .collect ? visiblePanes.contains(pane) : organiseVisiblePanes.contains(pane)
    }

    func setShowing(_ pane: PaneID, _ show: Bool) {
        switch pane {
        case .source: showBrowser = show
        case .extracted: showExtracted = show
        case .preview: showPreview = show
        case .library: showLibrary = show
        case .downloads: showDownloads = show
        case .organiseSource: showOrganiseSource = show
        case .organiseWork: showOrganiseWork = show
        case .organiseTarget: showOrganiseTarget = show
        }
        if visiblePanes.subtracting([.downloads]).isEmpty { showExtracted = true }
        if organiseVisiblePanes.isEmpty { showOrganiseSource = true }
    }

    /// Switches the Preview pane to a new subject, unless an edit with unsaved changes is open.
    func showInPreview(_ subject: PreviewSubject) {
        guard previewSubject != subject else { return }
        if activeEditor?.hasUnsavedChanges ?? false { return }
        editorRequest = nil
        previewSubject = subject
    }

    func gridQuickLook() {
        quickLook(selectedItems)
    }

    /// Quick Look for these items; the Preview pane passes the item it shows, whatever the grid selection is.
    func quickLook(_ chosen: [MediaItem]) {
        guard !chosen.isEmpty else { return }
        QuickLook.shared.show { [weak self] in
            guard let self else { return [] }
            var files: [URL] = []
            for item in chosen.prefix(20) {
                if let file = await self.previewFile(for: item) { files.append(file) }
            }
            return files
        }
    }

    func gridFocused() { focusedPane = .extracted }

    func gridAppeared(_ id: String) {
        guard app.preferences.autoProbe, let item = itemsByID[id] else { return }
        if item.displaySize == nil || item.displayBytes == nil || (item.best?.isDerived ?? false && item.best?.check == .unverified) {
            ensureProbed(item)
        }
    }

    var gridAcceptsDrops: Bool { true }

    func gridCanAccept(_ pasteboard: NSPasteboard) -> Bool {
        !Self.pdfFiles(in: pasteboard).isEmpty
    }

    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation _: NSDragOperation) -> Bool {
        let files = Self.pdfFiles(in: pasteboard)
        for file in files {
            extractPDF(local: file)
        }
        return !files.isEmpty
    }

    static func pdfFiles(in pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    // MARK: PDFs

    static var editsCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaPull/Edits", isDirectory: true)
    }

    func edit(_ id: String) {
        openEditor(EditorRequest(subject: .item(id)))
    }

    /// Videos open the video editor (frames and trimming); everything else the image editor.
    func isVideo(_ subject: EditorRequest.Subject) -> Bool {
        switch subject {
        case let .file(url): MediaFormat.fromExtension(url.pathExtension)?.kind == .video
        case let .item(id): itemsByID[id].map { $0.kind == .video || $0.kind == .stream } ?? false
        }
    }

    func openEditor(_ request: EditorRequest) {
        // An open edit with unsaved changes stays, as when another item is selected; Save or Cancel it first.
        if activeEditor?.hasUnsavedChanges ?? false, editorRequest?.subject != request.subject {
            showPreview = true
            NSSound.beep()
            return
        }
        switch request.subject {
        case let .item(id): previewSubject = .item(id)
        case let .file(url): previewSubject = .file(url)
        }
        editorRequest = request
        showPreview = true
    }

    /// Full-size downloads for the Preview pane and Quick Look; emptied at every launch.
    static var previewCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaPull/Preview", isDirectory: true)
    }

    static var pdfCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaPull/PDF", isDirectory: true)
    }

    /// Downloads a PDF from the web and lists the images inside it (SPEC section 31).
    /// `page` is the page that links to the PDF, if any; it decides the referer and whether cookies are sent.
    func extractPDF(remote url: URL, linkedFrom page: URL?) {
        guard extractedDocuments.insert(url.absoluteString).inserted else { return }
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let name = url.pathExtension.lowercased() == "pdf" ? (last as NSString).deletingPathExtension : (last.isEmpty ? "document" : last)
        let job = Job(kind: .scan, title: "Images in \(name)")
        job.subtitle = url.host ?? ""
        app.jobs.add(job)
        let file = Self.pdfCache.appendingPathComponent(ShortHash.of(url.absoluteString) + ".pdf")
        var context = RequestContext(accept: "application/pdf,*/*;q=0.5", userAgent: app.userAgent)
        if let page, page != url {
            context.referer = URLNormalizer.referer(for: url, from: page)
            if URLNormalizer.isSameSite(page, url) { context.cookieHeader = cookieJar.header(for: url) }
        } else {
            context.cookieHeader = cookieJar.header(for: url)
        }
        let request = GatedRequest.get(url, purpose: .save, context: context)
        job.task = Task { [weak self] in
            job.state = .running
            do {
                _ = try await AppModel.shared.gate.download(request, to: file) { received, total in
                    Task { @MainActor in job.fraction = total.map { Double(received) / Double(max($0, 1)) } }
                }
                guard Sniffer.sniff(MediaConverter.head(of: file)).isMarkup == false,
                      // lint:allow main-io five mapped bytes
                      (try? Data(contentsOf: file, options: .alwaysMapped).prefix(5)) == Data("%PDF-".utf8)
                else {
                    self?.extractedDocuments.remove(url.absoluteString)
                    AppModel.shared.jobs.finish(job, .failed("The site did not return a PDF."))
                    return
                }
                await self?.extractImages(from: file, documentURL: url, title: name, job: job)
            } catch {
                self?.extractedDocuments.remove(url.absoluteString)
                AppModel.shared.jobs.finish(job, .failed(error.localizedDescription))
            }
        }
    }

    /// Lists the images inside a PDF on this Mac.
    func extractPDF(local file: URL) {
        let name = file.deletingPathExtension().lastPathComponent
        guard extractedDocuments.insert(file.absoluteString).inserted else { return }
        let job = Job(kind: .scan, title: "Images in \(file.lastPathComponent)")
        app.jobs.add(job)
        job.task = Task { [weak self] in
            job.state = .running
            await self?.extractImages(from: file, documentURL: file, title: name, job: job)
        }
    }

    func extractAllDocuments() {
        for url in documents where !extractedDocuments.contains(url.absoluteString) {
            extractPDF(remote: url, linkedFrom: browser.url)
        }
    }

    private func extractImages(from file: URL, documentURL: URL, title: String, job: Job) async {
        let folder = Self.pdfCache.appendingPathComponent(ShortHash.of(documentURL.absoluteString), isDirectory: true)
        let progress = ProgressBox()
        // The extraction runs detached, which does not inherit Cancel from the job's task: pass it on, and show the pages.
        let shown = Task { [weak job] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let (page, pages) = progress.position
                if pages > 0 { job?.fraction = Double(page) / Double(pages) }
            }
        }
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { () -> Result<[PDFExtractedImage], Error> in
                Result {
                    try PDFImageExtractor.extract(pdf: file, to: folder, baseName: title, progress: { page, pages in
                        progress.set(page, pages)
                    }, isCancelled: { progress.cancelled })
                }
            }.value
        } onCancel: {
            progress.cancel()
        }
        shown.cancel()
        if Task.isCancelled || job.state == .cancelled {
            extractedDocuments.remove(documentURL.absoluteString)
            app.jobs.finish(job, .cancelled)
            return
        }
        switch result {
        case let .success(images):
            let inputs = images.map {
                DocumentImageInput(file: $0.file, documentURL: documentURL, documentTitle: title, page: $0.page, index: $0.index,
                                   width: $0.width, height: $0.height, format: $0.format, bytes: $0.bytes)
            }
            await ingestor.ingest(documentImages: inputs)
            job.found = images.count
            if images.isEmpty { job.notes.append("This PDF has no embedded images of useful size.") }
            app.jobs.finish(job, .completed)
        case let .failure(error):
            extractedDocuments.remove(documentURL.absoluteString)
            app.jobs.finish(job, .failed(error.localizedDescription))
        }
    }

    func gridWriter(_ id: String) -> NSPasteboardWriting? {
        guard let item = itemsByID[id] else { return nil }
        let format = predictedFormat(item)
        let type = UTType(filenameExtension: format.fileExtension)?.identifier ?? UTType.data.identifier
        let provider = ItemPromiseProvider(fileType: type, delegate: PromiseWriter.shared)
        provider.payload = ItemDragPayload(window: self.id, id: id)
        let base = item.best.flatMap { URLNormalizer.baseName(of: $0.url) } ?? "media"
        provider.userInfo = [
            "window": self.id.uuidString, "id": id, "name": FileNaming.fileName(stem: base, ext: format.fileExtension),
            "sidecar": NSEvent.modifierFlags.contains(.option) ? "1" : "0",
        ]
        return provider
    }

    func predictedFormat(_ item: MediaItem) -> MediaFormat {
        let format = item.displayFormat ?? (item.kind == .video || item.kind == .stream ? .mp4 : .jpeg)
        if format.isNormal || format == .svg { return format }
        switch format.kind {
        case .video, .stream: return .mp4
        case .audio: return format
        default: return item.kind == .animatedImage ? .gif : (format == .webp || format == .avif ? .jpeg : .png)
        }
    }

    /// The bytes of items a page made itself (`blob:` addresses), read from the tab that shows their page.
    func blobData(for items: [MediaItem]) async -> [String: Data] {
        var inline: [String: Data] = [:]
        for item in items {
            guard let url = item.best?.url, url.scheme == "blob" else { continue }
            if let data = await tab(showing: item.source.pageURL).readBlob(url) { inline[item.id] = data }
        }
        return inline
    }

    /// Writes one item where Finder asked, after downloading and converting it (SPEC R-1801).
    /// Saves into a private folder first, then places the file exactly at the URL the receiving
    /// app supplied, in the promised format.
    func writePromise(itemID: String, to url: URL, withSidecar: Bool) async -> Error? {
        guard let item = itemsByID[itemID] else { return CocoaError(.fileNoSuchFile) }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPull-promise-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let target = SaveTarget(folder: staging, layout: withSidecar ? .archive : .plain, autoSubfolders: false)
        let pipeline = app.pipeline()
        // Page-made (blob:) media exists only inside the page: read it there, as Save does.
        let context = SaveContext(cookies: await app.cookieJar(), userAgent: app.userAgent, inlineData: await blobData(for: [item]),
                                  nameOverrides: customNames)
        // The copy in the staging folder is temporary, so its events do not mark the item as saved.
        let outcomes = await pipeline.save([item], target: target, settings: app.saveSettings, context: context, concurrency: 1) { _ in }
        switch outcomes[itemID] {
        case let .saved(saved), let .duplicate(saved):
            do {
                // The promised name guessed the format. When the real one differs (a PNG promised as JPEG), keep the real file
                // under its own extension rather than re-encoding it; never replace an existing file.
                let actual = saved.pathExtension.lowercased()
                var destination = url.pathExtension.lowercased() == actual
                    ? url
                    : url.deletingPathExtension().appendingPathExtension(actual)
                destination = LibraryModel.uniqueURL(destination)
                let target = destination
                // A video copied to another disk can take a while: not on the main actor.
                try await LibraryModel.offMain { try MediaFiles.copy(saved, to: target, withSidecar: withSidecar) }
                return nil
            } catch {
                return error
            }
        case let .failed(reason), let .skipped(reason):
            return NSError(domain: "MediaPull", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        case nil:
            return CocoaError(.fileWriteUnknown)
        }
    }

    /// The item's best file in a cache folder, for Quick Look and the inspector preview.
    func previewFile(for item: MediaItem) async -> URL? {
        if let saved = states[item.id]?.savedURL, FileManager.default.fileExists(atPath: saved.path) { return saved }
        if let local = item.variants.first(where: { $0.url.isFileURL && FileManager.default.fileExists(atPath: $0.url.path) }) {
            return local.url
        }
        let candidates = SavePipeline.attemptOrder(item).filter { $0.url.scheme == "https" || $0.url.scheme == "http" }
        guard let variant = candidates.first else { return nil }
        let folder = Self.previewCache
        let ext = variant.format?.fileExtension ?? (variant.url.pathExtension.isEmpty ? "jpg" : variant.url.pathExtension)
        let file = folder.appendingPathComponent(ShortHash.of(variant.id) + "." + ext)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let request = GatedRequest.get(variant.url, purpose: .preview, context: requestContext(for: variant.url, item: item))
        do {
            _ = try await app.gate.download(request, to: file)
            return file
        } catch {
            return nil
        }
    }

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        guard !ids.isEmpty else { return nil }
        let chosen = visible.filter { ids.contains($0.id) }
        let menu = NSMenu()
        let count = chosen.count == 1 ? "" : " \(chosen.count) Items"
        menu.addItem(ActionMenuItem("Save\(count) to “\(saveFolderName)”") { [weak self] in self?.saveItems(chosen) })
        menu.addItem(ActionMenuItem("Save\(count) to…") { [weak self] in self?.saveTo(chosen) })
        menu.addItem(.separator())
        if let item = chosen.first, chosen.count == 1 {
            if let url = item.best?.url, url.scheme == "https" || url.scheme == "http" {
                menu.addItem(ActionMenuItem("Copy URL") { Format.copy(url.absoluteString) })
                // The larger original a CDN rule found (Appendix D), when it differs from the address above.
                if let original = item.variants.first(where: \.isDerived)?.url, original != url {
                    menu.addItem(ActionMenuItem("Copy Original URL") { Format.copy(original.absoluteString) })
                }
                menu.addItem(ActionMenuItem("Open Media in Browser") { [weak self] in self?.browser.load(url) })
            }
            if item.kind == .image || item.kind == .animatedImage {
                // The picture itself (downloaded through the gate first), for pasting into other apps.
                menu.addItem(ActionMenuItem("Copy Image") { [weak self] in
                    Task {
                        guard let self, let file = await self.previewFile(for: item),
                              let image = NSImage(contentsOf: file) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                })
            }
            if let page = item.source.pageURL {
                menu.addItem(ActionMenuItem("Open Source Page") { [weak self] in self?.browser.load(page) })
            }
            menu.addItem(ActionMenuItem("Show in Preview") { [weak self] in self?.gridActivate(item.id) })
            menu.addItem(ActionMenuItem(
                item.kind == .image ? "Edit…" : (item.kind == .video ? "Edit Video…" : "Rename…")
            ) { [weak self] in
                self?.edit(item.id)
            })
            if let saved = states[item.id]?.savedURL {
                menu.addItem(ActionMenuItem("Show Saved File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) })
            }
            menu.addItem(.separator())
            if !item.host.isEmpty {
                menu.addItem(ActionMenuItem("Hide Items from \(item.host)") { [weak self] in self?.hideDomain(of: item.id) })
            }
        } else {
            menu.addItem(ActionMenuItem("Copy URLs") {
                Format.copy(chosen.compactMap { $0.best?.url.absoluteString }.joined(separator: "\n"))
            })
            menu.addItem(.separator())
        }
        menu.addItem(ActionMenuItem("Quick Look") { [weak self] in self?.gridQuickLook() })
        menu.addItem(ActionMenuItem("Remove from List") { [weak self] in self?.remove(ids) })
        return menu
    }
}

/// Page progress shared between the extraction thread and the main actor.
nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var page = 0
    private var pages = 0
    private var isCancelled = false

    func set(_ page: Int, _ pages: Int) {
        lock.withLock {
            self.page = page
            self.pages = pages
        }
    }

    var cancelled: Bool { lock.withLock { isCancelled } }

    var position: (page: Int, pages: Int) { lock.withLock { (page, pages) } }

    func cancel() { lock.withLock { isCancelled = true } }
}

/// A menu item that runs a closure.
nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}

enum WindowSection: String, CaseIterable {
    case collect, organise

    var label: String { self == .collect ? "Collect" : "Organise" }
}

/// Extracted Media as a list (R-1709): one row per item, sorted by the pane's own sort.
extension WindowModel: MediaListOwner {
    var listColumns: [ListColumn] { ListColumn.extractedColumns }

    func listText(_ id: String, _ column: ListColumn) -> String {
        guard let item = itemsByID[id] else { return "" }
        switch column {
        case .name:
            return item.source.engine?.fileName ?? item.best.flatMap { URLNormalizer.baseName(of: $0.url) } ?? item.alt ?? item.kind.label
        case .dimensions: return item.displaySize.map { "\($0.width) × \($0.height)" } ?? ""
        case .size: return item.displayBytes.map(Format.bytes) ?? ""
        case .kind: return item.displayFormat?.label ?? item.kind.label
        case .duration: return item.duration.map(Format.duration) ?? ""
        case .source:
            return item.source.engine.map { $0.isInstagram ? $0.instagramSection.capitalized : $0.category } ?? item.host
        case .found: return "\(item.discoveryIndex + 1)"
        case .tags: return ""
        case .date: return item.source.engine?.date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        }
    }

    var listSort: (column: ListColumn, ascending: Bool)? {
        ListColumn(extractedSort: filter.sort).map { ($0, filter.ascending) }
    }

    func listSortChanged(_ column: ListColumn, ascending: Bool) {
        guard let sort = column.extractedSort else { return }
        filter.sort = sort
        filter.ascending = ascending
    }

    func listCanSort(_ column: ListColumn) -> Bool { column.extractedSort != nil }

    /// Extracted Media has no folders to open, so nothing is ever loaded.
    var onListChildrenLoaded: ((String) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}
