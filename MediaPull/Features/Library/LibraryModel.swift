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
        let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
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
    var selectedFolder: URL? {
        didSet { if selectedFolder != oldValue { reload(); watch() } }
    }

    var files: [LibraryFile] = []
    var subfolderCount = 0
    var selection: Set<String> = []
    var revision = 0
    var treeRevision = 0
    var cellSize: CGFloat = 104
    var message: String?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var details: [String: (PixelSize?, MediaFormat?)] = [:]
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var app: AppModel { .shared }

    var sections: [GridSection] {
        [GridSection(id: "files", title: "", ids: files.map(\.id))]
    }

    func reload() {
        reloadTask?.cancel()
        guard let folder = selectedFolder else {
            files = []
            return
        }
        reloadTask = Task { [weak self] in
            let (loaded, folders) = await Self.list(folder)
            guard !Task.isCancelled, let self, self.selectedFolder == folder else { return }
            self.files = loaded
            self.subfolderCount = folders
            self.selection = self.selection.intersection(Set(loaded.map(\.id)))
            self.revision += 1
        }
    }

    @concurrent
    static func list(_ folder: URL) async -> ([LibraryFile], Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let names = Set(entries.map(\.lastPathComponent))
        var files: [LibraryFile] = []
        var folders = 0
        for url in entries {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { folders += 1; continue }
            guard values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext != "json", let format = MediaFormat.fromExtension(ext) else { continue }
            files.append(LibraryFile(
                url: url, name: url.lastPathComponent, size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast, hasSidecar: names.contains(url.lastPathComponent + ".json"),
                format: format
            ))
        }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        return (files, folders)
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        guard let folder = selectedFolder else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.treeRevision += 1
            }
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
        FolderPicker.chooseFolder(title: "Choose a Library Folder", prompt: "Add Folder", start: AppModel.suggestedRootURL.deletingLastPathComponent(),
                                  window: window?.hostWindow) { [weak self] url in
            guard let url else { return }
            Task {
                await self?.app.addRoot(url, makeDefault: self?.app.roots.isEmpty ?? true)
                self?.selectedFolder = url
            }
        }
    }

    // MARK: Folder operations

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
            rename(url)
        } catch {
            message = error.localizedDescription
        }
    }

    func rename(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(url.lastPathComponent)”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = url.lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = FileNaming.sanitize(field.stringValue, maxBytes: 240)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            let sidecar = Sidecar.sidecarURL(for: url)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.moveItem(at: sidecar, to: Sidecar.sidecarURL(for: destination))
            }
            if selectedFolder == url { selectedFolder = destination }
            treeRevision += 1
            reload()
        } catch {
            message = error.localizedDescription
        }
    }

    /// Moves files (with their sidecars) or folders to the Trash. Nothing is ever deleted outright.
    func trash(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            let sidecar = Sidecar.sidecarURL(for: url)
            if FileManager.default.fileExists(atPath: sidecar.path) { try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil) }
            if selectedFolder == url { selectedFolder = url.deletingLastPathComponent() }
        }
        treeRevision += 1
        reload()
    }

    // MARK: Drops

    /// Files dropped into a folder: moved within the library, copied from elsewhere, converted when
    /// the folder uses the Archive layout (SPEC R-1801).
    func importFiles(_ urls: [URL], into folder: URL, move: Bool) {
        let target = app.target(for: folder)
        let converter = MediaConverter(ffmpeg: app.ffmpeg, svgRasterizer: SVGRasterizer.rasterize)
        let policy = app.preferences.conversion
        Task {
            var problems: [String] = []
            for url in urls {
                if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { continue }
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let destination = Self.uniqueURL(folder.appendingPathComponent(url.lastPathComponent))
                do {
                    if isDirectory.boolValue, !move {
                        try FileManager.default.copyItem(at: url, to: destination)
                        continue
                    }
                    if move {
                        try FileManager.default.moveItem(at: url, to: destination)
                        let sidecar = Sidecar.sidecarURL(for: url)
                        if !isDirectory.boolValue, FileManager.default.fileExists(atPath: sidecar.path) {
                            try? FileManager.default.moveItem(at: sidecar, to: Sidecar.sidecarURL(for: destination))
                        }
                        continue
                    }
                    let format = MediaFormat.fromExtension(url.pathExtension)
                    if target.layout == .archive, let format, !format.isNormal {
                        let work = SavePipeline.defaultWorkDirectory.appendingPathComponent("import-\(UUID().uuidString)")
                        defer { try? FileManager.default.removeItem(at: work) }
                        let result = try await converter.convert(url, policy: policy, layout: .archive, workDirectory: work)
                        let output = Self.uniqueURL(folder.appendingPathComponent(
                            FileNaming.fileName(stem: url.deletingPathExtension().lastPathComponent, ext: result.format.fileExtension)))
                        if result.converted {
                            try FileManager.default.moveItem(at: result.url, to: output)
                        } else {
                            try FileManager.default.copyItem(at: url, to: output)
                        }
                    } else {
                        try FileManager.default.copyItem(at: url, to: destination)
                        let sidecar = Sidecar.sidecarURL(for: url)
                        if FileManager.default.fileExists(atPath: sidecar.path) {
                            try? FileManager.default.copyItem(at: sidecar, to: Sidecar.sidecarURL(for: destination))
                        }
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

    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)")
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
        guard let file = files.first(where: { $0.id == id }) else { return nil }
        var detail: [String] = []
        if let (size, _) = details[id], let size { detail.append(size.label) }
        detail.append(file.format?.label ?? file.url.pathExtension.uppercased())
        var info = GridCellInfo(title: file.name, detail: detail.joined(separator: " · "), secondary: Format.bytes(file.size))
        switch file.format?.kind {
        case .video: info.kindSymbol = "play.fill"; info.placeholderSymbol = "film"
        case .audio: info.kindSymbol = "music.note"; info.placeholderSymbol = "waveform"
        default: break
        }
        if file.hasSidecar {
            info.stateSymbol = "text.badge.checkmark"
            info.stateColor = .secondaryLabelColor
        }
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        guard let file = files.first(where: { $0.id == id }) else { return nil }
        if details[id] == nil, file.format?.kind == .image || file.format?.kind == .animatedImage {
            if let analysis = ImageConversion.analyze(file.url) {
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
        guard let file = files.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.open(file.url)
    }

    func gridQuickLook() {
        QuickLook.shared.show(files.filter { selection.contains($0.id) }.map(\.url))
    }

    func gridAppeared(_: String) {}

    func gridWriter(_ id: String) -> NSPasteboardWriting? {
        files.first { $0.id == id }.map { $0.url as NSURL }
    }

    var gridAcceptsDrops: Bool { selectedFolder != nil }

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
        if chosen.count == 1, let file = chosen.first {
            menu.addItem(ActionMenuItem(file.format?.kind == .image ? "Edit…" : "Rename…") { [weak self] in
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
