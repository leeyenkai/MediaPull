import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullStore

/// Automated end-to-end check of the web extraction and save pipeline, started with
/// `--selftest-url <url> --selftest-out <folder>`. It loads the page, scrolls it to the end,
/// saves every item that passes the default filters into `<folder>/library`, and writes
/// `report.json` and `window.png` before quitting.
@MainActor
final class SelfTestRunner {
    static var arguments: (url: URL, out: URL, saveLimit: Int)? {
        let args = CommandLine.arguments
        guard let urlIndex = args.firstIndex(of: "--selftest-url"), args.count > urlIndex + 1,
              let outIndex = args.firstIndex(of: "--selftest-out"), args.count > outIndex + 1,
              let url = URL(string: args[urlIndex + 1])
        else { return nil }
        var limit = 400
        if let limitIndex = args.firstIndex(of: "--selftest-limit"), args.count > limitIndex + 1, let value = Int(args[limitIndex + 1]) {
            limit = value
        }
        return (url, URL(fileURLWithPath: args[outIndex + 1], isDirectory: true), limit)
    }

    static var isActive: Bool { arguments != nil }

    /// User plus system CPU time of this process.
    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func secondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private let model: WindowModel
    private var log: [String] = []
    private let started = Date()
    private static var running: SelfTestRunner?

    init(model: WindowModel) {
        self.model = model
    }

    static func startIfRequested(_ model: WindowModel) {
        guard running == nil, isActive else { return }
        let runner = SelfTestRunner(model: model)
        running = runner
        Task { await runner.run() }
    }

    private func note(_ text: String) {
        let line = String(format: "%7.1fs ", Date().timeIntervalSince(started)) + text
        log.append(line)
        print("SELFTEST " + line)
    }

    private func run() async {
        guard let (url, out, limit) = Self.arguments else { return }
        if let launched = Self.secondsSinceProcessStart() { note(String(format: "window ready %.2f s after launch", launched)) }
        let app = AppModel.shared
        let library = out.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        while app.store == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await app.addRoot(library, layout: .archive, makeDefault: true)
        model.library.selectedFolder = library
        let savedTheme = app.preferences.theme
        let savedArrangement = app.preferences.paneArrangement
        let savedZoom = app.preferences.thumbnailSize
        defer {
            app.preferences.thumbnailSize = savedZoom
            app.preferences.theme = savedTheme
            app.preferences.paneArrangement = savedArrangement
        }
        if let name = Self.value(after: "--selftest-theme"), let theme = AppTheme(rawValue: name) { app.preferences.theme = theme }
        if let zoom = Self.value(after: "--selftest-zoom").flatMap(Double.init) { model.cellSize = CGFloat(zoom) }
        if let index = Self.value(after: "--selftest-layout").flatMap(Int.init), PaneArrangement.presets.indices.contains(index) {
            app.preferences.paneArrangement = PaneArrangement.presets[index].arrangement
        }
        note("engines: \(app.engineVersions.map { "gallery-dl \($0.galleryDL ?? "?"), yt-dlp \($0.ytDLP ?? "?"), ffmpeg \($0.ffmpeg ?? "?")" } ?? "unknown")")

        if model.browser.webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            model.browser.webView.perform(NSSelectorFromString("_setWindowOcclusionDetectionEnabled:"), with: false)
        }
        model.browser.load(url)
        note("loading \(url.absoluteString)")
        await waitUntil(timeout: 45) { !self.model.browser.isLoading && self.model.browser.url != nil }
        try? await Task.sleep(for: .seconds(4))
        if let seconds = Self.value(after: "--selftest-idle").flatMap(Double.init), seconds > 0 {
            let before = Self.cpuSeconds()
            try? await Task.sleep(for: .seconds(seconds))
            let used = Self.cpuSeconds() - before
            note(String(format: "idle: app process used %.2f s of CPU in %.0f s (%.2f %%)", used, seconds, used / seconds * 100))
        }
        if let second = Self.value(after: "--selftest-browser").flatMap(URL.init(string:)) {
            await exerciseBrowser(second: second, out: out)
        }
        if CommandLine.arguments.contains("--selftest-pdf-links") {
            note("PDF links on page: \(model.documents.count)")
            for url in model.documents.prefix(3) {
                model.extractPDF(remote: url)
            }
        }
        await waitUntil(timeout: 240) { app.jobs.activeCount == 0 }
        if model.browser.isShowingPDF || !model.extractedDocuments.isEmpty {
            note("PDF jobs: " + app.jobs.jobs.filter { $0.kind == .scan }.map { "\($0.title): \($0.summary) \($0.state.label)" }.joined(separator: "; "))
        }
        let initial = model.items.count
        note("after load: \(initial) items, \(model.visible.count) shown")

