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

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.servicesProvider = self
    }

    /// Services > Download with MediaPull (R-1111c): the selected link or text fills in the Downloads pane; nothing starts
    /// until the person clicks Download (D-82).
    @objc func downloadWithMediaPull(_ pasteboard: NSPasteboard, userData _: String?,
                                     error _: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        let link = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.absoluteString
        guard let text = (link ?? pasteboard.string(forType: .string))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.utf8.count < 1 << 20
        else { return }
        NSApp.activate()
        let app = AppModel.shared
        if let window = app.frontWindow {
            window.showDownloads(text)
        } else {
            app.pendingDownloadAddress = text
            app.openMainWindow?()
        }
    }

    func applicationWillTerminate(_: Notification) {
        AppModel.shared.browsing.flush()
    }

    /// Library folders renamed or moved in the Finder while MediaPull was in the background are followed (R-1702).
    func applicationDidBecomeActive(_: Notification) {
        Task {
            let app = AppModel.shared
            if await app.followRootLocations() {
                app.libraryRevision += 1
                app.analysis.updateWatch()
            }
            await app.refreshAccountFolders()
            for window in app.windows { await window.organise.followFolders() }
        }
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Analysis picks up where it stopped at the next launch, so only other jobs ask before quitting.
        let running = AppModel.shared.jobs.jobs.filter { $0.state.isActive && $0.kind != .analyse }
        guard !running.isEmpty, !SelfTestRunner.isActive else {
            AppModel.shared.analysis.cancelScan()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "\(running.count) job\(running.count == 1 ? " is" : "s are") still running"
        alert.informativeText = "Quitting stops them. Instagram pulls can be resumed later and continue where they stopped."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppModel.shared.analysis.cancelScan()
            running.forEach { $0.cancel() }
            // An Organise run stops between files and then saves its journal; quit once it has, so every step it took
            // stays undoable (R-3807). A run that does not stop within a few seconds does not hold up quitting.
            // Pulls also get a moment to write what they saved into their folder's record (D-79).
            let organising = running.filter { [.organise, .pull].contains($0.kind) }.compactMap(\.task)
            guard !organising.isEmpty else { return .terminateNow }
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { for task in organising { await task.value } }
                    group.addTask { try? await Task.sleep(for: .seconds(5)) }
                    await group.next()
                    group.cancelAll()
                }
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateCancel
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowModel) private var window
    /// The browser is on screen: Collect is shown.
    private var browsing: Bool { window?.section == .collect }
    /// Thumbnail size is for Extracted Media's icon view (R-1711).
    private var extractedIcons: Bool { window?.viewMode(for: .extracted) == .icon }
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
                .disabled(!browsing)
            // Listed before the window's Close item, so ⌘W closes a tab first and the window with its last tab.
            // In Organise the browser is hidden: ⌘W closes the window rather than tabs no one can see.
            Button(browsing || window == nil ? "Close Tab" : "Close Window") {
                guard let window else { return }
                if window.section == .collect { window.closeTab(window.selectedTabID) } else { window.hostWindow?.performClose(nil) }
            }
                .keyboardShortcut("w")
                .disabled(window == nil)
            Button("Reopen Closed Tab") {
                window?.section = .collect
                window?.reopenClosedTab()
            }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(window?.canReopenClosedTab ?? false))
            Divider()
            Button("Pull Instagram Account…") {
                window?.showDownloads(window?.instagramPageAddress)
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
            Button(window.map { "Save to “\($0.saveFolderName)”" } ?? "Save") { window?.saveItems() }
                .keyboardShortcut("s")
                .disabled(window?.selection.isEmpty ?? true || window?.section != .collect)
            Button("Save to…") { window?.saveTo() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(window?.selection.isEmpty ?? true || window?.section != .collect)
            Divider()
            Button("Add Library Folder…") { window?.library.promptForRoot() }
            Button("New Folder") { window?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(window?.newFolderParent == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Selected Item…") {
                if let window, let id = window.selection.first, window.selection.count == 1 { window.edit(id) }
            }
            .keyboardShortcut("e")
            .disabled(window?.selection.count != 1 || window?.section != .collect)
            // Collect's commands never act on it while Organise is shown and it cannot be seen.
            Button("Select All Media") { window?.selectAll() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(window?.section != .collect)
            Button("Deselect All Media") { window?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(window?.section != .collect)
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
                Button(window?.showPreview ?? true ? "Hide Preview" : "Show Preview") {
                    window?.setShowing(.preview, !(window?.showPreview ?? true))
                }
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
            // As in the Finder: ⌘1 icons, ⌘2 list, ⌘3 columns, for the pane last clicked (R-1708).
            ForEach(Array(PaneViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle(mode.label, isOn: Binding(
                    get: { window.map { $0.viewMode(for: $0.viewModeTarget) == mode } ?? false },
                    set: { _ in if let window { window.setViewMode(mode, for: window.viewModeTarget) } }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(window.map { !PaneViewMode.allowed(for: $0.viewModeTarget).contains(mode) } ?? true)
            }
            Divider()
            Button("Zoom In Page") { window?.browser.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!browsing)
            Button("Zoom Out Page") { window?.browser.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!browsing)
            Button("Actual Size") { window?.browser.resetZoom() }
                .keyboardShortcut("0")
                .disabled(!browsing)
            Button("Larger Thumbnails") { if let window { window.cellSize = min(WindowModel.zoomRange.upperBound, window.cellSize + 40) } }
                .keyboardShortcut("+", modifiers: [.command, .option])
                .disabled(!browsing || !extractedIcons)
            Button("Smaller Thumbnails") { if let window { window.cellSize = max(WindowModel.zoomRange.lowerBound, window.cellSize - 40) } }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(!browsing || !extractedIcons)
            Divider()
            Button("Find") { window?.find() }
                .keyboardShortcut("f")
            Button("Clear Extracted Media") { window?.clear() }
                .keyboardShortcut("k")
                .disabled(window?.section != .collect)
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { window?.browser.goBack() }
                .keyboardShortcut("[")
                .disabled(!browsing)
            Button("Forward") { window?.browser.goForward() }
                .keyboardShortcut("]")
                .disabled(!browsing)
            Button(window?.keyboardFolderPane != nil ? "Show in Finder" : "Reload Page") { window?.revealOrReload() }
                .keyboardShortcut("r")
            Button("Stop") { window?.stop() }
                .keyboardShortcut(".")
                .disabled(!browsing || window?.section == .organise)
            Button("Open Address") {
                window?.section = .collect
                window?.setShowing(.source, true)
                window?.focusAddressToken += 1
            }
                .keyboardShortcut("l")
            Divider()
            Button("Scroll to End of Page") { window?.toggleAutoScroll() }
                .disabled(window?.section != .collect)
            Button("Look for Media Again") { window?.browser.rescan() }
                .disabled(window?.section != .collect)
            Divider()
            Button("Sign In to Instagram") {
                window?.section = .collect
                window?.browser.load(URL(string: "https://www.instagram.com/accounts/login/")!)
            }
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page…") { window?.bookmarkRequest += 1 }
                .keyboardShortcut("d")
                .disabled(window?.browser.url == nil || !browsing)
            Button("Show Bookmarks") {
                window?.section = .collect
                window?.browsingPanelTab = .bookmarks
                window?.showBrowsingPanel = true
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            ForEach(AppModel.shared.browsing.bookmarks.folders) { folder in
                Menu(folder.name) {
                    ForEach(folder.bookmarks.prefix(40)) { bookmark in
                        Button(bookmark.title) {
                            window?.section = .collect
                            window?.browser.load(bookmark.url)
                        }
                    }
                    if folder.bookmarks.isEmpty { Text("No bookmarks") }
                    if !folder.bookmarks.isEmpty {
                        Divider()
                        Button("Open All in Tabs") {
                            window?.section = .collect
                            folder.bookmarks.forEach { window?.newTab($0.url, select: false) }
                        }
                    }
                }
            }
        }
        CommandMenu("History") {
            Button("Show History") {
                window?.section = .collect
                window?.browsingPanelTab = .history
                window?.showBrowsingPanel = true
            }
            .keyboardShortcut("y")
            Divider()
            ForEach(AppModel.shared.browsing.history.entries.prefix(15)) { entry in
                Button(entry.title.isEmpty ? (entry.url.host ?? entry.url.absoluteString) : entry.title) {
                    window?.section = .collect
                    window?.browser.load(entry.url)
                }
            }
            Divider()
            Menu("Clear History") {
                ForEach(BrowsingStore.ClearRange.allCases) { range in
                    Button(range.label) { AppModel.shared.browsing.clearHistory(range) }
                }
            }
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") {
                window?.section = .collect
                window?.selectAdjacentTab(1)
            }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled((window?.tabs.count ?? 0) < 2)
            Button("Show Previous Tab") {
                window?.section = .collect
                window?.selectAdjacentTab(-1)
            }
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
