import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullStore
import Observation

/// The automatic sorts Organise offers (R-3803).
enum AutoSort: String, CaseIterable, Identifiable {
    case date, event, source, subject, person, screenshots, place

    var id: String { rawValue }

    var label: String {
        switch self {
        case .date: "Date"
        case .event: "Event"
        case .source: "Source"
        case .subject: "Subject"
        case .person: "Person"
        case .screenshots: "Screenshots"
        case .place: "Place"
        }
    }

    var detail: String {
        switch self {
        case .date: "Year, then month"
        case .event: "Photos taken close together"
        case .source: "Account or website"
        case .subject: "What the photo shows"
        case .person: "Who is in the photo"
        case .screenshots: "Screenshots apart from photos"
        case .place: "Country, then city"
        }
    }

    var symbol: String {
        switch self {
        case .date: "calendar"
        case .event: "calendar.badge.clock"
        case .source: "person.crop.square"
        case .subject: "tag"
        case .person: "person.2"
        case .screenshots: "iphone"
        case .place: "mappin.and.ellipse"
        }
    }
}

/// Where Organise puts results (R-3802, D-68).
enum OrganiseMode: String, CaseIterable {
    case inPlace, copy, move

    var label: String {
        switch self {
        case .inPlace: "In Place"
        case .copy: "Copy to Target"
        case .move: "Move to Target"
        }
    }

    var detail: String {
        switch self {
        case .inPlace: "Folders are made inside the source folder and files move into them."
        case .copy: "The source folder stays as it is. Organised copies go into the target folder and take no extra space on Mac drives."
        case .move: "Files move out of the source folder into folders in the target folder."
        }
    }
}

/// A change waiting to be applied, shown in the Organise pane rather than a separate window (R-3805).
struct PendingPlan: Identifiable {
    let id = UUID()
    var plan: OrganisePlan
    var note: String?
}

enum OrganiseTab: String, CaseIterable {
    case sort, people, history

    var label: String {
        switch self {
        case .sort: "Sort"
        case .people: "People"
        case .history: "History"
        }
    }
}

/// One folder pane of the Organise section: a folder tree and the selected folder's media.
@Observable
final class OrganisePane: MediaGridOwner {
    @ObservationIgnored weak var owner: OrganiseModel?
    let role: Role
    enum Role { case source, target }

    /// The folder opened in this pane (the top of its tree).
    var root: URL? {
        didSet {
            if root != oldValue {
                folder = root
                treeRevision += 1
            }
        }
    }

    var folder: URL? {
        didSet { if folder != oldValue { selection = []; reload() } }
    }

    var entries: [MediaEntry] = []
    /// More media than one listing holds (MediaListing.limit): sorts would leave the rest out, so they are refused.
    var listingLimited = false
    var shown: [MediaEntry] = []
    var sections: [LibrarySection] = []
    var subfolderCount = 0
    var selection: Set<String> = []
    var revision = 0
    var treeRevision = 0
    @ObservationIgnored let treeCache = FolderTreeCache()
    @ObservationIgnored private var treeRefresh: Task<Void, Never>?
    /// The top of the tree, kept between redraws so the folders it has read are not read again.
    @ObservationIgnored private var cachedRoot: (key: String, node: FolderNode)?
    var cellSize: CGFloat = 132
    var includeSubfolders = false {
        didSet { if includeSubfolders != oldValue { reload() } }
    }

    var query = LibraryQuery() {
        didSet {
            if query != oldValue {
                listFolders.forgetContents()
                refilter()
            }
        }
    }

    /// Subfolders and opened folders of the list view (R-1709).
    @ObservationIgnored let listFolders = FolderChildren()
    @ObservationIgnored var onListChildrenLoaded: ((String) -> Void)?
    @ObservationIgnored private var shownIndex: [String: Int] = [:]

    var loading = false
    /// The shown files are being worked out from the entries (search and filters); `shown` is not current until it ends.
    var filtering = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    init(role: Role) {
        self.role = role
    }

