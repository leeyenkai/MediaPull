import AppKit
import QuartzCore
import SwiftUI

/// What a grid cell shows.
struct GridCellInfo: Equatable {
    var title: String?
    var detail: String
    var secondary: String
    var kindSymbol: String?
    var stateSymbol: String?
    var stateColor: NSColor = .systemGreen
    var progress: Double?
    var placeholderSymbol = "photo"
    var dimmed = false
    /// A coloured frame drawn when the cell is not selected, such as the duplicate highlight.
    var highlight: NSColor?
    /// Changes when the file behind the cell changes in place, so its thumbnail is drawn again.
    var stamp = ""
}

struct GridSection: Hashable {
    var id: String
    var title: String
    var ids: [String]
}

/// Callbacks a grid owner provides.
@MainActor
protocol MediaGridOwner: AnyObject {
    func gridInfo(_ id: String) -> GridCellInfo?
    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage?
    func gridSelectionChanged(_ ids: Set<String>)
    func gridActivate(_ id: String)
    func gridQuickLook()
    func gridWriter(_ id: String) -> NSPasteboardWriting?
    /// More files that travel with a drag of these items, such as their metadata files (R-1801).
    func gridCompanionWriters(_ ids: [String]) -> [NSPasteboardWriting]
    func gridMenu(_ ids: Set<String>) -> NSMenu?
    func gridAppeared(_ id: String)
    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation: NSDragOperation) -> Bool
    var gridAcceptsDrops: Bool { get }
    func gridCanAccept(_ pasteboard: NSPasteboard) -> Bool
    /// Return on a selected item; Activate (open) unless the owner renames instead.
    func gridReturn(_ id: String)
    /// ⌘⌫ on the selection.
    func gridDelete(_ ids: Set<String>)
    /// A trackpad pinch over the grid; `amount` is the event's magnification.
    func gridMagnify(_ amount: CGFloat)
}

extension MediaGridOwner {
    func gridCanAccept(_: NSPasteboard) -> Bool { true }
    func gridCompanionWriters(_: [String]) -> [NSPasteboardWriting] { [] }
    func gridReturn(_ id: String) { gridActivate(id) }
    func gridDelete(_: Set<String>) {}
    func gridMagnify(_: CGFloat) {}
}

