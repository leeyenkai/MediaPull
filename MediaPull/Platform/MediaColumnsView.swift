import AppKit
import ImageIO
import MediaPullCore
import SwiftUI
import UniformTypeIdentifiers

/// What the column view needs beyond the list: where its first column starts and the folder open in the pane (R-1710).
@MainActor
protocol MediaColumnsOwner: MediaListOwner {
    /// Column zero lists this folder's contents; nil lists `columnRoots` instead (the library folders).
    var columnBase: URL? { get }
    var columnRoots: [URL] { get }
    /// The pane's folder, which the deepest selected folder of the browser follows both ways.
    var columnFolder: URL? { get }
    func columnFolderChanged(_ folder: URL)
    /// Folder ids about to be passed to the grid callbacks (menu, Trash, drag), so the owner treats them as folders.
    func columnNoteFolders(_ ids: [String])
    /// A folder's subfolders and media files, sorted by name; read off the main actor.
    func columnContents(_ folder: URL) async -> (folders: [URL], files: [URL])
}

/// A Finder-style column browser: each column a folder sorted by name with folders first, and a preview of the selected
/// file in the last column (R-1710). Open, Quick Look, menus, drag and drop and Trash go through the grid callbacks.
struct MediaColumns: NSViewRepresentable {
    var base: URL?
    var roots: [URL]
    var folder: URL?
    var revision: Int
    weak var owner: (any MediaColumnsOwner)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.owner = owner
        coordinator.base = base
        coordinator.roots = roots
        browser.delegate = coordinator
        browser.hasHorizontalScroller = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 150
        browser.setDefaultColumnWidth(210)
        browser.rowHeight = 22
        browser.autohidesScroller = true
        browser.target = coordinator
        browser.action = #selector(Coordinator.selectionChanged(_:))
        browser.doubleAction = #selector(Coordinator.doubleClicked(_:))
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        browser.registerForDraggedTypes([.fileURL, DragTypes.items])
        let menu = NSMenu()
        menu.delegate = coordinator
        browser.menu = menu
        coordinator.installKeys()
        browser.loadColumnZero()
        coordinator.lastRevision = revision
        coordinator.reveal(folder)
        return browser
    }

    func updateNSView(_: NSBrowser, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = owner
        coordinator.update(base: base, roots: roots, folder: folder, revision: revision)
    }

    static func dismantleNSView(_: NSBrowser, coordinator: Coordinator) {
        coordinator.removeKeys()
    }

    /// A folder or a file of the browser; the root is the base folder, or the virtual parent of the library folders.
    final class Node {
        let path: String
        let isFolder: Bool
        var children: [Node]?
        var loading = false

        init(path: String, isFolder: Bool) {
            self.path = path
            self.isFolder = isFolder
        }

        var url: URL { URL(fileURLWithPath: path, isDirectory: isFolder) }
        var name: String { url.lastPathComponent }
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate, NSMenuDelegate {
        weak var owner: (any MediaColumnsOwner)?
        weak var browser: NSBrowser?
        var base: URL?
        var roots: [URL] = []
        var lastRevision = 0
        private var root = Node(path: "", isFolder: true)
        /// The folder the browser shows as open, so a change from the pane can be told from one made here.
        private var shownFolder: String?
        private var revealing = false
        private var revealTask: Task<Void, Never>?
        private var keyMonitor: Any?
        private var icons: [String: NSImage] = [:]

        // MARK: Updates

        func update(base: URL?, roots: [URL], folder: URL?, revision: Int) {
            guard let browser else { return }
            if base != self.base || roots != self.roots {
                self.base = base
                self.roots = roots
                root = Node(path: "", isFolder: true)
                shownFolder = nil
                browser.loadColumnZero()
            } else if revision != lastRevision {
                // Files changed on disk: read the open columns again, then reopen the pane's folder.
                lastRevision = revision
                forget(root)
                shownFolder = nil
                browser.loadColumnZero()
            }
            if folder?.standardizedFileURL.path != shownFolder { reveal(folder) }
        }

        private func forget(_ node: Node) {
            node.children?.forEach(forget)
            node.children = nil
            node.loading = false
        }

        /// Opens the columns down to `folder`, reading each level first.
        func reveal(_ folder: URL?) {
            let target = folder?.standardizedFileURL.path
            shownFolder = target
            revealTask?.cancel()
            revealTask = Task { [weak self] in
                guard let self else { return }
                var indexes: [Int] = []
                var node = root
                if let target {
                    while node.path != target {
                        let children = await loaded(node)
                        guard !Task.isCancelled,
                              let index = children.firstIndex(where: { $0.isFolder && FolderPath.contains($0.path, target) })
                        else { break }
                        indexes.append(index)
                        node = children[index]
                    }
                    _ = await loaded(node)
                }
                guard !Task.isCancelled, let browser else { return }
                revealing = true
                browser.selectionIndexPath = indexes.isEmpty ? nil : IndexPath(indexes: indexes)
                if indexes.isEmpty { browser.reloadColumn(0) }
                revealing = false
            }
        }

        private func loaded(_ node: Node) async -> [Node] {
            if let children = node.children { return children }
            await load(node)
            return node.children ?? []
        }

        private func load(_ node: Node) async {
            guard node.children == nil, let owner else { return }
            node.loading = true
            let children: [Node]
            if node === root, base == nil {
                children = roots.map { Node(path: $0.standardizedFileURL.path, isFolder: true) }
            } else {
                let folder = node === root ? base ?? node.url : node.url
                let contents = await owner.columnContents(folder)
                children = contents.folders.map { Node(path: $0.standardizedFileURL.path, isFolder: true) }
                    + contents.files.map { Node(path: $0.standardizedFileURL.path, isFolder: false) }
            }
            guard node.loading else { return }
            node.loading = false
            node.children = children
        }

        /// The browser asked for a folder not read yet: read it, then fill its column.
        private func loadAndShow(_ node: Node) {
            guard !node.loading else { return }
            Task { [weak self] in
                guard let self else { return }
                await load(node)
                guard let browser else { return }
                for column in 0 ... max(browser.lastColumn, 0) where browser.parentForItems(inColumn: column) as? Node === node {
                    browser.reloadColumn(column)
                }
            }
        }

        // MARK: Data

        func rootItem(for _: NSBrowser) -> Any? { root }

        func browser(_: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? Node) ?? root
            if let children = node.children { return children.count }
            loadAndShow(node)
            return 0
        }

        func browser(_: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? Node) ?? root
            return node.children?[index] ?? root
        }

        func browser(_: NSBrowser, isLeafItem item: Any?) -> Bool { !((item as? Node)?.isFolder ?? true) }

        /// The browser draws text cells, so each row is its icon as an attachment followed by the name.
        func browser(_: NSBrowser, objectValueForItem item: Any?) -> Any? {
            guard let node = item as? Node else { return "" }
            let attachment = NSTextAttachment()
            attachment.image = icon(for: node)
            attachment.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: "  " + node.name))
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            return text
        }

        func browser(_ browser: NSBrowser, typeSelectStringForRow row: Int, inColumn column: Int) -> String? {
            (browser.item(atRow: row, inColumn: column) as? Node)?.name
        }

        private func icon(for node: Node) -> NSImage {
            let key = node.isFolder ? "/" : node.url.pathExtension.lowercased()
            if let known = icons[key] { return known }
            let type: UTType = node.isFolder ? .folder : UTType(filenameExtension: key) ?? .data
            let image = NSWorkspace.shared.icon(for: type)
            image.size = NSSize(width: 16, height: 16)
            icons[key] = image
            return image
        }

        func browser(_: NSBrowser, previewViewControllerForLeafItem _: Any) -> NSViewController? {
            let controller = ColumnPreviewController()
            controller.owner = owner
            return controller
        }

        // MARK: Selection

        /// The nodes selected in the deepest column that has a selection.
        private func selectedNodes() -> [Node] {
            guard let browser else { return [] }
            let paths = browser.selectionIndexPaths
            guard let depth = paths.map(\.count).max() else { return [] }
            return paths.filter { $0.count == depth }.compactMap { browser.item(at: $0) as? Node }
        }

        func selectedIDs() -> [String] {
            let nodes = selectedNodes()
            owner?.columnNoteFolders(nodes.filter(\.isFolder).map(\.path))
            return nodes.map(\.path)
        }

        @objc func selectionChanged(_ sender: NSBrowser) {
            guard !revealing, let owner else { return }
            owner.gridFocused()
            let nodes = selectedNodes()
            let folder: URL? = if nodes.count == 1, let only = nodes.first, only.isFolder {
                only.url
            } else if let first = nodes.first {
                parentFolder(of: first, in: sender)
            } else {
                nil
            }
            if let folder {
                shownFolder = folder.standardizedFileURL.path
                if folder.standardizedFileURL != owner.columnFolder?.standardizedFileURL { owner.columnFolderChanged(folder) }
            }
            owner.gridSelectionChanged(Set(nodes.filter { !$0.isFolder }.map(\.path)))
        }

        private func parentFolder(of node: Node, in browser: NSBrowser) -> URL? {
            for column in 0 ... max(browser.lastColumn, 0) {
                guard let parent = browser.parentForItems(inColumn: column) as? Node,
                      parent.children?.contains(where: { $0 === node }) == true
                else { continue }
                if parent === root { return base }
                return parent.url
            }
            return node.url.deletingLastPathComponent()
        }

        @objc func doubleClicked(_ sender: NSBrowser) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow, inColumn: sender.clickedColumn) as? Node,
                  !node.isFolder
            else { return }
            owner?.gridActivate(node.path)
        }

        // MARK: Keys and menu

        /// Space, Return and ⌘⌫ while the browser has focus. A local monitor, because the browser's own columns take
        /// the keys first; it acts only when focus is inside this browser, never in the web page.
        func installKeys() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let key = event
                let handled = MainActor.assumeIsolated {
                    guard let self, let browser = self.browser, key.window === browser.window,
                          let focused = browser.window?.firstResponder as? NSView, focused.isDescendant(of: browser)
                    else { return false }
                    let ids = self.selectedIDs()
                    return GridKeyRouter.handle(key, owner: self.owner, first: ids.first, selected: Set(ids))
                }
                return handled ? nil : event
            }
        }

        func removeKeys() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let browser, let owner else { return }
            let row = browser.clickedRow, column = browser.clickedColumn
            if row >= 0, column >= 0, browser.selectedRowIndexes(inColumn: column)?.contains(row) != true {
                browser.selectRow(row, inColumn: column)
                selectionChanged(browser)
            }
            guard let built = owner.gridMenu(Set(selectedIDs())) else { return }
            for item in built.items {
                built.removeItem(item)
                menu.addItem(item)
            }
        }

        // MARK: Drag and drop

        func browser(_: NSBrowser, canDragRowsWith _: IndexSet, inColumn _: Int, with _: NSEvent) -> Bool { true }

        func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
            guard let owner else { return false }
            let nodes = rowIndexes.compactMap { browser.item(atRow: $0, inColumn: column) as? Node }
            owner.columnNoteFolders(nodes.filter(\.isFolder).map(\.path))
            let files = nodes.filter { !$0.isFolder }.map(\.path)
            let writers = nodes.compactMap { owner.gridWriter($0.path) } + owner.gridCompanionWriters(files)
            guard !writers.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(writers)
        }

        /// The folder a drop lands in: a folder row it is on, otherwise the folder the column shows.
        private func dropFolder(_ browser: NSBrowser, row: Int, column: Int, on: Bool) -> URL? {
            if on, row >= 0, let node = browser.item(atRow: row, inColumn: column) as? Node, node.isFolder { return node.url }
            guard let parent = browser.parentForItems(inColumn: column) as? Node else { return nil }
            return parent === root ? base : parent.url
        }

        func browser(
            _ browser: NSBrowser,
            validateDrop info: NSDraggingInfo,
            proposedRow row: UnsafeMutablePointer<Int>,
            column: UnsafeMutablePointer<Int>,
            dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
        ) -> NSDragOperation {
            guard let owner, owner.gridAcceptsDrops, owner.gridCanAccept(info.draggingPasteboard),
                  dropFolder(browser, row: row.pointee, column: column.pointee, on: dropOperation.pointee == .on) != nil
            else { return [] }
            if dropOperation.pointee == .above { row.pointee = -1 }
            if dropOperation.pointee == .on,
               (browser.item(atRow: row.pointee, inColumn: column.pointee) as? Node)?.isFolder != true
            {
                row.pointee = -1
            }
            if NSEvent.modifierFlags.contains(.option) { return .copy }
            let local = info.draggingSource != nil
            return local && (info.draggingPasteboard.types?.contains(.fileURL) ?? false) ? .move : .copy
        }

        func browser(
            _ browser: NSBrowser,
            acceptDrop info: NSDraggingInfo,
            atRow row: Int,
            column: Int,
            dropOperation: NSBrowser.DropOperation
        ) -> Bool {
            guard let owner, let folder = dropFolder(browser, row: row, column: column, on: dropOperation == .on) else { return false }
            let operation: NSDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy : (info.draggingSource != nil ? .move : .copy)
            return owner.gridAcceptDrop(info.draggingPasteboard, operation: operation, into: folder)
        }
    }
}

