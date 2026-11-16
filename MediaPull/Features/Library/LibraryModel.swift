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

/// A folder in the Library tree. Children are read when first asked for.
final class FolderNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isRoot: Bool
    let rootID: UUID?
    private var cachedChildren: [FolderNode]??

    init(url: URL, name: String? = nil, isRoot: Bool = false, rootID: UUID? = nil) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isRoot = isRoot
        self.rootID = rootID
    }

    var id: String { url.path }

    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.url == rhs.url && lhs.isRoot == rhs.isRoot }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }

    var children: [FolderNode]? {
        if let cachedChildren { return cachedChildren }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        let folders = entries.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .map { FolderNode(url: $0) }
        let result: [FolderNode]? = folders.isEmpty ? nil : folders
        cachedChildren = .some(result)
        return result
    }
}

/// The Library pane of one window: the selected folder and its contents (SPEC section 17).
@Observable
final class LibraryModel: MediaGridOwner {
    @ObservationIgnored weak var window: WindowModel?
    @ObservationIgnored private let listenerID = UUID()
    @ObservationIgnored private var cachedTree: (key: String, nodes: [FolderNode])?

    /// The library folders, then a save folder chosen outside the library (D-70). The nodes, and the subfolders each has
    /// read, are kept until the tree changes, so a redraw does not read every open folder from disk again.
    func treeNodes() -> [FolderNode] {
        let roots = app.roots
        let key = "\(treeRevision)|\(app.libraryRevision)|\(roots.map { "\($0.id)\($0.name)" })|\(otherFolder?.path ?? "")"
        if let cachedTree, cachedTree.key == key { return cachedTree.nodes }
        var nodes = roots.map { FolderNode(url: $0.url, name: $0.name, isRoot: true, rootID: $0.id) }
        if let other = otherFolder, app.root(containing: other) == nil {
            nodes.append(FolderNode(url: other, name: other.lastPathComponent, isRoot: true, rootID: nil))
        }
        cachedTree = (key, nodes)
        return nodes
    }
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    init() {
        // The folder's own watch sees only its direct contents; analysis watches the library recursively (FSEvents),
        // which covers subfolders when they are included (R-1704).
        AppModel.shared.analysis.onFolderChange[listenerID] = { [weak self] paths in self?.foldersChanged(paths) }
    }

    isolated deinit {
        AppModel.shared.analysis.onFolderChange[listenerID] = nil
    }