/// A virtualized thumbnail grid on NSCollectionView (SPEC R-1001 to R-1003).
struct MediaGrid: NSViewRepresentable {
    var sections: [GridSection]
    var selection: Set<String>
    var cellSize: CGFloat
    var revision: Int
    weak var owner: (any MediaGridOwner)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let collection = MediaCollectionView()
        collection.coordinator = coordinator
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 6, left: 10, bottom: 12, right: 10)
        collection.collectionViewLayout = layout
        collection.register(MediaGridItem.self, forItemWithIdentifier: MediaGridItem.identifier)
        collection.register(GridHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridHeaderView.identifier)
        collection.delegate = coordinator
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        coordinator.collection = collection
        coordinator.makeDataSource()
        let scroll = NSScrollView()
        collection.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        collection.autoresizingMask = [.width]
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = owner
        // Files and Extracted items only: no grid can take file promises from other apps (R-1801). Registered once.
        if let owner, owner.gridAcceptsDrops, !coordinator.registeredDrops {
            coordinator.collection?.registerForDraggedTypes([.fileURL, DragTypes.items])
            coordinator.registeredDrops = true
        }
        coordinator.update(sections: sections, selection: selection, cellSize: cellSize, revision: revision)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var registeredDrops = false
        weak var collection: MediaCollectionView?
        weak var owner: (any MediaGridOwner)?
        var dataSource: NSCollectionViewDiffableDataSource<String, String>?
        var sections: [GridSection] = []
        var titles: [String: String] = [:]
        var cellSize: CGFloat = 0
        var revision = -1
        var applyingSelection = false

        func makeDataSource() {
            guard let collection else { return }
            let source = NSCollectionViewDiffableDataSource<String, String>(collectionView: collection) { [weak self] view, indexPath, id in
                let item = view.makeItem(withIdentifier: MediaGridItem.identifier, for: indexPath) as? MediaGridItem
                if let item, let self { self.configure(item, id: id) }
                return item
            }
            source.supplementaryViewProvider = { [weak self] view, kind, indexPath in
                let header = view.makeSupplementaryView(ofKind: kind, withIdentifier: GridHeaderView.identifier, for: indexPath)
                    as? GridHeaderView
                if let self, indexPath.section < self.sections.count {
                    header?.label.stringValue = self.sections[indexPath.section].title
                }
                return header
            }
            dataSource = source
        }

        func configure(_ item: MediaGridItem, id: String) {
            guard let owner else { return }
            item.cellSize = cellSize
            let info = owner.gridInfo(id)
            item.apply(id: id, info: info) { [weak owner] maxPixel in
                await owner?.gridThumbnail(id, maxPixel: maxPixel)
            }
            owner.gridAppeared(id)
        }

        func update(sections: [GridSection], selection: Set<String>, cellSize: CGFloat, revision: Int) {
            guard let collection, let dataSource else { return }
            let sizeChanged = cellSize != self.cellSize
            self.cellSize = cellSize
            if sizeChanged, let layout = collection.collectionViewLayout as? NSCollectionViewFlowLayout {
                layout.itemSize = NSSize(width: cellSize, height: cellSize + 36)
                layout.invalidateLayout()
            }
            let structureChanged = sections != self.sections
            if structureChanged {
                self.sections = sections
                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                // Section and item ids are tracked apart, so an item whose id equals a section id is still shown.
                var seenSections = Set<String>()
                var seenItems = Set<String>()
                for section in sections where seenSections.insert(section.id).inserted {
                    let ids = section.ids.filter { seenItems.insert($0).inserted }
                    snapshot.appendSections([section.id])
                    snapshot.appendItems(ids, toSection: section.id)
                }
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            if revision != self.revision || sizeChanged || structureChanged {
                self.revision = revision
                for case let item as MediaGridItem in collection.visibleItems() {
                    if let id = item.itemID { configure(item, id: id) }
                }
            }
            let current = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            if current != selection {
                applyingSelection = true
                let paths = Set(selection.compactMap { dataSource.indexPath(for: $0) })
                collection.selectionIndexPaths = paths
                applyingSelection = false
            }
        }

        func selectedIDs() -> Set<String> {
            guard let collection, let dataSource else { return [] }
            return Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
        }

        func id(at indexPath: IndexPath) -> String? {
            dataSource?.itemIdentifier(for: indexPath)
        }

        func collectionView(_: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
            guard !applyingSelection else { return }
            owner?.gridSelectionChanged(selectedIDs())
        }

        func collectionView(_: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
            guard !applyingSelection else { return }
            owner?.gridSelectionChanged(selectedIDs())
        }

        func collectionView(_: NSCollectionView, layout _: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
            guard section < sections.count, !sections[section].title.isEmpty, sections.count > 1 else { return .zero }
            return NSSize(width: 100, height: 26)
        }

        func collectionView(_: NSCollectionView, layout _: NSCollectionViewLayout, sizeForItemAt _: IndexPath) -> NSSize {
            NSSize(width: cellSize, height: cellSize + 36)
        }

        func collectionView(_: NSCollectionView, canDragItemsAt _: Set<IndexPath>, with _: NSEvent) -> Bool { true }

        func collectionView(_: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let id = id(at: indexPath) else { return nil }
            return owner?.gridWriter(id)
        }

        func collectionView(
            _: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt _: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        )
        {
            let extras = owner?.gridCompanionWriters(indexPaths.compactMap { id(at: $0) }) ?? []
            // writeObjects adds items after the ones already on the drag pasteboard.
            if !extras.isEmpty { session.draggingPasteboard.writeObjects(extras) }
        }

        func collectionView(
            _: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath _: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation
        {
            guard owner?.gridAcceptsDrops ?? false, owner?.gridCanAccept(draggingInfo.draggingPasteboard) ?? false else { return [] }
            if draggingInfo.draggingSource as? NSCollectionView === collection { return [] }
            dropOperation.pointee = .before
            let local = draggingInfo.draggingSource != nil
            if NSEvent.modifierFlags.contains(.option) { return .copy }
            return local && (draggingInfo.draggingPasteboard.types?.contains(.fileURL) ?? false) ? .move : .copy
        }

        func collectionView(_: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath _: IndexPath,
                            dropOperation _: NSCollectionView.DropOperation) -> Bool
        {
            let operation: NSDragOperation = NSEvent.modifierFlags.contains(.option) ? .copy
                : (draggingInfo.draggingSource != nil ? .move : .copy)
            return owner?.gridAcceptDrop(draggingInfo.draggingPasteboard, operation: operation) ?? false
        }
    }
}