/// Whether a folder path is `target` or one of its parents.
private enum FolderPath {
    static func contains(_ folder: String, _ target: String) -> Bool { target == folder || target.hasPrefix(folder + "/") }
}

/// The browser's preview column: the selected file's picture and its details.
final class ColumnPreviewController: NSViewController {
    weak var owner: (any MediaListOwner)?
    private var host: NSHostingView<MediaColumnPreview>?

    override func loadView() {
        let id = (representedObject as? MediaColumns.Node)?.path
        let host = NSHostingView(rootView: MediaColumnPreview(id: id, owner: owner))
        // The browser sizes the preview column; the view fills it rather than asking for its own height.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        self.host = host
        view = host
    }

    override var representedObject: Any? {
        didSet {
            let id = (representedObject as? MediaColumns.Node)?.path
            host?.rootView = MediaColumnPreview(id: id, owner: owner)
        }
    }
}

struct MediaColumnPreview: View {
    let id: String?
    weak var owner: (any MediaListOwner)?
    @State private var image: CGImage?
    @State private var facts: [(String, String)] = []

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 240)
            if let id {
                Text(URL(fileURLWithPath: id).lastPathComponent)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                ForEach(facts, id: \.0) { label, value in
                    GridRow {
                        Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(value).lineLimit(1)
                    }
                }
            }
            .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(minWidth: 200, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: id) { await load() }
    }

    private func load() async {
        image = nil
        facts = []
        guard let id else { return }
        let url = URL(fileURLWithPath: id)
        // File details and the pixel size are read off the main actor; analysis facts come from the pane when it has them.
        let read = await Task.detached(priority: .userInitiated) { () -> (String?, Int64?, Date?, Date?, String?) in
            let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                                                           .contentModificationDateKey])
            var pixels: String?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
            {
                pixels = "\(width) × \(height)"
            }
            return (values?.localizedTypeDescription, values?.fileSize.map(Int64.init), values?.creationDate,
                    values?.contentModificationDate, pixels)
        }.value
        guard !Task.isCancelled else { return }
        var rows: [(String, String)] = []
        if let kind = read.0 { rows.append(("Kind", kind)) }
        if let size = read.1 { rows.append(("Size", Format.bytes(size))) }
        let dimensions = owner?.listText(id, .dimensions) ?? ""
        if let pixels = dimensions.isEmpty ? read.4 : dimensions { rows.append(("Dimensions", pixels)) }
        if let duration = owner?.listText(id, .duration), !duration.isEmpty { rows.append(("Duration", duration)) }
        if let created = read.2 { rows.append(("Created", created.formatted(date: .abbreviated, time: .shortened))) }
        if let modified = read.3 { rows.append(("Modified", modified.formatted(date: .abbreviated, time: .shortened))) }
        facts = rows
        image = await owner?.gridThumbnail(id, maxPixel: 512)
    }
}