    private func foldersChanged(_ paths: [String]) {
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
            self.treeRevision += 1
        }
    }
    var selectedFolder: URL? {
        didSet { if selectedFolder != oldValue { reload(); watch() } }
    }

    /// A save folder outside the library, shown under the library folders until replaced or removed (D-70).
    var otherFolder: URL?

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
    /// The files with what analysis knows about them, and the sections the sort and filters produce (section 37).
    var entries: [MediaEntry] = [] {
        didSet { entryIndex = Dictionary(entries.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Grid cells look files up by id for every cell, so lookups go through these instead of scanning the lists.
    @ObservationIgnored private var fileIndex: [String: Int] = [:]
    @ObservationIgnored private var entryIndex: [String: Int] = [:]

    private func file(_ id: String) -> LibraryFile? { fileIndex[id].map { files[$0] } }
    var built: [LibrarySection] = []
    var query: LibraryQuery = AppModel.shared.preferences.libraryQuery {
        didSet {
            guard query != oldValue else { return }
            app.preferences.libraryQuery = query
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
        let entries = entries, query = query
        filterTask = Task { [weak self] in
            guard let self else { return }
            var context = LibraryQuery.Context(similarityFloor: AnalysisService.meaningFloor)
            if !query.search.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                context.similarity = await self.app.analysis.meaningScores(query.search, entries: entries)
                context.similarityFloor = AnalysisService.floor(for: context.similarity)
            }
            if query.sort == .similar || query.filter.similarOnly { context.similarGroups = await self.app.analysis.similarGroups(entries) }
            if !query.filter.people.isEmpty { context.people = await self.app.analysis.peopleByPath(entries) }
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
            let (listed, folders) = await MediaListing.load(folder, recursive: recursive)
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
        watcher?.cancel()
        watcher = nil
        guard let folder = selectedFolder else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChangeReload() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func refreshTree() {
        treeRevision += 1
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

    func newFolder(in parent: URL) {
        var name = "New Folder"
        var counter = 2
        while FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) {
            name = "New Folder \(counter)"
            counter += 1
        }
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            treeRevision += 1
            selectedFolder = url
            renaming = url.path
        } catch {
            message = error.localizedDescription
        }
    }

    func rename(_ url: URL) {
        renaming = url.path
    }

    func commitRename(_ url: URL, to text: String) {
        renaming = nil
        let name = FileNaming.sanitize(text.trimmingCharacters(in: .whitespacesAndNewlines), maxBytes: 240)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try MediaFiles.move(url, to: destination)
            app.noteMoved([(from: url.path, to: destination.path)])
            selectedFolder = selectedFolder.map { Self.moved($0, from: url, to: destination) }
            otherFolder = otherFolder.map { Self.moved($0, from: url, to: destination) }
            treeRevision += 1
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Moves files (with their sidecars) or folders to the Trash. Nothing is ever deleted outright.
    func trash(_ urls: [URL]) {
        for url in urls {
            do {
                try MediaFiles.trash(url)
            } catch {
                message = "\(url.lastPathComponent) could not be moved to the Trash: \(error.localizedDescription)"
                continue
            }
            // The save folder or one of its parents went to the Trash: save into the folder above instead.
            if let folder = selectedFolder, Self.isInside(folder, url) { selectedFolder = url.deletingLastPathComponent() }
            if let other = otherFolder, Self.isInside(other, url) { otherFolder = nil }
        }
        treeRevision += 1
        reload()
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
        Task {
            var problems: [String] = []
            var moved: [(from: String, to: String)] = []
            defer { app.noteMoved(moved) }
            for url in urls {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let destination = Self.uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
                let isFolder = isDirectory.boolValue
                do {
                    // Copies of large videos take a while, so file operations run off the main actor.
                    if isFolder, !move {
                        try await Self.offMain { try FileManager.default.copyItem(at: url, to: destination) }
                        continue
                    }
                    if move {
                        try await Self.offMain { try MediaFiles.move(url, to: destination) }
                        moved.append((from: url.path, to: destination.path))
                        continue
                    }
                    let format = MediaFormat.fromExtension(url.pathExtension)
                    if target.layout == .archive, let format, !format.isNormal {
                        let work = SavePipeline.defaultWorkDirectory.appendingPathComponent("import-\(UUID().uuidString)")
                        defer { try? FileManager.default.removeItem(at: work) }
                        let result = try await converter.convert(url, policy: policy, layout: .archive, workDirectory: work)
                        let output = Self.uniqueURL(folder.appendingPathComponent(
                            FileNaming.fileName(stem: url.deletingPathExtension().lastPathComponent, ext: result.format.fileExtension)))
                        let converted = result.converted, convertedURL = result.url
                        try await Self.offMain {
                            if converted {
                                try FileManager.default.moveItem(at: convertedURL, to: output)
                            } else {
                                try FileManager.default.copyItem(at: url, to: output)
                            }
                        }
                    } else {
                        try await Self.offMain { try MediaFiles.copy(url, to: destination) }
                    }
                } catch {
                    problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            message = problems.isEmpty ? nil : problems.prefix(3).joined(separator: "\n")
            treeRevision += 1
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

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
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
        guard let file = file(id) else { return nil }
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
        if ids.count == 1, let file = files.first(where: { ids.contains($0.id) }) { window?.showInPreview(.file(file.url)) }
    }

    func gridActivate(_ id: String) {
        guard let file = file(id) else { return }
        NSWorkspace.shared.open(file.url)
    }

    func gridQuickLook() {
        QuickLook.shared.show(files.filter { selection.contains($0.id) }.map(\.url))
    }

    /// Return renames and ⌘⌫ moves to the Trash, in the grid as in the folder tree (R-1707). The editor holds the name.
    func gridReturn(_ id: String) {
        guard let file = file(id) else { return }
        window?.openEditor(EditorRequest(subject: .file(file.url)))
    }

    func gridDelete(_ ids: Set<String>) {
        trash(files.filter { ids.contains($0.id) }.map(\.url))
    }

    func gridAppeared(_: String) {}

    func gridWriter(_ id: String) -> NSPasteboardWriting? {
        file(id).map { $0.url as NSURL }
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

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        let chosen = files.filter { ids.contains($0.id) }
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
            menu.addItem(ActionMenuItem("Convert to JPEG or PNG") { [weak self] in
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
}