/// Handles double-click, Space for Quick Look and the context menu.
final class MediaCollectionView: NSCollectionView {
    weak var coordinator: MediaGrid.Coordinator?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let indexPath = indexPathForItem(at: point), let id = coordinator?.id(at: indexPath) {
                coordinator?.owner?.gridActivate(id)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            coordinator?.owner?.gridQuickLook()
            return
        }
        if event.keyCode == 36, let first = selectionIndexPaths.first, let id = coordinator?.id(at: first) {
            coordinator?.owner?.gridReturn(id)
            return
        }
        if event.keyCode == 51, event.modifierFlags.contains(.command), let ids = coordinator?.selectedIDs(), !ids.isEmpty {
            coordinator?.owner?.gridDelete(ids)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point), !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
            coordinator?.owner?.gridSelectionChanged(coordinator?.selectedIDs() ?? [])
        }
        return coordinator?.owner?.gridMenu(coordinator?.selectedIDs() ?? [])
    }

    override func magnify(with event: NSEvent) {
        coordinator?.owner?.gridMagnify(event.magnification)
    }

    override var acceptsFirstResponder: Bool { true }
}

final class GridHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridHeader")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }
}

final class MediaGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("MediaGridItem")
    private(set) var itemID: String?
    var cellSize: CGFloat = 140
    private var info: GridCellInfo?
    private var loadTask: Task<Void, Never>?
    private var loadedFor: String?
    private let cell = MediaCellView()

    override func loadView() {
        view = cell
    }

    override var isSelected: Bool {
        didSet { cell.isSelected = isSelected }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { cell.isHighlighted = highlightState == .forSelection }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        loadedFor = nil
        itemID = nil
        cell.image = nil
    }

    func apply(id: String, info: GridCellInfo?, loader: @escaping (Int) async -> CGImage?) {
        let changedItem = itemID != id
        itemID = id
        if let info, info != self.info || changedItem {
            self.info = info
            cell.apply(info)
        } else {
            // A theme change reconfigures every cell without changing its info; the accent still has to follow.
            cell.refreshAccent()
        }
        let scale = view.window?.backingScaleFactor ?? 2
        // Thumbnails are decoded in 128 px steps so zooming does not re-decode on every slider tick.
        let maxPixel = min(768, Int((cellSize * scale / 128).rounded(.up)) * 128)
        let key = "\(id)#\(maxPixel)#\(info?.stamp ?? "")"
        guard loadedFor != key else { return }
        if changedItem { cell.image = nil }
        loadedFor = key
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let image = await loader(maxPixel)
            guard !Task.isCancelled, let self, self.itemID == id else { return }
            if let image { self.cell.image = image } else { self.loadedFor = nil }
        }
    }
}

/// The cell's drawing: thumbnail, badges and selection ring, all on layers.
final class MediaCellView: NSView {
    private let thumbLayer = CALayer()
    private let frameLayer = CALayer()
    private let placeholder = NSImageView()
    private let kindBadge = NSImageView()
    private let stateBadge = NSImageView()
    private let progressLayer = CAShapeLayer()
    private let detailLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")

