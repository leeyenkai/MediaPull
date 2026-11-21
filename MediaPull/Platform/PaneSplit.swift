import AppKit
import MediaPullCore
import SwiftUI

/// Resizable panes in any arrangement of columns and stacks (SPEC R-701, R-701a). Each pane keeps
/// one hosting controller for the life of the window, so the browser keeps its page when panes move.
/// Divider positions are saved per arrangement.
struct PaneSplit: NSViewControllerRepresentable {
    var arrangement: PaneArrangement
    var visible: Set<PaneID>
    var panes: [PaneID: AnyView]

    func makeNSViewController(context _: Context) -> PaneSplitController {
        let controller = PaneSplitController()
        controller.update(arrangement: arrangement, visible: visible, panes: panes, animated: false)
        return controller
    }

    func updateNSViewController(_ controller: PaneSplitController, context _: Context) {
        controller.update(arrangement: arrangement, visible: visible, panes: panes, animated: true)
    }
}

final class PaneSplitController: NSViewController {
    private var hosts: [PaneID: NSHostingController<AnyView>] = [:]
    private var root: ProportionalSplitViewController?
    private var arrangement: PaneArrangement?
    private var columnItems: [(item: NSSplitViewItem, panes: [PaneID], inner: [NSSplitViewItem])] = []
    private var visible: Set<PaneID> = []
    private static let resetNotification = Notification.Name("MediaPull.ResetPaneSizes")

    private var resetObserver: (any NSObjectProtocol)?

    override func loadView() {
        view = NSView()
        resetObserver = NotificationCenter.default
            .addObserver(forName: Self.resetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let arrangement = self.arrangement else { return }
                self.rebuild(arrangement, visible: self.visible)
            }
        }
    }

    isolated deinit {
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
    }

    /// Forgets every saved divider position and lays the open windows out afresh.
    static func resetSavedSizes() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView Subview Frames MediaPull.") {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: resetNotification, object: nil)
    }

    func update(arrangement: PaneArrangement, visible: Set<PaneID>, panes: [PaneID: AnyView], animated: Bool) {
        self.visible = visible
        for (id, content) in panes {
            if let host = hosts[id] {
                host.rootView = content
            } else {
                let host = NSHostingController(rootView: content)
                host.sizingOptions = []
                hosts[id] = host
            }
        }
        if arrangement != self.arrangement {
            rebuild(arrangement, visible: visible)
        } else {
            applyVisibility(visible, animated: animated)
        }
    }

    private static func minimumWidth(_ pane: PaneID) -> CGFloat {
        switch pane {
        case .source: 360
        case .extracted: 280
        case .preview: 240
        case .library: 200
        case .downloads: 240
        case .organiseSource: 300
        case .organiseWork: 300
        case .organiseTarget: 260
        case .organiseMap: 280
        case .devicesList: 220
        case .devicesMedia: 320
        case .devicesImport: 240
        }
    }

    private static func widthWeight(_ pane: PaneID) -> CGFloat {
        switch pane {
        case .source: 42
        case .extracted: 36
        case .preview: 26
        case .library: 22
        case .downloads: 42
        case .organiseSource: 40
        case .organiseWork: 28
        case .organiseTarget: 32
        case .organiseMap: 28
        case .devicesList: 22
        case .devicesMedia: 52
        case .devicesImport: 26
        }
    }

    private static func heightWeight(_ pane: PaneID) -> CGFloat {
        switch pane {
        case .source: 60
        case .extracted: 58
        case .preview: 42
        case .library: 50
        case .downloads: 40
        case .organiseSource: 50
        case .organiseWork: 50
        case .organiseTarget: 50
        case .organiseMap: 60
        case .devicesList: 50
        case .devicesMedia: 50
        case .devicesImport: 50
        }
    }

    /// Lower holding priority grows first when the window widens: the browser, then the media grid.
    private static func holding(_ pane: PaneID) -> Float {
        switch pane {
        case .source: 250
        case .extracted: 254
        case .preview: 257
        case .library: 260
        case .downloads: 252
        case .organiseSource: 250
        case .organiseWork: 258
        case .organiseTarget: 254
        case .organiseMap: 258
        case .devicesList: 258
        case .devicesMedia: 250
        case .devicesImport: 256
        }
    }

    private func rebuild(_ arrangement: PaneArrangement, visible: Set<PaneID>) {
        if let root {
            for column in columnItems {
                if let inner = column.item.viewController as? NSSplitViewController {
                    for item in inner.splitViewItems { inner.removeSplitViewItem(item) }
                }
                root.removeSplitViewItem(column.item)
            }
            root.view.removeFromSuperview()
            root.removeFromParent()
        }
        columnItems = []
        self.arrangement = arrangement

        let columns = arrangement.columns
        let outer = ProportionalSplitViewController(
            fractions: columns.map { $0.map(Self.widthWeight).max() ?? 30 },
            autosave: "MediaPull.Columns." + arrangement.key, vertical: true
        )
        for (index, column) in columns.enumerated() {
            var inner: [NSSplitViewItem] = []
            let controller: NSViewController
            if column.count == 1, let host = hosts[column[0]] {
                controller = host
            } else {
                let stack = ProportionalSplitViewController(
                    fractions: column.map(Self.heightWeight), autosave: "MediaPull.Stack.\(arrangement.key).\(index)", vertical: false
                )
                for pane in column {
                    guard let host = hosts[pane] else { continue }
                    let item = NSSplitViewItem(viewController: host)
                    item.minimumThickness = 150
                    item.canCollapse = true
                    item.holdingPriority = NSLayoutConstraint.Priority(Self.holding(pane))
                    stack.addSplitViewItem(item)
                    inner.append(item)
                }
                stack.finishSetup()
                controller = stack
            }
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = column.map(Self.minimumWidth).max() ?? 200
            item.canCollapse = true
            item.holdingPriority = NSLayoutConstraint.Priority(column.map(Self.holding).min() ?? 255)
            outer.addSplitViewItem(item)
            columnItems.append((item, column, inner))
        }
        outer.finishSetup()
        addChild(outer)
        outer.view.frame = view.bounds
        outer.view.autoresizingMask = [.width, .height]
        view.addSubview(outer.view)
        root = outer
        applyVisibility(visible, animated: false)
    }

    private func applyVisibility(_ visible: Set<PaneID>, animated: Bool) {
        func set(_ item: NSSplitViewItem, collapsed: Bool) {
            guard item.isCollapsed != collapsed else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    item.animator().isCollapsed = collapsed
                }
            } else {
                item.isCollapsed = collapsed
            }
        }
        for column in columnItems {
            let shown = column.panes.filter(visible.contains)
            for (pane, item) in zip(column.panes, column.inner) {
                set(item, collapsed: !visible.contains(pane))
            }
            set(column.item, collapsed: shown.isEmpty)
        }
    }
}