    isolated deinit {
        for task in [treeRefresh, loadTask, filterTask] {
            task?.cancel()
        }
    }

    func rootNode(_ root: URL) -> FolderNode {
        let key = "\(treeRevision)|\(root.path)"
        if let cachedRoot, cachedRoot.key == key { return cachedRoot.node }
        let node = FolderNode(url: root, isRoot: true, cache: treeCache)
        cachedRoot = (key, node)
        return node
    }

    /// Folders changed on disk: the tree's folders are read again off the main actor, then it redraws.
    func invalidateTree() {
        treeRefresh?.cancel()
        treeRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.treeCache.refresh()
            guard !Task.isCancelled else { return }
            self.treeRevision += 1
        }
    }

    private var app: AppModel { .shared }

    func reload() {
        loadTask?.cancel()
        guard let folder else {
            loading = false
            entries = []
            shown = []
            sections = []
            revision += 1
            return
        }
        loading = true
        let recursive = includeSubfolders
        loadTask = Task { [weak self] in
            let (listed, folders, subfolders, limited) = await MediaListing.load(folder, recursive: recursive)
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            let attached = await self.app.analysis.attach(listed)
            guard !Task.isCancelled, self.folder == folder else { return }
            self.entries = attached
            self.listingLimited = limited
            self.subfolderCount = folders
            self.listFolders.reset(top: subfolders)
            self.selection = self.selection.intersection(Set(attached.map(\.path)))
            self.loading = false
            self.refilter()
        }
    }

    /// New analysis results for the files already listed.
    func reattach() {
        let current = entries
        guard !current.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let attached = await self.app.analysis.attach(current)
            guard self.entries.map(\.path) == current.map(\.path) else { return }
            self.entries = attached
            self.refilter()
        }
    }

    func refilter() {
        filterTask?.cancel()
        let entries = entries, query = query
        filtering = true
        filterTask = Task { [weak self] in
            guard let self else { return }
            if !query.search.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let context = await self.app.analysis.queryContext(for: query, entries: entries)
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .userInitiated) { query.apply(entries, context: context) }.value
            guard !Task.isCancelled else { return }
            self.sections = built
            self.shown = built.flatMap(\.items)
            self.shownIndex = Dictionary(self.shown.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
            self.filtering = false
            self.revision += 1
        }
    }

    var gridSections: [GridSection] {
        sections.enumerated().map { GridSection(id: "\($0.offset)", title: $0.element.title ?? "", ids: $0.element.items.map(\.path)) }
    }

    func entry(_ path: String) -> MediaEntry? { shownIndex[path].map { shown[$0] } ?? listFolders.entry(path) }

    /// The selected files and folders; files inside folders opened in the list view count too.
    var selectedURLs: [URL] { urls(selection) }

    private func urls(_ ids: Set<String>) -> [URL] {
        ids.sorted().compactMap { id in listFolders.isFolder(id) ? URL(fileURLWithPath: id, isDirectory: true) : entry(id)?.url }
    }

    // MARK: Grid owner

    func gridInfo(_ id: String) -> GridCellInfo? {
        guard let entry = entry(id) else { return nil }
        var detail: [String] = []
        if let w = entry.facts?.pixelWidth, let h = entry.facts?.pixelHeight { detail.append("\(w) × \(h)") }
        detail.append(entry.format?.label ?? entry.url.pathExtension.uppercased())
        var info = GridCellInfo(title: entry.name, detail: detail.joined(separator: " · "), secondary: Format.bytes(entry.size))
        if entry.kind == .video { info.kindSymbol = "play.fill"; info.placeholderSymbol = "film" }
        if entry.source != nil { info.stateSymbol = "text.badge.checkmark"; info.stateColor = .secondaryLabelColor }
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        await app.thumbnails.localThumbnail(for: URL(fileURLWithPath: id), maxPixel: maxPixel)?.image
    }

    func gridSelectionChanged(_ ids: Set<String>) { selection = ids }

    /// A folder (a row of the list or column view) opens in the pane, as in the Finder.
    func gridActivate(_ id: String) {
        if listFolders.isFolder(id) {
            folder = URL(fileURLWithPath: id, isDirectory: true)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: id))
    }

    func gridQuickLook() {
        QuickLook.shared.show(selection.sorted().compactMap { id in
            entry(id)?.url ?? (listFolders.isFolder(id) || !id.hasPrefix("/") ? nil : URL(fileURLWithPath: id))
        })
    }

    func gridDelete(_ ids: Set<String>) {
        let chosen = urls(ids)
        guard !chosen.isEmpty else { return }
        owner?.run(FolderOperations.trash(chosen))
    }

    func gridAppeared(_: String) {}

    var paneID: PaneID { role == .source ? .organiseSource : .organiseTarget }

    func gridFocused() { owner?.window?.focusedPane = paneID }

    func gridWriter(_ id: String) -> NSPasteboardWriting? { URL(fileURLWithPath: id, isDirectory: listFolders.isFolder(id)) as NSURL }

    var gridAcceptsDrops: Bool { folder != nil }

    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation: NSDragOperation) -> Bool {
        guard let folder else { return false }
        return gridAcceptDrop(pasteboard, operation: operation, into: folder)
    }

    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation _: NSDragOperation, into folder: URL) -> Bool {
        guard let owner else { return false }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        owner.drop(Sidecar.withoutCompanions(urls), into: folder)
        return true
    }

    func gridMagnify(_ amount: CGFloat) { cellSize = min(320, max(72, cellSize * (1 + amount))) }

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        guard let owner else { return nil }
        let chosen = urls(ids)
        guard !chosen.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Open") { chosen.forEach { NSWorkspace.shared.open($0) } })
        menu.addItem(ActionMenuItem("Quick Look") { [weak self] in self?.gridQuickLook() })
        menu.addItem(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen) })
        menu.addItem(.separator())
        if role == .source, let target = owner.targetFolder, target.standardizedFileURL != folder?.standardizedFileURL {
            menu.addItem(ActionMenuItem("Copy to “\(target.lastPathComponent)”") {
                owner.run(FolderOperations.copy(chosen, to: target))
            })
            menu.addItem(ActionMenuItem("Move to “\(target.lastPathComponent)”") {
                owner.run(FolderOperations.move(chosen, to: target))
            })
        }
        // R-3803: any folder, chosen in a panel, as one change ⌘Z takes back.
        menu.addItem(ActionMenuItem("Move To…") { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            panel.directoryURL = self?.folder
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            owner.run(FolderOperations.move(chosen, to: destination))
        })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move to Trash") { owner.run(FolderOperations.trash(chosen)) })
        return menu
    }
}

