import AppKit
import MediaPullCore
import SwiftUI
import UniformTypeIdentifiers

/// A Finder-style list (R-1709): one row per item with a small thumbnail and columns, subfolders that open in place with a
/// disclosure triangle, and header clicks that sort through the pane's own sort. Everything else (open, Quick Look,
/// menus, drag and drop, Trash) goes through the same owner callbacks as the grid.
struct MediaList: NSViewRepresentable {
    var sections: [GridSection]
    var topFolders: [String]
    var selection: Set<String>
    var revision: Int
    weak var owner: (any MediaListOwner)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = MediaOutlineView()
        let coordinator = context.coordinator
        outline.coordinator = coordinator
        coordinator.outline = outline
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.style = .fullWidth
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.rowHeight = 24
        outline.intercellSpacing = NSSize(width: 6, height: 2)
        outline.target = coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = owner
        owner?.onListChildrenLoaded = { [weak coordinator] id in coordinator?.childrenLoaded(id) }
        coordinator.update(sections: sections, topFolders: topFolders, selection: selection, revision: revision)
    }

    /// A row: a group heading (Events, Group Similar), a folder that opens in place, or a file.
    final class Node {
        enum Kind: Equatable { case group(String), folder, file }

        let id: String
        let kind: Kind
        /// Read from the owner when first shown; nil until then.
        var children: [Node]?

        init(id: String, kind: Kind, children: [Node]? = nil) {
            self.id = id
            self.kind = kind
            self.children = children
        }

        var isGroup: Bool { if case .group = kind { true } else { false } }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        weak var owner: (any MediaListOwner)?
        weak var outline: MediaOutlineView?
        private var roots: [Node] = []
        private var shownSections: [GridSection] = []
        private var shownFolders: [String] = []
        /// Rows by id, for selecting and refreshing without walking the tree.
        private var index: [String: Node] = [:]
        private var lastRevision = -1
        private var shownGeneration = -1
        /// Folders that were open before the rows were rebuilt; each opens again once its contents are read.
        private var pendingExpand: Set<String> = []
        private var applyingSelection = false
        private var applyingSort = false
        private var columnsBuilt = false

        // MARK: Updates

        func update(sections: [GridSection], topFolders: [String], selection: Set<String>, revision: Int) {
            guard let outline, let owner else { return }
            if !columnsBuilt { buildColumns(owner.listColumns) }
            // New rows, or the opened folders' contents were dropped (a reload after files changed): rebuild, so no row
            // keeps an id the pane no longer knows.
            if sections != shownSections || topFolders != shownFolders || owner.listGeneration != shownGeneration {
                shownSections = sections
                shownFolders = topFolders
                shownGeneration = owner.listGeneration
                let expanded = expandedIDs()
                pendingExpand = expanded
                index = [:]
                if sections.count > 1 {
                    roots = sections.map { section in
                        Node(id: "group:\(section.id)", kind: .group(section.title), children: section.ids.map { make($0, .file) })
                    }
                } else {
                    roots = topFolders.map { make($0, .folder) } + sections.flatMap(\.ids).map { make($0, .file) }
                }
                outline.reloadData()
                for node in roots where node.isGroup {
                    outline.expandItem(node)
                }
                reexpand(expanded, in: roots)
                lastRevision = revision
            } else if revision != lastRevision {
                lastRevision = revision
                // Same rows, new details (sizes measured, analysis results): redraw only what is on screen.
                let visible = outline.rows(in: outline.visibleRect)
                if visible.length > 0 {
                    outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location ..< visible.location + visible.length),
                                       columnIndexes: IndexSet(integersIn: 0 ..< outline.numberOfColumns))
                }
            }
            applySortIndicator()
            applySelection(selection)
        }

        private func buildColumns(_ columns: [ListColumn]) {
            guard let outline, let owner else { return }
            columnsBuilt = true
            for column in columns {
                let table = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
                table.title = column.title
                table.minWidth = column == .name ? 160 : 50
                table.width = switch column {
                case .name: 280
                case .date: 150
                case .size, .duration, .found: 70
                case .dimensions: 100
                case .kind: 110
                case .source, .tags: 140
                }
                if [.size, .dimensions, .duration, .found].contains(column) { table.headerCell.alignment = .right }
                if owner.listCanSort(column) {
                    table.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column.defaultAscending)
                }
                outline.addTableColumn(table)
                if column == .name { outline.outlineTableColumn = table }
            }
        }

        private func applySortIndicator() {
            guard let outline else { return }
            let wanted = owner?.listSort.map { [NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending)] } ?? []
            guard outline.sortDescriptors != wanted else { return }
            applyingSort = true
            outline.sortDescriptors = wanted
            applyingSort = false
        }

        private func make(_ id: String, _ kind: Node.Kind) -> Node {
            let node = Node(id: id, kind: kind)
            index[id] = node
            return node
        }

        private func applySelection(_ selection: Set<String>) {
            guard let outline, selectedIDs() != selection else { return }
            var rows = IndexSet()
            for id in selection {
                if let node = index[id] {
                    let row = outline.row(forItem: node)
                    if row >= 0 { rows.insert(row) }
                }
            }
            applyingSelection = true
            outline.selectRowIndexes(rows, byExtendingSelection: false)
            applyingSelection = false
        }

        /// Contents of an opened folder arrived: show them under its row.
        func childrenLoaded(_ id: String) {
            guard let outline, let node = index[id], case .folder = node.kind else { return }
            node.children = nil
            outline.reloadItem(node, reloadChildren: true)
            if pendingExpand.remove(id) != nil { outline.expandItem(node) }
            for child in children(of: node) where pendingExpand.contains(child.id) {
                outline.expandItem(child)
            }
        }

        private func expandedIDs() -> Set<String> {
            guard let outline else { return [] }
            var ids = Set<String>()
            for row in 0 ..< outline.numberOfRows {
                if let node = outline.item(atRow: row) as? Node, case .folder = node.kind, outline.isItemExpanded(node) { ids.insert(node.id) }
            }
            return ids
        }

        private func reexpand(_ ids: Set<String>, in nodes: [Node]) {
            guard let outline, !ids.isEmpty else { return }
            for node in nodes where ids.contains(node.id) {
                outline.expandItem(node)
                if let children = node.children { reexpand(ids, in: children) }
            }
        }

        func selectedIDs() -> Set<String> {
            guard let outline else { return [] }
            return Set(outline.selectedRowIndexes.compactMap { row in
                (outline.item(atRow: row) as? Node).flatMap { $0.isGroup ? nil : $0.id }
            })
        }

        func firstSelectedID() -> String? {
            guard let outline, let row = outline.selectedRowIndexes.first else { return nil }
            return (outline.item(atRow: row) as? Node).flatMap { $0.isGroup ? nil : $0.id }
        }

        // MARK: Data source

        private func children(of item: Any?) -> [Node] {
            guard let node = item as? Node else { return roots }
            if let children = node.children { return children }
            guard case .folder = node.kind, let owner, let ids = owner.listChildren(node.id) else { return [] }
            let children = ids.map { make($0, owner.listIsFolder($0) ? .folder : .file) }
            node.children = children
            return children
        }

        func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }

        func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }

        func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            if case .file = node.kind { return false }
            return true
        }

        // MARK: Rows

        func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.isGroup ?? false }

        func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool { !((item as? Node)?.isGroup ?? false) }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let owner else { return nil }
            if case let .group(title) = node.kind {
                let cell = ListTextCell.make(in: outlineView, identifier: "group")
                cell.textField?.stringValue = title
                cell.textField?.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                return cell
            }
            guard let identifier = tableColumn?.identifier, let column = ListColumn(rawValue: identifier.rawValue) else { return nil }
            if column == .name {
                // A row on screen is measured like a grid cell (sizes and unverified originals, R-912).
                if node.kind == .file { owner.gridAppeared(node.id) }
                let cell = ListNameCell.make(in: outlineView)
                cell.show(id: node.id, name: owner.listText(node.id, .name), isFolder: node.kind == .folder, owner: owner)
                return cell
            }
            let cell = ListTextCell.make(in: outlineView, identifier: column.rawValue)
            cell.textField?.stringValue = owner.listText(node.id, column)
            cell.textField?.alignment = [.size, .dimensions, .duration, .found].contains(column) ? .right : .left
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }

        func outlineView(_: NSOutlineView, typeSelectStringFor _: NSTableColumn?, item: Any) -> String? {
            guard let node = item as? Node, !node.isGroup else { return nil }
            return owner?.listText(node.id, .name)
        }

        func outlineViewSelectionDidChange(_: Notification) {
            guard !applyingSelection else { return }
            owner?.gridSelectionChanged(selectedIDs())
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
            guard !applyingSort, let owner, let key = outlineView.sortDescriptors.first?.key, let column = ListColumn(rawValue: key) else {
                return
            }
            // The pane sorts (off the main actor); the list shows its order. A new column starts in its own direction.
            let next = ListSortState.next(clicked: column, current: owner.listSort)
            owner.listSortChanged(next.column, ascending: next.ascending)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node, !node.isGroup else { return }
            owner?.gridActivate(node.id)
        }

        // MARK: Drag and drop

        func outlineView(_: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node, !node.isGroup else { return nil }
            return owner?.gridWriter(node.id)
        }

        func outlineView(_: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt _: NSPoint, forItems items: [Any]) {
            let ids = items.compactMap { ($0 as? Node).flatMap { $0.isGroup ? nil : $0.id } }
            let extras = owner?.gridCompanionWriters(ids) ?? []
            if !extras.isEmpty { session.draggingPasteboard.writeObjects(extras) }
            DragTypes.fromMediaPull = true
        }

        func outlineView(_: NSOutlineView, draggingSession _: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            DragTypes.fromMediaPull = false
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                         proposedChildIndex _: Int) -> NSDragOperation
        {
            guard let owner, owner.gridAcceptsDrops, owner.gridCanAccept(info.draggingPasteboard) else { return [] }
            let fromHere = info.draggingSource as? NSOutlineView === outlineView
            if let node = item as? Node, case .folder = node.kind {
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                // Onto the pane's folder: a drag within the list that is not onto a folder changes nothing.
                guard !fromHere else { return [] }
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            if NSEvent.modifierFlags.contains(.option) { return .copy }
            let local = info.draggingSource != nil
            return local && (info.draggingPasteboard.types?.contains(.fileURL) ?? false) ? .move : .copy
        }

        func outlineView(_: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex _: Int) -> Bool {
            let operation: NSDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy : (info.draggingSource != nil ? .move : .copy)
            if let node = item as? Node, case .folder = node.kind {
                return owner?.gridAcceptDrop(info.draggingPasteboard, operation: operation, into: URL(fileURLWithPath: node.id)) ?? false
            }
            return owner?.gridAcceptDrop(info.draggingPasteboard, operation: operation) ?? false
        }
    }
}