        if CommandLine.arguments.contains("--selftest-site") {
            await waitUntil(timeout: 20) { self.model.siteExtractorCategory != nil }
            guard let category = model.siteExtractorCategory else {
                note("no site extractor for this page")
                writeReport(to: out, url: url, initial: initial, afterScroll: initial, job: nil, library: library)
                NSApp.terminate(nil)
                return
            }
            note("site extractor: \(category)")
            let scan = app.engines.startSiteScan(url: url, category: category, window: model)
            await waitUntil(timeout: 300) { scan?.state.isFinished ?? true }
            try? await Task.sleep(for: .seconds(1))
            note("site scan: \(scan?.summary ?? "") – \(scan?.state.label ?? "")")
            model.filter.sources = [.siteExtractor]
        }
        model.toggleAutoScroll()
        await waitUntil(timeout: 120) { !self.model.autoScrolling }
        try? await Task.sleep(for: .seconds(3))
        let afterScroll = model.items.count
        note("after scrolling: \(afterScroll) items (\(afterScroll - initial) appeared while scrolling), \(model.visible.count) shown")

        for item in model.items {
            model.ensureProbed(item)
        }
        await waitUntil(timeout: 60) {
            self.model.items.allSatisfy { item in
                item.displaySize != nil || item.kind == .stream || item.kind == .audio || item.flags.contains(.blobOnly)
                    || (item.best?.hasFailed ?? false)
            }
        }
        try? await Task.sleep(for: .seconds(2))
        let unknown = model.items.filter { $0.displaySize == nil }.count
        note("after probing: \(unknown) items still without a known size")
        if let largest = model.visible.filter({ $0.kind == .image }).max(by: { ($0.displaySize?.pixels ?? 0) < ($1.displaySize?.pixels ?? 0) }) {
            model.gridSelectionChanged([largest.id])
            model.gridRevision += 1
            try? await Task.sleep(for: .seconds(3))
        }
        snapshot(to: out.appendingPathComponent("window-extracted.png"))