extension OrganisePane: MediaListOwner {
    var listColumns: [ListColumn] { ListColumn.fileColumns }

    func listText(_ id: String, _ column: ListColumn) -> String {
        if listFolders.isFolder(id) { return ListText.folder(id, column) }
        return entry(id).map { ListText.entry($0, column) } ?? ""
    }

    var listSort: (column: ListColumn, ascending: Bool)? { ListColumn(librarySort: query.sort).map { ($0, query.ascending) } }

    func listSortChanged(_ column: ListColumn, ascending: Bool) {
        guard let sort = column.librarySort else { return }
        query.sort = sort
        query.ascending = ascending
    }

    func listCanSort(_ column: ListColumn) -> Bool { column.librarySort != nil }

    /// Subfolders come first, as in the Finder, unless the list is flat: search, Include Subfolders or groups.
    var listTopFolders: [String] {
        let flat = !query.search.trimmingCharacters(in: .whitespaces).isEmpty || includeSubfolders || sections.count > 1
        return flat ? [] : listFolders.top
    }

    func listIsFolder(_ id: String) -> Bool { listFolders.isFolder(id) }

    var listGeneration: Int { listFolders.generation }

    func listChildren(_ folderID: String) -> [String]? {
        listFolders.onLoaded = { [weak self] id in self?.onListChildrenLoaded?(id) }
        return listFolders.contents(of: folderID, query: query)
    }
}

