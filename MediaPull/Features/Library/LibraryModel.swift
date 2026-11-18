import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullStore
import Observation
import UniformTypeIdentifiers

struct LibraryFile: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var size: Int64
    var modified: Date
    var hasSidecar: Bool
    var format: MediaFormat?
}

/// The subfolders of folders a tree has shown, kept per pane. A folder is read the first time it is opened; after changes
/// on disk every folder already read is read again off the main actor (`refresh`), so drawing the tree never waits on
/// the disk while files are being saved (a folder of an account can hold tens of thousands of files).
final class FolderTreeCache {
    private var subfolders: [String: [URL]] = [:]
    private var reading: Set<String> = []
    private var announced = false
    /// Called once folders read in the background have arrived, so the tree is drawn again with them.
    var onLoaded: (() -> Void)?

    /// A folder's subfolders, or none yet: a folder not read before is read off the main actor (a folder of an account
    /// can hold tens of thousands of files) and shown when it arrives.
    func children(of url: URL) -> [URL] {
        let key = url.standardizedFileURL.path
        if let known = subfolders[key] { return known }
        if reading.insert(key).inserted {
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) { Self.list(url) }.value
                guard let self else { return }
                self.subfolders[key] = found
                self.reading.remove(key)
                // Many folders arriving together redraw the tree once.
                guard !self.announced else { return }
                self.announced = true
                await Task.yield()
                self.announced = false
                self.onLoaded?()
            }
        }
        return []
    }

    /// Whether a change at `path` (a folder FSEvents names) can change what the tree shows.
    func shows(_ path: String) -> Bool {
        subfolders[path] != nil || subfolders[(path as NSString).deletingLastPathComponent] != nil
    }

    /// Reads every folder the tree has shown again, off the main actor.
    func refresh() async {
        let keys = Array(subfolders.keys)
        let fresh = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: keys.map { ($0, Self.list(URL(fileURLWithPath: $0, isDirectory: true))) })
        }.value
        subfolders = fresh
    }

    nonisolated static func list(_ url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        // lint:allow main-io called only from detached tasks
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return entries.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// A folder in a tree; its subfolders come from the pane's `FolderTreeCache`.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isRoot: Bool
    let rootID: UUID?
    private let cache: FolderTreeCache

    init(url: URL, name: String? = nil, isRoot: Bool = false, rootID: UUID? = nil, cache: FolderTreeCache) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isRoot = isRoot
        self.rootID = rootID
        self.cache = cache
    }

    var id: String { url.path }

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.url == rhs.url && lhs.isRoot == rhs.isRoot }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    var children: [FolderNode]? {
        let folders = cache.children(of: url).map { FolderNode(url: $0, cache: cache) }
        return folders.isEmpty ? nil : folders
    }
}

/// The Library pane of one window: the selected folder and its contents (SPEC section 17).
@Observable
final class LibraryModel: MediaGridOwner {
    @ObservationIgnored weak var window: WindowModel?
    @ObservationIgnored private let listenerID = UUID()
    @ObservationIgnored private var cachedTree: (key: String, nodes: [FolderNode])?
    @ObservationIgnored let treeCache = FolderTreeCache()
    @ObservationIgnored private var treeRefresh: Task<Void, Never>?

    /// The library folders, then a save folder chosen outside the library (D-70). The nodes, and the subfolders each has
    /// read, are kept until the tree changes, so a redraw does not read every open folder from disk again.
    func treeNodes() -> [FolderNode] {
        let roots = app.roots
        let key = "\(treeRevision)|\(roots.map { "\($0.id)\($0.name)\($0.path)" })|\(otherFolder?.path ?? "")"
        if let cachedTree, cachedTree.key == key { return cachedTree.nodes }
        var nodes = roots.map { FolderNode(url: $0.url, name: $0.name, isRoot: true, rootID: $0.id, cache: treeCache) }
        if let other = otherFolder, app.root(containing: other) == nil {
            nodes.append(FolderNode(url: other, name: other.lastPathComponent, isRoot: true, rootID: nil, cache: treeCache))
        }
        cachedTree = (key, nodes)
        return nodes
    }
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    init() {
        treeCache.onLoaded = { [weak self] in self?.treeRevision += 1 }
        // The folder's own watch sees only its direct contents; analysis watches the library recursively (FSEvents),
        // which covers subfolders when they are included (R-1704).
        AppModel.shared.analysis.onFolderChange[listenerID] = { [weak self] paths in self?.foldersChanged(paths) }
    }

    isolated deinit {
        AppModel.shared.analysis.onFolderChange[listenerID] = nil
        // This window's save folder outside the library is no longer watched.
        Task { @MainActor in AppModel.shared.analysis.updateWatch() }
        // A closed window's work stops with it; the watcher's cancel handler closes its file descriptor.
        watcher?.cancel()
        for task in [changeTask, filterTask, reloadTask, duplicateTask, treeRefresh, checkTask] {
            task?.cancel()
        }
    }

    /// Folders changed anywhere in the library (FSEvents through analysis): the tree follows Finder changes in any folder
    /// it shows (R-1704), and the listing follows its subfolders when they are included.
    private func foldersChanged(_ paths: [String]) {
        let paths = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        // A folder above the selected one renamed or trashed in the Finder sends no event to the folder's own watch.
        followSelectedFolder()
        if paths.contains(where: treeCache.shows) { invalidateTree() }
        guard includeSubfolders, let folder = selectedFolder?.standardizedFileURL.path else { return }
        if paths.contains(where: { $0.hasPrefix(folder + "/") }) { scheduleChangeReload() }
    }

