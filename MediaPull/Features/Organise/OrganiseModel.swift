import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullStore
import Observation

/// The automatic sorts Organise offers (R-3803).
enum AutoSort: String, CaseIterable, Identifiable {
    case date, event, source, subject, person, screenshots, place, artist, album

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
        case .artist: "Artist"
        case .album: "Album"
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
        case .artist: "Audio: artist, then album"
        case .album: "Audio: one folder per album"
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
        case .artist: "music.mic"
        case .album: "square.stack"
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
    case sort, people, details, history

    var label: String {
        switch self {
        case .sort: "Sort"
        case .people: "People"
        case .details: "Details"
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
                rememberRoot()
            }
        }
    }

    /// The top folder's bookmark, so a folder renamed or moved in the Finder is followed (audit 5, B5-M1).
    @ObservationIgnored private(set) var rootBookmark: (path: String, data: Data)?

    private func rememberRoot() {
        rootBookmark = nil
        guard let root else { return }
        Task { [weak self] in
            let data = await Task.detached { try? root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
                .value
            guard let self, self.root == root, let data else { return }
            self.rootBookmark = (root.standardizedFileURL.path, data)
        }
    }

    var folder: URL? {
        didSet {
            if folder != oldValue {
                selection = []
                reload()
                // The last folder's profile never shows for this one while it is worked out.
                profileSource = nil
                detectProfile()
            }
        }
    }

    /// What the folder can be shown as in the Profile view (D-113), worked out off the main actor; nil when it is not one.
    var profileSource: ProfileSource?
    /// Bumped when the folder's files change, so an open Profile view reads them again.
    var profileRevision = 0
    @ObservationIgnored private var profileTask: Task<Void, Never>?

    /// `changed`: the folder's files changed (a burst of file events is taken once), so an open Profile view reads them again.
    func detectProfile(changed: Bool = false) {
        profileTask?.cancel()
        guard let folder else {
            profileSource = nil
            return
        }
        profileTask = Task { [weak self] in
            if changed { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let work = Task.detached(priority: .utility) { ProfileDetector.detect(folder) }
            let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            if found != self.profileSource { self.profileSource = found }
            if changed { self.profileRevision += 1 }
        }
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

    /// Duplicates in the folder this pane has open (R-3301, D-114).
    let duplicates = DuplicateScan()
    @ObservationIgnored private var pendingReveal: URL?

    init(role: Role) {
        defer {
            treeCache.onLoaded = { [weak self] in self?.treeRevision += 1 }
            duplicates.onChange = { [weak self] in self?.revision += 1 }
        }
        self.role = role
    }

    func scanDuplicates() {
        let inLibrary = root.map { app.root(containing: $0)?.url.standardizedFileURL == $0.standardizedFileURL } ?? false
        duplicates.scan(root: root, inLibrary: inLibrary)
    }

    /// Files shown here that have copies.
    var duplicatesHere: Int { duplicates.count(in: entries.map(\.url)) }

    func trashExtraCopies(confirm: @escaping @MainActor (String, String) -> Bool = DuplicateScan.ask) {
        guard let owner else { return }
        if let note = duplicates.trashExtraCopies(here: entries.map(\.url), confirm: confirm, perform: { owner.run($0) }) {
            owner.message = note
        }
    }

    /// Shows a file in this pane: opens its folder when it is inside the pane's folder, then selects it.
    func reveal(_ url: URL) {
        guard let root, url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if folder?.standardizedFileURL == parent, !includeSubfolders || entry(url.standardizedFileURL.path) != nil {
            selectRevealed(url)
        } else {
            pendingReveal = url
            folder = parent
        }
    }

    private func selectRevealed(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let match = entries.first(where: { $0.url.standardizedFileURL.path == path }) else { return }
        if duplicates.showOnly, duplicates.group(for: url) == nil { duplicates.showOnly = false }
        selection = [match.path]
        revision += 1
    }

    isolated deinit {
        for task in [treeRefresh, loadTask, filterTask, profileTask] {
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
            if let shown = self.owner?.details, shown.pane == self.role,
               !FileManager.default.fileExists(atPath: shown.url.path)
            {
                self.owner?.details = nil
            }
            self.loading = false
            self.refilter()
            self.scanDuplicates()
            if let pending = self.pendingReveal {
                self.pendingReveal = nil
                self.selectRevealed(pending)
            }
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
        // One event gap everywhere: Settings, the Sort menu and Sort by Event (B9).
        var adjusted = query
        adjusted.eventGap = app.preferences.eventGapHours * 3600
        let entries = entries, query = adjusted
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
        if duplicates.showOnly, duplicates.report != nil {
            return [GridSection(id: "duplicates", title: "", ids: duplicates.onlyDuplicates(shown, url: \.url).map(\.path))]
        }
        return sections.enumerated().map {
            GridSection(id: "\($0.offset)", title: $0.element.title ?? "", ids: $0.element.items.map(\.path))
        }
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
        if entry.kind == .audio { info.kindSymbol = "music.note"; info.placeholderSymbol = "waveform" }
        GridCellInfo.markUnit(&info, entry)
        if entry.source != nil { info.stateSymbol = "text.badge.checkmark"; info.stateColor = .secondaryLabelColor }
        info.tagColors = GridCellInfo.tagColors(entry.finderTags)
        duplicates.mark(&info, for: entry.url)
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        await app.thumbnails.localThumbnail(for: URL(fileURLWithPath: id), maxPixel: maxPixel)?.image
    }

    func gridSelectionChanged(_ ids: Set<String>) {
        selection = ids
        owner?.window?.editTargets = nil
        // The Details tab shows the one file chosen last in either pane (D-114).
        if ids.count == 1, let id = ids.first, !listFolders.isFolder(id), let entry = entry(id) {
            owner?.details = (entry.url, role)
        } else if owner?.details?.pane == role {
            owner?.details = nil
        }
    }

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

    func gridFocused() { owner?.window?.noteOrganiseFocus(paneID) }

    func gridWriter(_ id: String) -> NSPasteboardWriting? { URL(fileURLWithPath: id, isDirectory: listFolders.isFolder(id)) as NSURL }

    /// Dragged out, files take their metadata files with them, as in the Library (R-1708).
    func gridCompanionWriters(_ ids: [String]) -> [NSPasteboardWriting] {
        ids.compactMap { entry($0) }.filter { $0.source != nil }.map { Sidecar.sidecarURL(for: $0.url) as NSURL }
    }

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
        if chosen.count == 1, let file = chosen.first,
           let copies = duplicates.copiesMenuItem(for: file, reveal: { [weak self] in self?.reveal($0) })
        {
            menu.addItem(copies)
        }
        let role = role
        for item in owner.window?.metadataMenuItems(for: chosen, showDetails: { [weak owner] photos in
            owner?.details = (photos[0], role)
            owner?.tab = .details
        }) ?? [] {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if role == .source, let target = owner.targetFolder, target.standardizedFileURL != folder?.standardizedFileURL {
            menu.addItem(ActionMenuItem("Copy to “\(target.lastPathComponent)”") {
                owner.runPlanned { FolderOperations.copy(chosen, to: target) }
            })
            menu.addItem(ActionMenuItem("Move to “\(target.lastPathComponent)”") {
                owner.runPlanned { FolderOperations.move(chosen, to: target) }
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
            owner.runPlanned { FolderOperations.move(chosen, to: destination) }
        })
        // Numbered in the order the pane shows them.
        let files = shown.filter { ids.contains($0.path) }.map(\.url)
        if files.count > 1 {
            menu.addItem(ActionMenuItem("Rename \(files.count) Files…") { owner.startBatchRename(files) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Move to Trash") { owner.run(FolderOperations.trash(chosen)) })
        return menu
    }
}

/// Renaming several files by one pattern, typed in the Organise pane (R-3808).
struct BatchRenameDraft: Equatable {
    var files: [URL]
    var pattern = "{name}"
    /// Archive folders keep MediaPull's names, which their metadata depends on (R-1504).
    var archive: Bool
    /// The first files' new names as the rename will give them (nil: unchanged), worked out off the main actor.
    var preview: [BatchRenamePreviewRow] = []
}

struct BatchRenamePreviewRow: Equatable {
    var old: String
    var new: String?
}

extension OrganisePane: MediaListOwner {
    var listColumns: [ListColumn] { ListColumn.fileColumns }

    func listText(_ id: String, _ column: ListColumn) -> String {
        if listFolders.isFolder(id) {
            return ListText.folder(id, column) { [weak self] id in self?.onListChildrenLoaded?(id) }
        }
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
            || duplicates.showOnly
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
    var batchRename: BatchRenameDraft?

    func startBatchRename(_ files: [URL]) {
        // Archive until known otherwise: by its library folder, or (outside the library) by holding metadata files (R-3804),
        // read off the main actor.
        batchRename = BatchRenameDraft(files: files, archive: true)
        let folders = Set(files.map { $0.deletingLastPathComponent() })
        Task { [weak self] in
            guard let self else { return }
            var archive = false
            for folder in folders where await self.layoutFor(folder) == .archive {
                archive = true
            }
            if self.batchRename?.files == files { self.batchRename?.archive = archive }
        }
        tab = .sort
        window?.setShowing(.organiseWork, true)
        updateBatchPreview()
    }

    func setBatchPattern(_ pattern: String) {
        guard batchRename?.pattern != pattern else { return }
        batchRename?.pattern = pattern
        updateBatchPreview()
    }

    @ObservationIgnored private var batchPreviewTask: Task<Void, Never>?

    /// The preview is planned as the rename itself is, so it shows the numbers names that are taken get (audit 4, B4-m14).
    /// It reads the folder, so it runs off the main actor, a moment after typing stops.
    private func updateBatchPreview() {
        batchPreviewTask?.cancel()
        guard let draft = batchRename else { return }
        batchPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let rows = await Task.detached(priority: .userInitiated) {
                FolderOperations.batchRenamePreview(draft.files, pattern: draft.pattern)
                    .map { BatchRenamePreviewRow(old: $0.old, new: $0.new) }
            }.value
            guard !Task.isCancelled, let self, self.batchRename?.files == draft.files, self.batchRename?.pattern == draft.pattern
            else { return }
            self.batchRename?.preview = rows
        }
    }

    func applyBatchRename() {
        guard let draft = batchRename, !draft.archive else { return }
        batchRename = nil
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                FolderOperations.batchRename(draft.files, pattern: draft.pattern)
            }.value
            self?.run(plan)
        }
    }
    var history: [JournalEntry] = []
    var working: String?
    var tab: OrganiseTab = .sort
    /// The file the Details tab shows and the pane it was chosen in.
    var details: (url: URL, pane: OrganisePane.Role)?
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
        siblingRefresh?.cancel()
        batchPreviewTask?.cancel()
        AppModel.shared.analysis.onFolderChange[listenerID] = nil
        // Once this window is gone, its folders stop being watched (after the window's own reference has cleared).
        Task { @MainActor in OrganiseModel.updateAnalysisFolders() }
    }

    /// Opens the default library folder, in place, the first time Organise is shown (D-68). History is read again: changes
    /// made before then reached no Organise view (audit 6, B6-m3).
    func prepare() {
        if source.root == nil, let library = app.defaultRoot?.url { open(library) }
        Task { await refreshHistory() }
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
        let events = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for pane in [source, target] {
            // Any folder the tree shows, as in the Library (audit 4, B4-m3).
            if events.contains(where: pane.treeCache.shows) { pane.invalidateTree() }
            guard let folder = pane.folder?.standardizedFileURL.path else { continue }
            // A change inside the shown folder, or to a folder above it (renamed or moved to the Trash in the Finder).
            let affected = events.contains { event in
                event == folder || event.hasPrefix(folder + "/") || folder.hasPrefix(event == "/" ? event : event + "/")
            }
            if affected {
                pane.reload()
                pane.invalidateTree()
                pane.detectProfile(changed: true)
            }
        }
        if events.contains(where: siblingCache.shows) { refreshSiblings() }
        Task { await followFolders() }
    }

    /// Top folders renamed, moved or trashed in the Finder are followed through their bookmarks; a folder shown inside one
    /// that went away gives way to the nearest folder still there (audit 5, B5-M1). Runs whenever MediaPull comes forward
    /// and after folder events.
    func followFolders() async {
        let panes = [source, target]
        let bookmarks = panes.map(\.rootBookmark)
        let shown = panes.map(\.folder)
        let found = await Task.detached(priority: .userInitiated) {
            zip(bookmarks, shown).map { bookmark, folder -> (moved: URL?, gone: Bool, folder: URL?) in
                var folderLeft: URL?
                if var current = folder, !OperationJournal.isFolder(current) {
                    while !OperationJournal.isFolder(current), current.pathComponents.count > 1 { current.deleteLastPathComponent() }
                    folderLeft = current
                }
                guard let bookmark, !OperationJournal.isFolder(URL(fileURLWithPath: bookmark.path)) else { return (nil, false, folderLeft) }
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: bookmark.data, options: [.withoutUI, .withoutMounting],
                                         relativeTo: nil, bookmarkDataIsStale: &stale),
                      OperationJournal.isFolder(url), !FileFlags.isInTrash(url)
                else { return (nil, true, folderLeft) }
                return (url.standardizedFileURL, false, folderLeft)
            }
        }.value
        for (pane, result) in zip(panes, found) {
            guard let old = pane.rootBookmark.map({ URL(fileURLWithPath: $0.path, isDirectory: true) }) ?? pane.root else { continue }
            if let moved = result.moved {
                foldersMoved([(from: old.path, to: moved.path)])
            } else if result.gone {
                foldersTrashed([old.path])
            } else if let left = result.folder, let root = pane.root, LibraryModel.isInside(left, root) {
                pane.folder = left
            }
        }
    }

    /// MediaPull moved or renamed folders (any window or section): each pane's folder and top folder follow them, so the
    /// target stays the folder it was (audit 4, B4-m2).
    func foldersMoved(_ moves: [(from: String, to: String)]) {
        var changed = false
        for pane in [source, target] {
            var root = pane.root, folder = pane.folder
            for move in moves {
                let from = URL(fileURLWithPath: move.from, isDirectory: true), to = URL(fileURLWithPath: move.to, isDirectory: true)
                root = root.map { LibraryModel.moved($0, from: from, to: to) }
                folder = folder.map { LibraryModel.moved($0, from: from, to: to) }
            }
            guard root != pane.root || folder != pane.folder else { continue }
            pane.root = root
            pane.folder = folder
            changed = true
        }
        if changed {
            // A previewed plan names the old paths: it is shown again for the new ones by choosing it again.
            pending = nil
            updateAnalysisFolders()
        }
    }

    /// Folders MediaPull moved to the Trash: a pane showing one goes to the folder above, and a pane whose top folder went
    /// is emptied (the target then means in place again).
    func foldersTrashed(_ paths: [String]) {
        let gone = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var changed = false
        for pane in [source, target] {
            if let root = pane.root, gone.contains(where: { LibraryModel.isInside(root, $0) }) {
                pane.root = nil
                changed = true
            } else if let folder = pane.folder, let top = gone.first(where: { LibraryModel.isInside(folder, $0) }) {
                pane.folder = top.deletingLastPathComponent()
            }
        }
        if changed {
            pending = nil
            updateAnalysisFolders()
        }
    }

    func refreshAfterChange() {
        for pane in [source, target] {
            pane.invalidateTree()
            pane.reload()
        }
        refreshSiblings()
        app.libraryRevision += 1
    }

    /// Library folders were added, renamed or changed elsewhere (a save, a pull, the Library pane): the trees read their
    /// folders again. The listings follow their own folders' changes.
    func libraryChanged() {
        for pane in [source, target] {
            pane.invalidateTree()
        }
        refreshSiblings()
    }

    // MARK: Running changes

    /// Small changes apply at once (and can be undone); sorts, flattening and merging are previewed first, in the Organise pane.
    func run(_ plan: OrganisePlan, preview: Bool = false, note: String? = nil) {
        // A library folder itself is never moved, renamed or trashed from Organise: the Library does that, so its saves,
        // records and analysis follow (audit 2, B2-M5).
        // A folder that is a library folder or holds one counts: trashing, emptying or moving it changes the library folder
        // too. Copies change nothing and are allowed (audit 3, B3-M4, B3-m1).
        if plan.changes(anyOf: app.roots.map(\.url)) {
            message = "A library folder is not changed from Organise. Rename or remove it in the Library."
            return
        }
        // A locked card can be read and imported from, never changed (R-4304).
        if let drive = app.driveCenter.drive(containing: plan.root), drive.isReadOnly {
            message = "“\(drive.name)” is locked, so nothing on it can be changed. Copy to a target folder instead."
            return
        }
        guard !plan.isEmpty else {
            let nothing = plan.unsorted > 0
                ? "Nothing to change: \(plan.unsorted) file\(plan.unsorted == 1 ? "" : "s") could not be sorted."
                : "Nothing to change."
            // The sort's own explanation (such as turning on recognising people) says why.
            message = plan.unsorted > 0 && note != nil ? nothing + " " + (note ?? "") : nothing
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

    /// Plans that walk whole folders or check many names (flatten, merge, copies and moves of a large selection) are made
    /// off the main actor, as sorts and renames are (audit 6, B6-m2), then run or previewed as `run` does.
    func runPlanned(_ reading: String? = nil, preview: Bool = false, note: String? = nil,
                    _ make: @escaping @Sendable () -> OrganisePlan)
    {
        if let reading { working = reading }
        Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) { make() }.value
            guard let self else { return }
            if let reading, self.working == reading { self.working = nil }
            self.run(plan, preview: preview, note: note)
        }
    }

    func execute(_ plan: OrganisePlan, then finished: (@MainActor () -> Void)? = nil) {
        pending = nil
        message = nil
        let app = app
        let job = Job(kind: .organise, title: plan.title)
        job.total = plan.moves.count + plan.itemsToTrash.count + plan.foldersToCreate.count + plan.foldersToTrash.count
        job.state = .running
        // Every change is a job, so Quit waits for it to stop between files (R-3807); small ones leave Activity once done.
        let listed = plan.showsInActivity
        app.jobs.add(job)
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
            // A small run leaves Activity once done; one that is taken back stays until then, so Quit waits for it (B18-m1).
            if !listed, entry.failures.isEmpty, entry.finished { app.jobs.jobs.removeAll { $0 === job } }
            // A rename through temporary names that stopped between its two steps would leave files under hidden names:
            // it is taken back at once (audit 3, B3-m7, C3-m9).
            let usedTemporaryNames = plan.moves.contains { $0.destination.lastPathComponent.hasPrefix(".mediapull-rename-") }
            if usedTemporaryNames, !entry.finished || !entry.failures.isEmpty, !entry.steps.isEmpty {
                // In a task of its own: the run was stopped (Cancel, Quit), and a stopped task's Undo would stop before it
                // started. The run's task waits for it, so Quit does too (audit 16, B16-M2).
                let report = await Task { await app.undoChange(entry.id) }.value
                guard let self else { return }
                // Only what the undo really did, and whether it was recorded (audit 4, B4-m10; audit 14, B14-m5).
                if let report, report.done == 0 {
                    self.message = "\(plan.title) stopped part way and could not be taken back. Undo it in History to try again."
                    self.window?.registerUndo(entry)
                } else if let report, report.skipped.isEmpty {
                    self.message = "\(plan.title) stopped part way, so it was taken back: every file has its old name."
                } else if let report {
                    self.message = "\(plan.title) stopped part way and was taken back, except \(report.skipped.count): "
                        + report.skipped.prefix(2).joined(separator: "; ")
                } else {
                    self.message = "\(plan.title) stopped part way and could not be taken back. Undo it in History to try again."
                    self.window?.registerUndo(entry)
                }
                if report?.unsaved == true, let message = self.message { self.message = message + " " + OperationJournal.unsavedNote }
                self.working = nil
                await self.refreshHistory()
                return
            }
            guard let self else { return }
            self.message = entry.failures.isEmpty
                ? "\(plan.title): done. ⌘Z undoes it."
                : entry.failures.prefix(3).joined(separator: "\n")
            // A plan that changed nothing (its folder went away since the preview) leaves nothing to undo.
            if !entry.steps.isEmpty { self.window?.registerUndo(entry) }
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
            // Inside the pane's tree only: "Trip 2023" is not inside "Trip" (audit 2, B2-m9).
            if pane.folder?.standardizedFileURL != plan.root.standardizedFileURL,
               let top = pane.root.map({ $0.standardizedFileURL.path }),
               plan.root.standardizedFileURL.path == top || plan.root.standardizedFileURL.path.hasPrefix(top + "/")
            {
                pane.folder = plan.root
            }
        }
        refreshAfterChange()
    }

    func refreshHistory() async {
        // Kept no longer than the setting says, also while MediaPull stays open (audit 17, B17-m2).
        await app.journal.prune(olderThan: app.preferences.undoHistoryDays)
        history = await app.journal.entries()
    }

    /// The History's Undo, and the toolbar's: through the window, so ⇧⌘Z can redo it.
    func redo(_ entry: JournalEntry) {
        guard let window, !window.redoing.contains(entry.id), !window.undoing.contains(entry.id) else { return }
        // Off every window's ⇧⌘Z stack first, so the change is never done twice (audit 14, B14-m3).
        for other in app.windows { other.forgetUndo(entry.id) }
        window.redoChange(entry)
    }

    func undo(_ entry: JournalEntry) {
        guard let window, !window.redoing.contains(entry.id), !window.undoing.contains(entry.id) else { return }
        window.undoChange(entry)
    }

    /// Any window changed files: the History and both panes show the result.
    func fileChanged() {
        Task { await refreshHistory() }
        refreshAfterChange()
    }

    /// The toolbar's Undo: the change ⌘Z would undo, whichever section of this window made it (audit 5, B5-m3). Changes
    /// made in other windows, or before MediaPull last opened, are undone from History.
    func undoLast() {
        guard let window else { return }
        if !window.undoLastFileChange(known: history) {
            message = "Nothing to undo in this window. Earlier changes can be undone in History."
        }
    }

    /// Whether the toolbar's Undo has a change to undo: this window's ⌘Z stack holds one the History lists as not undone.
    var canUndoLast: Bool {
        guard let id = window?.lastFileChange else { return false }
        return history.first { $0.id == id }.map { !$0.undone } ?? true
    }

    /// Files dropped on a folder: copied when copying to the target (or from outside), otherwise moved.
    func drop(_ urls: [URL], into folder: URL) {
        let roots = [source.root, target.root].compactMap(\.self)
        let fromOutside = urls.contains { url in roots.allSatisfy { !url.path.hasPrefix($0.path + "/") } }
        let copy = mode == .copy || fromOutside || NSEvent.modifierFlags.contains(.option)
        runPlanned { copy ? FolderOperations.copy(urls, to: folder) : FolderOperations.move(urls, to: folder) }
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
        let note = "Every file from the subfolders moves up into “\(folder.lastPathComponent)”; the emptied folders go to the Trash."
        runPlanned("Reading “\(folder.lastPathComponent)”…", preview: true, note: note) { FolderOperations.flatten(folder) }
    }

    func removeFolder(_ folder: URL) {
        runPlanned("Reading “\(folder.lastPathComponent)”…", preview: true,
                   note: "The folder's contents move up one level; the emptied folder goes to the Trash.") {
            FolderOperations.removeSubfolders([folder])
        }
    }

    func merge(_ folder: URL, into other: URL) {
        runPlanned("Reading “\(folder.lastPathComponent)”…", preview: true,
                   note: "Folders with the same name are merged; “\(folder.lastPathComponent)” goes to the Trash once empty.") {
            FolderOperations.merge(folder, into: other)
        }
    }

    /// Folders next to `folder`, for Merge Into.
    /// The folders beside `folder`, read off the main actor the first time (audit 3, B3-m5): the menu shows them as soon
    /// as they are read.
    func siblings(of folder: URL) -> [URL] {
        siblingCache.onLoaded = { [weak self] in self?.source.treeRevision += 1 }
        return siblingCache.children(of: folder.deletingLastPathComponent()).filter { $0.standardizedFileURL != folder.standardizedFileURL }
    }

    @ObservationIgnored private let siblingCache = FolderTreeCache()
    @ObservationIgnored private var siblingRefresh: Task<Void, Never>?

    /// Folders were renamed, made or trashed: Merge Into reads its folders again, so it never offers one that is gone
    /// (audit 4, B4-M1).
    private func refreshSiblings() {
        siblingRefresh?.cancel()
        siblingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.siblingCache.refresh()
            guard !Task.isCancelled else { return }
            self.source.treeRevision += 1
            self.target.treeRevision += 1
        }
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
        // The Profile view hides the search, filters and selection a sort works on, so it would sort what is not seen.
        if window?.viewMode(for: .organiseSource) == .profile, source.profileSource != nil {
            message = "Sorts work in Icons, List or Columns. Switch the Source to one of them first."
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
        let individually = app.preferences.sortPostImagesIndividually
        let copy = mode == .copy
        Task {
            let layoutForRoot = await self.layoutFor(destination)
            var assignment: [String: [[String]]] = [:]
            var note: String?
            switch kind {
            case .date: for f in files { assignment[f.path] = SortRules.byDate(f) }
            case .event: assignment = SortRules.eventFolders(files, gap: gap)
            case .source: for f in files { assignment[f.path] = SortRules.bySource(f) }
            case .screenshots: for f in files { assignment[f.path] = SortRules.byScreenshot(f) }
            case .place: for f in files { assignment[f.path] = SortRules.byPlace(f) }
            case .artist: for f in files { assignment[f.path] = SortRules.byArtist(f) }
            case .album: for f in files { assignment[f.path] = SortRules.byAlbum(f) }
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
            if [.artist, .album].contains(kind) { note = "Only audio files with tags are sorted; everything else stays where it is." }
            // A post with several pictures stays together (R-4208) unless the person sorts images individually.
            if !individually {
                let kept = PostGroups.keepTogether(files, assignment: assignment, byMajority: [.subject, .person].contains(kind))
                assignment = kept.assignment
                if kept.posts > 0 {
                    note = [note, "\(kept.posts) post\(kept.posts == 1 ? " was" : "s were") kept together."].compactMap { $0 }
                        .joined(separator: " ")
                }
            }
            if missing > 0, kind != .date, kind != .source, kind != .event {
                note = [note, "\(missing) file\(missing == 1 ? " is" : "s are") not analysed yet and will go to Unsorted."]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            let urls = files.map(\.url)
            let title = "Sort by \(kind.label)", keepUnsorted = [.person, .artist, .album].contains(kind)
            let plan = await Task.detached(priority: .userInitiated) {
                FolderOperations.sort(urls, into: destination, title: title, keepUnsorted: keepUnsorted, copy: copy) {
                    assignment[$0.path] ?? []
                }
            }.value
            working = nil
            run(plan, preview: true, note: note)
        }
    }

    /// A folder's layout: its library folder's, or for a folder outside the library, Archive when it holds metadata files
    /// (R-3804). Reads names, so it runs off the main actor (audit 3, B3-m5).
    func layoutFor(_ folder: URL) async -> SaveLayout {
        if let root = app.root(containing: folder) { return root.layout }
        return await Task.detached(priority: .userInitiated) { Self.layoutOfFolder(folder) }.value
    }

    nonisolated static func layoutOfFolder(_ folder: URL) -> SaveLayout {
        // Names only, stopping at the first metadata file.
        // lint:allow main-io called from a detached task
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
