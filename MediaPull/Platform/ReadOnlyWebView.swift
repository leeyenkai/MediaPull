import AppKit
import SwiftUI
import WebKit

/// A web view that refuses drags carrying files, so no file on this Mac can be dropped onto a web
/// page (SPEC R-508). Text and links can still be dropped to navigate.
final class ReadOnlyWebView: WKWebView {
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = {
        var types: Set<NSPasteboard.PasteboardType> = [.fileURL, .fileContents, NSPasteboard.PasteboardType("NSFilenamesPboardType")]
        for identifier in NSFilePromiseReceiver.readableDraggedTypes {
            types.insert(NSPasteboard.PasteboardType(identifier))
        }
        types.insert(DragTypes.items)
        return types
    }()

    /// The page's typing has an undo list of its own: the window's is for file changes, so ⌘Z never erases typing in a page
    /// the person is not in (SPEC 21, audit 17, B17-M3).
    private let pageUndo = UndoManager()
    override var undoManager: UndoManager? { pageUndo }

    private func carriesFiles(_ info: NSDraggingInfo) -> Bool {
        let types = Set(info.draggingPasteboard.types ?? [])
        return !types.isDisjoint(with: Self.fileTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesFiles(sender) ? [] : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesFiles(sender) ? false : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        carriesFiles(sender) ? false : super.performDragOperation(sender)
    }
}

/// Hosts an existing web view inside SwiftUI without ever recreating it.
struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ view: NSView, context _: Context) {
        if webView.superview !== view { attach(to: view) }
    }

    private func attach(to container: NSView) {
        // Switching tabs swaps the web view; only the selected tab's view stays in the container.
        for view in container.subviews where view !== webView { view.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

extension ReadOnlyWebView {
    /// Whether keyboard input is going to a web page (the responder is a web view or inside one).
    @MainActor
    static func isTyping(in window: NSWindow?) -> Bool {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is ReadOnlyWebView { return true }
            view = current.superview
        }
        return false
    }
}