    /// Bursts of changes (a download writing many files) reload once.
    private func scheduleChangeReload() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.reload()
            self.invalidateTree()
        }
    }
    var selectedFolder: URL? {
        didSet {
            guard selectedFolder != oldValue else { return }
            check = nil
            reload()
            watch()
            findAccount()
        }
    }

    /// The last Check Folder result for the selected folder (R-1713), and whether one is running.
    var check: FolderCheck.Report?
    var checking = false

    /// Check Folder: reads every file once and reports what no longer matches what was saved; changes nothing (R-1713).
    /// A second Check Folder, or closing the window, stops the one running.
    func checkFolder(_ folder: URL) {
        selectedFolder = folder
        check = nil
        checking = true
        let archive = app.root(containing: folder)?.layout == .archive
        checkTask?.cancel()
        let work = Task.detached(priority: .userInitiated) { FolderCheck.run(folder, archive: archive) }
        checkTask = Task { [weak self] in
            let report = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let self else { return }
            self.checking = false
            if self.selectedFolder == folder { self.check = report }
        }
    }

    @ObservationIgnored private var checkTask: Task<Void, Never>?

    /// Trash Extra Copies (R-3305): one file of each duplicate group here stays, the others go to the Trash as one
    /// operation, after a confirmation; ⌘Z puts them all back.
    func trashExtraCopies() {
        guard let report = duplicates else { return }
        let here = Set(files.map(\.url.standardizedFileURL.path))
        // Copies of each other side by side in one folder: one of them stays there, and copies in other folders (another
        // account's folder, a collab post saved twice, a subfolder shown with Include Subfolders) are never touched
        // (audits 2 and 3, C2-M6, B3-M5).
        let groups = report.groups.flatMap { group -> [(members: [URL], identical: Bool)] in
            let inHere = group.members.filter { here.contains($0.standardizedFileURL.path) }
            return Dictionary(grouping: inHere) { $0.deletingLastPathComponent().standardizedFileURL.path }.values
                .filter { $0.count > 1 }.map { ($0, group.identical) }
        }
        guard !groups.isEmpty else {
            message = "No file here has a copy in this same folder."
            return
        }
        let members = groups.map(\.members)
        let alike = groups.filter { !$0.identical }.count
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) { ExtraCopies.plan(members) }.value
            guard let self, !plan.trash.isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "Move \(plan.trash.count) extra cop\(plan.trash.count == 1 ? "y" : "ies") in this folder to the Trash?"
            alert.informativeText = "One file of each of the \(groups.count) groups stays: the largest picture, then one with a "
                + "metadata file, then the oldest. This frees \(Format.bytes(plan.bytes))."
                + (alike > 0 ? " \(alike) of the groups only look alike, so their files are not identical." : "")
                + " Undo puts everything back."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.perform(FolderOperations.trash(plan.trash))
        }
    }

    /// The Instagram account whose folder the selected folder is, or is inside (D-78), for the one-click Update (D-80).
    var account: AccountFolders.Match?
    @ObservationIgnored private var accountTask: Task<Void, Never>?

    /// Remembered folders are known at once; any other folder is recognised from its metadata files, off the main actor.
    func findAccount() {
        accountTask?.cancel()
        guard let folder = selectedFolder else {
            account = nil
            return
        }
        let record = app.accountFolder(containing: folder)
        let remembered = record.map { AccountFolders.Match(account: $0.account, folder: URL(fileURLWithPath: $0.path, isDirectory: true)) }
        if let remembered {
            if AccountFolderStore.key(remembered.folder.path) == AccountFolderStore.key(folder.path) {
                account = remembered
                return
            }
            // A folder inside a remembered one may be another account's folder or a Hashtags or Saved posts folder (a library
            // folder that is an account's holds them too): what it holds decides, not the folder around it (audit 5, C5-m6).
            if Self.isCollection(folder, below: remembered.folder) {
                account = nil
                return
            }
        }
        account = nil
        let root = app.root(containing: folder)?.url
        accountTask = Task { [weak self] in
            let match = await Task.detached(priority: .utility) { AccountFolders.detect(folder, stopAt: root) }.value
            guard !Task.isCancelled, let self, self.selectedFolder == folder else { return }
            self.account = Self.preferred(match, over: remembered)
        }
    }

    /// The detected account wins over the remembered folder around it only when it is another account whose own folder is
    /// inside the remembered one; files named after an account's old name never take its folder from it.
    static func preferred(_ detected: AccountFolders.Match?, over remembered: AccountFolders.Match?) -> AccountFolders.Match? {
        guard let remembered else { return detected }
        guard let detected, detected.account != remembered.account else { return remembered }
        let outer = AccountFolderStore.key(remembered.folder.path)
        return AccountFolderStore.key(detected.folder.path).hasPrefix(outer + "/") ? detected : remembered
    }

    /// Whether `folder` is, or is inside, a Hashtags or Saved posts folder below `top`: those hold many accounts' posts.
    static func isCollection(_ folder: URL, below top: URL) -> Bool {
        let names = [SaveTarget.tagsFolder, SaveTarget.savedFolder].map { $0.lowercased() }
        let stop = AccountFolderStore.key(top.path)
        var current = folder.standardizedFileURL
        while current.path != "/", AccountFolderStore.key(current.path).hasPrefix(stop + "/") {
            if names.contains(current.lastPathComponent.lowercased()) { return true }
            current = current.deletingLastPathComponent()
        }
        return false
    }

    /// Whether an update of the account folder `folder` is queued or running.
    func isUpdating(_ folder: URL, account: String? = nil) -> Bool {
        // Compared as the volume compares names (audit 5, C5-m2). A pull of the account into the folder's parent counts too:
        // it finds the account's folder when it starts (D-78), under whatever name it has.
        let own = AccountFolderStore.key(folder.path)
        let named = account.map {
            AccountFolderStore.key(folder.deletingLastPathComponent().appendingPathComponent(FileNaming.safeTopFolder($0)).path)
        }
        // Paused or held by a checkpoint counts too: Resume carries it on.
        return app.jobs.jobs.contains { job in
            guard job.state.canCancel, let destination = job.destination else { return false }
            let key = AccountFolderStore.key(destination.path)
            return key == own || (job.kind == .pull && key == named)
        }
    }

    /// Update an account folder, or find what it is missing (D-79, D-80).
    func update(_ match: AccountFolders.Match, findMissing: Bool = false) {
        Task { [weak self] in
            await self?.app.engines.startUpdate(account: match.account, folder: match.folder, findMissing: findMissing,
                                                window: self?.window)
        }
    }

    /// Update every remembered account folder inside `folder`, one after another (R-1113).
    func updateAll(inside folder: URL) {
        let records = app.accountFolders(inside: folder)
        Task { [weak self] in
            for record in records {
                await self?.app.engines.startUpdate(account: record.account, folder: URL(fileURLWithPath: record.path, isDirectory: true),
                                                    findMissing: false, window: self?.window)
            }
        }
    }

    /// Context menu items for a folder: Update and Find Missing for an account folder, Update All for a folder of them.
    func accountMenuItems(for folder: URL) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let match = accountMatch(for: folder) {
            items.append(ActionMenuItem("Update @\(match.account)") { [weak self] in self?.update(match) })
            items.append(ActionMenuItem("Find Missing from @\(match.account)") { [weak self] in self?.update(match, findMissing: true) })
        }
        let inside = app.accountFolders(inside: folder).count
        if inside > 1 {
            items.append(ActionMenuItem("Update All Accounts (\(inside))") { [weak self] in self?.updateAll(inside: folder) })
        }
        return items
    }

    /// The account of `folder` when MediaPull knows it without reading the folder: remembered, or the selected folder's.
    func accountMatch(for folder: URL) -> AccountFolders.Match? {
        let key = AccountFolderStore.key(folder.path)
        // The selected folder's account is worked out from what it holds (audit 5, C5-m6).
        if let selectedFolder, AccountFolderStore.key(selectedFolder.path) == key { return account }
        guard let record = app.accountFolder(containing: folder) else { return nil }
        let remembered = URL(fileURLWithPath: record.path, isDirectory: true)
        if AccountFolderStore.key(record.path) != key {
            if Self.isCollection(folder, below: remembered) { return nil }
            // A library folder that is an account's folder holds other accounts' folders too: which account a folder in it
            // belongs to is known only once it is selected and read.
            if app.roots.contains(where: { AccountFolderStore.key($0.url.path) == AccountFolderStore.key(record.path) }) { return nil }
        }
        return AccountFolders.Match(account: record.account, folder: remembered)
    }

    /// A save folder outside the library, shown under the library folders until replaced or removed (D-70).
    var otherFolder: URL? {
        didSet { if otherFolder != oldValue { app.analysis.updateWatch() } }
    }

    /// Whether the folder is inside a library folder or the other folder.
    func shows(_ folder: URL) -> Bool {
        if app.root(containing: folder) != nil { return true }
        guard let other = otherFolder?.standardizedFileURL.path else { return false }
        let path = folder.standardizedFileURL.path
        return path == other || path.hasPrefix(other + "/")
    }

    var files: [LibraryFile] = [] {
        didSet { fileIndex = Dictionary(files.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// The folder holds more media than one listing shows (MediaListing.limit); the header says so.
    var listingLimited = false
    /// The files with what analysis knows about them, and the sections the sort and filters produce (section 37).
    var entries: [MediaEntry] = [] {
        didSet { entryIndex = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Grid cells look files up by id for every cell, so lookups go through these instead of scanning the lists.
    @ObservationIgnored private var fileIndex: [String: Int] = [:]
    @ObservationIgnored private var entryIndex: [String: Int] = [:]

    /// A file of the folder, or one inside a folder opened in place in the list view (R-1709).
    private func file(_ id: String) -> LibraryFile? {
        if let index = fileIndex[id] { return files[index] }
        return listFolders.entry(id).map {
            LibraryFile(url: $0.url, name: $0.name, size: $0.size, modified: $0.modified, hasSidecar: $0.source != nil, format: $0.format)
        }
    }

    private func entry(_ id: String) -> MediaEntry? { entryIndex[id].map { entries[$0] } ?? listFolders.entry(id) }

    /// The subfolders shown above the files in the list view, and the folders opened in place.
    @ObservationIgnored let listFolders = FolderChildren()
    @ObservationIgnored var onListChildrenLoaded: ((String) -> Void)?
    var built: [LibrarySection] = []
    var query: LibraryQuery = AppModel.shared.preferences.libraryQuery {
        didSet {
            guard query != oldValue else { return }
            // The sort and filters are kept between launches; the search text is not (D-77).
            var kept = query
            kept.search = ""
            if app.preferences.libraryQuery != kept { app.preferences.libraryQuery = kept }
            listFolders.forgetContents()
            refilter()
        }
    }

    var includeSubfolders: Bool = AppModel.shared.preferences.libraryIncludeSubfolders {
        didSet {
            guard includeSubfolders != oldValue else { return }
            app.preferences.libraryIncludeSubfolders = includeSubfolders
            reload()
        }
    }

    @ObservationIgnored private var filterTask: Task<Void, Never>?
    var subfolderCount = 0
    var selection: Set<String> = []
    var revision = 0
    var treeRevision = 0
    /// The Library pane keeps one thumbnail size; zooming is for the Extracted pane (R-1001a).
    let cellSize: CGFloat = 104
    var message: String?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var details: [String: (PixelSize?, MediaFormat?)] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var app: AppModel { .shared }

    /// Duplicates found under the library folder that holds the selected folder (SPEC section 33).
    var duplicates: DuplicateFinder.Report?
    var duplicateProgress: (done: Int, total: Int)?
    var showOnlyDuplicates = false {
        didSet { revision += 1 }
    }
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?
    /// The scan whose progress may show; a scan that was replaced or stopped reports into nothing.
    @ObservationIgnored private var duplicateScanID = UUID()

    var shownFiles: [LibraryFile] {
        let queried = built.flatMap(\.items).compactMap { file($0.path) }
        guard showOnlyDuplicates, let duplicates else { return queried }
        // Copies sit next to each other.
        return queried.filter { duplicates.group(for: $0.url) != nil }
            .sorted {
                (duplicates.groupOf[$0.url.standardizedFileURL.path] ?? 0, $0.name)
                    < (duplicates.groupOf[$1.url.standardizedFileURL.path] ?? 0, $1.name)
            }
    }

    var sections: [GridSection] {
        guard !showOnlyDuplicates, built.count > 1 else { return [GridSection(id: "files", title: "", ids: shownFiles.map(\.id))] }
        return built.enumerated().map { GridSection(id: "\($0.offset)", title: $0.element.title ?? "", ids: $0.element.items.map(\.path)) }
    }

    /// Recomputes what is shown from the files, the sort, the filters and the search (off the main actor).
    func refilter() {
        filterTask?.cancel()
        // One event gap everywhere: Settings, the Sort menu and Sort by Event (B9).
        var adjusted = query
        adjusted.eventGap = app.preferences.eventGapHours * 3600
        let entries = entries, query = adjusted
        filterTask = Task { [weak self] in
            guard let self else { return }
            if !query.search.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let context = await self.app.analysis.queryContext(for: query, entries: entries)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { query.apply(entries, context: context) }.value
            guard !Task.isCancelled else { return }
            self.built = result
            self.revision += 1
        }
    }

    func duplicateGroup(for file: URL) -> DuplicateFinder.Group? {
        guard app.preferences.highlightDuplicates else { return nil }
        return duplicates?.group(for: file)
    }

    /// Duplicates in the folder being shown.
    var duplicatesHere: Int {
        guard let duplicates else { return 0 }
        return files.count { duplicates.group(for: $0.url) != nil }
    }

    @ObservationIgnored private var pendingReveal: URL?

    /// Shows a file in this pane: selects it, opening its folder first when needed.
    func reveal(_ url: URL) {
        let folder = url.deletingLastPathComponent().standardizedFileURL
        if selectedFolder?.standardizedFileURL == folder {
            selectRevealed(url)
        } else {
            pendingReveal = url
            selectedFolder = folder
        }
    }

    private func selectRevealed(_ url: URL) {
        guard let file = files.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        if showOnlyDuplicates, duplicates?.group(for: url) == nil { showOnlyDuplicates = false }
        selection = [file.id]
        revision += 1
        window?.showInPreview(.file(file.url))
    }

    func scanDuplicates() {
        duplicateTask?.cancel()
        let scanID = UUID()
        duplicateScanID = scanID
        guard app.preferences.highlightDuplicates, let folder = selectedFolder, let root = app.root(containing: folder)?.url else {
            duplicates = nil
            duplicateProgress = nil
            showOnlyDuplicates = false
            revision += 1
            return
        }
        let finder = app.duplicates
        let sensitivity = app.preferences.duplicateSensitivity
        duplicateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let report = await finder.scan(root: root, sensitivity: sensitivity) { done, total in
                Task { @MainActor in
                    guard let self, self.duplicateScanID == scanID else { return }
                    self.duplicateProgress = total > 30 && done < total ? (done, total) : nil
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.duplicates = report
            self.duplicateProgress = nil
            self.revision += 1
        }
    }

    func reload() {
        reloadTask?.cancel()
        guard let folder = selectedFolder else {
            files = []
            return
        }
        let recursive = includeSubfolders
        reloadTask = Task { [weak self] in
            let (listed, folders, subfolders, limited) = await MediaListing.load(folder, recursive: recursive)
            guard !Task.isCancelled, let self, self.selectedFolder == folder else { return }
            let attached = await self.app.analysis.attach(listed)
            guard !Task.isCancelled, self.selectedFolder == folder else { return }
            let loaded = await Task.detached(priority: .userInitiated) {
                attached.map {
                    let sidecar = $0.source != nil || FileManager.default.fileExists(atPath: Sidecar.sidecarURL(for: $0.url).path)
                    return LibraryFile(url: $0.url, name: $0.name, size: $0.size, modified: $0.modified,
                                       hasSidecar: sidecar, format: $0.format)
                }
            }.value
            guard !Task.isCancelled, self.selectedFolder == folder else { return }
            // A file changed in place (an edit saved over it) is measured again.
            let previous = Dictionary(self.files.map { ($0.id, $0.modified) }, uniquingKeysWith: { first, _ in first })
            for file in loaded where previous[file.id].map({ $0 != file.modified }) ?? false {
                self.details[file.id] = nil
            }
            self.entries = attached
            self.files = loaded
            self.listingLimited = limited
            self.listFolders.reset(top: subfolders)
            self.refilter()
            self.subfolderCount = folders
            self.selection = self.selection.intersection(Set(loaded.map(\.id)))
            self.revision += 1
            if let pending = self.pendingReveal {
                self.pendingReveal = nil
                self.selectRevealed(pending)
            }
            self.scanDuplicates()
        }
    }

    /// New analysis results for the files already listed, without listing the folder again.
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

    private func watch() {
        watchedDescriptor = -1
        watcher?.cancel()
        watcher = nil
        guard let folder = selectedFolder else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.followSelectedFolder()
                self?.scheduleChangeReload()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        watchedDescriptor = descriptor
    }

    /// The selected folder's open descriptor while it is watched (closed by the watcher's cancel handler), else -1.
    @ObservationIgnored private var watchedDescriptor: Int32 = -1

    func refreshTree() {
        invalidateTree()
        reload()
    }

    func promptForRoot() {
        FolderPicker.chooseFolder(title: "Choose a Library Folder", prompt: "Add Folder",
                                  start: AppModel.suggestedRootURL.deletingLastPathComponent(),
                                  window: window?.hostWindow) { [weak self] url in
            guard let url else { return }
            Task {
                await self?.app.addRoot(url, makeDefault: self?.app.roots.isEmpty ?? true)
                self?.selectedFolder = url
            }
        }
    }

    // MARK: Folder operations

    /// The folder being renamed in place in the tree (no pop-up, D-69).
    var renaming: String?

    /// Through the journal, so ⌘Z takes it back (SPEC 21, R-3806), then renamed in place.
    func newFolder(in parent: URL) {
        let plan = FolderOperations.newFolder(named: "New Folder", in: parent)
        guard let url = plan.foldersToCreate.first else { return }
        perform(plan) { [weak self] entry in
            guard let self, entry.failures.isEmpty else { return }
            self.selectedFolder = url
            self.renaming = url.path
        }
    }

    func rename(_ url: URL) {
        renaming = url.path
    }

    func commitRename(_ url: URL, to text: String) {
        renaming = nil
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let plan = FolderOperations.rename(url, to: name)
        guard let destination = plan.moves.first?.destination else { return }
        perform(plan) { [weak self] entry in
            guard let self, entry.failures.isEmpty else { return }
            self.selectedFolder = self.selectedFolder.map { Self.moved($0, from: url, to: destination) }
            self.otherFolder = self.otherFolder.map { Self.moved($0, from: url, to: destination) }
        }
    }

    /// Folders changed on disk: the tree reads the folders it has shown again (off the main actor), then redraws. Bursts
    /// (a download creating folders) are read once.
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

    /// Folders MediaPull moved to the Trash (from any window or section): the save folder inside one goes to the folder
    /// above, as `trash` does for the Library's own (audit 4, B4-m2).
    func foldersTrashed(_ paths: [String]) {
        let gone = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let other = otherFolder, gone.contains(where: { Self.isInside(other, $0) }) { otherFolder = nil }
        if let folder = selectedFolder, let top = gone.first(where: { Self.isInside(folder, $0) }) {
            let parent = top.deletingLastPathComponent()
            selectedFolder = shows(parent) ? parent : app.defaultRoot?.url
        }
    }

    /// The selected folder was renamed, moved or put in the Trash in the Finder (its watch says so): the pane, and with it
    /// Save, follows it, or goes to the folder above when it is in the Trash (audit 4, B4-m2). The open descriptor knows
    /// where the folder is now. A library folder itself renamed is followed when MediaPull becomes active (R-1702).
    private func followSelectedFolder() {
        guard let old = selectedFolder?.standardizedFileURL, watchedDescriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(watchedDescriptor, F_GETPATH, &buffer) != -1 else { return }
        let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        let now = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard now.path != old.path else { return }
        if FileFlags.isInTrash(now) {
            foldersTrashed([old.path])
        } else if shows(now) || otherFolder?.standardizedFileURL == old {
            rootMoved(from: old, to: now)
        }
    }

    /// A library folder was renamed or moved in the Finder: the selection follows it.
    func rootMoved(from old: URL, to new: URL) {
        selectedFolder = selectedFolder.map { Self.moved($0, from: old, to: new) }
        otherFolder = otherFolder.map { Self.moved($0, from: old, to: new) }
        invalidateTree()
    }

    /// Moves files (with their sidecars) or folders to the Trash, as one change ⌘Z puts back. Nothing is deleted outright.
    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // A library folder, or a folder holding one, is removed from the library, never moved to the Trash from here.
        let plan = FolderOperations.trash(urls)
        guard !refusesLibraryFolderChange(plan) else { return }
        // The save folder or one of its parents goes to the Trash: save into the folder above instead.
        if let folder = selectedFolder, let gone = urls.first(where: { Self.isInside(folder, $0) }) {
            selectedFolder = gone.deletingLastPathComponent()
        }
        if let other = otherFolder, urls.contains(where: { Self.isInside(other, $0) }) { otherFolder = nil }
        perform(plan)
    }

    /// A library folder, or a folder that holds one, is never moved, renamed or trashed as a file: its saves, records and
    /// analysis would lose it. The same rule as in Organise (audit 4, B4-M2); copies are fine.
    private func refusesLibraryFolderChange(_ plan: OrganisePlan) -> Bool {
        guard plan.changes(anyOf: app.roots.map(\.url)) else { return false }
        message = "A library folder, or a folder that holds one, is not moved, renamed or moved to the Trash here. "
            + "Use Rename in List or Remove from Library in its menu."
        return true
    }

    /// Runs a file change through the journal (undoable with ⌘Z, R-3806) and shows its problems, if any.
    /// It runs as a job, so Quit waits for it to stop between files (R-3807); copies and long changes show in Activity.
    func perform(_ plan: OrganisePlan, then finished: ((JournalEntry) -> Void)? = nil) {
        guard !plan.isEmpty, !refusesLibraryFolderChange(plan) else { return }
        let app = app
        let job = Job(kind: .organise, title: plan.title)
        job.total = plan.moves.count + plan.itemsToTrash.count + plan.foldersToCreate.count + plan.foldersToTrash.count
        job.state = .running
        let listed = plan.showsInActivity
        app.jobs.add(job)
        job.task = Task { [weak self] in
            let entry = await app.applyChange(plan) { done, total in
                Task { @MainActor in
                    job.fraction = Double(done) / Double(max(total, 1))
                    job.summaryOverride = "\(done) of \(total) steps"
                }
            }
            job.summaryOverride = entry.fileCount > 0 ? "\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")" : nil
            app.jobs.finish(job, entry.finished ? (entry.failures.isEmpty ? .completed : .failed("Some files could not be changed"))
                : .cancelled)
            if !listed, entry.failures.isEmpty { app.jobs.jobs.removeAll { $0 === job } }
            guard let self else { return }
            self.message = entry.failures.isEmpty ? nil : entry.failures.prefix(3).joined(separator: "\n")
            if !entry.steps.isEmpty { self.window?.registerUndo(entry) }
            finished?(entry)
            self.invalidateTree()
            self.reload()
        }
    }

    static func isInside(_ folder: URL, _ parent: URL) -> Bool {
        let path = folder.standardizedFileURL.path, top = parent.standardizedFileURL.path
        return path == top || path.hasPrefix(top + "/")
    }

    /// `folder` after `from` was renamed to `to`, when it is `from` or inside it.
    static func moved(_ folder: URL, from: URL, to: URL) -> URL {
        guard isInside(folder, from) else { return folder }
        let rest = folder.standardizedFileURL.path.dropFirst(from.standardizedFileURL.path.count)
        return URL(fileURLWithPath: to.standardizedFileURL.path + rest, isDirectory: true)
    }

    // MARK: Drops

    /// Files dropped into a folder: moved within the library, copied from elsewhere, converted when
    /// the folder uses the Archive layout (SPEC R-1801).
    func importFiles(_ urls: [URL], into folder: URL, move: Bool) {
        let target = app.target(for: folder)
        let converter = MediaConverter(ffmpeg: app.ffmpeg, svgRasterizer: SVGRasterizer.rasterize)
        let policy = app.preferences.conversion
        let urls = Sidecar.withoutCompanions(urls)
            .filter { $0.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL }
        // Files that an Archive folder needs in a normal format are converted on the way in (a new file, like a save);
        // everything else is moved or copied as one journaled change that ⌘Z takes back (R-3806).
        let converts = move ? [] : urls.filter { url in
            guard target.layout == .archive, let format = MediaFormat.fromExtension(url.pathExtension) else { return false }
            return !format.isNormal
        }
        let rest = urls.filter { !converts.contains($0) }
        if !rest.isEmpty {
            perform(move ? FolderOperations.move(rest, to: folder) : FolderOperations.copy(rest, to: folder))
        }
        guard !converts.isEmpty else { return }
        Task {
            var problems: [String] = []
            for url in converts {
                do {
                    let work = SavePipeline.defaultWorkDirectory.appendingPathComponent("import-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: work) }
                    let result = try await converter.convert(url, policy: policy, layout: .archive, workDirectory: work)
                    let stem = url.deletingPathExtension().lastPathComponent
                    let name = FileNaming.fileName(stem: stem, ext: result.format.fileExtension)
                    let output = Self.uniqueURL(folder.appendingPathComponent(name))
                    let converted = result.converted, convertedURL = result.url
                    try await Self.offMain {
                        if converted {
                            try FileManager.default.moveItem(at: convertedURL, to: output) // lint:allow main-io inside offMain
                        } else {
                            try FileManager.default.copyItem(at: url, to: output) // lint:allow main-io inside offMain
                        }
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            message = problems.isEmpty ? nil : problems.prefix(3).joined(separator: "\n")
            invalidateTree()
            reload()
        }
    }

    nonisolated static func offMain(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// Where a rename lands: the name asked for when only its case changes (the volume sees the same file), otherwise
    /// a free name.
    static func renameTarget(from source: URL, to target: URL) -> URL {
        source.standardizedFileURL.path.lowercased() == target.standardizedFileURL.path.lowercased() ? target : uniqueURL(target)
    }

    /// A free name for `url`: neither the file nor a metadata file of that name may exist, so a later sidecar write never
    /// replaces an orphaned one.
    /// `replacing` is the file an edit replaces: its own metadata file goes with the edit, so it does not take the name
    /// (audit 3, B3-M1).
    nonisolated static func uniqueURL(_ url: URL, replacing: URL? = nil) -> URL {
        func free(_ candidate: URL) -> Bool {
            let fm = FileManager.default
            let ownSidecar = replacing.map { $0.standardizedFileURL == candidate.standardizedFileURL } ?? false
            return !fm.fileExists(atPath: candidate.path) && (ownSidecar || !fm.fileExists(atPath: Sidecar.sidecarURL(for: candidate).path))
        }
        guard !free(url) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            if free(candidate) { return candidate }
            counter += 1
        }
    }

    /// Handles anything dropped on a folder: extracted items are saved, files are copied or moved.
    func handleDrop(_ pasteboard: NSPasteboard, into folder: URL, operation: NSDragOperation) -> Bool {
        let payloads = ItemDragPayload.read(from: pasteboard)
        if !payloads.isEmpty {
            for (windowID, group) in Dictionary(grouping: payloads, by: \.window) {
                guard let source = app.window(windowID) else { continue }
                source.save(group.map(\.id), to: folder)
            }
            return true
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        let inLibrary = urls.allSatisfy { app.root(containing: $0) != nil }
        importFiles(urls, into: folder, move: operation.contains(.move) && inLibrary && !NSEvent.modifierFlags.contains(.option))
        return true
    }

    // MARK: Grid owner

    func gridInfo(_ id: String) -> GridCellInfo? {
        guard let file = file(id) else { return nil }
        var detail: [String] = []
        if let facts = entryIndex[id].map({ entries[$0] })?.facts, let w = facts.pixelWidth, let h = facts.pixelHeight {
            detail.append("\(w) × \(h)")
        } else if let (size, _) = details[id], let size { detail.append(size.label) }
        detail.append(file.format?.label ?? file.url.pathExtension.uppercased())
        var info = GridCellInfo(title: file.name, detail: detail.joined(separator: " · "), secondary: Format.bytes(file.size))
        info.stamp = "\(file.modified.timeIntervalSinceReferenceDate)-\(file.size)"
        info.tagColors = GridCellInfo.tagColors(entryIndex[id].map { entries[$0].finderTags } ?? [])
        switch file.format?.kind {
        case .video: info.kindSymbol = "play.fill"; info.placeholderSymbol = "film"
        case .audio: info.kindSymbol = "music.note"; info.placeholderSymbol = "waveform"
        default: break
        }
        if file.hasSidecar {
            info.stateSymbol = "text.badge.checkmark"
            info.stateColor = .secondaryLabelColor
        }
        if let group = duplicateGroup(for: file.url), let duplicates {
            let identical = duplicates.isIdentical(file.url)
            let color: NSColor = identical ? .systemOrange : .systemPurple
            info.highlight = color
            info.stateSymbol = identical ? "doc.on.doc.fill" : "square.on.square"
            info.stateColor = color
            info.secondary += " · \(group.members.count - 1) other\(group.members.count == 2 ? "" : "s")"
        }
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        // The column view shows files before the pane has read their folder; ids are paths, so those load directly.
        guard let file = file(id) else {
            if listFolders.isFolder(id) { return nil }
            return await app.thumbnails.localThumbnail(for: URL(fileURLWithPath: id), maxPixel: maxPixel)?.image
        }
        let measured = entryIndex[id].map { entries[$0] }?.facts?.pixelWidth != nil
        if details[id] == nil, !measured, file.format?.kind == .image || file.format?.kind == .animatedImage {
            let url = file.url
            if let analysis = await Task.detached(priority: .utility, operation: { ImageConversion.analyze(url) }).value {
                details[id] = (PixelSize(width: analysis.width, height: analysis.height), analysis.format)
                revision += 1
            }
        }
        return await app.thumbnails.localThumbnail(for: file.url, maxPixel: maxPixel)?.image
    }

    func gridSelectionChanged(_ ids: Set<String>) {
        selection = ids
        if ids.count == 1, let id = ids.first, let url = fileURL(id) { window?.showInPreview(.file(url)) }
    }

    /// The selected files and folders.
    var selectedURLs: [URL] {
        selection.sorted().compactMap { id in
            fileURL(id) ?? (listFolders.isFolder(id) ? URL(fileURLWithPath: id, isDirectory: true) : nil)
        }
    }

    /// A media file's address from its id, also for a file the pane has not listed yet (a column view click in another
    /// folder arrives before that folder's listing).
    private func fileURL(_ id: String) -> URL? {
        if let file = file(id) { return file.url }
        guard id.hasPrefix("/"), !listFolders.isFolder(id), MediaFormat.fromExtension(URL(fileURLWithPath: id).pathExtension) != nil
        else { return nil }
        return URL(fileURLWithPath: id)
    }

    /// A folder (a row of the list or column view) opens in the pane, as in the Finder.
    func gridActivate(_ id: String) {
        if listFolders.isFolder(id) {
            selectedFolder = URL(fileURLWithPath: id, isDirectory: true)
            return
        }
        guard let url = fileURL(id) else { return }
        NSWorkspace.shared.open(url)
    }

    func gridQuickLook() {
        QuickLook.shared.show(selection.sorted().compactMap { fileURL($0) })
    }

    /// Return renames and ⌘⌫ moves to the Trash, in the grid as in the folder tree (R-1707). The editor holds the name.
    func gridReturn(_ id: String) {
        guard let url = fileURL(id) else { return gridActivate(id) }
        window?.openEditor(EditorRequest(subject: .file(url)))
    }

    func gridDelete(_ ids: Set<String>) {
        trash(ids.sorted().compactMap { id in listFolders.isFolder(id) ? URL(fileURLWithPath: id, isDirectory: true) : file(id)?.url })
    }

    func gridAppeared(_: String) {}

    func gridFocused() { window?.focusedPane = .library }

    func gridWriter(_ id: String) -> NSPasteboardWriting? {
        if listFolders.isFolder(id) { return URL(fileURLWithPath: id, isDirectory: true) as NSURL }
        return file(id).map { $0.url as NSURL }
    }

    /// Library items dragged to the Finder are copied with their metadata files (R-1801).
    func gridCompanionWriters(_ ids: [String]) -> [NSPasteboardWriting] {
        ids.compactMap { file($0) }.filter(\.hasSidecar).map { Sidecar.sidecarURL(for: $0.url) as NSURL }
    }

    var gridAcceptsDrops: Bool { selectedFolder != nil }

    func gridCanAccept(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.types?.contains(DragTypes.items) == true
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation: NSDragOperation) -> Bool {
        guard let folder = selectedFolder else { return false }
        return handleDrop(pasteboard, into: folder, operation: operation)
    }

    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation: NSDragOperation, into folder: URL) -> Bool {
        handleDrop(pasteboard, into: folder, operation: operation)
    }

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        let folders = ids.filter(listFolders.isFolder).sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        if !folders.isEmpty { return folderMenu(folders) }
        let chosen = ids.sorted().compactMap(file)
        guard !chosen.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Open") { chosen.forEach { NSWorkspace.shared.open($0.url) } })
        menu.addItem(ActionMenuItem("Quick Look") { [weak self] in self?.gridQuickLook() })
        menu.addItem(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen.map(\.url)) })
        if chosen.count == 1, let file = chosen.first, let group = duplicateGroup(for: file.url),
           let root = duplicates?.root
        {
            let copies = NSMenu()
            for other in group.members where other != file.url.standardizedFileURL {
                let relative = String(other.path.dropFirst(root.standardizedFileURL.path.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let kind = duplicates?.areIdentical(file.url, other) == true ? "Identical" : "Looks alike"
                copies.addItem(ActionMenuItem("\(relative.isEmpty ? other.lastPathComponent : relative) (\(kind))") { [weak self] in
                    self?.reveal(other)
                })
            }
            let item = NSMenuItem(title: "Copies and Look-alikes", action: nil, keyEquivalent: "")
            item.submenu = copies
            menu.addItem(item)
        }
        if chosen.count == 1, let file = chosen.first {
            menu.addItem(ActionMenuItem(
                file.format?.kind == .image ? "Edit…" : (file.format?.kind == .video ? "Edit Video…" : "Rename…")
            ) { [weak self] in
                self?.window?.openEditor(EditorRequest(subject: .file(file.url)))
            })
            if file.hasSidecar {
                menu.addItem(ActionMenuItem("Show Metadata File") {
                    NSWorkspace.shared.activateFileViewerSelecting([Sidecar.sidecarURL(for: file.url)])
                })
            }
        }
        let convertible = chosen.filter { !($0.format?.isNormal ?? true) && $0.format?.kind != .audio && $0.format != .svg }
        if !convertible.isEmpty {
            menu.addItem(.separator())
            // Named by what comes out: videos become MP4, animations GIF, still pictures JPEG or PNG (section 16).
            let videos = convertible.filter { $0.format?.kind == .video }.count
            let animated = convertible.filter { entry($0.id)?.facts?.isAnimated == true || $0.format?.kind == .animatedImage }.count
            let title = videos == convertible.count ? "Convert to MP4"
                : animated == convertible.count ? "Convert to GIF"
                : videos + animated == 0 ? "Convert to JPEG or PNG"
                : "Convert to Normal Formats"
            menu.addItem(ActionMenuItem(title) { [weak self] in
                guard let self else { return }
                self.app.convertFiles(convertible.map(\.url), destination: nil, policy: self.app.preferences.conversion) { _, _ in }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(chosen.map { $0.url as NSURL })
        })
        menu.addItem(ActionMenuItem("Move to Trash") { [weak self] in self?.trash(chosen.map(\.url)) })
        return menu
    }

    /// Folder rows of the list or column view: open in the pane, show in the Finder, move to the Trash.
    private func folderMenu(_ folders: [URL]) -> NSMenu {
        let menu = NSMenu()
        if folders.count == 1, let folder = folders.first {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.selectedFolder = folder })
        }
        menu.addItem(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(folders) })
        if folders.count == 1, let folder = folders.first {
            menu.addItem(ActionMenuItem("Check Folder") { [weak self] in self?.checkFolder(folder) })
            let items = accountMenuItems(for: folder)
            if !items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move to Trash") { [weak self] in self?.trash(folders) })
        return menu
    }
}

// MARK: - List view (R-1709)

extension LibraryModel: MediaListOwner {
    var listColumns: [ListColumn] { ListColumn.fileColumns }

    func listText(_ id: String, _ column: ListColumn) -> String {
        if listFolders.isFolder(id) {
            return ListText.folder(id, column) { [weak self] id in self?.onListChildrenLoaded?(id) }
        }
        guard let entry = entry(id) else { return "" }
        return ListText.entry(entry, column, measured: details[id]?.0 ?? nil)
    }

    var listSort: (column: ListColumn, ascending: Bool)? {
        ListColumn(librarySort: query.sort).map { ($0, query.ascending) }
    }

    func listSortChanged(_ column: ListColumn, ascending: Bool) {
        guard let sort = column.librarySort else { return }
        query.sort = sort
        query.ascending = ascending
    }

    func listCanSort(_ column: ListColumn) -> Bool { column.librarySort != nil }

    /// Subfolders come first, as in the Finder, unless the list is flat: search, Include Subfolders, duplicates or groups.
    var listTopFolders: [String] {
        let flat = !query.search.trimmingCharacters(in: .whitespaces).isEmpty || includeSubfolders || showOnlyDuplicates || built.count > 1
        return flat ? [] : listFolders.top
    }

    func listIsFolder(_ id: String) -> Bool { listFolders.isFolder(id) }

    var listGeneration: Int { listFolders.generation }

    func listChildren(_ folderID: String) -> [String]? {
        listFolders.onLoaded = { [weak self] id in self?.onListChildrenLoaded?(id) }
        return listFolders.contents(of: folderID, query: query)
    }

    /// Return renames a folder row, as in the tree (R-1707, audit 4, B4-m1).
    var listRenamesFolders: Bool { true }

    func listRenameFolder(_ id: String, to name: String) {
        commitRename(URL(fileURLWithPath: id, isDirectory: true), to: name)
    }
}

extension LibraryModel: MediaColumnsOwner {
    var columnBase: URL? { nil }

    /// The library folders, then the save folder outside them (D-70), as in the folder tree.
    var columnRoots: [URL] {
        let roots = app.roots.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        guard let other = otherFolder, app.root(containing: other) == nil else { return roots }
        return roots + [other]
    }

    var columnFolder: URL? { selectedFolder }

    func columnFolderChanged(_ folder: URL) { selectedFolder = folder }

    func columnNoteFolders(_ ids: [String]) { listFolders.note(ids) }
}