/// Sets sensible starting sizes the first time an arrangement is shown, before any divider
/// positions were saved for it.
final class ProportionalSplitViewController: NSSplitViewController {
    private var placed = false
    private let fractions: [CGFloat]
    private let autosave: String
    private let vertical: Bool

    init(fractions: [CGFloat], autosave: String, vertical: Bool) {
        self.fractions = fractions
        self.autosave = autosave
        self.vertical = vertical
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Call after adding the items: autosaving only restores sizes for items that already exist.
    func finishSetup() {
        splitView.isVertical = vertical
        splitView.dividerStyle = .thin
        // A self-test lays panes out from the starting fractions and leaves the person's saved sizes alone (audit 8, B8-m7).
        if !SelfTestRunner.isActive { splitView.autosaveName = autosave }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let length = vertical ? view.bounds.width : view.bounds.height
        guard !placed, length > 300 else { return }
        placed = true
        let saved = !SelfTestRunner.isActive && UserDefaults.standard.object(forKey: "NSSplitView Subview Frames " + autosave) != nil
        guard !saved, fractions.count > 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let total = self.fractions.reduce(0, +)
            let available = self.vertical ? self.splitView.bounds.width : self.splitView.bounds.height
            var position: CGFloat = 0
            for (index, fraction) in self.fractions.dropLast().enumerated() {
                position += available * fraction / total
                self.splitView.setPosition(position.rounded(), ofDividerAt: index)
            }
        }
    }
}

/// Lets a SwiftUI view find its NSWindow.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
