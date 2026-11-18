import AVFoundation
import AppKit
import Foundation
import MediaPullCore
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
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
    private var restorePreferences: () -> Void = {}

    private func quit() {
        restorePreferences()
        NSApp.terminate(nil)
    }
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
        // The settings a result depends on start from their defaults, whoever's Mac this runs on (audit 12, C12-m6). Only
        // in memory: a self-test never writes the person's settings.
        app.preferences.defaultContent = Set(InstagramContent.defaults)
        app.preferences.archiveEngineTemplate = NameTemplate.archiveEngine.pattern
        app.preferences.archiveWebTemplate = NameTemplate.archiveWeb.pattern
        app.preferences.plainTemplate = NameTemplate.plain.pattern
        app.preferences.stopAfterKnown = 12
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
        let savedViews = app.preferences.paneViewModes
        // NSApp.terminate exits without running defer blocks, so every exit restores these first.
        restorePreferences = { [app] in
            app.preferences.thumbnailSize = savedZoom
            app.preferences.paneViewModes = savedViews
            app.preferences.theme = savedTheme
            app.preferences.paneArrangement = savedArrangement
        }
        if let name = Self.value(after: "--selftest-theme"), let theme = AppTheme(rawValue: name) { app.preferences.theme = theme }
        if let zoom = Self.value(after: "--selftest-zoom").flatMap(Double.init) { model.cellSize = CGFloat(zoom) }
        if let index = Self.value(after: "--selftest-layout").flatMap(Int.init), PaneArrangement.presets.indices.contains(index) {
            app.preferences.paneArrangement = PaneArrangement.presets[index].arrangement
        }
        if let folder = Self.value(after: "--selftest-analyse") {
            await exerciseAnalysis(source: URL(fileURLWithPath: folder, isDirectory: true), library: library, out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-update") {
            await exerciseUpdate(library: library, out: out)
            quit()
            return
        }
        await waitUntil(timeout: 20) { app.engineVersions != nil }
        let versions = app.engineVersions.map { "gallery-dl \($0.galleryDL ?? "?"), yt-dlp \($0.ytDLP ?? "?"), ffmpeg \($0.ffmpeg ?? "?")" }
        note("engines: \(versions ?? "unknown")")

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
        if let page = Self.value(after: "--selftest-video-download").flatMap(URL.init(string:)) {
            await exerciseVideoDownload(page: page, library: library, out: out)
        }
        if let list = Self.value(after: "--selftest-galleries") {
            await exerciseGalleries(list: URL(fileURLWithPath: list), library: library, out: out)
        }
        if let account = Self.value(after: "--selftest-pullsheet") {
            model.showDownloads("@\(account)")
            try? await Task.sleep(for: .seconds(4))
            snapshot(to: out.appendingPathComponent("downloads-instagram.png"))
            note("downloads pane shown for @\(account)")
        }
        if let list = Self.value(after: "--selftest-downloads-list") {
            model.showDownloads(list.replacingOccurrences(of: "|", with: "\n"))
            await waitUntil(timeout: 30) { !self.model.downloads.batch.contains { $0.kind == .checking } }
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: out.appendingPathComponent("downloads-list.png"))
            note("downloads list: " + model.downloads.batch.map { "\($0.text) = \($0.label)" }.joined(separator: "; "))
            // Every line recognised for what it is: @accounts and #hashtags as Instagram, nothing left checking (C3-m12), and a
            // saved-posts link as the person's saved posts, never an account (audit 5, C5-m9).
            let right = model.downloads.batch.allSatisfy { entry in
                if entry.kind == .checking || entry.label.hasSuffix("@") { return false }
                // A web address given to the test is one it should know: a video page or a site gallery (audit 9, C9-m5).
                if entry.text.hasPrefix("http"), entry.kind == .unrecognised { return false }
                if entry.text.contains("instagram.com/"), entry.text.contains("/saved") {
                    return entry.label == "Your saved Instagram posts"
                }
                if entry.text.hasPrefix("@") || entry.text.hasPrefix("#") {
                    if case .instagram = entry.kind { return true }
                    return false
                }
                return true
            }
            note("downloads list: \(right && model.downloads.batch.count > 1 ? "PASS" : "FAIL")")
        }
        if let second = Self.value(after: "--selftest-browser").flatMap(URL.init(string:)) {
            await exerciseBrowser(second: second, out: out)
        }
        if CommandLine.arguments.contains("--selftest-pdf-links") {
            note("PDF links on page: \(model.documents.count)")
            for url in model.documents.prefix(3) {
                model.extractPDF(remote: url, linkedFrom: model.browser.url)
            }
        }
        await waitUntil(timeout: 240) { app.jobs.activeCount == 0 }
        if model.browser.isShowingPDF || !model.extractedDocuments.isEmpty {
            note("PDF jobs: "
                + app.jobs.jobs.filter { $0.kind == .scan }.map { "\($0.title): \($0.summary) \($0.state.label)" }.joined(separator: "; "))
        }
        let initial = model.items.count
        note("after load: \(initial) items, \(model.visible.count) shown")

        if CommandLine.arguments.contains("--selftest-site") {
            await waitUntil(timeout: 20) { self.model.siteExtractorCategory != nil }
            guard let category = model.siteExtractorCategory else {
                note("no site extractor for this page")
                writeReport(to: out, url: url, initial: initial, afterScroll: initial, job: nil, library: library)
                quit()
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
        if let largest = model.visible.filter({ $0.kind == .image })
            .max(by: { ($0.displaySize?.pixels ?? 0) < ($1.displaySize?.pixels ?? 0) })
        {
            model.gridSelectionChanged([largest.id])
            model.gridRevision += 1
            try? await Task.sleep(for: .seconds(3))
        }
        // The page back at its top for the screenshots.
        _ = try? await model.browser.webView.evaluateJavaScript("window.scrollTo(0, 0)")
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("window-extracted.png"))

        let toSave = Array(model.visible.prefix(limit))
        note("saving \(toSave.count) items to \(library.path)")
        model.selection = Set(toSave.map(\.id))
        let job = app.save(toSave, from: model, to: library, title: "Self-test save")
        await waitUntil(timeout: 600) { job?.state.isFinished ?? true }
        try? await Task.sleep(for: .seconds(1))
        note("save finished: \(job?.summary ?? "no job") – \(job?.state.label ?? "")")
        model.library.selectedFolder = library.appendingPathComponent(FileNaming.safeTopFolder(url.host ?? "web"))
        // The listing waits for analysis of the files just saved; the screenshot shows the folder once it is read.
        await waitUntil(timeout: 240) { !self.model.library.files.isEmpty }
        try? await Task.sleep(for: .seconds(10))
        snapshot(to: out.appendingPathComponent("window-saved.png"))

        if CommandLine.arguments.contains("--selftest-edit") { await exerciseEditor(library: library, out: out) }
        if CommandLine.arguments.contains("--selftest-duplicates") { await exerciseDuplicates(library: library, out: out) }
        if CommandLine.arguments.contains("--selftest-video") { await exerciseVideo(library: library, out: out) }
        if CommandLine.arguments.contains("--selftest-views") { await exerciseViews(library: library, out: out) }
        writeReport(to: out, url: url, initial: initial, afterScroll: afterScroll, job: job, library: library)
        note("report written")
        try? await Task.sleep(for: .milliseconds(500))
        quit()
    }

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
        let order = fileMenu?.items.filter { $0.keyEquivalent.lowercased() == "w" }.map { item in
            let mask = item.keyEquivalentModifierMask
            let keys = (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) || item.keyEquivalent == "W" ? "⇧" : "") + "⌘W"
            return "\(item.title) [\(keys)]"
        }
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

    /// Plants an identical copy and a resized copy of a saved picture, then checks the Library pane finds both.
    private func exerciseDuplicates(library: URL, out: URL) async {
        let images = (FileManager.default.enumerator(at: library, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["jpg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { (ImageConversion.analyze($0)?.width ?? 0) > (ImageConversion.analyze($1)?.width ?? 0) }
        guard let source = images.first, let image = ImageEditing.loadOriented(source) else {
            note("duplicates: no saved picture to copy")
            return
        }
        let folder = source.deletingLastPathComponent()
        let copies = folder.appendingPathComponent("copies", isDirectory: true)
        try? FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: source, to: copies.appendingPathComponent("identical copy." + source.pathExtension))
        let small = ImageEditing.cropped(image, to: CGRect(x: 0, y: 0, width: 1, height: 1)).flatMap { full -> CGImage? in
            let width = max(64, full.width / 3), height = max(64, full.height / 3)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
        if let small {
            try? ImageEditing.write(small, format: .jpeg, metadataFrom: nil, to: folder.appendingPathComponent("resized copy.jpg"))
        }
        model.library.selectedFolder = folder
        model.library.reload()
        await waitUntil(timeout: 120) { self.model.library.duplicates != nil && self.model.library.duplicateProgress == nil }
        try? await Task.sleep(for: .seconds(1))
        let report = model.library.duplicates
        let summary = report?.groups.map { group in
            "\(group.identical ? "identical" : "similar"): " + group.members.map(\.lastPathComponent).joined(separator: ", ")
        }.joined(separator: " | ") ?? "none"
        note("duplicates: \(report?.filesChecked ?? 0) files checked, \(report?.groups.count ?? 0) groups: \(summary)")
        note("duplicates here: \(model.library.duplicatesHere)")
        if let first = model.library.files.first(where: { $0.name == "resized copy.jpg" }) {
            model.library.selection = [first.id]
            model.library.revision += 1
            model.showInPreview(.file(first.url))
        }
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: out.appendingPathComponent("window-duplicates.png"))
    }

    /// Downloads the first few items from each address in a list through the whole app (site choices, the bridge, the save
    /// pipeline and folders), and reports what was saved (SPEC R-1111b).
    private func exerciseGalleries(list: URL, library: URL, out: URL) async {
        let app = AppModel.shared
        let addresses = ((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }.compactMap(URL.init(string:))
        let root = app.destination(for: library)
        var shown = false
        for url in addresses {
            guard let site = await app.engines.siteInfo(for: url) else {
                note("gallery \(url.absoluteString): not recognised")
                continue
            }
            // As a person would: open the page in the browser first, so its session and any browser check carry over.
            model.browser.load(url)
            await waitUntil(timeout: 30) { !self.model.browser.isLoading }
            try? await Task.sleep(for: .seconds(4))
            if !shown {
                model.showDownloads(url.absoluteString)
                try? await Task.sleep(for: .seconds(3))
                snapshot(to: out.appendingPathComponent("downloads-gallery.png"))
                shown = true
            }
            let include = SiteCatalogue.visibleChoices(site.choices).filter { site.defaults.contains($0) }
            let key = SiteInfoKey(category: site.category, baseCategory: site.baseCategory)
            let switches = Dictionary(uniqueKeysWithValues: app.sites.switches(key).map { ($0.key, $0.default) })
            let started = Date()
            guard let job = app.engines.startGalleryDownload(url: url, site: site, include: include, switches: switches, range: "1-3",
                                                             from: nil, to: nil, onlyNew: false, root: root, window: model)
            else { continue }
            await waitUntil(timeout: 240) { job.state.isFinished }
            let folder = job.destination ?? library
            let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                .filter { !$0.hasDirectoryPath && $0.pathExtension != "json" }
            let kinds: String = Set(files.map { $0.pathExtension.lowercased() }).sorted().joined(separator: "/")
            let name: String = app.sites.name(key)
            let seconds = Int(Date().timeIntervalSince(started))
            let place: String = folder.path.replacingOccurrences(of: library.path, with: "<library>")
            let failure: String = job.failures.first.map { "; first failure: \($0.1)" } ?? ""
            let extra: String = job.notes.first.map { "; note: \($0)" } ?? ""
            let counts = "saved \(job.saved), duplicates \(job.duplicates), failed \(job.failed) in \(seconds) s"
            note("""
                gallery \(name) [\(site.category)/\(site.subcategory)]: \(job.state.label), \(counts); files \
                \(kinds.isEmpty ? "none" : kinds) in \(place)\(failure)\(extra)
                """)
        }
    }

    /// Looks up a video page's formats, shows them in the Downloads pane, then saves it as 360p H.264 and as audio only.
    private func exerciseVideoDownload(page: URL, library: URL, out: URL) async {
        let app = AppModel.shared
        guard case let .success(info) = await app.engines.videoInfo(for: page) else {
            note("video download: lookup failed")
            return
        }
        let heights = VideoDownloadFormat.allCases.map {
            "\($0.rawValue) \($0.heights(in: info.formats).map(String.init).joined(separator: "/"))"
        }
        note("video download: \(info.title) by \(info.uploader ?? "?"), \(info.formats.count) formats; \(heights.joined(separator: "; "))")
        model.showDownloads(page.absoluteString)
        try? await Task.sleep(for: .seconds(8))
        snapshot(to: out.appendingPathComponent("downloads-video.png"))
        let root = app.destination(for: library)
        for (format, height) in [(VideoDownloadFormat.h264MP4, Optional(360)), (.audioM4A, nil)] {
            let started = Date()
            let job = app.engines.saveVideo(info, format: format, height: height, root: root, window: model)
            await waitUntil(timeout: 600) { job.state.isFinished }
            let file = job.destination
            var facts = "\(format.rawValue): \(job.state.label) in \(Int(Date().timeIntervalSince(started))) s"
            if let file, FileManager.default.fileExists(atPath: file.path) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                facts += ", \(file.lastPathComponent), \(Format.bytes(Int64(size)))"
                facts += FileManager.default.fileExists(atPath: Sidecar.sidecarURL(for: file).path) ? ", with metadata" : ", no metadata"
                facts += " in \(file.deletingLastPathComponent().path.replacingOccurrences(of: library.path, with: "library"))"
            }
            if !job.notes.isEmpty { facts += " (\(job.notes.joined(separator: "; ")))" }
            note("video download \(facts)")
        }
    }

    /// Makes a short clip in the library, then saves a frame and a trimmed copy through the video editor.
    private func exerciseVideo(library: URL, out: URL) async {
        let clip = library.appendingPathComponent("2026-01-01_120000_0001_test clip.mp4")
        do {
            try await Self.writeTestClip(to: clip)
        } catch {
            note("video: could not make a test clip: \(error.localizedDescription)")
            return
        }
        try? Data(#"{"category":"example.com","date":"2026-01-01 12:00:00","duration":4.0,"num":1,"count":2,"subcategory":"page","username":"example.com"}"#.utf8)
            .write(to: Sidecar.sidecarURL(for: clip))
        model.library.selectedFolder = library
        let request = EditorRequest(subject: .file(clip))
        model.openEditor(request)
        try? await Task.sleep(for: .seconds(3))
        snapshot(to: out.appendingPathComponent("window-video-editor.png"))
        model.editorRequest = nil

        let editor = VideoEditorModel(request: request, window: model)
        await editor.load()
        guard let stage = editor.stage else {
            note("video: editor did not load: \(editor.message ?? "")")
            return
        }
        await stage.player.seek(to: CMTime(seconds: 2.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        await editor.saveFrame()
        note("video: \(editor.message ?? "no message")")
        editor.selection = 1.0 ... 3.0
        await editor.saveTrim(replacing: false)
        let files = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.path < $1.path })
            where file.lastPathComponent.contains("test clip") && file.pathExtension != "json"
        {
            var facts = file.lastPathComponent
            if file.pathExtension == "png", let image = ImageConversion.analyze(file) { facts += " \(image.width)x\(image.height)" }
            if file.pathExtension == "mp4" { facts += String(format: " %.2f s", await VideoTools.duration(of: file) ?? 0) }
            if let data = try? Data(contentsOf: Sidecar.sidecarURL(for: file)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                facts += " sidecar: " + ["frame_time", "trimmed_from", "duration", "num", "width", "edited"]
                    .compactMap { key in object[key].map { "\(key)=\($0)" } }.joined(separator: " ")
            }
            note("video file: \(facts)")
        }
        stage.stop()
    }

    /// A 4-second 640×360 H.264 clip with a moving square.
    static func writeTestClip(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 640,
            kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 100 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let pixels = buffer else { continue }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 640, height: 360, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            {
                context.setFillColor(red: 0.1, green: 0.12, blue: 0.2 + Double(frame) / 200, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
                context.setFillColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1)
                context.fill(CGRect(x: 40 + frame * 5, y: 120, width: 120, height: 120))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 25))
        }
        input.markAsFinished()
        await writer.finishWriting()
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

    /// Opens the editor on the first saved image, rotates, crops to a square, renames and saves a copy.
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
        await editor.settled()
        editor.aspect = .square
        editor.applyAspect()
        editor.name = "Edited by self-test"
        let size = editor.outputSize
        guard let saved = await editor.saveFile(asCopy: true) else {
            note("editor: save failed: \(editor.message ?? "")")
            return
        }
        let analysis = ImageConversion.analyze(saved)
        let sidecar = (try? Data(contentsOf: Sidecar.sidecarURL(for: saved)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        note("editor: \(before.width)x\(before.height) rotated and cropped to \(size?.label ?? "?"), saved \(saved.lastPathComponent) "
            + "as \(analysis.map { "\($0.width)x\($0.height)" } ?? "?"), original kept: "
                + "\(FileManager.default.fileExists(atPath: file.path)), "
            + "sidecar width \(sidecar?["width"] ?? "none"), edited \(sidecar?["edited"] ?? "no")")
        // An edit saved in place keeps the file's name, metadata file and all (audit 3, B3-M1).
        let inPlace = EditorModel(request: EditorRequest(subject: .file(saved)), window: model)
        await inPlace.load()
        inPlace.rotate(clockwise: true)
        await inPlace.settled()
        let replaced = await inPlace.saveFile(asCopy: false)
        let sameName = replaced?.lastPathComponent == saved.lastPathComponent
        let keptSidecar = replaced.map { FileManager.default.fileExists(atPath: Sidecar.sidecarURL(for: $0).path) } ?? false
        note("editor: \(sameName && keptSidecar ? "PASS" : "FAIL") an edit saved in place keeps the name "
            + "(\(replaced?.lastPathComponent ?? "not saved"), metadata file \(keptSidecar))")
        // An edit of an extracted item saved before is saved as a new file, not skipped as already saved (audit 6, A6-M3).
        let savedItem = model.items.first { item in
            guard item.kind == .image, case let .saved(url)? = model.states[item.id] else { return false }
            return ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()) && (ImageConversion.analyze(url)?.width ?? 0) >= 64
        }
        guard let savedItem, let folder = model.saveFolder else {
            note("editor: FAIL no saved extracted image to edit again")
            return
        }
        let count = { (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects.count) ?? 0 }
        let filesBefore = count()
        let originalState = model.states[savedItem.id]
        let originalName = model.customNames[savedItem.id]
        let itemEditor = EditorModel(request: EditorRequest(subject: .item(savedItem.id)), window: model)
        await itemEditor.load()
        itemEditor.rotate(clockwise: true)
        await itemEditor.settled()
        // A name typed with edits names the copy only (audit 8, C8-M1; audit 9, C9-m4).
        itemEditor.name = "Edited copy by self-test"
        let started = await itemEditor.saveItem(to: folder)
        await waitUntil(timeout: 60) { AppModel.shared.jobs.activeCount == 0 }
        let added = count() - filesBefore
        // The copy took the typed name (audit 10, C10-m7).
        let copyNamed = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .contains { $0.lastPathComponent.hasPrefix("Edited copy by self-test") }
        // The original is still itself: saved where it was, not taken for its copy (audit 7, C7-M2).
        let originalKept = model.states[savedItem.id] == originalState && model.customNames[savedItem.id] == originalName
            && copyNamed
        note("editor: \(started && added > 0 && originalKept ? "PASS" : "FAIL") an edited copy of a saved item is saved "
            + "(\(added) files added), the original keeps its own state \(originalKept)")
    }

    /// Sockets the app process has open; analysis must not open any (R-513).
    static func socketCount() -> Int {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        return fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.count
    }

    /// Where `--selftest-update` points the engine paths: a stand-in bridge that replays recorded events offline.
    static var replayBridge: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("Engines/selftest", isDirectory: true)
    }

    /// Updates an account folder offline (D-78 to D-81). The folder is called "alice old" and holds a post by its archive
    /// name and a renamed one known only by its metadata; the record remembers a file the person deleted. Update must add
    /// only the new post and story, into the folder's own type folders, with no copies and no nested folder; a second
    /// Update adds nothing; Find Missing brings back the deleted file.
    private func exerciseUpdate(library: URL, out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        guard let home = app.enginePaths?.engineHome, app.enginePaths?.bridgeDirectory == Self.replayBridge else {
            note("update: FAIL the stand-in bridge is not in use")
            return
        }
        let folder = library.appendingPathComponent("alice old", isDirectory: true)
        let fixtures = out.appendingPathComponent("update-fixtures", isDirectory: true)
        for directory in [folder.appendingPathComponent("posts"), fixtures, home] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // A folder of web saves beside it must not make the library look like alice's folder.
        let web = library.appendingPathComponent("example.com", isDirectory: true)
        try? fm.createDirectory(at: web, withIntermediateDirectories: true)
        try? Self.jpeg(9).write(to: web.appendingPathComponent("page.jpg"))
        try? #"{"category":"example.com","subcategory":"page","username":"example.com","post_id":"1"}"#
            .write(to: web.appendingPathComponent("page.jpg.json"), atomically: true, encoding: .utf8)

        let ids = (1 ... 5).map { "30088112233445566\(String(format: "%02d", $0))" }
        let posts = (1 ... 5).map { "31000000000000000\(String(format: "%02d", $0))" }
        func meta(_ index: Int, subcategory: String = "posts") -> [String: Any] {
            ["category": "instagram", "subcategory": subcategory, "username": "alice", "post_id": posts[index], "media_id": ids[index],
             "num": 1, "count": 1, "date": "2024-0\(index + 1)-01 10:00:00",
             "post_shortcode": InstagramIDs.shortcode(fromID: posts[index]) ?? "x",
             "shortcode": InstagramIDs.shortcode(fromID: ids[index]) ?? "x"]
        }
        func sidecar(_ fields: [String: Any], for file: URL) {
            try? JSONSerialization.data(withJSONObject: fields).write(to: Sidecar.sidecarURL(for: file))
        }
        // On disk: item 0 by its archive name; item 1 renamed, known from post_id and num (no media_id: older metadata).
        let code0 = InstagramIDs.shortcode(fromID: ids[0]) ?? "x"
        let byName = folder.appendingPathComponent("posts/2024-01-01_100000_\(code0)_01.jpg")
        try? Self.jpeg(0).write(to: byName)
        sidecar(meta(0), for: byName)
        let renamed = folder.appendingPathComponent("posts/Beach.jpg")
        try? Self.jpeg(1).write(to: renamed)
        var older = meta(1)
        older["media_id"] = nil
        sidecar(older, for: renamed)
        let before = [byName, renamed].map { (try? FileHasher.sha256(of: $0)) ?? "" }
        // Item 4 was saved here once and deleted on purpose.
        let record = await app.accountFolders.record(account: "alice", folder: folder)
        await app.accountFolders.addKeys(["ig:\(ids[4])"], to: record.id)
        await app.refreshAccountFolders()

        var items: [[String: Any]] = []
        for index in 0 ..< 5 {
            let source = fixtures.appendingPathComponent("item\(index).jpg")
            try? Self.jpeg(index).write(to: source)
            items.append(["key": "ig:\(ids[index])", "source": source.path,
                          "meta": meta(index, subcategory: index == 3 ? "stories" : "posts")])
        }
        let replay: [String: Any] = ["account": ["username": "alice", "user_id": "42", "post_count": 5, "is_private": false],
                                     "items": items]
        try? JSONSerialization.data(withJSONObject: replay).write(to: home.appendingPathComponent("replay.json"))

        model.library.selectedFolder = folder.appendingPathComponent("posts")
        await waitUntil(timeout: 20) { self.model.library.account != nil }
        let shown = model.library.account
        let button = shown.map { "Update @\($0.account) for \($0.folder.lastPathComponent)" } ?? "no Update button"
        note("update: selected posts/ shows \(button)")
        model.library.selectedFolder = library
        try? await Task.sleep(for: .seconds(1))
        note("update: library root shows \(model.library.account.map { "@\($0.account)" } ?? "no Update button") (expected none)")

        func run(_ title: String, findMissing: Bool) async -> Job? {
            let job = await app.engines.startUpdate(account: "alice", folder: folder, findMissing: findMissing, window: model)
            await waitUntil(timeout: 120) { job?.state.isFinished ?? true }
            note("update: \(title): saved \(job?.saved ?? -1), duplicates \(job?.duplicates ?? -1), skipped \(job?.skipped ?? -1), "
                + "failed \(job?.failed ?? -1) – \(job?.state.label ?? "no job")")
            return job
        }
        let first = await run("first Update", findMissing: false)
        let tree = (fm.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []).filter { !$0.hasSuffix(".json") }.sorted()
        note("update: folder holds \(tree.joined(separator: ", "))")
        let nested = fm.fileExists(atPath: folder.appendingPathComponent("alice").path)
            || fm.fileExists(atPath: library.appendingPathComponent("alice").path)
        let numbered = tree.contains { $0.range(of: #" \d+\.[a-z0-9]+$"#, options: .regularExpression) != nil }
        let after = [byName, renamed].map { (try? FileHasher.sha256(of: $0)) ?? "" }
        let story = tree.contains { $0.hasPrefix("stories/") }
        // The early stop is sent: with a stop after 2 known items, the second Update stops after 2 (audit 2, C2-m9).
        let savedStop = app.preferences.stopAfterKnown
        app.preferences.stopAfterKnown = 2
        let second = await run("second Update", findMissing: false)
        app.preferences.stopAfterKnown = savedStop
        let stoppedEarly = second?.skipped == 2
        // A file the folder held before its first 1.8 Update (an earlier version saved it), deleted since, stays deleted
        // (D-79, D-98, audit 15, C15-M1).
        try? fm.removeItem(at: Sidecar.sidecarURL(for: byName))
        try? fm.removeItem(at: byName)
        let afterDeletion = await run("Update after a deletion", findMissing: false)
        let deletionKept = afterDeletion?.saved == 0 && afterDeletion?.state == .completed && !fm.fileExists(atPath: byName.path)
        note("update: a file held before the first Update and deleted since stayed deleted \(deletionKept)")
        let missing = await run("Find Missing", findMissing: true)
        let code4 = InstagramIDs.shortcode(fromID: ids[4]) ?? "-"
        let restored = fm.enumerator(atPath: folder.path)?.allObjects.contains { ($0 as? String)?.contains(code4) ?? false }
        // An update that stopped part way (R-1904): the next one pulls from the top, then continues from where it stopped.
        await app.accountFolders.setPlace(ResumePlace(cursor: "after-3", untilEnd: true), in: record.id)
        let pulls = { app.jobs.jobs.filter { $0.kind == .pull }.count }
        let jobsBefore = pulls()
        _ = await run("Update after a stop", findMissing: false)
        await waitUntil(timeout: 120) { !app.jobs.jobs.contains { $0.kind == .pull && !$0.state.isFinished } }
        // The continuation starts at the stored place: of the 2 items after the third, only the post is listed (the other
        // is a story, and a continuation walks posts only).
        let continuation = app.jobs.jobs.filter { $0.kind == .pull }.last { $0.title.contains("@alice") && $0.skipped == 1 }
        let continued = pulls() - jobsBefore == 2 && continuation != nil
        let cleared = await app.accountFolders.all().first { $0.id == record.id }?.stoppedPartWay == false
        note("update: after a stop, \(pulls() - jobsBefore) jobs ran (top, then the rest); place cleared \(cleared)")
        // A first pull into a new folder that stops part way keeps its place and what it saved (audit round 1, C3).
        var cut = replay
        cut["account"] = ["username": "bob", "user_id": "43", "post_count": 5, "is_private": false]
        cut["items"] = items.map { item -> [String: Any] in
            var copy = item
            copy["key"] = "ig:bob\(item["key"] as? String ?? "")"
            var meta = item["meta"] as? [String: Any] ?? [:]
            meta["username"] = "bob"
            copy["meta"] = meta
            return copy
        }
        cut["stop_after"] = 2
        try? JSONSerialization.data(withJSONObject: cut).write(to: home.appendingPathComponent("replay.json"))
        var draft = app.engines.draft(username: "bob")
        draft.content = [.posts]
        draft.incremental = false
        let interrupted = app.engines.startPull(draft, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { interrupted?.state.isFinished ?? true }
        let bobRecord = await app.accountFolders.all().first { $0.account == "bob" }
        let bobPlace = bobRecord?.places?.first
        let keptPlace = bobPlace?.cursor == "after-2" && bobPlace?.untilEnd == true && bobRecord?.keys.count == 2
        note("update: a first pull stopped part way kept its place \(bobPlace?.cursor ?? "none") and \(bobRecord?.keys.count ?? 0) items")
        // Places (D-87), each a case an audit found going wrong.
        func writeReplay(_ value: [String: Any]) {
            try? JSONSerialization.data(withJSONObject: value).write(to: home.appendingPathComponent("replay.json"))
        }
        func waitForPulls() async { await waitUntil(timeout: 120) { !app.jobs.jobs.contains { $0.kind == .pull && !$0.state.isFinished } } }
        func places(_ account: String) async -> [ResumePlace] {
            await app.accountFolders.all().first { $0.account == account }?.places ?? []
        }
        let bobFolder = URL(fileURLWithPath: bobRecord?.path ?? "/", isDirectory: true)
        // A pull that does not walk the posts listing (stories only) leaves bob's place alone (A3-M3). The stand-in lists
        // only the content asked for, as the bridge does, and the pull runs to its end (audit 4, C4-m7).
        cut["stop_after"] = nil
        writeReplay(cut)
        var storiesOnly = app.engines.draft(username: "bob")
        storiesOnly.content = [.stories]
        storiesOnly.contentFromAddress = true
        storiesOnly.accountFolder = bobFolder
        let storiesJob = app.engines.startPull(storiesOnly, scanOnly: false, window: model)
        await waitUntil(timeout: 60) { storiesJob?.state.isFinished ?? true }
        let placeKept = await places("bob").first?.cursor == "after-2" && storiesJob?.saved == 1
        // Activity's Resume continues from the place, not from the top (A3-M5): only the posts among items 3 to 5 are listed
        // (the story among them is not a post).
        let jobsBeforeResume = Set(app.jobs.jobs.map(\.id))
        await app.engines.resumePlaces(account: "bob", folder: bobFolder, window: model)
        await waitForPulls()
        let resumed = app.jobs.jobs.first { $0.kind == .pull && !jobsBeforeResume.contains($0.id) }
        let resumedFromPlace = resumed?.saved == 2 && resumed?.skipped == 0
        note("update: Resume of bob: \(resumed?.title ?? "none") saved \(resumed?.saved ?? -1), duplicates \(resumed?.duplicates ?? -1), "
            + "skipped \(resumed?.skipped ?? -1), failed \(resumed?.failed ?? -1)")
        let bobDone = await places("bob").isEmpty
        // A continuation whose place has gone does nothing (A3-M4).
        var stale = app.engines.draft(username: "bob")
        stale.accountFolder = bobFolder
        stale.continueFrom = ResumePlace(cursor: "after-1", untilEnd: true)
        stale.content = [.posts]
        let staleJob = app.engines.startPull(stale, scanOnly: false, window: model)
        await waitUntil(timeout: 60) { staleJob?.state.isFinished ?? true }
        let staleIdle = staleJob?.saved == 0 && staleJob?.skipped == 0
        // An update whose posts listing ended, then failed (a Reel), leaves no place (A3-M2).
        var failing = replay
        failing["fail_after_listing"] = true
        writeReplay(failing)
        _ = await run("Update that fails after the posts", findMissing: false)
        await waitForPulls()
        let noPlaceAfterLateFailure = await places("alice").isEmpty
        // An update stopped part way leaves a place that may stop at known posts; the next Update continues it (D-87).
        var cutUpdate = replay
        cutUpdate["stop_after"] = 2
        writeReplay(cutUpdate)
        _ = await run("Update stopped part way", findMissing: false)
        await waitForPulls()
        let updatePlace = await places("alice").first
        writeReplay(replay)
        _ = await run("Update after it", findMissing: false)
        await waitForPulls()
        let updateContinued = updatePlace?.untilEnd == false && updatePlace?.cursor == "after-2"
        let aliceDone = await places("alice").isEmpty
        note("update: places: stories-only kept bob's \(placeKept), Resume from the place \(resumedFromPlace) and cleared \(bobDone), "
            + "stale continuation idle \(staleIdle), no place after a late failure \(noPlaceAfterLateFailure), "
            + "interrupted update left \(updatePlace.map { "\($0.cursor) untilEnd \($0.untilEnd)" } ?? "none") "
            + "and was continued \(aliceDone)")
        // Audit 4: a file that fails is a failure Retry Failed fetches again (A4-M3, A4-M4).
        var dana = replay
        dana["account"] = ["username": "dana", "user_id": "44", "post_count": 5, "is_private": false]
        dana["items"] = items.map { item -> [String: Any] in
            var copy = item
            copy["key"] = "ig:dana\(item["key"] as? String ?? "")"
            var meta = item["meta"] as? [String: Any] ?? [:]
            meta["username"] = "dana"
            meta["subcategory"] = "posts"
            copy["meta"] = meta
            return copy
        }
        // 16 posts, the 15th failing: deeper than the early stop (12 known in a row), so only a full walk reaches it.
        func account(_ name: String, id: String, count: Int) -> [String: Any] {
            var value = replay
            value["account"] = ["username": name, "user_id": id, "post_count": count, "is_private": false]
            value["items"] = (0 ..< count).map { index -> [String: Any] in
                let source = fixtures.appendingPathComponent("\(name)\(index).jpg")
                try? Self.jpeg(20 + index).write(to: source)
                var fields = meta(index % 5)
                let post = "32\(String(format: "%015d", index))", media = "33\(String(format: "%015d", index))"
                fields["username"] = name
                fields["post_id"] = post
                fields["media_id"] = media
                fields["post_shortcode"] = InstagramIDs.shortcode(fromID: post) ?? "x"
                fields["shortcode"] = InstagramIDs.shortcode(fromID: media) ?? "x"
                fields["date"] = "2025-01-\(String(format: "%02d", 28 - index)) 10:00:00"
                return ["key": "ig:\(name)\(index)", "source": source.path, "meta": fields]
            }
            return value
        }
        let savedStopAfter = app.preferences.stopAfterKnown
        app.preferences.stopAfterKnown = 12
        defer { app.preferences.stopAfterKnown = savedStopAfter }
        let danaFive = dana
        dana = account("dana", id: "44", count: 16)
        var failingFile = dana
        failingFile["fail_files"] = [15]
        writeReplay(failingFile)
        var danaDraft = app.engines.draft(username: "dana")
        danaDraft.content = [.posts]
        danaDraft.incremental = true
        let danaJob = app.engines.startPull(danaDraft, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { danaJob?.state.isFinished ?? true }
        let failedCounted = danaJob?.failed == 1 && danaJob?.saved == 15
        note("update: dana saved \(danaJob?.saved ?? -1), duplicates \(danaJob?.duplicates ?? -1), failed \(danaJob?.failed ?? -1)")
        writeReplay(dana)
        danaJob?.retry?()
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil(timeout: 120) { danaJob?.state.isFinished ?? true }
        let retried = failedCounted && danaJob?.saved == 16 && danaJob?.failed == 0
        note("update: a failed file counted \(failedCounted), Retry Failed fetched it from deep in the listing \(retried)")
        // Retry Failed cut off near the top, then Resumed: the full walk goes on, not the original update (audit 5, C5-M2).
        let fay = account("fay", id: "46", count: 16)
        var fayFailing = fay
        fayFailing["fail_files"] = [15]
        writeReplay(fayFailing)
        var fayDraft = app.engines.draft(username: "fay")
        fayDraft.content = [.posts]
        fayDraft.incremental = true
        let fayJob = app.engines.startPull(fayDraft, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { fayJob?.state.isFinished ?? true }
        var fayCut = fay
        fayCut["stop_after"] = 2
        writeReplay(fayCut)
        fayJob?.retry?()
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil(timeout: 120) { fayJob?.state.isFinished ?? true }
        writeReplay(fay)
        fayJob?.resume?()
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil(timeout: 120) { fayJob?.state.isFinished ?? true }
        let resumedRetry = fayJob?.saved == 16 && fayJob?.failed == 0
        note("update: Resume of a cut-off Retry Failed reached the failed file \(resumedRetry) (saved \(fayJob?.saved ?? -1))")
        // A job's own Resume continues from where it stopped, not from the top (C4-m8).
        var erin = danaFive
        erin["account"] = ["username": "erin", "user_id": "45", "post_count": 5, "is_private": false]
        erin["items"] = (danaFive["items"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            var copy = item
            copy["key"] = (item["key"] as? String ?? "").replacingOccurrences(of: "dana", with: "erin")
            var meta = item["meta"] as? [String: Any] ?? [:]
            meta["username"] = "erin"
            copy["meta"] = meta
            return copy
        }
        var erinCut = erin
        erinCut["stop_after"] = 2
        writeReplay(erinCut)
        var erinDraft = app.engines.draft(username: "erin")
        erinDraft.content = [.posts]
        let erinJob = app.engines.startPull(erinDraft, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { erinJob?.state.isFinished ?? true }
        let erinCursor = erinJob?.lastCursor
        writeReplay(erin)
        erinJob?.resume?()
        try? await Task.sleep(for: .milliseconds(300))
        await waitUntil(timeout: 120) { erinJob?.state.isFinished ?? true }
        let resumedOwn = erinCursor == "after-2" && erinJob?.saved == 5 && erinJob?.skipped == 0
        note("update: a job's Resume continued from \(erinCursor ?? "none"): saved \(erinJob?.saved ?? -1), "
            + "skipped \(erinJob?.skipped ?? -1)")
        // A name taken by another person is never pulled into the folder (C4-M4).
        var taken = replay
        taken["account"] = ["username": "alice", "user_id": "99", "post_count": 5, "is_private": false]
        writeReplay(taken)
        let other = await run("Update of a name now someone else's", findMissing: false)
        let refusedOther = other?.saved == 0 && (other?.state.label.contains("different Instagram account") ?? false)
        writeReplay(replay)
        // A folder renamed while its pull was queued is followed, never made again at its old path (A4-M5, C4-M1).
        let renamedFolder = library.appendingPathComponent("alice renamed", isDirectory: true)
        try? fm.moveItem(at: folder, to: renamedFolder)
        var queued = app.engines.draft(username: "alice")
        queued.accountFolder = folder
        queued.content = [.posts]
        let queuedJob = app.engines.startPull(queued, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { queuedJob?.state.isFinished ?? true }
        let recreated = fm.fileExists(atPath: folder.path)
        let followed = !recreated && queuedJob?.destination?.standardizedFileURL == renamedFolder.standardizedFileURL
        note("update: queued pull went to \(queuedJob?.destination?.lastPathComponent ?? "nowhere") "
            + "(\(queuedJob?.state.label ?? "no job")), old path made again \(recreated)")
        try? fm.moveItem(at: renamedFolder, to: folder)
        // The same when MediaPull renamed it (the record moves at once, the queued draft keeps the old path; audit 5, C5-M4).
        var byRecord = queued
        byRecord.accountFolderID = record.id
        // Renamed through MediaPull's own change, as the Library's Rename does (audit 9, C9-m6).
        _ = await app.applyChange(FolderOperations.rename(folder, to: renamedFolder.lastPathComponent))
        let queuedAgain = app.engines.startPull(byRecord, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { queuedAgain?.state.isFinished ?? true }
        let followedOwn = !fm.fileExists(atPath: folder.path)
            && queuedAgain?.destination?.standardizedFileURL == renamedFolder.standardizedFileURL
            && !(queuedAgain?.state.label.contains("no longer there") ?? true)
        _ = await app.applyChange(FolderOperations.rename(renamedFolder, to: folder.lastPathComponent))
        // A folder moved to the Trash while queued stops the pull and is never made again (A4-M5).
        var trashedAt: NSURL?
        try? fm.trashItem(at: folder, resultingItemURL: &trashedAt)
        let trashedJob = app.engines.startPull(byRecord, scanOnly: false, window: model)
        await waitUntil(timeout: 120) { trashedJob?.state.isFinished ?? true }
        let stoppedForTrash = !fm.fileExists(atPath: folder.path) && trashedJob?.saved == 0
            && (trashedJob?.state.label.contains("no longer there") ?? false)
        if let trashedAt = trashedAt as URL? { try? fm.moveItem(at: trashedAt, to: folder) }
        note("update: renamed in MediaPull: \(queuedAgain?.destination?.lastPathComponent ?? "nowhere") "
            + "(\(queuedAgain?.state.label ?? "no job"))")
        note("update: name taken by someone else refused \(refusedOther), folder renamed while queued followed \(followed), "
            + "renamed in MediaPull followed \(followedOwn), trashed stopped \(stoppedForTrash)")
        // Audit 7: items of whoever has the name now are refused on every route (A7-M2, C7-M3): saving listed items and a
        // single post. The folder knows its account as id 42.
        let filesIn = { (fm.enumerator(atPath: folder.path)?.allObjects.count) ?? 0 }
        let beforeRefusals = filesIn()
        let stranger = fixtures.appendingPathComponent("stranger.jpg")
        try? Self.jpeg(41).write(to: stranger)
        var strangerContext = EngineContext(key: "ig:stranger1", category: "instagram", subcategory: "posts")
        strangerContext.username = "alice"
        strangerContext.ownerID = "99"
        let strangerItem = MediaItem(id: "ig:stranger1", kind: .image,
                                     variants: [MediaVariant(id: stranger.absoluteString, url: stranger, format: .jpeg, origin: .img)],
                                     source: .engine(strangerContext), discoveryIndex: 0, group: "g", groupTitle: "t")
        let refusedSave = app.save([strangerItem], from: model, to: folder)
        await waitUntil(timeout: 60) { refusedSave?.state.isFinished ?? true }
        var post = replay
        post["account"] = ["username": "alice", "user_id": "99", "post_count": 1, "is_private": false]
        var postMeta = meta(2)
        postMeta["owner_id"] = "99"
        postMeta["media_id"] = "3400000000000000001"
        postMeta["post_id"] = "3400000000000000002"
        post["items"] = [["key": "ig:3400000000000000001", "source": stranger.path, "meta": postMeta]]
        writeReplay(post)
        let single = app.engines.startPull(app.engines.draft(username: "", postURL: URL(string: "https://www.instagram.com/p/strange/")),
                                           scanOnly: false, window: model, saveFolder: library)
        await waitUntil(timeout: 120) { single?.state.isFinished ?? true }
        let refusedRoutes = refusedSave?.saved == 0 && (refusedSave?.skipped ?? 0) >= 1 && single?.saved == 0
            && (single?.skipped ?? 0) >= 1 && filesIn() == beforeRefusals
        note("update: another owner's items refused when saving listed items \(refusedSave?.skipped ?? -1) "
            + "and as a single post \(single?.skipped ?? -1); folder unchanged \(filesIn() == beforeRefusals)")
        // A folder made by saving listed items records its owner's id, and then refuses another owner's items (A9-M3,
        // A10-M1).
        func listed(_ id: String, owner: String, colour: Int, name: String = "ivy") -> MediaItem {
            let source = fixtures.appendingPathComponent("\(id).jpg")
            try? Self.jpeg(colour).write(to: source)
            var context = EngineContext(key: "ig:\(id)", category: "instagram", subcategory: "posts")
            context.username = name
            context.ownerID = owner
            context.postID = "35\(colour)"
            context.mediaID = "36\(colour)"
            return MediaItem(id: "ig:\(id)", kind: .image,
                             variants: [MediaVariant(id: source.absoluteString, url: source, format: .jpeg, origin: .img)],
                             source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        }
        let firstSave = app.save([listed("ivy1", owner: "50", colour: 42)], from: model, to: library)
        await waitUntil(timeout: 60) { firstSave?.state.isFinished ?? true }
        let ivyRecord = await app.accountFolders.all().first { $0.account == "ivy" }
        let otherSave = app.save([listed("ivy2", owner: "51", colour: 43)], from: model, to: library)
        await waitUntil(timeout: 60) { otherSave?.state.isFinished ?? true }
        // It remembers what it saved, so a deleted item never comes back at its first Update (audit 12, A12-M1, C12-M1).
        let madeFolderChecked = ivyRecord?.userID == "50" && firstSave?.saved == 1 && otherSave?.saved == 0
            && (otherSave?.skipped ?? 0) == 1 && ivyRecord?.keys.contains("ig:ivy1") == true
        note("update: a folder made by saving listed items took its owner's id \(ivyRecord?.userID ?? "none"), "
            + "remembered \(ivyRecord?.keys.sorted() ?? []) and refused another owner's item \(otherSave?.skipped ?? -1)")
        // The same in a Plain library, the case A10-M1 was about (audit 11, A11-m1, C11-m5).
        let plainLibrary = out.appendingPathComponent("plain-library", isDirectory: true)
        try? fm.createDirectory(at: plainLibrary, withIntermediateDirectories: true)
        await app.addRoot(plainLibrary, layout: .plain)
        let plainSave = app.save([listed("ivo1", owner: "70", colour: 44, name: "ivo")], from: model, to: plainLibrary)
        await waitUntil(timeout: 60) { plainSave?.state.isFinished ?? true }
        let ivoRecord = await app.accountFolders.all().first { $0.account == "ivo" }
        let plainChecked = ivoRecord?.userID == "70" && plainSave?.saved == 1 && ivoRecord?.keys.contains("ig:ivo1") == true
        note("update: in a Plain library the new folder took its owner's id \(ivoRecord?.userID ?? "none")")
        // Where an earlier version's first pull stopped is continued by the first Update (C3-m14, audit 11, A11-M1).
        let jay = library.appendingPathComponent("jay", isDirectory: true)
        try? fm.createDirectory(at: jay.appendingPathComponent("posts"), withIntermediateDirectories: true)
        let jayFile = jay.appendingPathComponent("posts/2025-01-28_100000_x_01.jpg")
        try? Self.jpeg(45).write(to: jayFile)
        sidecar(["category": "instagram", "subcategory": "posts", "username": "jay", "post_id": "1", "num": 1], for: jayFile)
        writeReplay(account("jay", id: "61", count: 6))
        await app.store?.updateAccount("jay", resumeCursor: .some("after-3"))
        let jayJobsBefore = pulls()
        _ = await app.engines.startUpdate(account: "jay", folder: jay, findMissing: false, window: model)
        await waitForPulls()
        let jayCursorLeft = await app.store?.account("jay")?.resumeCursor
        let jayContinued = pulls() - jayJobsBefore == 2 && (jayCursorLeft ?? "").isEmpty
        note("update: an earlier version's stopped place was continued \(jayContinued) (\(pulls() - jayJobsBefore) jobs)")
        // A save folder renamed after a download was queued is followed (C6-M3).
        let saves = library.appendingPathComponent("Saves", isDirectory: true)
        try? fm.createDirectory(at: saves, withIntermediateDirectories: true)
        writeReplay(account("gus", id: "47", count: 3))
        var gusDraft = app.engines.draft(username: "gus")
        gusDraft.content = [.posts]
        let gusJob = app.engines.startPull(gusDraft, scanOnly: false, window: model, saveFolder: saves)
        let savesRenamed = library.appendingPathComponent("Saves renamed", isDirectory: true)
        try? fm.moveItem(at: saves, to: savesRenamed)
        await waitUntil(timeout: 120) { gusJob?.state.isFinished ?? true }
        let savedFollowed = gusJob?.saved == 3 && !fm.fileExists(atPath: saves.path)
            && fm.fileExists(atPath: savesRenamed.appendingPathComponent("gus").path)
        note("update: a save folder renamed while the download was queued was followed \(savedFollowed) "
            + "(\(gusJob?.state.label ?? "no job"), saved \(gusJob?.saved ?? -1))")
        // Download All saves where its folder is when each entry runs, not where it was at the click (C7-M4, audit 8, C8-m6).
        let listFolder = library.appendingPathComponent("List", isDirectory: true)
        try? fm.createDirectory(at: listFolder, withIntermediateDirectories: true)
        let selectedBefore = model.library.selectedFolder
        model.library.selectedFolder = listFolder
        writeReplay(account("hal", id: "48", count: 2))
        model.downloads.useList(["@hal"])
        await waitUntil(timeout: 30) { !self.model.downloads.batch.contains { $0.kind == .checking } }
        model.downloads.runAll(window: model)
        let listRenamed = library.appendingPathComponent("List renamed", isDirectory: true)
        try? fm.moveItem(at: listFolder, to: listRenamed)
        await waitUntil(timeout: 120) { !self.model.downloads.batchRunning }
        let listFollowed = model.downloads.batch.first?.progress == .done && !fm.fileExists(atPath: listFolder.path)
            && fm.fileExists(atPath: listRenamed.appendingPathComponent("hal").path)
        note("update: Download All followed its folder renamed after the click \(listFollowed) "
            + "(\(model.downloads.batch.first.map { "\($0.progress)" } ?? "no entry"))")
        // A pull with another account's folder as the save folder goes into the account's own folder beside it, never a
        // numbered new folder or one inside (audit 12, A12-M2; audit 13, A13-M4).
        let danaFolder = await app.accountFolders.all().first { $0.account == "dana" }.map { URL(fileURLWithPath: $0.path) }
        let ivyFolder = library.appendingPathComponent("ivy", isDirectory: true)
        writeReplay(account("dana", id: "44", count: 17))
        var besideDraft = app.engines.draft(username: "dana")
        besideDraft.content = [.posts]
        besideDraft.incremental = false
        let besideJob = app.engines.startPull(besideDraft, scanOnly: false, window: model, saveFolder: ivyFolder)
        await waitUntil(timeout: 120) { besideJob?.state.isFinished ?? true }
        let danaEntries = (try? fm.contentsOfDirectory(atPath: library.path)) ?? []
        let besideChecked = besideJob?.saved == 1 && danaFolder != nil && !danaEntries.contains("dana 2")
            && !fm.fileExists(atPath: ivyFolder.appendingPathComponent("dana").path)
            && besideJob?.destination?.standardizedFileURL.path == danaFolder?.standardizedFileURL.path
        note("update: a pull with another account's folder selected went into the account's folder beside it \(besideChecked) "
            + "(saved \(besideJob?.saved ?? -1), to \(besideJob?.destination?.path ?? "none"))")
        model.library.selectedFolder = selectedBefore
        writeReplay(replay)
        let placesPass = placeKept && resumedFromPlace && bobDone && staleIdle && noPlaceAfterLateFailure && updateContinued && aliceDone
            && retried && resumedRetry && resumedOwn && refusedOther && followed && followedOwn && stoppedForTrash && refusedRoutes
            && savedFollowed && listFollowed && madeFolderChecked && plainChecked && jayContinued && besideChecked && deletionKept
        let passed = shown?.folder.standardizedFileURL == folder.standardizedFileURL && first?.saved == 2 && story && !nested && !numbered
            && after == before && second?.saved == 0 && stoppedEarly && missing?.saved == 2 && restored == true && continued && cleared
            && keptPlace && placesPass
        note("update: \(passed ? "PASS" : "FAIL") (new items placed \(first?.saved ?? 0) of 2, story in stories/ \(story), "
            + "nested folder \(nested), "
            + "numbered copies \(numbered), existing files unchanged \(after == before), second Update saved \(second?.saved ?? -1), "
            + "Find Missing restored the deleted file \(restored == true), resumed after a stop \(continued && cleared), "
            + "first pull kept its place \(keptPlace), stopped early \(stoppedEarly), places \(placesPass))")
        writeLog(to: out)
    }

    /// A small JPEG in a colour of its own, so no two fixtures are the same picture.
    static func jpeg(_ index: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let colour = NSColor(hue: CGFloat(index % 10) / 10, saturation: 0.8, brightness: 0.9 - CGFloat(index / 10) * 0.07, alpha: 1)
        for x in 0 ..< 64 {
            for y in 0 ..< 48 {
                rep.setColor(x < 32 ? colour : colour.blended(withFraction: CGFloat(y) / 48, of: .black) ?? colour, atX: x, y: y)
            }
        }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) ?? Data()
    }

    /// Copies a folder of test media into the library, analyses it (faces included), searches, filters, sorts it in Organise and
    /// undoes the sort, checking the tree is restored exactly (sections 36 to 39).
    private func exerciseAnalysis(source: URL, library: URL, out: URL) async {
        let app = AppModel.shared
        let savedFaces = app.preferences.facesEnabled
        let savedBattery = app.preferences.analysisPauseOnBattery
        defer {
            app.preferences.facesEnabled = savedFaces
            app.preferences.analysisPauseOnBattery = savedBattery
        }
        app.preferences.facesEnabled = true
        app.preferences.analysisPauseOnBattery = false
        let test = library.appendingPathComponent("Test media", isDirectory: true)
        try? FileManager.default.copyItem(at: source, to: test)
        let files = FolderOperations.mediaFiles(in: test, recursive: true)
        note("analysis: \(files.count) files copied; models \(AnalysisService.modelsFolder?.path ?? "missing")")
        await waitUntil(timeout: 60) { app.analysis.modelsLoaded }
        let socketsBefore = Self.socketCount()
        var peakSockets = socketsBefore
        let started = Date()
        app.analysis.schedule(after: .milliseconds(100))
        // Copying the test folder makes folder events that reschedule the scan, so wait for the results, not for idleness.
        await waitUntil(timeout: 900) {
            peakSockets = max(peakSockets, Self.socketCount())
            return !app.analysis.isRunning && app.analysis.analysedCount >= files.count
        }
        let seconds = Date().timeIntervalSince(started)
        note(String(format: "analysis: %d files in %.1f s (%.1f per second); sockets before %d, most during %d",
                    app.analysis.analysedCount, seconds, Double(files.count) / max(seconds, 0.1), socketsBefore, peakSockets))
        let listed = await MediaListing.load(test, recursive: true).entries
        let entries = await app.analysis.attach(listed)
        let records = entries.compactMap(\.record)
        note("records: \(records.count) of \(entries.count); with labels \(records.filter { !$0.labels.isEmpty }.count), with text "
            + "\(records.filter { $0.text != nil }.count), with faces \(records.filter { !$0.faces.isEmpty }.count), "
            + "with embeddings \(records.filter(\.hasEmbedding).count), places \(records.compactMap(\.place).count)")
        if let sample = records.first(where: { !$0.labels.isEmpty }) {
            note("sample: "
                + "\(sample.labels.prefix(5).map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")); "
                + "colour \(sample.colour?.rawValue ?? "none"); faces \(sample.faces.count)")
        }
        for query in ["bus", "a person playing tennis", "skiing in the snow", "dog"] {
            let scores = await app.analysis.meaningScores(query, entries: entries)
            var q = LibraryQuery()
            q.search = query
            let found = q.apply(entries, context: .init(similarity: scores, similarityFloor: AnalysisService.floor(for: scores)))
                .flatMap(\.items)
            note("search “\(query)”: \(found.count) results, first \(found.prefix(3).map(\.name).joined(separator: ", "))")
        }
        let similar = await app.analysis.similarGroups(entries)
        note("similar sets: \(Set(similar.values).count) sets covering \(similar.count) files")
        let found = app.analysis.people.filter { $0.faceCount > 0 }.map { "\($0.displayName) (\($0.faceCount))" }.prefix(8)
        let suggested = app.analysis.suggestions.values.sorted().joined(separator: ", ")
        note("people: \(found.joined(separator: ", ")); suggested names: \(suggested)")

        // A second scan finds nothing new to analyse.
        let jobsBefore = app.jobs.jobs.filter { $0.kind == .analyse }.count
        app.analysis.schedule(after: .milliseconds(100))
        try? await Task.sleep(for: .seconds(3))
        await waitUntil(timeout: 120) { !app.analysis.isRunning }
        note("second scan: \(app.jobs.jobs.filter { $0.kind == .analyse }.count - jobsBefore) new analyse jobs")

        // Library with a filter, then Organise: sort by subject, preview, run, undo.
        model.library.selectedFolder = test
        model.library.includeSubfolders = true
        var query = LibraryQuery()
        query.filter.faces = .withFaces
        model.library.query = query
        try? await Task.sleep(for: .seconds(3))
        note("library filter “with faces”: \(model.library.shownFiles.count) of \(model.library.files.count)")

        // The save folder (D-70): any folder, shown in the Library pane without joining the library.
        let outside = out.appendingPathComponent("Outside folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let rootsBefore = app.roots.count
        model.useSaveFolder(outside)
        try? await Task.sleep(for: .seconds(1))
        note("save folder: \(model.saveFolderName); shown in Library: \(model.library.shows(outside)); "
            + """
                library folders unchanged: \(app.roots.count == rootsBefore); downloads go to \
                \(app.destination(for: outside).url.lastPathComponent)
                """)
        model.library.otherFolder = nil
        model.library.selectedFolder = library
        snapshot(to: out.appendingPathComponent("library-filtered.png"))
        model.library.query = LibraryQuery()
        model.library.includeSubfolders = false

        func checksums() -> [String: String] {
            var out: [String: String] = [:]
            let walker = FileManager.default.enumerator(at: test, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = walker?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                out[String(url.path.dropFirst(test.path.count))] = (try? FileHasher.sha256(of: url)) ?? "?"
            }
            return out
        }
        let before = checksums()
        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        model.organise.open(test)
        model.organise.source.includeSubfolders = true
        try? await Task.sleep(for: .seconds(3))
        snapshot(to: out.appendingPathComponent("organise.png"))
        note("organise opens: mode \(model.organise.mode.label), target \(model.organise.target.root?.lastPathComponent ?? "none")")

        // Copy to a separate target: the source must stay exactly as it was.
        let sortedCopy = library.appendingPathComponent("Sorted copy", isDirectory: true)
        try? FileManager.default.createDirectory(at: sortedCopy, withIntermediateDirectories: true)
        model.organise.open(sortedCopy, in: model.organise.target)
        model.organise.moveToTarget = false
        model.organise.open(test)
        note("new source keeps the target: \(model.organise.target.root?.lastPathComponent ?? "none"), mode \(model.organise.mode.label)")
        model.organise.autoSort(.date)
        await waitUntil(timeout: 60) { self.model.organise.pending != nil }
        if let pending = model.organise.pending {
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: out.appendingPathComponent("organise-copy-preview.png"))
            model.organise.execute(pending.plan)
            await waitUntil(timeout: 120) { self.model.organise.working == nil }
            let copied = FolderOperations.mediaFiles(in: sortedCopy, recursive: true)
            let folders = Set(copied.map { $0.deletingLastPathComponent() }).count
            note("copy to target: \(copied.count) copies in \(folders) folders; source unchanged: \(checksums() == before)")
            snapshot(to: out.appendingPathComponent("organise-copied.png"))
            if let entry = model.organise.history.first {
                model.organise.undo(entry)
                await waitUntil(timeout: 120) { self.model.organise.working == nil }
            }
            note("copy undone: \(FolderOperations.mediaFiles(in: sortedCopy, recursive: true).count) copies left")
        } else {
            note("copy preview: no plan (\(model.organise.message ?? "no message"))")
        }

        // A search that matches nothing must sort nothing, never the whole folder (1.8 audit).
        model.organise.open(test, in: model.organise.target)
        model.organise.source.query.search = "zzqx no such file"
        await waitUntil(timeout: 30) { !self.model.organise.source.filtering }
        model.organise.autoSort(.date)
        try? await Task.sleep(for: .seconds(1))
        note("sort with no matches: plan \(model.organise.pending == nil ? "none" : "MADE"), "
            + "message \(model.organise.message ?? "none")")
        model.organise.source.query.search = ""
        await waitUntil(timeout: 30) { !self.model.organise.source.filtering }

        // In place: sort by subject, then undo.
        model.organise.open(test, in: model.organise.target)
        model.organise.autoSort(.subject)
        await waitUntil(timeout: 60) { self.model.organise.pending != nil }
        if let pending = model.organise.pending {
            note("preview: \(pending.plan.title), \(pending.plan.moves.count) moves into \(pending.plan.destinations.count) folders, "
                + "\(pending.plan.unsorted) unsorted: "
                + pending.plan.destinations.prefix(6).map { "\($0.folder.lastPathComponent) \($0.files.count)" }
                .joined(separator: ", "))
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: out.appendingPathComponent("organise-preview.png"))
            model.organise.execute(pending.plan)
            await waitUntil(timeout: 120) { self.model.organise.working == nil }
            try? await Task.sleep(for: .seconds(1))
            let sorted = checksums()
            note("after sort: \(sorted.count) files, \(Set(sorted.keys.map { ($0 as NSString).deletingLastPathComponent }).count) folders")
            snapshot(to: out.appendingPathComponent("organise-sorted.png"))
            if let entry = model.organise.history.first {
                model.organise.undo(entry)
                await waitUntil(timeout: 120) { self.model.organise.working == nil }
                try? await Task.sleep(for: .seconds(1))
            }
            let after = checksums()
            note("undo: tree restored exactly: \(after == before) (\(after.count) files)")
        } else {
            note("preview: no plan (\(model.organise.message ?? "no message"))")
        }
        model.organise.tab = .people
        try? await Task.sleep(for: .seconds(3))
        snapshot(to: out.appendingPathComponent("people.png"))
        model.organise.tab = .sort
        model.section = .collect
        try? await Task.sleep(for: .seconds(2))
        model.showDownloads("https://www.youtube.com/watch?v=aqz-KE-bpKQ")
        try? await Task.sleep(for: .seconds(8))
        snapshot(to: out.appendingPathComponent("downloads.png"))
        await app.analysis.deleteAllFaceData(turnOff: false)
        let faceFiles = app.analysis.vectorFileNames(prefix: "faces-")
        note("face data deleted: \(app.analysis.people.isEmpty), face vector files left: \(faceFiles.count)")
        writeLog(to: out)
    }

    /// The list of a pane, found by its owner.
    private func outline(of owner: AnyObject) -> MediaOutlineView? {
        func find(_ view: NSView) -> MediaOutlineView? {
            if let outline = view as? MediaOutlineView, outline.coordinator?.owner === owner { return outline }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return model.hostWindow?.contentView.flatMap(find)
    }

    /// The column browser of a pane, found by its owner.
    private func browser(of owner: AnyObject) -> NSBrowser? {
        func find(_ view: NSView) -> NSBrowser? {
            if let browser = view as? NSBrowser, (browser.delegate as? MediaColumns.Coordinator)?.owner === owner { return browser }
            for child in view.subviews {
                if let found = find(child) { return found }
            }
            return nil
        }
        return model.hostWindow?.contentView.flatMap(find)
    }

    /// Selects a row of a column as a click would.
    private func click(_ browser: NSBrowser, row: Int, column: Int) {
        browser.selectRow(row, inColumn: column)
        browser.sendAction(browser.action, to: browser.target)
    }

    /// Icon, list and column views of the Library, Extracted Media and Organise panes (R-1708 to R-1711).
    private func exerciseViews(library: URL, out: URL) async {
        let lib = model.library
        // The folder tree reads folders off the main actor and shows them once read (audit 2, B2-m6).
        let libraryNode = { lib.treeNodes().first { $0.url.standardizedFileURL == library.standardizedFileURL } }
        _ = libraryNode()?.children
        await waitUntil(timeout: 10) { (libraryNode()?.children?.count ?? 0) > 0 }
        let shown = libraryNode()?.children?.map(\.name) ?? []
        note("views: \(shown.isEmpty ? "FAIL" : "PASS") folder tree shows \(shown.joined(separator: ", ")) under the library folder")
        // Folder sizes in List view (R-1714): measured in the background, then shown.
        if let first = shown.first {
            let path = library.appendingPathComponent(first).path
            await waitUntil(timeout: 15) { ListText.folder(path, .size) { _ in } != "--" }
            let size = ListText.folder(path, .size)
            let kind = ListText.folder(path, .kind)
            note("views: \(size != "--" ? "PASS" : "FAIL") folder size \(size), \(kind)")
        }
        let savedSubfolders = lib.includeSubfolders
        defer { lib.includeSubfolders = savedSubfolders }
        lib.includeSubfolders = false
        lib.selectedFolder = library
        model.setViewMode(.list, for: .library)
        await waitUntil(timeout: 60) { !lib.listTopFolders.isEmpty }
        try? await Task.sleep(for: .seconds(1))
        let rows = outline(of: lib)?.numberOfRows ?? -1
        note("views: library list \(rows) rows for \(lib.listTopFolders.count) folders and \(lib.shownFiles.count) files")
        if let outline = outline(of: lib), outline.numberOfRows > 0, let first = outline.item(atRow: 0) {
            outline.expandItem(first)
            // Listings wait for the analysis store, which is busy with the files just saved.
            await waitUntil(timeout: 120) { outline.numberOfRows > 1 }
            try? await Task.sleep(for: .seconds(3))
            note("views: library list after opening the first folder \(outline.numberOfRows) rows")
        }
        snapshot(to: out.appendingPathComponent("view-library-list.png"))
        let savedQuery = lib.query
        lib.listSortChanged(.size, ascending: false)
        note("views: Size header sorts by \(lib.query.sort.rawValue), ascending \(lib.query.ascending)")
        lib.query = savedQuery

        let host = library.appendingPathComponent(FileNaming.safeTopFolder(model.browser.url?.host ?? "web"), isDirectory: true)
        lib.selectedFolder = host
        model.setViewMode(.column, for: .library)
        await waitUntil(timeout: 120) { (self.browser(of: lib)?.lastColumn ?? 0) >= 1 }
        try? await Task.sleep(for: .seconds(2))
        if let browser = browser(of: lib) {
            note("views: library columns open at column \(browser.lastColumn), \(browser.selectionIndexPath?.description ?? "none") "
                + "for \(lib.selectedFolder?.lastPathComponent ?? "none")")
            let last = browser.lastColumn
            click(browser, row: 0, column: last)
            try? await Task.sleep(for: .seconds(3))
            note("views: file chosen in columns: folder \(lib.selectedFolder?.lastPathComponent ?? "none"), "
                + "\(lib.selection.count) selected")
            snapshot(to: out.appendingPathComponent("view-library-columns.png"))
            click(browser, row: 0, column: 0)
            try? await Task.sleep(for: .seconds(1))
            note("views: library folder chosen in columns: \(lib.selectedFolder?.lastPathComponent ?? "none")")
        } else {
            note("views: no column browser in the Library pane")
        }
        model.setViewMode(.list, for: .library)

        model.setViewMode(.list, for: .extracted)
        try? await Task.sleep(for: .seconds(6))
        note("views: extracted list \(outline(of: model)?.numberOfRows ?? -1) rows for \(model.visible.count) items")
        if let first = model.visible.first {
            let started = Date()
            let image = await model.gridThumbnail(first.id, maxPixel: 64)
            note("views: extracted thumbnail \(image.map { "\($0.width)×\($0.height)" } ?? "none") in "
                + String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
        if let outline = outline(of: model), outline.numberOfRows > 0, let cell = outline.view(atColumn: 0, row: 0, makeIfNecessary: false)
            as? ListNameCell
        {
            note("views: first extracted row image \(cell.imageView?.image?.size.debugDescription ?? "none")")
        }
        snapshot(to: out.appendingPathComponent("view-extracted-list.png"))
        model.setViewMode(.column, for: .extracted)
        note("views: extracted asked for columns shows \(model.viewMode(for: .extracted).rawValue)")

        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        model.organise.open(library)
        model.setViewMode(.list, for: .organiseSource)
        let source = model.organise.source
        await waitUntil(timeout: 30) { !source.loading && self.outline(of: source) != nil }
        try? await Task.sleep(for: .seconds(2))
        note("views: section \(model.section), source \(source.root?.lastPathComponent ?? "none"), loading \(source.loading)")
        note("views: organise list \(outline(of: source)?.numberOfRows ?? -1) rows for \(source.listTopFolders.count) folders "
            + "and \(source.shown.count) files")
        if let outline = outline(of: source), outline.numberOfRows > 0, let first = outline.item(atRow: 0) {
            outline.expandItem(first)
            await waitUntil(timeout: 120) { outline.numberOfRows > 1 }
            try? await Task.sleep(for: .seconds(3))
            note("views: organise list after opening the first folder \(outline.numberOfRows) rows")
        }
        snapshot(to: out.appendingPathComponent("view-organise-list.png"))
        model.setViewMode(.column, for: .organiseSource)
        await waitUntil(timeout: 60) { (self.browser(of: source)?.numberOfVisibleColumns ?? 0) > 0 }
        try? await Task.sleep(for: .seconds(2))
        if let browser = browser(of: source) {
            click(browser, row: 0, column: 0)
            try? await Task.sleep(for: .seconds(2))
            note("views: organise folder chosen in columns: \(source.folder?.lastPathComponent ?? "none")")
            let last = browser.lastColumn
            click(browser, row: 0, column: last)
            try? await Task.sleep(for: .seconds(3))
            note("views: organise file chosen: folder \(source.folder?.lastPathComponent ?? "none"), \(source.selection.count) selected")
            snapshot(to: out.appendingPathComponent("view-organise-columns.png"))
        } else {
            note("views: no column browser in the Source pane")
        }
        model.section = .collect
    }

    private func writeLog(to out: URL) {
        try? log.joined(separator: "\n").write(to: out.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
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