/// The list's keys (Space, Return, ⌘⌫), context menu and focus, as in the grid.
final class MediaOutlineView: NSOutlineView {
    weak var coordinator: MediaList.Coordinator?

    override func keyDown(with event: NSEvent) {
        let selected = coordinator?.selectedIDs() ?? []
        if GridKeyRouter.handle(event, owner: coordinator?.owner, first: coordinator?.firstSelectedID(), selected: selected) { return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.owner?.gridMenu(coordinator?.selectedIDs() ?? [])
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.owner?.gridFocused() }
        return became
    }
}

/// A text cell, reused by identifier.
final class ListTextCell: NSTableCellView {
    static func make(in outline: NSOutlineView, identifier: String) -> ListTextCell {
        let id = NSUserInterfaceItemIdentifier("text-\(identifier)")
        if let cell = outline.makeView(withIdentifier: id, owner: nil) as? ListTextCell { return cell }
        let cell = ListTextCell()
        cell.identifier = id
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// The name cell: a small thumbnail (a folder icon for folders) and the name. Thumbnails come from the owner, decoded
/// off the main actor and cached.
final class ListNameCell: NSTableCellView {
    private var shownID: String?
    private var loadTask: Task<Void, Never>?

    static func make(in outline: NSOutlineView) -> ListNameCell {
        let id = NSUserInterfaceItemIdentifier("name")
        if let cell = outline.makeView(withIdentifier: id, owner: nil) as? ListNameCell { return cell }
        let cell = ListNameCell()
        cell.identifier = id
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(field)
        cell.imageView = image
        cell.textField = field
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 20),
            image.heightAnchor.constraint(equalToConstant: 20),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func show(id: String, name: String, isFolder: Bool, owner: any MediaGridOwner) {
        textField?.stringValue = name
        // Keyed with the file's stamp (size and date), as the grid does, so a picture edited in place is drawn again.
        let key = "\(id)#\(owner.gridInfo(id)?.stamp ?? "")"
        guard key != shownID else { return }
        shownID = key
        loadTask?.cancel()
        if isFolder {
            imageView?.image = NSWorkspace.shared.icon(for: .folder)
            return
        }
        // Files show their kind's icon until the thumbnail arrives; extracted items (not files) show the grid's placeholder.
        if id.hasPrefix("/") {
            imageView?.image = NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(fileURLWithPath: id).pathExtension) ?? .data)
        } else {
            let symbol = owner.gridInfo(id)?.placeholderSymbol ?? "photo"
            imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        loadTask = Task { [weak self, weak owner] in
            guard let image = await owner?.gridThumbnail(id, maxPixel: 64), let self, !Task.isCancelled, self.shownID == id else { return }
            self.imageView?.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }
}