    var image: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.contents = image
            CATransaction.commit()
            placeholder.isHidden = image != nil
        }
    }

    var isSelected = false { didSet { updateSelection() } }
    var isHighlighted = false { didSet { updateSelection() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        frameLayer.cornerRadius = 8
        frameLayer.masksToBounds = true
        frameLayer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        thumbLayer.contentsGravity = .resizeAspect
        thumbLayer.minificationFilter = .trilinear
        frameLayer.addSublayer(thumbLayer)
        layer?.addSublayer(frameLayer)
        placeholder.symbolConfiguration = .init(pointSize: 26, weight: .light)
        placeholder.contentTintColor = .tertiaryLabelColor
        for badge in [kindBadge, stateBadge] {
            badge.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
            badge.wantsLayer = true
            badge.layer?.shadowOpacity = 0.6
            badge.layer?.shadowRadius = 2
            badge.layer?.shadowOffset = .zero
        }
        kindBadge.contentTintColor = .white
        progressLayer.fillColor = nil
        progressLayer.strokeColor = AppTheme.currentAccent.cgColor
        progressLayer.lineWidth = 3
        progressLayer.lineCap = .round
        layer?.addSublayer(progressLayer)
        for label in [detailLabel, secondaryLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            label.alignment = .center
            label.maximumNumberOfLines = 1
        }
        detailLabel.textColor = .labelColor
        secondaryLabel.textColor = .secondaryLabelColor
        for view in [placeholder, kindBadge, stateBadge, detailLabel, secondaryLabel] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    private var fullDetail = ""
    private var fullSecondary = ""

    private var highlight: NSColor?

    func apply(_ info: GridCellInfo) {
        highlight = info.highlight
        updateSelection()
        fullDetail = info.title ?? info.detail
        fullSecondary = info.title == nil ? info.secondary : [info.detail, info.secondary].filter { !$0.isEmpty }.joined(separator: " · ")
        placeholder.image = NSImage(systemSymbolName: info.placeholderSymbol, accessibilityDescription: nil)
        kindBadge.image = info.kindSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        kindBadge.isHidden = info.kindSymbol == nil
        stateBadge.image = info.stateSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        stateBadge.contentTintColor = info.stateColor
        stateBadge.isHidden = info.stateSymbol == nil
        alphaValue = info.dimmed ? 0.45 : 1
        if let progress = info.progress {
            progressLayer.isHidden = false
            progressLayer.strokeEnd = max(0.03, min(1, progress))
        } else {
            progressLayer.isHidden = true
        }
        setAccessibilityLabel([info.title, info.detail, info.secondary].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    func refreshAccent() {
        progressLayer.strokeColor = AppTheme.currentAccent.cgColor
        updateSelection()
    }

    private func updateSelection() {
        let selected = isSelected || isHighlighted
        if !selected, let highlight {
            frameLayer.borderWidth = 2
            frameLayer.borderColor = highlight.cgColor
            frameLayer.backgroundColor = highlight.withAlphaComponent(0.14).cgColor
            return
        }
        frameLayer.borderWidth = selected ? 3 : 0
        frameLayer.borderColor = AppTheme.currentAccent.cgColor
        frameLayer.backgroundColor = selected ? AppTheme.currentAccent.withAlphaComponent(0.18).cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
    }

    override func layout() {
        super.layout()
        let side = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = CGRect(x: 0, y: bounds.height - side, width: side, height: side)
        thumbLayer.frame = frameLayer.bounds.insetBy(dx: 3, dy: 3)
        let ring = CGRect(x: side - 26, y: bounds.height - 26, width: 18, height: 18)
        progressLayer.path = CGPath(ellipseIn: ring, transform: nil)
        CATransaction.commit()
        placeholder.frame = NSRect(x: 0, y: bounds.height - side, width: side, height: side)
        kindBadge.frame = NSRect(x: 7, y: bounds.height - 25, width: 18, height: 18)
        stateBadge.frame = NSRect(x: side - 26, y: bounds.height - 26, width: 20, height: 20)
        detailLabel.frame = NSRect(x: 0, y: 16, width: side, height: 15)
        secondaryLabel.frame = NSRect(x: 0, y: 1, width: side, height: 15)
        detailLabel.stringValue = Self.fitting(fullDetail, font: detailLabel.font, width: side - 12)
        secondaryLabel.stringValue = Self.fitting(fullSecondary, font: secondaryLabel.font, width: side - 12)
    }

    /// Drops trailing "·" parts (format, then duration) until the caption fits, so small cells keep whole
    /// numbers rather than truncating "1500×1500" in the middle.
    static func fitting(_ text: String, font: NSFont?, width: CGFloat) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 10.5)]
        var parts = text.components(separatedBy: " · ")
        while parts.count > 1, (parts.joined(separator: " · ") as NSString).size(withAttributes: attributes).width > width {
            parts.removeLast()
        }
        return parts.joined(separator: " · ")
    }

    override var isFlipped: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelection()
        progressLayer.strokeColor = AppTheme.currentAccent.cgColor
    }
}