        let toSave = Array(model.visible.prefix(limit))
        note("saving \(toSave.count) items to \(library.path)")
        model.selection = Set(toSave.map(\.id))
        let job = app.save(toSave, from: model, to: library, title: "Self-test save")
        await waitUntil(timeout: 600) { job?.state.isFinished ?? true }
        try? await Task.sleep(for: .seconds(1))
        note("save finished: \(job?.summary ?? "no job") – \(job?.state.label ?? "")")
        model.library.selectedFolder = library.appendingPathComponent(FileNaming.safeTopFolder(url.host ?? "web"))
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: out.appendingPathComponent("window-saved.png"))

        if CommandLine.arguments.contains("--selftest-edit") { await exerciseEditor(library: library, out: out) }
        writeReport(to: out, url: url, initial: initial, afterScroll: afterScroll, job: job, library: library)
        note("report written")
        try? await Task.sleep(for: .milliseconds(500))
        app.preferences.theme = savedTheme
        app.preferences.paneArrangement = savedArrangement
        app.preferences.thumbnailSize = savedZoom
        NSApp.terminate(nil)
    }

    /// Opens the editor on the first saved image, rotates, crops to a square, renames and saves a copy.
    /// Tabs, the This Page filter, bookmarks, history, the panel and the walkthrough.
    private func exerciseBrowser(second: URL, out: URL) async {
        let app = AppModel.shared
        let first = model.browser
        let firstURL = first.url
        let beforeItems = model.items.count
        let tab = model.newTab(second)
        await waitUntil(timeout: 45) { !tab.isLoading && tab.url != nil }
        try? await Task.sleep(for: .seconds(4))
        note("tabs: \(model.tabs.count), second tab \(tab.url?.host ?? "?"), items \(beforeItems) -> \(model.items.count) from both tabs")
        model.filter.currentPageOnly = true
        let secondOnly = model.visible.count
        model.selectTab(first.id)
        let firstOnly = model.visible.count
        model.filter.currentPageOnly = false
        note("This Page: \(secondOnly) shown for the second tab, \(firstOnly) for the first, \(model.visible.count) for all")
        model.selectTab(tab.id)
        snapshot(to: out.appendingPathComponent("window-tabs.png"))

        if let firstURL { app.browsing.addBookmark(title: first.title, url: firstURL) }
        var folder = UUID()
        app.browsing.edit { folder = $0.addFolder(named: "Research") }
        if let url = tab.url {
            let mark = app.browsing.addBookmark(title: tab.title, url: url, folder: folder)
            app.browsing.edit {
                $0.renameFolder(folder, to: "Catalogues")
                $0.rename(mark.id, to: "Second page")
            }
        }
        let names = app.browsing.bookmarks.folders.map { "\($0.name) (\($0.bookmarks.count))" }.joined(separator: ", ")
        note("bookmarks: \(names); history: \(app.browsing.history.entries.count) pages")

        model.browsingPanelTab = .bookmarks
        model.showBrowsingPanel = true
        try? await Task.sleep(for: .seconds(1.5))
        capturePopover(to: out.appendingPathComponent("panel-bookmarks.png"))
        model.browsingPanelTab = .history
        try? await Task.sleep(for: .seconds(1))
        capturePopover(to: out.appendingPathComponent("panel-history.png"))
        app.browsing.clearHistory(.lastHour)
        note("history after clearing the last hour: \(app.browsing.history.entries.count) pages")
        model.showBrowsingPanel = false

        let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
        let order = fileMenu?.items.filter { $0.keyEquivalent == "w" }.map { "\($0.title) [\($0.keyEquivalentModifierMask.contains(.shift) ? "⇧⌘W" : "⌘W")]" }
        note("File menu items on W: \(order?.joined(separator: ", ") ?? "none")")

        app.showWalkthrough(.tour)
        try? await Task.sleep(for: .seconds(1.5))
        if let sheet = model.hostWindow?.attachedSheet {
            print("SELFTEST-CAPTURE \(sheet.windowNumber) \(out.appendingPathComponent("walkthrough-1.png").path)")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(3))
        } else {
            note("walkthrough sheet did not appear")
        }
        app.walkthrough = nil
        try? await Task.sleep(for: .seconds(1))
        model.closeTab(tab.id)
        note("after closing: \(model.tabs.count) tab, can reopen: \(model.canReopenClosedTab)")
    }

    private func capturePopover(to file: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) else {
            note("no popover to capture")
            return
        }
        print("SELFTEST-CAPTURE \(window.windowNumber) \(file.path)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 2.5)
    }

    private func exerciseEditor(library: URL, out: URL) async {
        let images = (FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        guard let file = images.first(where: { (ImageConversion.analyze($0)?.width ?? 0) >= 200 }) else {
            note("editor: no saved image to edit")
            return
        }
        let request = EditorRequest(subject: .file(file))
        model.openEditor(request)
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: out.appendingPathComponent("window-editor.png"))
        model.editorRequest = nil
        model.showInPreview(.file(file))
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(to: out.appendingPathComponent("window-preview-file.png"))
        let editor = EditorModel(request: request, window: model)
        await editor.load()
        guard let before = editor.working else {
            note("editor: could not load \(file.lastPathComponent)")
            return
        }
        editor.rotate(clockwise: true)
        editor.aspect = .square
        editor.applyAspect()
        editor.name = "Edited by self-test"
        let size = editor.outputSize
        guard let saved = editor.saveFile(asCopy: true) else {
            note("editor: save failed: \(editor.message ?? "")")
            return
        }
        let analysis = ImageConversion.analyze(saved)
        let sidecar = (try? Data(contentsOf: Sidecar.sidecarURL(for: saved))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        note("editor: \(before.width)x\(before.height) rotated and cropped to \(size?.label ?? "?"), saved \(saved.lastPathComponent) "
            + "as \(analysis.map { "\($0.width)x\($0.height)" } ?? "?"), original kept: \(FileManager.default.fileExists(atPath: file.path)), "
            + "sidecar width \(sidecar?["width"] ?? "none"), edited \(sidecar?["edited"] ?? "no")")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    private func snapshot(to file: URL) {
        if let number = model.hostWindow?.windowNumber {
            print("SELFTEST-CAPTURE \(number) \(file.path)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 2.5)
            if FileManager.default.fileExists(atPath: file.path) { return }
        }
        guard let view = model.hostWindow?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            note("no window to capture")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }

    private func writeReport(to out: URL, url: URL, initial: Int, afterScroll: Int, job: Job?, library: URL) {
        var kinds: [String: Int] = [:]
        var formats: [String: Int] = [:]
        var sources: [String: Int] = [:]
        var derivedWins = 0
        for item in model.items {
            kinds[item.kind.rawValue, default: 0] += 1
            formats[item.displayFormat?.rawValue ?? "unknown", default: 0] += 1
            for group in MediaFilter.sourceGroup(of: item) {
                sources[group.rawValue, default: 0] += 1
            }
            if item.best?.isDerived == true, item.best?.check == .verified { derivedWins += 1 }
        }
        let items: [[String: Any]] = model.items.prefix(500).map { item in
            var entry: [String: Any] = [
                "id": item.id, "kind": item.kind.rawValue, "variants": item.variants.count,
                "best": item.best?.url.absoluteString ?? "", "bestOrigin": item.best?.origin.rawValue ?? "",
                "visible": model.visible.contains { $0.id == item.id },
            ]
            if let size = item.displaySize { entry["size"] = "\(size.width)x\(size.height)" }
            if let bytes = item.displayBytes { entry["bytes"] = bytes }
            if let format = item.displayFormat { entry["format"] = format.rawValue }
            switch model.states[item.id] {
            case let .saved(url): entry["saved"] = url.path
            case let .duplicate(url): entry["duplicate"] = url.path
            case let .failed(reason): entry["failed"] = reason
            case let .skipped(reason): entry["skipped"] = reason
            default: break
            }
            return entry
        }
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator {
                files.append(file.path.replacingOccurrences(of: library.path + "/", with: ""))
            }
        }
        let report: [String: Any] = [
            "url": url.absoluteString, "seconds": Date().timeIntervalSince(started), "itemsAfterLoad": initial,
            "itemsAfterScroll": afterScroll, "visible": model.visible.count, "kinds": kinds, "formats": formats, "sources": sources,
            "derivedOriginalsUsed": derivedWins, "job": job?.summary ?? "", "jobState": job?.state.label ?? "",
            "failures": job?.failures.map { "\($0.id): \($0.message)" } ?? [], "notes": job?.notes ?? [], "files": files.sorted(),
            "log": log, "items": items,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("report.json"))
        }
    }
}