/// The Organise section of one window (SPEC section 38): source, organise and target panes.
@Observable
final class OrganiseModel {
    let source = OrganisePane(role: .source)
    let target = OrganisePane(role: .target)
    var pending: PendingPlan?
    var history: [JournalEntry] = []
    var working: String?
    var tab: OrganiseTab = .sort
    /// The folder being renamed in place.
    var renaming: String?
    /// With a target other than the source: move files there instead of copying them.
    var moveToTarget = false {
        didSet { if moveToTarget != oldValue { pending = nil } }
    }

    /// In place when the target is the source folder ("Same as Source"); otherwise copy or move to the target (D-68).
    var mode: OrganiseMode {
        guard let source = source.root, let target = target.root, source.standardizedFileURL != target.standardizedFileURL
        else { return .inPlace }
        return moveToTarget ? .move : .copy
    }

    var message: String? {
        didSet {
            messageTask?.cancel()
            guard message != nil else { return }
            // Results are kept in History, so the note goes away on its own.
            messageTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.message = nil
            }
        }
    }

    @ObservationIgnored private var messageTask: Task<Void, Never>?

    @ObservationIgnored weak var window: WindowModel?
    @ObservationIgnored private let listenerID = UUID()
    @ObservationIgnored private var lastEntryID: UUID?

    private var app: AppModel { .shared }

    init() {
        source.owner = self
        target.owner = self
        AppModel.shared.analysis.onFolderChange[listenerID] = { [weak self] paths in self?.foldersChanged(paths) }
        Task { await refreshHistory() }
    }

    /// A closed window's Organise section stops listening for folder changes.
    isolated deinit {
        messageTask?.cancel()
        AppModel.shared.analysis.onFolderChange[listenerID] = nil
        // Once this window is gone, its folders stop being watched (after the window's own reference has cleared).
        Task { @MainActor in OrganiseModel.updateAnalysisFolders() }
    }

    /// Opens the default library folder, in place, the first time Organise is shown (D-68).
    func prepare() {
        if source.root == nil, let library = app.defaultRoot?.url { open(library) }
    }

    var recentFolders: [URL] {
        app.preferences.recentOrganiseFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Where results go: the source pane's selected folder in place, otherwise the target pane's folder.
    var destination: URL? { mode == .inPlace ? source.folder : targetFolder }
    var targetFolder: URL? { target.folder ?? target.root }

    /// Opens a folder in the source or target pane. The target is opt-in and survives a change of source (D-68);
    /// a target that is the source folder itself means in place.
    func open(_ folder: URL, in pane: OrganisePane? = nil) {
        let pane = pane ?? source
        let same = { (a: URL?, b: URL?) in a?.standardizedFileURL.path == b?.standardizedFileURL.path }
        if pane.role == .target {
            target.root = same(folder, source.root) ? nil : folder
        } else {
            source.root = folder
            var recent = app.preferences.recentOrganiseFolders.filter { $0 != folder.path }
            recent.insert(folder.path, at: 0)
            app.preferences.recentOrganiseFolders = Array(recent.prefix(10))
        }
        pending = nil
        updateAnalysisFolders()
    }

    /// No target: sorts make folders inside the source folder.
    func clearTarget() {
        target.root = nil
        pending = nil
        updateAnalysisFolders()
    }

    func updateAnalysisFolders() {
        Self.updateAnalysisFolders()
    }

    /// The folders open in Organise in any window are watched and analysed too; a folder inside another counts once.
    static func updateAnalysisFolders() {
        var folders = Set<String>()
        for model in AppModel.shared.windows.map(\.organise) {
            if let root = model.source.root { folders.insert(root.standardizedFileURL.path) }
            if let root = model.target.root { folders.insert(root.standardizedFileURL.path) }
        }
        AppModel.shared.analysis.extraFolders = folders.filter { folder in
            !folders.contains { $0 != folder && folder.hasPrefix($0 + "/") }
        }
    }

    func chooseFolder(for pane: OrganisePane) {
        FolderPicker.chooseFolder(title: pane.role == .source ? "Open a Folder to Organise" : "Choose the Target Folder",
                                  prompt: "Open", start: pane.root ?? AppModel.suggestedRootURL,
                                  window: window?.hostWindow) { [weak self] url in
            guard let url else { return }
            self?.open(url, in: pane)
        }
    }

    private func foldersChanged(_ paths: [String]) {
        for pane in [source, target] {
            guard let folder = pane.folder?.path else { continue }
            // A change inside the shown folder, or to a folder above it (renamed or moved to the Trash in the Finder).
            let affected = paths.contains { path in
                let event = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
                return event == folder || event.hasPrefix(folder + "/") || folder.hasPrefix(event == "/" ? event : event + "/")
            }
            if affected {
                pane.reload()
                pane.invalidateTree()
            }
        }
    }

    func refreshAfterChange() {
        for pane in [source, target] {
            pane.invalidateTree()
            pane.reload()
        }
        app.libraryRevision += 1
    }

    // MARK: Running changes

    /// Small changes apply at once (and can be undone); sorts, flattening and merging are previewed first, in the Organise pane.
    func run(_ plan: OrganisePlan, preview: Bool = false, note: String? = nil) {
        guard !plan.isEmpty else {
            message = plan.unsorted > 0 ? "Nothing to change: \(plan.unsorted) file\(plan.unsorted == 1 ? "" : "s") could not be sorted."
                : "Nothing to change."
            return
        }
        if preview {
            pending = PendingPlan(plan: plan, note: note)
            tab = .sort
            window?.setShowing(.organiseWork, true)
        } else {
            execute(plan)
        }
    }

    func execute(_ plan: OrganisePlan, then finished: (@MainActor () -> Void)? = nil) {
        pending = nil
        message = nil
        let app = app
        let job = Job(kind: .organise, title: plan.title)
        job.total = plan.moves.count + plan.itemsToTrash.count + plan.foldersToCreate.count + plan.foldersToTrash.count
        job.state = .running
        if job.total > 20 { app.jobs.add(job) }
        working = plan.title
        job.task = Task { [weak self] in
            // The files move whether or not the window is still open: the records follow them and the job ends.
            let entry = await app.applyChange(plan) { done, total in
                Task { @MainActor in
                    job.fraction = Double(done) / Double(max(total, 1))
                    job.summaryOverride = "\(done) of \(total) steps"
                }
            }
            job.summaryOverride = "\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")"
                + (entry.failures.isEmpty ? "" : ", \(entry.failures.count) problems")
            job.failures = entry.failures.map { (id: $0, message: $0) }
            app.jobs.finish(
                job,
                entry.finished ? (entry.failures.isEmpty ? .completed : .failed("Some files could not be moved")) : .cancelled
            )
            guard let self else { return }
            self.message = entry.failures.isEmpty
                ? "\(plan.title): done. ⌘Z undoes it."
                : entry.failures.prefix(3).joined(separator: "\n")
            self.window?.registerUndo(entry)
            self.lastEntryID = entry.id
            await self.refreshHistory()
            self.working = nil
            self.showResults(of: plan)
            finished?()
        }
    }

    /// Shows where a change put files: the folder it worked on, with the files of its subfolders in the grid.
    func showResults(of plan: OrganisePlan) {
        let pane = mode == .inPlace ? source : target
        if !plan.destinations.isEmpty {
            pane.includeSubfolders = true
            if pane.folder?.standardizedFileURL != plan.root.standardizedFileURL, plan.root.path.hasPrefix(pane.root?.path ?? "\u{0}") {
                pane.folder = plan.root
            }
        }
        refreshAfterChange()
    }

    func refreshHistory() async {
        history = await app.journal.entries()
    }

    /// The History's Undo, and the toolbar's: through the window, so ⇧⌘Z can redo it.
    func undo(_ entry: JournalEntry) {
        window?.undoChange(entry)
    }

    /// Any window changed files: the History and both panes show the result.
    func fileChanged() {
        Task { await refreshHistory() }
        refreshAfterChange()
    }

    /// The toolbar's Undo: this window's last change, as ⌘Z, else the newest change not undone yet.
    func undoLast() {
        if let id = lastEntryID, let mine = history.first(where: { $0.id == id && !$0.undone }) {
            undo(mine)
        } else if let last = history.first(where: { !$0.undone }) {
            undo(last)
        }
    }

    /// Files dropped on a folder: copied when copying to the target (or from outside), otherwise moved.
    func drop(_ urls: [URL], into folder: URL) {
        let roots = [source.root, target.root].compactMap(\.self)
        let fromOutside = urls.contains { url in roots.allSatisfy { !url.path.hasPrefix($0.path + "/") } }
        let copy = mode == .copy || fromOutside || NSEvent.modifierFlags.contains(.option)
        run(copy ? FolderOperations.copy(urls, to: folder) : FolderOperations.move(urls, to: folder))
    }

    /// Makes "New Folder" through the journal, so it can be undone (R-3805), and starts renaming it in place.
    func newFolder(in parent: URL) {
        let plan = FolderOperations.newFolder(named: "New Folder", in: parent)
        guard let folder = plan.foldersToCreate.first else { return }
        execute(plan) { [weak self] in
            if FileManager.default.fileExists(atPath: folder.path) { self?.renaming = folder.path }
        }
    }

    func commitRename(_ url: URL, to name: String) {
        renaming = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return }
        run(FolderOperations.rename(url, to: trimmed))
    }

    func flatten(_ folder: URL) {
        run(FolderOperations.flatten(folder), preview: true,
            note: "Every file from the subfolders moves up into “\(folder.lastPathComponent)”; the emptied folders go to the Trash.")
    }

    func removeFolder(_ folder: URL) {
        run(FolderOperations.removeSubfolders([folder]), preview: true,
            note: "The folder's contents move up one level; the emptied folder goes to the Trash.")
    }

    func merge(_ folder: URL, into other: URL) {
        run(FolderOperations.merge(folder, into: other), preview: true,
            note: "Folders with the same name are merged; “\(folder.lastPathComponent)” goes to the Trash once empty.")
    }

    /// Folders next to `folder`, for Merge Into.
    func siblings(of folder: URL) -> [URL] {
        let parent = folder.deletingLastPathComponent()
        // lint:allow main-io one folder's entries, when its menu opens
        let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0 != folder }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: Automatic sorts

    /// Plans an automatic sort of the source pane's shown files (or its selection) and previews it in the Organise pane.
    func autoSort(_ kind: AutoSort) {
        // Until a newly opened folder is listed and filtered, the pane still holds the previous folder's files: wait.
        if source.loading || source.filtering {
            working = "Reading the folder…"
            Task { [weak self] in
                let deadline = Date().addingTimeInterval(60)
                while self?.source.loading == true || self?.source.filtering == true, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard let self else { return }
                self.working = nil
                if self.source.loading || self.source.filtering {
                    self.message = "The folder is taking a long time to read. Try again in a moment."
                } else {
                    self.autoSort(kind)
                }
            }
            return
        }
        if source.listingLimited {
            message = "This folder holds more than \(MediaListing.limit.formatted()) files, more than one sort can see. "
                + "Sort its subfolders one at a time."
            return
        }
        // Only what the pane shows: with a search or filters that match nothing, nothing is sorted (never the whole folder).
        let all = source.shown
        let files = source.selection.isEmpty ? all : all.filter { source.selection.contains($0.path) }
        guard let destination, !files.isEmpty else {
            let narrowed = !source.query.filter.isEmpty || !source.query.search.trimmingCharacters(in: .whitespaces).isEmpty
            message = destination == nil ? "Choose a target folder first."
                : narrowed && !source.entries.isEmpty ? "No files match the search or filters."
                : "There is nothing to sort in this folder."
            return
        }
        working = "Planning a sort by \(kind.label.lowercased())…"
        let gap = app.preferences.eventGapHours * 3600
        let threshold = Float(app.preferences.subjectThreshold)
        let placement = app.preferences.groupPhotoPlacement
        let layoutForRoot = layoutFor(destination)
        let copy = mode == .copy
        Task {
            var assignment: [String: [[String]]] = [:]
            var note: String?
            switch kind {
            case .date: for f in files { assignment[f.path] = SortRules.byDate(f) }
            case .event: assignment = SortRules.eventFolders(files, gap: gap)
            case .source: for f in files { assignment[f.path] = SortRules.bySource(f) }
            case .screenshots: for f in files { assignment[f.path] = SortRules.byScreenshot(f) }
            case .place: for f in files { assignment[f.path] = SortRules.byPlace(f) }
            case .subject:
                let subjects = await app.analysis.subjects(for: files)
                for f in files {
                    if let (subject, confidence) = subjects[f.path], confidence >= threshold { assignment[f.path] = [[subject]] }
                }
                note = "Files whose best subject is below \(Int(threshold * 100)) % confidence go to Unsorted."
            case .person:
                let byPath = await app.analysis.peopleByPath(files)
                let names = Dictionary(uniqueKeysWithValues: app.analysis.people.map { ($0.id, $0) })
                let includeUnnamed = app.preferences.sortUnnamedPeople
                // Archive folders keep one copy per post: group photos share a folder there (D-64).
                let effective: GroupPhotoPlacement = layoutForRoot == .archive && placement == .everyPerson ? .sharedFolder : placement
                for f in files {
                    let people = (byPath[f.path] ?? []).compactMap { names[$0] }.filter { includeUnnamed || $0.name != nil }
                        .sorted { $0.faceCount > $1.faceCount }.map(\.displayName)
                    assignment[f.path] = SortRules.personFolders(names: people, placement: effective)
                }
                note = effective == .everyPerson
                    ? "A photo of several people goes into each person's folder as a copy that takes no extra space."
                    : effective == .sharedFolder ? "Photos of several people go into “\(FolderNames.groupPhotos)”." : nil
                if !app.preferences.facesEnabled { note = "Turn on recognising people in the People tab first." }
            }
            let missing = files.filter { $0.record == nil }.count
            if missing > 0, kind != .date, kind != .source, kind != .event {
                note = [note, "\(missing) file\(missing == 1 ? " is" : "s are") not analysed yet and will go to Unsorted."]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            let urls = files.map(\.url)
            let title = "Sort by \(kind.label)", keepUnsorted = kind == .person
            let plan = await Task.detached(priority: .userInitiated) {
                FolderOperations.sort(urls, into: destination, title: title, keepUnsorted: keepUnsorted, copy: copy) {
                    assignment[$0.path] ?? []
                }
            }.value
            working = nil
            run(plan, preview: true, note: note)
        }
    }

    func layoutFor(_ folder: URL) -> SaveLayout {
        if let root = app.root(containing: folder) { return root.layout }
        // Names only, stopping at the first metadata file: once per planned change.
        // lint:allow main-io names of one folder, no file is opened
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "json" { return .archive }
        }
        return .plain
    }
}

extension OrganisePane: MediaColumnsOwner {
    var columnBase: URL? { root }
    var columnRoots: [URL] { [] }
    var columnFolder: URL? { folder }

    func columnFolderChanged(_ folder: URL) { self.folder = folder }

    func columnNoteFolders(_ ids: [String]) { listFolders.note(ids) }
}
