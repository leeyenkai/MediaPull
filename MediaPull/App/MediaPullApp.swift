import MediaPullCore
import SwiftUI

@main
struct MediaPullApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let app = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindow()
        }
        .defaultSize(width: 1500, height: 920)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { AppCommands() }

        Window("Activity", id: "activity") {
            ActivityView()
        }
        .defaultSize(width: 520, height: 480)
        .keyboardShortcut("j", modifiers: [.command, .shift])

        Window("Converter", id: "converter") {
            ConverterView()
        }
        .defaultSize(width: 560, height: 600)
        .keyboardShortcut("k", modifiers: [.command, .shift])

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Analysis picks up where it stopped at the next launch, so only other jobs ask before quitting.
        AppModel.shared.analysis.cancelScan()
        let running = AppModel.shared.jobs.jobs.filter { $0.state.isActive && $0.kind != .analyse }
        guard !running.isEmpty, !SelfTestRunner.isActive else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "\(running.count) job\(running.count == 1 ? " is" : "s are") still running"
        alert.informativeText = "Quitting stops them. Instagram pulls can be resumed later and continue where they stopped."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            running.forEach { $0.cancel() }
            return .terminateNow
        }
        return .terminateCancel
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    @Environment(\.openWindow) private var openWindow

    private func paneToggle(_ pane: PaneID, key: Character) -> some View {
        let showing = window?.isShowing(pane) ?? true
        return Button(showing ? "Hide \(pane.title)" : "Show \(pane.title)") { window?.setShowing(pane, !showing) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { window?.newTab() }
                .keyboardShortcut("t")
                .disabled(window == nil)
            // Listed before the window's Close item, so ⌘W closes a tab first and the window with its last tab.
            Button("Close Tab") { if let window { window.closeTab(window.selectedTabID) } }
                .keyboardShortcut("w")
                .disabled(window == nil)
            Button("Reopen Closed Tab") { window?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(window?.canReopenClosedTab ?? false))
            Divider()
            Button("Pull Instagram Account…") {
                window?.showDownloads(window?.pageKind.instagramUsername.map { "@\($0)" })
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(window == nil)
            Button("Save Video from This Page…") { window?.showDownloads(video: true) }
                .keyboardShortcut("y", modifiers: [.command, .shift])
                .disabled(window?.browser.url == nil)
            if window?.section == .organise {
                Button("Open Folder to Organise…") { if let window { window.organise.chooseFolder(for: window.organise.source) } }
                    .keyboardShortcut("o")
            } else {
                Button("Open PDF…") {
                    PDFPicker.choose(window: window?.hostWindow) { files in files.forEach { window?.extractPDF(local: $0) } }
                }
                .keyboardShortcut("o")
                .disabled(window == nil)
            }
            Divider()
            Button("Save to Library") { window?.saveToLibrary() }
                .keyboardShortcut("s")
                .disabled(window?.selection.isEmpty ?? true)
            Button("Save to Last Folder") { window?.saveToLastFolder() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(window?.selection.isEmpty ?? true)
            Button("Save to…") { window?.saveTo() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(window?.selection.isEmpty ?? true)
            Divider()
            Button("Add Library Folder…") { window?.library.promptForRoot() }
            Button("New Folder") {
                if let folder = window?.library.selectedFolder { window?.library.newFolder(in: folder) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(window?.library.selectedFolder == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Selected Item…") {
                if let window, let id = window.selection.first, window.selection.count == 1 { window.edit(id) }
            }
            .keyboardShortcut("e")
            .disabled(window?.selection.count != 1)
            Button("Select All Media") { window?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Deselect All Media") { window?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Collect") { window?.section = .collect }
                .keyboardShortcut("1", modifiers: [.command, .control])
            Button("Organise") { window?.section = .organise }
                .keyboardShortcut("2", modifiers: [.command, .control])
            Divider()
            if window?.section == .organise {
                ForEach(Array(PaneID.panes(in: .organise).enumerated()), id: \.element) { index, pane in
                    paneToggle(pane, key: Character("\(index + 1)"))
                }
            } else {
                paneToggle(.source, key: "1")
                paneToggle(.extracted, key: "2")
                paneToggle(.library, key: "3")
                paneToggle(.downloads, key: "4")
                Button(window?.showPreview ?? true ? "Hide Preview" : "Show Preview") { window?.setShowing(.preview, !(window?.showPreview ?? true)) }
                    .keyboardShortcut("i")
            }
            Menu("Arrange Panes") {
                let group: PaneGroup = window?.section == .organise ? .organise : .collect
                LayoutPresetCommands(group: group)
                Divider()
                ForEach(PaneID.panes(in: group), id: \.self) { pane in
                    Menu(pane.title) { PaneMoveCommands(pane: pane, window: window) }
                }
                Divider()
                Button("Reset Pane Sizes") { PaneSplitController.resetSavedSizes() }
            }
            Divider()
            Button("Zoom In Page") { window?.browser.zoomIn() }
                .keyboardShortcut("+")
            Button("Zoom Out Page") { window?.browser.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { window?.browser.resetZoom() }
                .keyboardShortcut("0")
            Button("Larger Thumbnails") { if let window { window.cellSize = min(WindowModel.zoomRange.upperBound, window.cellSize + 40) } }
                .keyboardShortcut("+", modifiers: [.command, .option])
            Button("Smaller Thumbnails") { if let window { window.cellSize = max(WindowModel.zoomRange.lowerBound, window.cellSize - 40) } }
                .keyboardShortcut("-", modifiers: [.command, .option])
            Divider()
            Button("Filters") { window?.showFilters.toggle() }
                .keyboardShortcut("f")
            Button("Clear Extracted Media") { window?.clear() }
                .keyboardShortcut("k")
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { window?.browser.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { window?.browser.goForward() }
                .keyboardShortcut("]")
            Button("Reload Page") { window?.browser.reloadOrStop() }
                .keyboardShortcut("r")
            Button("Open Address") {
                window?.setShowing(.source, true)
                window?.focusAddressToken += 1
            }
                .keyboardShortcut("l")
            Divider()
            Button("Scroll to End of Page") { window?.toggleAutoScroll() }
            Button("Look for Media Again") { window?.browser.rescan() }
            Divider()
            Button("Sign In to Instagram") { window?.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!) }
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page…") { window?.bookmarkRequest += 1 }
                .keyboardShortcut("d")
                .disabled(window?.browser.url == nil)
            Button("Show Bookmarks") {
                window?.browsingPanelTab = .bookmarks
                window?.showBrowsingPanel = true
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            ForEach(AppModel.shared.browsing.bookmarks.folders) { folder in
                Menu(folder.name) {
                    ForEach(folder.bookmarks.prefix(40)) { bookmark in
                        Button(bookmark.title) { window?.browser.load(bookmark.url) }
                    }
                    if folder.bookmarks.isEmpty { Text("No bookmarks") }
                    if !folder.bookmarks.isEmpty {
                        Divider()
                        Button("Open All in Tabs") { folder.bookmarks.forEach { window?.newTab($0.url, select: false) } }
                    }
                }
            }
        }
        CommandMenu("History") {
            Button("Show History") {
                window?.browsingPanelTab = .history
                window?.showBrowsingPanel = true
            }
            .keyboardShortcut("y")
            Divider()
            ForEach(AppModel.shared.browsing.history.entries.prefix(15)) { entry in
                Button(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title) { window?.browser.load(entry.url) }
            }
            Divider()
            Menu("Clear History") {
                ForEach(BrowsingStore.ClearRange.allCases) { range in
                    Button(range.label) { AppModel.shared.browsing.clearHistory(range) }
                }
            }
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { window?.selectAdjacentTab(1) }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled((window?.tabs.count ?? 0) < 2)
            Button("Show Previous Tab") { window?.selectAdjacentTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((window?.tabs.count ?? 0) < 2)
            Divider()
            Button("Activity") { openWindow(id: "activity") }
            Button("Converter") { openWindow(id: "converter") }
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("MediaPull Walkthrough") { AppModel.shared.showWalkthrough(.tour) }
        }
    }

}
