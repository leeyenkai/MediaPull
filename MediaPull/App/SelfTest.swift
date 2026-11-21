import AVFoundation
import AppKit
import ImageIO
import Foundation
import MediaPullCore
import MediaPullDevices
import MediaPullEdit
import MediaPullEngines
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import MediaPullStore
import UniformTypeIdentifiers

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
        if CommandLine.arguments.contains("--selftest-save-as") {
            await exerciseSaveAs(library: library, out: out)
            quit()
            return
        }
        if let mount = Self.value(after: "--selftest-drives") {
            await exerciseDrives(mount: URL(fileURLWithPath: mount, isDirectory: true), out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-edit-photo") {
            await exerciseEditPhoto(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-edit-video") {
            await exerciseEditVideo(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-edit-audio") {
            await exerciseEditAudio(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-edits") {
            await exerciseEdits(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-formats") {
            await exerciseFormats(library: library, out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-devices") {
            await exerciseDevices(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-details") {
            await exerciseDetails(library: library, out: out)
            await exerciseOrganiseParity(out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-profile") {
            await exerciseProfiles(library: library, out: out)
            quit()
            return
        }
        if CommandLine.arguments.contains("--selftest-update") {
            await exerciseReplace(library: library)
            await exerciseNotes(out: out)
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
    static func writeTestClip(to url: URL, seed: Int = 0) async throws {
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
                context.setFillColor(red: 0.1 + Double(seed % 7) / 10, green: 0.12, blue: 0.2 + Double(frame) / 200, alpha: 1)
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

    /// Editor Replace through the whole app, offline (D-107): a case-only rename with an edit keeps the metadata file, ⌘Z
    /// puts the original back exactly, Redo does it again, and nothing is left under a hidden name.
    private func exerciseReplace(library: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        let folder = library.appendingPathComponent("edits", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("Photo.jpg")
        let originalData = Self.jpeg(3)
        try? originalData.write(to: original)
        try? #"{"category":"instagram","username":"x","media_id":"m1"}"#
            .write(to: Sidecar.sidecarURL(for: original), atomically: true, encoding: .utf8)
        func metadata(_ url: URL) -> [String: Any]? {
            (try? Data(contentsOf: Sidecar.sidecarURL(for: url))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        func names() -> [String] { ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
        let editor = EditorModel(request: EditorRequest(subject: .file(original)), window: model)
        await editor.load()
        editor.rotate(clockwise: true)
        await editor.settled()
        editor.name = "photo"
        let replaced = await editor.saveFile(asCopy: false)
        let placed = replaced?.lastPathComponent == "photo.jpg" && names() == ["photo.jpg", "photo.jpg.json"]
            && metadata(folder.appendingPathComponent("photo.jpg"))?["edited"] as? Bool == true
            && metadata(folder.appendingPathComponent("photo.jpg"))?["media_id"] as? String == "m1"
        let entry = await app.journal.entries().first { $0.title.hasPrefix("Edit ") }
        var undone = false, redone = false
        if let entry {
            _ = await app.undoChange(entry.id)
            undone = names() == ["Photo.jpg", "Photo.jpg.json"] && (try? Data(contentsOf: original)) == originalData
                && metadata(original)?["edited"] == nil
            _ = await app.redoChange(entry.id)
            redone = names() == ["photo.jpg", "photo.jpg.json"]
                && metadata(folder.appendingPathComponent("photo.jpg"))?["edited"] as? Bool == true
        }
        let pass = placed && undone && redone
        note("replace: \(pass ? "PASS" : "FAIL") a case-only rename with an edit keeps its metadata file (\(placed)), "
            + "⌘Z puts the original back (\(undone)), Redo does it again (\(redone)); now \(names()) \(editor.message ?? "")")
    }

    /// Save As in the Downloads pane (D-108), offline through the stand-in bridge: for Instagram, videos and galleries, a
    /// download goes exactly into the chosen folder, never redirected, whether that folder is another source's, an existing
    /// folder of the same source (only what is missing is added) or empty (a full copy). Download All As… puts each entry in a
    /// folder of its own inside the chosen one, and a Retry stays in the chosen folder.
    private func exerciseSaveAs(library: URL, out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        guard let home = app.enginePaths?.engineHome, app.enginePaths?.bridgeDirectory == Self.replayBridge else {
            note("save-as: FAIL the stand-in bridge is not in use")
            return
        }
        let base = library.appendingPathComponent("saveas", isDirectory: true)
        let fixtures = out.appendingPathComponent("save-as-fixtures", isDirectory: true)
        for directory in [base, fixtures, home] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("save-as: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        func sidecar(_ fields: [String: Any], for file: URL) {
            try? JSONSerialization.data(withJSONObject: fields).write(to: Sidecar.sidecarURL(for: file))
        }
        // Temporary folders are reached through /var and /private/var: compared resolved.
        let top = library.resolvingSymlinksInPath().path
        /// Every file under the library, by path relative to it.
        func snapshot() -> Set<String> {
            let walker = fm.enumerator(at: library, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var paths = Set<String>()
            while let url = walker?.nextObject() as? URL {
                let path = url.resolvingSymlinksInPath().path
                if !OperationJournal.isFolder(url), path.hasPrefix(top + "/") { paths.insert(String(path.dropFirst(top.count + 1))) }
            }
            return paths
        }
        /// New files since `before` all lie inside `folder`.
        func onlyInside(_ folder: URL, since before: Set<String>) -> (Bool, Int) {
            let prefix = String(folder.resolvingSymlinksInPath().path.dropFirst(top.count + 1)) + "/"
            let added = snapshot().subtracting(before)
            return (added.allSatisfy { $0.hasPrefix(prefix) }, added.filter { !$0.hasSuffix(".json") }.count)
        }
        func folder(_ name: String) -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func writeReplay(_ value: [String: Any]) {
            try? JSONSerialization.data(withJSONObject: value).write(to: home.appendingPathComponent("replay.json"))
        }
        func waitFor(_ job: Job?) async { await waitUntil(timeout: 120) { job?.state.isFinished ?? true } }

        // Instagram: three posts of alice.
        let mediaIDs = (1 ... 3).map { "3700000000000000\($0)" }, postIDs = (1 ... 3).map { "3800000000000000\($0)" }
        func igMeta(_ index: Int) -> [String: Any] {
            ["category": "instagram", "subcategory": "posts", "username": "alice", "post_id": postIDs[index], "media_id": mediaIDs[index],
             "num": 1, "count": 1, "date": "2024-0\(index + 1)-01 10:00:00", "owner_id": "42"]
        }
        var igItems: [[String: Any]] = []
        for index in 0 ..< 3 {
            let source = fixtures.appendingPathComponent("ig\(index).jpg")
            try? Self.jpeg(60 + index).write(to: source)
            igItems.append(["key": "ig:\(mediaIDs[index])", "source": source.path, "meta": igMeta(index)])
        }
        let igReplay: [String: Any] = ["account": ["username": "alice", "user_id": "42", "post_count": 3, "is_private": false],
                                       "items": igItems]
        // alice's own folder holds post 1; bob's folder holds one of bob's.
        let alice = folder("alice"), bob = folder("bob")
        try? fm.createDirectory(at: alice.appendingPathComponent("posts"), withIntermediateDirectories: true)
        let aliceFirst = alice.appendingPathComponent("posts/first.jpg")
        try? Self.jpeg(60).write(to: aliceFirst)
        sidecar(igMeta(0), for: aliceFirst)
        let bobFile = bob.appendingPathComponent("bob.jpg")
        try? Self.jpeg(70).write(to: bobFile)
        sidecar(["category": "instagram", "subcategory": "posts", "username": "bob", "post_id": "1", "media_id": "2", "num": 1],
                for: bobFile)
        writeReplay(igReplay)
        var draft = app.engines.draft(username: "alice")
        draft.content = [.posts]
        func pull(into chosen: URL) async -> Job? {
            let job = app.engines.startPull(draft, scanOnly: false, window: model, saveFolder: chosen, exactly: true)
            await waitFor(job)
            return job
        }
        var before = snapshot()
        let intoBob = await pull(into: bob)
        var (inside, added) = onlyInside(bob, since: before)
        check(inside && added == 3 && intoBob?.saved == 3 && fm.fileExists(atPath: bobFile.path),
              "Instagram into another account's folder: \(added) files, all inside bob \(inside)")
        before = snapshot()
        let intoOwn = await pull(into: alice)
        (inside, added) = onlyInside(alice, since: before)
        check(inside && added == 2 && intoOwn?.saved == 2 && (intoOwn?.skipped ?? 0) >= 1,
              "Instagram into its existing folder: only the 2 missing added, inside \(inside)")
        let alice2 = folder("alice 2")
        before = snapshot()
        let intoEmpty = await pull(into: alice2)
        (inside, added) = onlyInside(alice2, since: before)
        check(inside && added == 3 && intoEmpty?.saved == 3 && fm.fileExists(atPath: alice2.appendingPathComponent("posts").path),
              "Instagram into an empty folder: a full copy of 3 in its posts folder, inside \(inside)")

        // Videos: two of channel X.
        var videos: [[String: Any]] = []
        for index in 1 ... 2 {
            let clip = fixtures.appendingPathComponent("v\(index).mp4")
            try? await Self.writeTestClip(to: clip, seed: index)
            videos.append(["key": "video:youtube:v\(index)", "source": clip.path,
                           "meta": ["id": "v\(index)", "title": "Video \(index)", "uploader": "X", "upload_date": "2024010\(index)",
                                    "webpage_url": "https://www.youtube.com/watch?v=v\(index)"]])
        }
        writeReplay(["videos": videos])
        let info = VideoInfo(title: "X", uploader: "X", id: "list", uploadDate: nil, webpageURL: URL(string: "https://www.youtube.com/@x")!,
                             extractor: "youtube", duration: nil, thumbnail: nil, description: nil, formats: [])
        func download(into chosen: URL) async -> Job {
            var extras = BridgeRequest.Extras()
            extras.playlist = true
            var root = app.destination(for: chosen)
            root.exact = true
            let job = app.engines.saveVideo(info, format: .bestMP4, height: nil, extras: extras, root: root, window: model)
            await waitFor(job)
            return job
        }
        let channelX = folder("X videos"), channelY = folder("Y videos")
        // Held files differ in their bytes from what the engine brings, so only skipping by id can keep them single (B26-m3).
        let held = channelX.appendingPathComponent("held.mp4")
        try? await Self.writeTestClip(to: held, seed: 9)
        sidecar(["category": "youtube", "subcategory": "video", "username": "X", "post_id": "v1"], for: held)
        let yFile = channelY.appendingPathComponent("y.mp4")
        try? await Self.writeTestClip(to: yFile, seed: 5)
        sidecar(["category": "youtube", "subcategory": "video", "username": "Y", "post_id": "y1"], for: yFile)
        before = snapshot()
        let videoIntoY = await download(into: channelY)
        (inside, added) = onlyInside(channelY, since: before)
        check(inside && added == 2 && videoIntoY.saved == 2,
              "videos into another channel's folder: \(added) straight in, inside \(inside) (\(videoIntoY.state.label))")
        before = snapshot()
        let videoIntoX = await download(into: channelX)
        (inside, added) = onlyInside(channelX, since: before)
        check(inside && added == 1 && videoIntoX.saved == 1, "videos into the channel's folder: only the missing one added (\(added))")
        let channelX2 = folder("X videos 2")
        before = snapshot()
        let videoIntoEmpty = await download(into: channelX2)
        (inside, added) = onlyInside(channelX2, since: before)
        check(inside && added == 2 && videoIntoEmpty.saved == 2, "videos into an empty folder: a full copy (\(added))")
        let videoAllHeld = await download(into: channelX2)
        check(videoAllHeld.state == .completed && videoAllHeld.saved == 0,
              "videos into a folder that holds them all: nothing added, completed (\(videoAllHeld.state.label))")

        // Galleries: two items of carol on a test site.
        // As the engine keys them (D-75): a file numbered 0 by its bare post id, others with their number. g3 is a post of
        // two pages numbered from 0, as on pixiv.
        var galleryItems: [[String: Any]] = []
        for (index, (post, num, count)) in [("g1", 1, 1), ("g2", 1, 1), ("g3", 0, 2), ("g3", 1, 2)].enumerated() {
            let source = fixtures.appendingPathComponent("g\(index).jpg")
            try? Self.jpeg(80 + index).write(to: source)
            galleryItems.append(["key": num == 0 ? "testsite:\(post)" : "testsite:\(post):\(num)", "source": source.path,
                                 "meta": ["category": "testsite", "subcategory": "user", "username": "carol", "post_id": post,
                                          "num": num, "count": count, "date": "2024-02-0\(index + 1) 10:00:00"]])
        }
        writeReplay(["account": ["username": "carol"], "gallery_items": galleryItems])
        let site = SiteInfo(category: "testsite", subcategory: "user")
        let galleryURL = URL(string: "https://example.org/carol")!
        func gallery(into chosen: URL) async -> Job? {
            var root = app.destination(for: chosen)
            root.exact = true
            let job = app.engines.startGalleryDownload(url: galleryURL, site: site, include: [], switches: [:], range: nil, from: nil,
                                                       to: nil, onlyNew: false, root: root, window: model)
            await waitFor(job)
            return job
        }
        let carol = folder("carol"), dave = folder("dave")
        // carol's folder holds g1 and the second page of g3, with metadata as the app writes it.
        let carolHeld = carol.appendingPathComponent("one.jpg")
        try? Self.jpeg(180).write(to: carolHeld)
        sidecar(["category": "testsite", "subcategory": "user", "username": "carol", "post_id": "g1", "num": 1, "count": 1], for: carolHeld)
        let carolPage = carol.appendingPathComponent("three-2.jpg")
        try? Self.jpeg(183).write(to: carolPage)
        sidecar(["category": "testsite", "subcategory": "user", "username": "carol", "post_id": "g3", "num": 1, "count": 2], for: carolPage)
        let daveFile = dave.appendingPathComponent("dave.jpg")
        try? Self.jpeg(90).write(to: daveFile)
        sidecar(["category": "testsite", "subcategory": "user", "username": "dave", "post_id": "d1", "num": 1], for: daveFile)
        before = snapshot()
        let galleryIntoDave = await gallery(into: dave)
        (inside, added) = onlyInside(dave, since: before)
        check(inside && added == 4 && galleryIntoDave?.saved == 4,
              "gallery into another user's folder: \(added) straight in, inside \(inside)")
        before = snapshot()
        let galleryIntoCarol = await gallery(into: carol)
        (inside, added) = onlyInside(carol, since: before)
        check(inside && added == 2 && galleryIntoCarol?.saved == 2,
              "gallery into its existing folder: only the 2 missing added, the first page of a post among them (\(added))")
        let carol2 = folder("carol 2")
        before = snapshot()
        let galleryIntoEmpty = await gallery(into: carol2)
        (inside, added) = onlyInside(carol2, since: before)
        check(inside && added == 4 && galleryIntoEmpty?.saved == 4, "gallery into an empty folder: a full copy (\(added))")

        // A Retry stays in the chosen folder: one file fails, then is fetched again into the same folder.
        writeReplay(["account": ["username": "carol"], "gallery_items": galleryItems, "fail_files": [2]])
        let carol3 = folder("carol 3")
        let failing = await gallery(into: carol3)
        writeReplay(["account": ["username": "carol"], "gallery_items": galleryItems])
        before = snapshot()
        failing?.retry?()
        try? await Task.sleep(for: .seconds(1))
        await waitUntil(timeout: 120) { !app.jobs.jobs.contains { $0.kind == .pull && !$0.state.isFinished } }
        (inside, added) = onlyInside(carol3, since: before)
        check(failing?.failed == 0 && inside && added == 1, "a Retry of a Save As download stays in its folder (\(added) added)")

        // Download All As…: each entry in a folder of its own inside the chosen one, an existing one when it holds the source;
        // galleries and videos in `<user> (<site>)` folders named from their files.
        var everything = igReplay
        everything["gallery_items"] = galleryItems
        everything["videos"] = videos
        everything["video_info"] = ["webpage_url": "https://www.youtube.com/watch?v=v1", "title": "Video 1", "uploader": "X",
                                    "id": "v1", "extractor": "youtube"]
        writeReplay(everything)
        let batch = folder("batch")
        let myAlice = batch.appendingPathComponent("alice/posts", isDirectory: true)
        try? fm.createDirectory(at: myAlice, withIntermediateDirectories: true)
        let batchFirst = myAlice.appendingPathComponent("first.jpg")
        try? Self.jpeg(160).write(to: batchFirst)
        sidecar(igMeta(0), for: batchFirst)
        before = snapshot()
        model.downloads.useList(["@alice", "#sunset", "https://example.org/carol", "https://www.youtube.com/watch?v=v1"])
        await waitUntil(timeout: 30) { !self.model.downloads.batch.contains { $0.kind == .checking } }
        model.downloads.runAll(window: model, exactParent: batch)
        try? await Task.sleep(for: .seconds(1))
        await waitUntil(timeout: 180) { !self.model.downloads.batchRunning }
        (inside, added) = onlyInside(batch, since: before)
        let allNew = snapshot().subtracting(before)
        let aliceAdded = allNew.filter { $0.hasPrefix("saveas/batch/alice/") && !$0.hasSuffix(".json") }.count
        let tagAdded = allNew.filter { $0.hasPrefix("saveas/batch/#sunset/") && !$0.hasSuffix(".json") }.count
        let carolAdded = allNew.filter { $0.hasPrefix("saveas/batch/carol (testsite)/") && !$0.hasSuffix(".json") }.count
        let videosAdded = allNew.filter { $0.hasPrefix("saveas/batch/X (youtube.com)/") && !$0.hasSuffix(".json") }.count
        check(inside && aliceAdded == 2 && tagAdded == 3 && carolAdded == 4 && videosAdded == 2
            && model.downloads.batch.allSatisfy { $0.progress == .done },
              "Download All As…: alice's 2 missing into her folder, #sunset 3, carol 4 and channel X 2 into folders of their own, "
                  + "inside \(inside) (\(model.downloads.batch.map { "\($0.progress)" }))")
        // The same list again adds nothing and makes no new folder (B26-M1, B26-M2).
        let batchFolders = Set((try? fm.contentsOfDirectory(atPath: batch.path)) ?? [])
        before = snapshot()
        model.downloads.useList(["@alice", "#sunset", "https://example.org/carol", "https://www.youtube.com/watch?v=v1"])
        await waitUntil(timeout: 30) { !self.model.downloads.batch.contains { $0.kind == .checking } }
        model.downloads.runAll(window: model, exactParent: batch)
        try? await Task.sleep(for: .seconds(1))
        await waitUntil(timeout: 180) { !self.model.downloads.batchRunning }
        let againFolders = Set((try? fm.contentsOfDirectory(atPath: batch.path)) ?? [])
        (inside, added) = onlyInside(batch, since: before)
        check(added == 0 && againFolders == batchFolders, "Download All As… again adds nothing and no folder (\(added), "
            + "\(againFolders.subtracting(batchFolders).sorted()))")
        // Save As leaves the account's remembered choices alone (A25-M3).
        let options = await app.store?.account("alice")?.options
        check(options == nil, "Save As kept no remembered choices for alice")
        // Nor any download archive entry: a later Automatic download of the gallery knows nothing of the copies (B24-M4).
        let archived = await app.store?.knownKeys(account: "gallery:testsite:\(galleryURL.absoluteString.lowercased())") ?? []
        check(archived.isEmpty, "Save As wrote no download archive entries (\(archived.count))")
        // A Resume after a check never stops early at what the job saved itself (A25-M1): 14 Reels, held after 13.
        var reels: [[String: Any]] = []
        for index in 1 ... 14 {
            let source = fixtures.appendingPathComponent("reel\(index).jpg")
            try? Self.jpeg(100 + index).write(to: source)
            reels.append(["key": "ig:39\(index)", "source": source.path,
                          "meta": ["category": "instagram", "subcategory": "reels", "username": "alice", "post_id": "40\(index)",
                                   "media_id": "39\(index)", "num": 1, "count": 1, "product_type": "clips",
                                   "date": String(format: "2024-01-%02d 10:00:00", index), "owner_id": "42"]])
        }
        var heldReplay = igReplay
        heldReplay["items"] = reels
        heldReplay["cursor_posts_only"] = true
        heldReplay["checkpoint_after"] = 13
        writeReplay(heldReplay)
        var reelDraft = app.engines.draft(username: "alice")
        reelDraft.content = [.posts, .reels]
        reelDraft.incremental = true
        let resumed = folder("alice reels")
        let stopped = app.engines.startPull(reelDraft, scanOnly: false, window: model, saveFolder: resumed, exactly: true)
        await waitUntil(timeout: 120) { if case .blocked = stopped?.state { true } else { stopped?.state.isFinished ?? true } }
        heldReplay["checkpoint_after"] = nil
        writeReplay(heldReplay)
        app.engines.gate = .ready
        stopped?.resume?()
        try? await Task.sleep(for: .seconds(1))
        await waitFor(stopped)
        let reelFiles = snapshot().filter { $0.hasPrefix("saveas/alice reels/") && !$0.hasSuffix(".json") }.count
        check(reelFiles == 14, "a resumed Save As reaches every Reel, past the 13 it saved itself (\(reelFiles) of 14)")
        // Save As keeps no memory: no account folder record, no remembered item for any folder it saved into.
        let records = await app.accountFolders.all().map { URL(fileURLWithPath: $0.path).lastPathComponent }
        check(records.isEmpty, "Save As made no account folder records (\(records))")
        // Automatic is as before: a pull of alice from the folder above goes to her own folder, never a copy Save As made.
        writeReplay(igReplay)
        before = snapshot()
        let automatic = app.engines.startPull(draft, scanOnly: false, window: model, saveFolder: base)
        await waitFor(automatic)
        (inside, _) = onlyInside(alice, since: before)
        check(inside && automatic?.destination?.standardizedFileURL.path == alice.standardizedFileURL.path,
              "an Automatic pull afterwards goes to alice's own folder (\(automatic?.destination?.lastPathComponent ?? "none"))")

        // The same into a folder MediaPull remembers as alice's: its Resume never stops at what the job saved either (A26-M1).
        let remembered = folder("alice remembered")
        let rememberedRecord = await app.accountFolders.record(account: "alice", folder: remembered)
        heldReplay["checkpoint_after"] = 13
        writeReplay(heldReplay)
        app.engines.gate = .ready
        let stoppedAgain = app.engines.startPull(reelDraft, scanOnly: false, window: model, saveFolder: remembered, exactly: true)
        await waitUntil(timeout: 120) { if case .blocked = stoppedAgain?.state { true } else { stoppedAgain?.state.isFinished ?? true } }
        heldReplay["checkpoint_after"] = nil
        writeReplay(heldReplay)
        app.engines.gate = .ready
        stoppedAgain?.resume?()
        try? await Task.sleep(for: .seconds(1))
        await waitFor(stoppedAgain)
        let rememberedFiles = snapshot().filter { $0.hasPrefix("saveas/alice remembered/") && !$0.hasSuffix(".json") }.count
        let recordKeys = await app.accountFolders.all().first { $0.id == rememberedRecord.id }?.keys.count ?? 0
        check(rememberedFiles == 14 && recordKeys >= 14,
              "a resumed Save As into a remembered folder reaches every Reel and keeps that folder's memory "
                  + "(\(rememberedFiles) of 14, \(recordKeys) remembered)")
        app.engines.gate = .ready

        note("save-as: \(failures.isEmpty ? "PASS" : "FAIL \(failures.count): \(failures.joined(separator: "; "))")")
    }

    /// The scratchpad (D-109): notes added, edited and deleted are written to their file and read back by a new store; a file
    /// that cannot be read is set aside, never written over.
    private func exerciseNotes(out: URL) async {
        let folder = out.appendingPathComponent("notes", isDirectory: true)
        let store = NotesStore(folder: folder)
        await waitUntil(timeout: 10) { store.hasLoaded }
        let kept = store.add()
        store.update(kept.id, text: "Ideas\nsave the gallery")
        let gone = store.add()
        store.update(gone.id, text: "Delete me")
        store.delete(gone.id)
        store.flush()
        let reread = NotesStore(folder: folder)
        await waitUntil(timeout: 10) { reread.notes.notes.count == 1 }
        let readBack = reread.notes.notes.map(\.title) == ["Ideas"] && reread.problem == nil
        try? Data("not json".utf8).write(to: folder.appendingPathComponent("notes.json"))
        let damaged = NotesStore(folder: folder)
        await waitUntil(timeout: 10) { damaged.problem != nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let setAside = names.contains { $0.hasPrefix("notes.damaged-") } && damaged.notes.notes.isEmpty
        let pass = readBack && setAside
        note("notes: \(pass ? "PASS" : "FAIL") read back after quit \(readBack), an unreadable file set aside \(setAside)")
    }

    /// A photo's recorded details and location map in the Preview pane (D-110, R-1009b, R-514): no map until allowed, then a
    /// map, then the map expanded; snapshots of each for a person to look at.
    private func exerciseDetails(library: URL, out: URL) async {
        let app = AppModel.shared
        let photo = library.appendingPathComponent("Eiffel.jpg")
        let image = NSImage(data: Self.jpeg(5)).flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        if let image, let destination = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0 / 120,
                                                 kCGImagePropertyExifISOSpeedRatings: [64], kCGImagePropertyExifFocalLength: 6.86,
                                                 kCGImagePropertyExifDateTimeOriginal: "2024:06:01 18:30:05"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"],
            ] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        let savedMaps = app.preferences.showMaps
        defer { app.preferences.showMaps = savedMaps }
        app.preferences.showMaps = false
        model.setShowing(.preview, true)
        model.showInPreview(.file(photo))
        let recorded = await RecordedDetails.read(photo)
        let rows = recorded.sections.flatMap(\.rows).map(\.0) + recorded.locationRows.map(\.0)
        let wanted = ["Model", "Focal length", "Aperture", "Shutter", "ISO", "Taken", "Coordinates", "Near"]
        let missing = wanted.filter { !rows.contains($0) }
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(to: out.appendingPathComponent("details-no-map.png"))
        // The map loads images from Apple, so only when asked for (check.sh runs this offline).
        if CommandLine.arguments.contains("--selftest-map") {
            app.preferences.showMaps = true
            try? await Task.sleep(for: .seconds(4))
            snapshot(to: out.appendingPathComponent("details-map.png"))
        }
        let near = recorded.locationRows.first { $0.0 == "Near" }?.1 ?? "none"
        note("details: \(missing.isEmpty ? "PASS" : "FAIL missing \(missing)") rows \(rows), near \(near)")
    }

    /// Devices (section 41), offline: a folder stands in for an iPhone and a simulated MTP phone for an Android one. Browses
    /// both, imports with Live Photo clips, runs Import New again (nothing new), and checks names, dates, originals kept byte
    /// for byte, the device left as it was, only read operations sent and no sockets opened.
    private func exerciseDevices(out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("devices: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let phone = out.appendingPathComponent("iPhone", isDirectory: true)
        let camera = phone.appendingPathComponent("DCIM/100APPLE", isDirectory: true)
        try? fm.createDirectory(at: camera, withIntermediateDirectories: true)
        let taken = Date(timeIntervalSince1970: 1_717_266_605)
        if let image = NSImage(data: Self.jpeg(4)).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
           let heic = CGImageDestinationCreateWithURL(camera.appendingPathComponent("IMG_0001.HEIC") as CFURL,
                                                      "public.heic" as CFString, 1, nil)
        {
            CGImageDestinationAddImage(heic, image, nil)
            CGImageDestinationFinalize(heic)
        }
        try? await Self.writeTestClip(to: camera.appendingPathComponent("IMG_0001.MOV"))
        try? Self.jpeg(6).write(to: camera.appendingPathComponent("IMG_0002.JPG"))
        try? await Self.writeTestClip(to: camera.appendingPathComponent("IMG_0003.MOV"), seed: 3)
        try? Data("<plist/>".utf8).write(to: camera.appendingPathComponent("IMG_0002.AAE"))
        for name in (try? fm.contentsOfDirectory(atPath: camera.path)) ?? [] {
            try? fm.setAttributes([.modificationDate: taken], ofItemAtPath: camera.appendingPathComponent(name).path)
        }
        func checksums(_ folder: URL) -> [String: String] {
            var sums: [String: String] = [:]
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                sums[name] = try? FileHasher.sha256(of: folder.appendingPathComponent(name))
            }
            return sums
        }
        let before = checksums(camera)

        let simulator = MTPResponderSimulator(serial: "SELFTEST-PIXEL")
        let dcim = await simulator.add("DCIM")
        let pixelCamera = await simulator.add("Camera", in: dcim)
        await simulator.add("PXL_20240601_183005.jpg", in: pixelCamera, data: Self.jpeg(8), captured: taken)
        await simulator.add("Download")
        let session = MTPSession(transport: simulator)
        let info = try? await session.open()
        let pixelIdentity = DeviceIdentity(name: "Pixel", serial: info?.serial, vendorID: 0x18D1, productID: 0x4EE1)
        let pixel = MTPSource(identity: pixelIdentity, session: session)
        let iphone = FolderDeviceSource(root: phone, identity: DeviceIdentity(name: "iPhone", serial: "SELFTEST-IPHONE", vendorID: 0x05AC,
                                                                                productID: 0x12A8))
        let destination = out.appendingPathComponent("Imported", isDirectory: true)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let savedFolder = app.preferences.deviceImportFolder, savedClips = app.preferences.includeLivePhotoClips
        defer {
            app.preferences.deviceImportFolder = savedFolder
            app.preferences.includeLivePhotoClips = savedClips
        }
        app.preferences.deviceImportFolder = destination.path
        app.preferences.includeLivePhotoClips = true
        let socketsBefore = Self.socketCount()

        app.deviceCenter.standIns = [
            ConnectedDevice(id: "iphone", name: "iPhone", symbol: "iphone", isApple: true, state: .ready(iphone)),
            ConnectedDevice(id: "pixel", name: "Pixel", symbol: "smartphone", isApple: false, state: .ready(pixel)),
        ]
        let devices = model.devices
        model.section = .devices
        await waitUntil(timeout: 30) { devices.deviceID == "iphone" && !devices.loading && !devices.entries.isEmpty }
        check(devices.entries.map(\.name) == ["DCIM"], "the iPhone opens at its top folder (\(devices.entries.map(\.name)))")
        if let folder = devices.entries.first { devices.open(folder) }
        await waitUntil(timeout: 30) { !devices.loading && devices.entries.first?.name == "100APPLE" }
        if let folder = devices.entries.first { devices.open(folder) }
        await waitUntil(timeout: 30) { !devices.loading && devices.media.count == 4 }
        check(devices.media.map(\.name).sorted() == ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0002.JPG", "IMG_0003.MOV"],
              "only photos and videos are listed (\(devices.media.map(\.name)))")
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(to: out.appendingPathComponent("devices.png"))

        devices.importNew()
        await waitUntil(timeout: 60) { devices.importJob?.state.isFinished == true }
        let names = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
        check(names == ["IMG_0001.HEIC", "IMG_0001.MOV", "IMG_0002.JPG", "IMG_0003.MOV"],
              "imported under the device's names (\(names.sorted()))")
        let copied = checksums(destination)
        check(["IMG_0001.HEIC", "IMG_0002.JPG", "IMG_0001.MOV"].allSatisfy { copied[$0] != nil && copied[$0] == before[$0] },
              "originals kept byte for byte, HEIC included")
        let date = (try? fm.attributesOfItem(atPath: destination.appendingPathComponent("IMG_0002.JPG").path))?[.modificationDate] as? Date
        check(date == taken, "dated when taken")
        check(!names.contains { $0.hasSuffix(".json") }, "no metadata files (D-117)")
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("devices-imported.png"))

        let firstJob = devices.importJob
        devices.importNew()
        await waitUntil(timeout: 60) { devices.importJob !== firstJob && devices.importJob?.state.isFinished == true }
        check(devices.importJob?.saved == 0 && (try? fm.contentsOfDirectory(atPath: destination.path).count) == 4,
              "Import New again brings nothing (\(devices.importJob?.saved ?? -1) imported)")
        check(checksums(camera) == before, "the device is left exactly as it was")

        devices.deviceID = "pixel"
        await waitUntil(timeout: 30) { !devices.loading && devices.entries.map(\.name) == ["DCIM", "Download"] }
        check(devices.entries.map(\.name) == ["DCIM", "Download"], "the Android phone shows its whole storage")
        let secondJob = devices.importJob
        devices.importNew()
        await waitUntil(timeout: 60) { devices.importJob !== secondJob && devices.importJob?.state.isFinished == true }
        check(fm.fileExists(atPath: destination.appendingPathComponent("PXL_20240601_183005.jpg").path),
              "Import New from the top of the phone finds the camera folder's photo")
        let received = await simulator.received
        check(Set(received).isSubset(of: MTPOperation.allowedCodes), "only read operations reached the phone")
        check(Self.socketCount() <= socketsBefore, "no sockets opened")
        app.deviceCenter.standIns = []
        model.section = .collect
        note("devices: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Drives (section 43) on a real exFAT disk image that check.sh attaches: listed by itself, a camera card in Devices
    /// whose Import New brings a RAW+JPEG pair and then nothing, a pair moved on the card and put back, and Eject.
    private func exerciseDrives(mount: URL, out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("drives: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let camera = mount.appendingPathComponent("DCIM/100CANON", isDirectory: true)
        try? fm.createDirectory(at: camera, withIntermediateDirectories: true)
        for (name, type, colour) in [("IMG_0001.CR3", UTType.tiff, 1), ("IMG_0001.JPG", .jpeg, 1), ("IMG_0002.JPG", .jpeg, 2)] {
            guard let image = NSImage(data: Self.jpeg(colour)).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
                  let destination = CGImageDestinationCreateWithURL(camera.appendingPathComponent(name) as CFURL,
                                                                     type.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        app.driveCenter.refresh()
        let mountPath = mount.standardizedFileURL.path
        await waitUntil(timeout: 20) { app.driveCenter.drives.contains { $0.url.standardizedFileURL.path == mountPath && $0.isCameraCard } }
        let drive = app.driveCenter.drives.first { $0.url.standardizedFileURL.path == mountPath }
        check(drive != nil && drive?.uuid != nil, "the card is listed by itself, with its UUID (\(app.driveCenter.drives.map(\.name)))")
        check(drive?.isCameraCard == true, "a DCIM folder makes it a camera card")

        // Import New from the card, in Devices.
        let destination = out.appendingPathComponent("Imported", isDirectory: true)
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let savedFolder = app.preferences.deviceImportFolder
        defer { app.preferences.deviceImportFolder = savedFolder }
        app.preferences.deviceImportFolder = destination.path
        let devices = model.devices
        model.section = .devices
        let cardID = "volume:\(drive?.id ?? "")"
        await waitUntil(timeout: 20) { app.deviceCenter.devices.contains { $0.id == cardID } }
        devices.deviceID = cardID
        await waitUntil(timeout: 20) { !devices.loading && !devices.entries.isEmpty }
        let first = devices.importJob
        devices.importNew()
        await waitUntil(timeout: 60) { devices.importJob !== first && devices.importJob?.state.isFinished == true }
        let imported = Set((try? fm.contentsOfDirectory(atPath: destination.path)) ?? [])
        check(imported == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.JPG"], "Import New copied the card (\(imported.sorted()))")
        let second = devices.importJob
        devices.importNew()
        await waitUntil(timeout: 60) { devices.importJob !== second && devices.importJob?.state.isFinished == true }
        check(devices.importJob?.saved == 0, "Import New again brings nothing")

        // On the card itself: the pair moves as one and Undo puts it back.
        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        let organise = model.organise
        organise.open(camera)
        await waitUntil(timeout: 30) { !organise.source.loading && organise.source.entries.count == 2 }
        let sorted = camera.appendingPathComponent("Sorted", isDirectory: true)
        try? fm.createDirectory(at: sorted, withIntermediateDirectories: true)
        let changes = organise.history.count
        organise.run(FolderOperations.move([camera.appendingPathComponent("IMG_0001.CR3")], to: sorted))
        await waitUntil(timeout: 30) { organise.history.count > changes && organise.working == nil }
        let moved = Set((try? fm.contentsOfDirectory(atPath: sorted.path)) ?? [])
        check(moved == ["IMG_0001.CR3", "IMG_0001.JPG"], "the pair moved on the exFAT card (\(moved.sorted()))")
        if let entry = organise.history.first { organise.undo(entry) }
        await waitUntil(timeout: 30) {
            organise.working == nil && fm.fileExists(atPath: camera.appendingPathComponent("IMG_0001.JPG").path)
        }
        check(fm.fileExists(atPath: camera.appendingPathComponent("IMG_0001.CR3").path)
              && fm.fileExists(atPath: camera.appendingPathComponent("IMG_0001.JPG").path), "Undo on the card put the pair back")

        // A rating written into a JPEG on the card: exFAT cannot swap names, so the hidden-name path runs (R-4503).
        let onCard = organise.source.entries.first { $0.name == "IMG_0002.JPG" }?.url ?? camera.appendingPathComponent("IMG_0002.JPG")
        let before = out.appendingPathComponent("IMG_0002-before.JPG")
        try? fm.copyItem(at: onCard, to: before)
        let edits = organise.history.count
        model.editMetadata([onCard], .rating(3))
        await waitUntil(timeout: 30) { organise.history.count > edits }
        check(MetadataWriter.values(of: onCard).rating == 3 && MetadataWriter.samePicture(before, onCard),
              "a rating is written into a photo on the exFAT card, its picture unchanged")
        check(((try? fm.contentsOfDirectory(atPath: camera.path)) ?? []).allSatisfy { !$0.hasPrefix(".mediapull-edit-") },
              "nothing hidden is left on the card")
        if let entry = organise.history.first(where: { !$0.undone }) {
            organise.undo(entry)
            await waitUntil(timeout: 30) { organise.history.first { $0.id == entry.id }?.undone == true }
        }
        check(MetadataWriter.values(of: onCard).rating == nil, "⌘Z takes the rating back on the card")

        // Eject: the card goes, and the pane says so.
        if let drive { app.driveCenter.eject(drive) }
        await waitUntil(timeout: 30) { !app.driveCenter.drives.contains { $0.url.standardizedFileURL.path == mountPath } }
        check(!fm.fileExists(atPath: camera.path), "Eject unmounted the card")
        check(app.driveCenter.isOnMissingDrive(camera), "the pane knows its drive was ejected")
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("drive-ejected.png"))
        model.section = .collect
        note("drives: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Formats, units and posts (section 42), offline: a RAW+JPEG pair, a Live Photo, a Fujifilm `.hif`, tagged audio and an
    /// Instagram post in a folder opened in Organise. Units list once with their badge and move as one; a HEIC dropped into
    /// an Archive library folder stays HEIC; audio gets its tags; a sort keeps the post together.
    private func exerciseFormats(library: URL, out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("formats: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let folder = out.appendingPathComponent("Camera roll", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func picture(_ name: String, type: UTType, colour: Int, date: String? = nil) {
            guard let image = NSImage(data: Self.jpeg(colour)).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
                  let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                                     type.identifier as CFString,
                                                                     1, nil) else { return }
            var properties: [CFString: Any] = [:]
            if let date { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        // A DNG is a TIFF inside, which is what the system reads for this test.
        picture("DSC_1.DNG", type: .tiff, colour: 1)
        picture("DSC_1.JPG", type: .jpeg, colour: 1)
        try? Data("<x:xmpmeta/>".utf8).write(to: folder.appendingPathComponent("DSC_1.xmp"))
        picture("IMG_2.HEIC", type: .heic, colour: 2)
        try? await Self.writeTestClip(to: folder.appendingPathComponent("IMG_2.MOV"))
        picture("DSCF3.hif", type: .heic, colour: 3)
        picture("photo.heic", type: .heic, colour: 4)
        await Self.writeTaggedSong(to: folder.appendingPathComponent("song.m4a"), work: out)
        // A post of three pictures taken in three months, saved with metadata files.
        let account = folder.appendingPathComponent("someone", isDirectory: true)
        try? fm.createDirectory(at: account, withIntermediateDirectories: true)
        for (number, month) in [(1, "01"), (2, "05"), (3, "09")] {
            let name = "2024-01-01_120000_POST_0\(number).jpg"
            let url = account.appendingPathComponent(name)
            guard let image = NSImage(data: Self.jpeg(10 + number)).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:\(month):10 10:00:00",
            ]] as CFDictionary)
            CGImageDestinationFinalize(destination)
            let meta: [String: Any] = ["category": "instagram", "subcategory": "posts", "username": "someone", "post_id": "999",
                                       "post_shortcode": "POST", "num": number, "count": 3, "date": "2024-01-01 12:00:00"]
            try? JSONSerialization.data(withJSONObject: meta).write(to: Sidecar.sidecarURL(for: url))
        }

        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        let organise = model.organise, pane = organise.source
        organise.open(folder)
        await waitUntil(timeout: 60) { !pane.loading && !pane.filtering && pane.entries.count >= 5 }
        let names = pane.entries.map(\.name).sorted()
        check(names == ["DSCF3.hif", "DSC_1.DNG", "IMG_2.HEIC", "photo.heic", "song.m4a"],
              "units list once, .hif and audio are listed (\(names))")
        let byName = Dictionary(pane.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        check(byName["DSC_1.DNG"]?.unit == .rawPair && byName["IMG_2.HEIC"]?.unit == .live, "RAW+JPEG and LIVE badges")
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("formats.png"))

        // The pair moves as one, and Undo brings every file back.
        let into = folder.appendingPathComponent("Sorted", isDirectory: true)
        try? fm.createDirectory(at: into, withIntermediateDirectories: true)
        let changes = organise.history.count
        organise.run(FolderOperations.move([folder.appendingPathComponent("DSC_1.DNG")], to: into))
        await waitUntil(timeout: 30) { organise.history.count > changes && organise.working == nil }
        let moved = Set((try? fm.contentsOfDirectory(atPath: into.path)) ?? [])
        check(moved == ["DSC_1.DNG", "DSC_1.JPG", "DSC_1.xmp"], "the pair moved with its edit file (\(moved.sorted()))")
        if let entry = organise.history.first { organise.undo(entry) }
        await waitUntil(timeout: 30) { organise.working == nil && fm.fileExists(atPath: folder.appendingPathComponent("DSC_1.JPG").path) }
        check(["DSC_1.DNG", "DSC_1.JPG", "DSC_1.xmp"].allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) },
              "Undo put the whole pair back")

        // A HEIC dropped into an Archive library folder keeps its format (D-121).
        model.library.importFiles([folder.appendingPathComponent("photo.heic")], into: library, move: false)
        await waitUntil(timeout: 30) { fm.fileExists(atPath: library.appendingPathComponent("photo.heic").path) }
        check(fm.fileExists(atPath: library.appendingPathComponent("photo.heic").path)
              && !fm.fileExists(atPath: library.appendingPathComponent("photo.jpg").path), "a HEIC copied into the library stays HEIC")

        // Audio tags come from analysis; the post stays together in a sort by date. The move showed its destination: back.
        pane.folder = pane.root
        await waitUntil(timeout: 30) { !pane.loading && !pane.filtering && pane.entries.count >= 5 }
        app.analysis.schedule(after: .milliseconds(100))
        await waitUntil(timeout: 120) {
            pane.entries.first { $0.name == "song.m4a" }?.facts?.audio?.title != nil
        }
        let song = pane.entries.first { $0.name == "song.m4a" }
        check(song?.facts?.audio?.title == "Test Song" && song?.facts?.audio?.artist == "Test Artist" && (song?.facts?.duration ?? 0) > 0,
              "audio tags and length (\(song?.facts?.audio?.title ?? "none"), \(song?.facts?.duration ?? 0) s)")
        organise.open(account)
        await waitUntil(timeout: 120) {
            !pane.loading && !pane.filtering && pane.entries.count == 3 && pane.entries.allSatisfy { $0.facts?.captureDate != nil }
        }
        let saved = app.preferences.sortPostImagesIndividually
        defer { app.preferences.sortPostImagesIndividually = saved }
        app.preferences.sortPostImagesIndividually = false
        organise.pending = nil
        organise.autoSort(.date)
        await waitUntil(timeout: 60) { organise.pending != nil }
        let folders = Set(organise.pending?.plan.moves.map { $0.destination.deletingLastPathComponent().lastPathComponent } ?? [])
        check(folders == ["2024-01"], "the post stays in its first picture's month (\(folders.sorted()))")
        organise.pending = nil
        model.section = .collect
        note("formats: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Metadata edits (section 45), offline: a rating written into a HEIC with its picture unchanged and its analysis kept,
    /// a keyword in a RAW pair's `.xmp` shown over the files, a date shift, the Rating filter, and ⌘Z taking each back.
    private func exerciseEdits(out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("edits: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let folder = out.appendingPathComponent("Edits", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func picture(_ name: String, type: UTType, colour: Int) {
            guard let image = NSImage(data: Self.jpeg(colour)).flatMap({ $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }),
                  let destination = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL,
                                                                     type.identifier as CFString, 1, nil) else { return }
            let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                                         kCGImagePropertyExifOffsetTimeOriginal: "+01:00"]
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        picture("IMG_1.HEIC", type: .heic, colour: 1)
        picture("DSC_2.NEF", type: .tiff, colour: 2)
        picture("DSC_2.JPG", type: .jpeg, colour: 2)
        let made = folder.appendingPathComponent("IMG_1.HEIC")
        let original = out.appendingPathComponent("IMG_1-original.HEIC")
        try? fm.copyItem(at: made, to: original)
        let jpegBytes = try? Data(contentsOf: folder.appendingPathComponent("DSC_2.JPG"))

        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        let organise = model.organise, pane = organise.source
        organise.open(folder)
        await waitUntil(timeout: 60) { !pane.loading && !pane.filtering && pane.entries.count == 2 }
        app.analysis.schedule(after: .milliseconds(100))
        await waitUntil(timeout: 120) { pane.entries.allSatisfy { $0.record != nil } }
        func entry(_ name: String) -> MediaEntry? { pane.entries.first { $0.name == name } }
        // As the panes give them (a temporary folder is under /var, which is /private/var), as the person chooses them.
        let heic = entry("IMG_1.HEIC")?.url ?? made
        let raw = entry("DSC_2.NEF")?.url ?? folder.appendingPathComponent("DSC_2.NEF")
        let shaBefore = (try? FileHasher.sha256(of: heic)) ?? ""
        let analysedAt = await app.analysis.store?.record(sha256: shaBefore)?.analysedAt
        check(analysedAt != nil, "the photo was analysed first")

        func edit(_ files: [URL], _ change: MetadataEdit, until condition: @escaping () -> Bool) async {
            let before = organise.history.count
            model.editMetadata(files, change)
            await waitUntil(timeout: 60) { organise.history.count > before }
            await waitUntil(timeout: 60) { !pane.loading && !pane.filtering && condition() }
        }

        await edit([heic], .rating(4)) { entry("IMG_1.HEIC")?.facts?.rating == 4 }
        check(MetadataWriter.values(of: heic).rating == 4, "the rating is in the HEIC itself")
        check(MetadataWriter.samePicture(original, heic), "its picture is unchanged")
        let shaAfter = (try? FileHasher.sha256(of: heic)) ?? ""
        let carried = await app.analysis.store?.record(sha256: shaAfter)
        check(shaAfter != shaBefore && carried?.analysedAt == analysedAt, "its analysis followed it without running again")
        check(entry("IMG_1.HEIC")?.facts?.rating == 4, "the pane shows its stars")
        check(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).allSatisfy { !$0.hasPrefix(".mediapull-edit-") },
              "nothing hidden is left beside it")

        await edit([raw], .keywords(add: ["birds"], remove: [])) { entry("DSC_2.NEF")?.facts?.keywords == ["birds"] }
        let xmp = folder.appendingPathComponent("DSC_2.xmp")
        check(MetadataWriter.values(ofXMPAt: xmp)?.keywords == ["birds"], "the RAW pair's keyword is in its .xmp")
        check((try? Data(contentsOf: folder.appendingPathComponent("DSC_2.JPG"))) == jpegBytes, "the pair's JPEG is untouched")
        check(entry("DSC_2.NEF")?.facts?.keywords == ["birds"], "the pane shows the .xmp's keyword over the files")

        let takenBefore = entry("IMG_1.HEIC")?.facts?.captureDate
        await edit([heic], .shiftDate(seconds: 3600)) {
            entry("IMG_1.HEIC")?.facts?.captureDate != takenBefore
        }
        let takenAfter = entry("IMG_1.HEIC")?.facts?.captureDate
        check(takenBefore.flatMap { before in takenAfter.map { $0.timeIntervalSince(before) == 3600 } } == true,
              "the date moved by an hour (\(String(describing: takenAfter)))")

        pane.query.filter.minRating = 4
        await waitUntil(timeout: 30) { !pane.filtering && pane.shown.count == 1 }
        check(pane.shown.map(\.name) == ["IMG_1.HEIC"], "the Rating filter keeps the rated photo (\(pane.shown.map(\.name)))")
        pane.query.filter.minRating = nil

        // ⌘Z, newest first: date, keyword, rating.
        for _ in 0 ..< 3 {
            guard let last = organise.history.first(where: { !$0.undone }) else { break }
            organise.undo(last)
            await waitUntil(timeout: 60) { organise.working == nil && organise.history.first { $0.id == last.id }?.undone == true }
        }
        let back = MetadataWriter.values(of: heic)
        check(back.rating == nil && back.taken?.original == "2020:01:02 03:04:05", "Undo wrote the old rating and date back")
        check(!fm.fileExists(atPath: xmp.path), "Undo sent the .xmp it made to the Trash")
        check(MetadataWriter.samePicture(original, heic), "the picture is still the same")
        await waitUntil(timeout: 60) { entry("IMG_1.HEIC")?.facts?.rating == nil && entry("DSC_2.NEF")?.facts?.keywords == nil }
        check(entry("IMG_1.HEIC")?.record?.analysedAt == analysedAt, "the analysis is still the first one")
        model.section = .collect
        note("edits: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Edit/Frame for photos (section 46), offline: adjustments, a look, the Poster template with three fonts, export at a
    /// social size, the original untouched, the recipe kept and reopened, Revert and ⌘Z.
    private func exerciseEditPhoto(out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("edit-photo: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let folder = out.appendingPathComponent("Framing", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // An 800 × 600 photo: a blue-green gradient, with a date and a place.
        let photo = folder.appendingPathComponent("street.jpg")
        if let context = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        {
            for y in 0 ..< 600 {
                context.setFillColor(red: 0.1, green: 0.2 + CGFloat(y) / 1500, blue: 0.4 + CGFloat(y) / 1200, alpha: 1)
                context.fill(CGRect(x: 0, y: y, width: 800, height: 1))
            }
            if let image = context.makeImage(),
               let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            {
                CGImageDestinationAddImage(destination, image, [
                    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:12:22 21:00:00"],
                    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.9, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 77.0, kCGImagePropertyGPSLongitudeRef: "W"],
                ] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
        }
        let original = (try? FileHasher.sha256(of: photo)) ?? ""
        let edit = model.edit
        model.openInEdit([photo])
        await waitUntil(timeout: 30) { edit.session != nil && edit.preview != nil }
        check(model.section == .edit && edit.preview != nil, "the photo opened on the canvas")
        check(edit.entries.contains { $0.name == "street.jpg" }, "the Media pane lists its folder")

        edit.change { recipe in
            recipe.adjust.exposure = 0.4
            recipe.adjust.contrast = 15
            recipe.look = Look(name: .film, amount: 0.6)
            EditTemplate.poster.apply(to: &recipe)
            for index in recipe.layers.indices {
                guard case var .text(style) = recipe.layers[index].kind else { continue }
                if style.text == "The Title" { style.text = "The Post" }
                if style.text.hasPrefix("First Name") { style.text = "Streep\nHanks" }
                recipe.layers[index].kind = .text(style)
            }
        }
        await waitUntil(timeout: 20) { edit.missingFonts.isEmpty && edit.preview != nil }
        let fonts = Set((edit.recipe?.layers ?? []).compactMap { layer -> String? in
            if case let .text(style) = layer.kind { return style.family }
            return nil
        })
        check(fonts.count >= 2 && edit.missingFonts.isEmpty, "the Poster template's fonts are on this Mac (\(fonts.sorted()))")
        edit.tab = .text
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("edit-frame.png"))

        // Kept as a recipe, in Application Support only.
        await waitUntil(timeout: 10) { edit.editedPaths.contains(photo.standardizedFileURL.path) }
        let stored = await app.recipes.recipe(for: photo)
        check(stored?.layers.count == 5 && stored?.look?.name == .film, "the recipe is kept as it was made")
        check(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []) == ["street.jpg"], "nothing is written beside the photo")
        // Another window saved newer edits of this photo: leaving the section or quitting here writes nothing over them,
        // since this window has no change of its own unsaved (B3-6).
        if let stored {
            var newer = stored
            newer.adjust.contrast = 77
            await app.recipes.save(newer)
            edit.leftSection()
            edit.saveBeforeQuit()
            try? await Task.sleep(for: .milliseconds(300))
            let kept = await app.recipes.recipe(for: photo)
            check(kept?.adjust.contrast == 77, "leaving or quitting writes only this window's own changes")
            await app.recipes.save(stored)
        }

        // Export for a post: 4:5 at most, a 2:3 poster inside it.
        edit.change { $0.export.size = .post45 }
        edit.export()
        let exported = folder.appendingPathComponent("street-edited.jpg")
        await waitUntil(timeout: 60) { !edit.exporting && fm.fileExists(atPath: exported.path) }
        check(fm.fileExists(atPath: exported.path), "Export wrote street-edited.jpg")
        check((try? FileHasher.sha256(of: photo)) == original, "the original is unchanged")
        if let source = CGImageSourceCreateWithURL(exported as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        {
            check(image.width <= 1080 && image.height <= 1350 && abs(Double(image.width) / Double(image.height) - 2.0 / 3) < 0.01,
                  "the export fits a post and keeps the poster's shape (\(image.width) × \(image.height))")
            let corner = Self.colour(image, x: 3, y: 3)
            check(corner.r > 240 && corner.g > 240 && corner.b > 240, "the border is white (\(corner))")
            // Dark ink of the date and credits in the bottom border, white title text over the photo.
            var dark = 0
            for x in stride(from: image.width / 2, to: image.width - 8, by: 2) {
                for y in stride(from: Int(Double(image.height) * 0.8), to: Int(Double(image.height) * 0.86), by: 2)
                    where Self.colour(image, x: x, y: y).r < 90
                {
                    dark += 1
                }
            }
            check(dark > 15, "the script date is drawn in the border (\(dark) dark points)")
            var light = 0
            for x in stride(from: Int(Double(image.width) * 0.06), to: Int(Double(image.width) * 0.6), by: 2) {
                for y in stride(from: Int(Double(image.height) * 0.66), to: Int(Double(image.height) * 0.73), by: 2) {
                    let pixel = Self.colour(image, x: x, y: y)
                    if pixel.r > 220, pixel.g > 220 { light += 1 }
                }
            }
            check(light > 40, "the white title is drawn over the photo (\(light) light points)")
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            check(properties?[kCGImagePropertyGPSDictionary] != nil, "the location is kept, as set")
        } else {
            check(false, "the export can be read")
        }

        // Reopened: the same recipe.
        edit.load(exported)
        await waitUntil(timeout: 20) { edit.session != nil && edit.current == exported }
        edit.load(photo)
        await waitUntil(timeout: 20) { edit.session != nil && edit.current == photo && edit.recipe != nil }
        check(edit.recipe?.layers.count == 5 && edit.recipe?.adjust.exposure == 0.4, "reopening the photo brings its recipe back")

        // Revert, then ⌘Z.
        // In use each change is its own event (a click, a drag), which closes its undo group. A self-test has no events,
        // so it gives the model an undo manager of its own and makes Revert a group of its own, as a click would.
        let manager = UndoManager()
        manager.groupsByEvent = false
        edit.testUndoManager = manager
        manager.beginUndoGrouping()
        edit.revert()
        manager.endUndoGrouping()
        check(edit.recipe?.isEdited == false, "Revert clears the edits")
        manager.undo()
        edit.testUndoManager = nil
        check(edit.recipe?.layers.count == 5, "⌘Z brings them back")

        // Copy the settings, paste them onto a second photo, then export both at once (R-4611).
        let second = folder.appendingPathComponent("second.jpg")
        try? fm.copyItem(at: photo, to: second)
        edit.reloadFolder()
        await waitUntil(timeout: 20) { edit.entries.contains { $0.name == "second.jpg" } }
        edit.copySettings()
        edit.pasteSettings(Set(SettingGroup.allCases), to: [second])
        await waitUntil(timeout: 20) { edit.editedPaths.contains(second.standardizedFileURL.path) }
        let pasted = await AppModel.shared.recipes.recipe(for: second)
        check(pasted?.layers.count == 5 && pasted?.look?.name == .film && pasted?.frame?.shape == .portrait23,
              "Paste Settings carries the look, frame and text to another photo")
        let exportedBefore = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        // As the Media pane lists them (a temporary folder is under /var, which is /private/var), as a click selects them.
        edit.selection = Set(edit.entries.filter { ["street.jpg", "second.jpg"].contains($0.name) }.map(\.path))
        edit.exportSelected()
        await waitUntil(timeout: 60) {
            !edit.exporting && Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).count >= exportedBefore.count + 2
        }
        let added = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(exportedBefore)
        check(added.count == 2 && added.contains("second-edited.jpg"), "Export Selected wrote both (\(added.sorted()))")

        // Renamed by MediaPull while open: the recipe follows, and later edits are saved under the new name (audit B1-2).
        edit.load(photo)
        await waitUntil(timeout: 20) { edit.current == photo && edit.recipe?.layers.count == 5 }
        if let open = edit.current {
            let renamed = open.deletingLastPathComponent().appendingPathComponent("renamed.jpg")
            _ = await AppModel.shared.applyChange(FolderOperations.rename(open, to: "renamed.jpg"))
            check(edit.current?.lastPathComponent == "renamed.jpg", "the open photo follows its new name")
            edit.change { $0.adjust.exposure = 0.9 }
            edit.flushSave()
            try? await Task.sleep(for: .milliseconds(500))
            let followed = await AppModel.shared.recipes.recipe(for: renamed)
            check(followed?.adjust.exposure == 0.9 && followed?.layers.count == 5, "later edits are kept under the new name")

            // Revert Edits of two files is one change ⌘Z takes back (audit B1-3).
            let manager = UndoManager()
            manager.groupsByEvent = false
            edit.testUndoManager = manager
            manager.beginUndoGrouping()
            edit.revert([renamed, second])
            await waitUntil(timeout: 10) { edit.recipe?.isEdited == false }
            try? await Task.sleep(for: .milliseconds(300))
            manager.endUndoGrouping()
            let gone = await AppModel.shared.recipes.recipe(for: second)
            check((gone?.isEdited ?? false) == false && edit.recipe?.isEdited == false, "Revert Edits of two files clears both recipes")
            manager.undo()
            try? await Task.sleep(for: .milliseconds(800))
            let back = await AppModel.shared.recipes.recipe(for: second)
            check(back?.layers.count == 5 && edit.recipe?.layers.count == 5, "⌘Z brings both back")
            edit.testUndoManager = nil
        }
        // The Frame tab stays up when the frame is taken away while it is shown (audit B2-1).
        edit.tab = .frame
        try? await Task.sleep(for: .milliseconds(500))
        edit.change { $0.frame = nil }
        try? await Task.sleep(for: .milliseconds(800))
        edit.change { EditTemplate.centredTitle.apply(to: &$0) }
        try? await Task.sleep(for: .milliseconds(500))
        check(edit.recipe?.frame == nil, "the Frame tab survives its frame being removed")
        model.section = .collect
        note("edit-photo: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Edit/Frame for videos (section 46, R-4609), offline: a cut and a turn written without re-encoding, then a look, the
    /// Poster frame, speed and a fade rendered into HEVC, a frame saved, the original untouched.
    private func exerciseEditVideo(out: URL) async {
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("edit-video: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        let folder = out.appendingPathComponent("Clips", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appendingPathComponent("clip.mp4")
        try? await Self.writeTestClip(to: clip)
        let original = (try? FileHasher.sha256(of: clip)) ?? ""
        let edit = model.edit
        model.openInEdit([clip])
        await waitUntil(timeout: 30) { edit.session != nil && edit.mediaDuration > 0 }
        check(edit.kind == .video && edit.tab == .trim && edit.mediaDuration > 3.9,
              "the video opened on the Trim tab (\(edit.mediaDuration) s)")

        // Cut to 1 s – 3 s and turned: no re-encoding.
        edit.player.seek(1)
        edit.trimStart(at: 1)
        edit.trimEnd(at: 3)
        edit.change { $0.geometry.quarterTurns = 1 }
        check(edit.keptRanges == [TimeRange(start: 1, end: 3)], "the cut keeps 1 s to 3 s (\(edit.keptRanges))")
        func exportAndWait(_ name: String) async -> URL {
            let url = folder.appendingPathComponent(name)
            edit.export()
            await waitUntil(timeout: 120) { !edit.exporting && fm.fileExists(atPath: url.path) }
            await waitUntil(timeout: 10) { !edit.exporting }
            return url
        }
        let cut = await exportAndWait("clip-edited.mp4")
        let cutAsset = AVURLAsset(url: cut)
        let cutDuration = (try? await cutAsset.load(.duration).seconds) ?? 0
        let cutTrack = try? await cutAsset.loadTracks(withMediaType: .video).first
        let codec = try? await cutTrack?.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        let natural = (try? await cutTrack?.load(.naturalSize)) ?? .zero
        let transform = (try? await cutTrack?.load(.preferredTransform)) ?? .identity
        let shown = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        check(abs(cutDuration - 2) < 0.1, "the cut is 2 s long (\(cutDuration))")
        check(codec == kCMVideoCodecType_H264, "the cut is not re-encoded (still H.264)")
        check(shown.width < shown.height, "the cut is turned upright (\(shown))")

        // A look, the Poster frame, twice the speed and a fade: rendered.
        edit.change { recipe in
            recipe.look = Look(name: .noir)
            EditTemplate.poster.apply(to: &recipe)
            recipe.timeline?.speed = 2
            recipe.timeline?.fadeIn = 0.3
            recipe.export.size = .post45
        }
        let rendered = await exportAndWait("clip-edited 2.mp4")
        let renderedAsset = AVURLAsset(url: rendered)
        let renderedDuration = (try? await renderedAsset.load(.duration).seconds) ?? 0
        let renderedTrack = try? await renderedAsset.loadTracks(withMediaType: .video).first
        let renderedCodec = try? await renderedTrack?.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        let size = (try? await renderedTrack?.load(.naturalSize)) ?? .zero
        check(abs(renderedDuration - 1) < 0.15, "twice as fast: 1 s (\(renderedDuration))")
        check(renderedCodec == kCMVideoCodecType_HEVC, "rendered as HEVC")
        check(size.height <= 1350 && abs(size.width / max(size.height, 1) - 2.0 / 3) < 0.02, "the poster's 2:3 shape (\(size))")
        if let frame = await VideoComposer.frame(rendered, at: 0.6) {
            let corner = Self.colour(frame, x: 2, y: 2)
            check(corner.r > 220 && corner.g > 220, "the white border is drawn on the video (\(corner))")
        } else {
            check(false, "a frame of the rendered video can be read")
        }

        // A frame saved as a PNG; the original untouched.
        edit.tab = .trim
        edit.player.seek(2)
        let before = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
        edit.saveFrame()
        await waitUntil(timeout: 20) { Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).count > before.count }
        let frames = Set((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).subtracting(before)
        check(frames.count == 1 && frames.first?.hasSuffix(".png") == true, "Save Frame wrote a PNG (\(frames.sorted()))")
        check((try? FileHasher.sha256(of: clip)) == original, "the original is unchanged")
        model.section = .collect
        note("edit-video: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Edit/Frame for audio (section 46, R-4610), offline: a tagged MP3 cut by copying its frames, then faded, made louder
    /// and written as FLAC with a new title, the original untouched.
    private func exerciseEditAudio(out: URL) async {
        let fm = FileManager.default
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("edit-audio: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        guard let ffmpeg = AppModel.shared.ffmpeg else {
            check(false, "the bundled ffmpeg is there")
            note("edit-audio: FAIL [\"no ffmpeg\"]")
            return
        }
        let folder = out.appendingPathComponent("Sounds", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // A quiet 6 s tone, made into a tagged MP3 with the bundled encoder.
        let wav = out.appendingPathComponent("tone.wav")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
           let file = try? AVAudioFile(forWriting: wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                                                                   AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                                                   AVLinearPCMIsFloatKey: false]),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 6)
        {
            buffer.frameLength = 44100 * 6
            for i in 0 ..< Int(buffer.frameLength) {
                buffer.floatChannelData?[0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44100) * 0.1)
            }
            try? file.write(from: buffer)
        }
        let song = folder.appendingPathComponent("tone.mp3")
        var make = AudioEditPlan(source: wav, output: song, format: .mp3, kept: [TimeRange(start: 0, end: 6)])
        make.tags.title = "Tone"
        make.tags.artist = "Tester"
        do { try await ffmpeg.editAudio(make) } catch { check(false, "an MP3 can be made: \(error.localizedDescription)") }
        let original = (try? FileHasher.sha256(of: song)) ?? ""

        let edit = model.edit
        model.openInEdit([song])
        await waitUntil(timeout: 30) { edit.kind == .audio && !edit.waveform.isEmpty && edit.mediaDuration > 5 }
        check(edit.tab == .sound && edit.waveform.count > 100, "the MP3 opened with its waveform (\(edit.waveform.count) slices)")
        check(edit.currentTags?.title == "Tone", "its own tags are shown")
        check(edit.audioLengthKnown && edit.audioSource.map { abs($0.duration - edit.mediaDuration) < 0.001 } == true,
              "cuts use the measured length (\(edit.mediaDuration) s), not the system's guess")

        // Keep 1 s to 3 s: the MP3's frames are copied, not encoded again.
        edit.audioSelection = TimeRange(start: 1, end: 3)
        edit.keepSelection()
        check(edit.keptRanges == [TimeRange(start: 1, end: 3)], "Keep Selection keeps 1 s to 3 s")
        func exportAndWait(_ name: String) async -> URL {
            let url = folder.appendingPathComponent(name)
            edit.export()
            await waitUntil(timeout: 5) { edit.exporting }
            await waitUntil(timeout: 60) { !edit.exporting }
            if !fm.fileExists(atPath: url.path) { note("edit-audio: export of \(name) said \(edit.message ?? "nothing")") }
            return url
        }
        let cut = await exportAndWait("tone-edited.mp3")
        let cutTags = await ffmpeg.audioTags(cut)
        check(abs((cutTags?.duration ?? 0) - 2) < 0.1 && cutTags?.tags.codec == "MP3", "the cut is a 2 s MP3 (\(cutTags?.duration ?? 0))")
        check(cutTags?.tags.title == "Tone", "the cut keeps its tags")

        // Faded, evened out, retitled, as FLAC.
        edit.setTimeline { $0.fadeIn = 0.5; $0.normalize = true }
        edit.setTags { $0.title = "New Title" }
        edit.change { $0.export.audioFormat = .flac }
        let flac = await exportAndWait("tone-edited.flac")
        let flacTags = await ffmpeg.audioTags(flac)
        check(flacTags?.tags.codec == "FLAC" && flacTags?.tags.title == "New Title", "written as FLAC with the new title")
        let peaks = (try? await ffmpeg.waveform(flac, buckets: 10)) ?? []
        check(peaks.count == 10 && peaks[0] < peaks[5], "it fades in (\(peaks.prefix(3)))")
        check((peaks.max() ?? 0) > 0.2, "it is louder than the quiet original (\(peaks.max() ?? 0))")
        check((try? FileHasher.sha256(of: song)) == original, "the original is unchanged")
        model.section = .collect
        note("edit-audio: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// The colour of one pixel, origin top left.
    static func colour(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// A short tagged AAC file, made with the system's encoder (no ffmpeg needed).
    static func writeTaggedSong(to url: URL, work: URL) async {
        let wave = work.appendingPathComponent("tone.caf")
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let file = try? AVAudioFile(forWriting: wave, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)
        else { return }
        buffer.frameLength = 44100
        for frame in 0 ..< Int(buffer.frameLength) {
            buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 44100) * 0.2)
        }
        try? file.write(from: buffer)
        let asset = AVURLAsset(url: wave)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
        func item(_ key: AVMetadataKey, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.key = key.rawValue as NSString
            item.value = value as NSString
            return item
        }
        export.metadata = [
            item(.commonKeyTitle, "Test Song"), item(.commonKeyArtist, "Test Artist"), item(.commonKeyAlbumName, "Test Album"),
        ]
        try? await export.export(to: url, as: .m4a)
    }

    /// Organise has the Library's duplicates and the Preview pane's details (D-114), offline, in a folder outside the library:
    /// marks, Only Duplicates, Trash Extra Copies as one change ⌘Z takes back, and the Details tab.
    private func exerciseOrganiseParity(out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        let folder = out.appendingPathComponent("Phone dump", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("IMG_0001.jpg")
        let copy = folder.appendingPathComponent("IMG_0001 copy.jpg")
        let other = folder.appendingPathComponent("IMG_0002.jpg")
        try? Self.jpeg(3).write(to: original)
        try? Self.jpeg(3).write(to: copy)
        try? Self.jpeg(9).write(to: other)
        let savedHighlight = app.preferences.highlightDuplicates
        defer { app.preferences.highlightDuplicates = savedHighlight }
        app.preferences.highlightDuplicates = true
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("organise: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        let organise = model.organise
        let pane = organise.source
        organise.open(folder)
        await waitUntil(timeout: 60) {
            pane.duplicates.report != nil && pane.duplicates.progress == nil && pane.entries.count == 3 && !pane.filtering
                && pane.shown.count == 3
        }
        // Panes list files by their real paths (/private/var, not /var), so ids are taken from the listing.
        let listed = Dictionary(pane.shown.map { ($0.name, $0.path) }, uniquingKeysWith: { first, _ in first })
        check(app.root(containing: folder) == nil, "the folder is outside the library")
        check(pane.duplicatesHere == 2, "two files marked as copies (\(pane.duplicatesHere))")
        let id = { (url: URL) in listed[url.lastPathComponent] ?? url.path }
        check(pane.gridInfo(id(original))?.highlight != nil && pane.gridInfo(id(other))?.highlight == nil,
              "the copies are marked and the other file is not")
        check(!pane.duplicates.inLibrary, "the bar speaks of this folder, not a library folder")
        pane.duplicates.showOnly = true
        check(pane.gridSections.flatMap(\.ids).count == 2, "Only Duplicates shows the two copies")
        try? await Task.sleep(for: .seconds(1))
        snapshot(to: out.appendingPathComponent("organise-duplicates.png"))
        pane.duplicates.showOnly = false
        let changes = organise.history.count
        var asked = false
        pane.trashExtraCopies { _, _ in
            asked = true
            return true
        }
        await waitUntil(timeout: 60) { organise.history.count > changes && organise.working == nil }
        let left = [original, copy].filter { fm.fileExists(atPath: $0.path) }
        check(asked && left.count == 1 && fm.fileExists(atPath: other.path), "Trash Extra Copies keeps one copy (\(left.count) left)")
        if let entry = organise.history.first {
            organise.undo(entry)
            await waitUntil(timeout: 60) {
                organise.working == nil && fm.fileExists(atPath: original.path) && fm.fileExists(atPath: copy.path)
            }
        }
        check(fm.fileExists(atPath: original.path) && fm.fileExists(atPath: copy.path), "Undo puts the copy back")
        await waitUntil(timeout: 30) { pane.entries.count == 3 && !pane.filtering && pane.shown.count == 3 }
        pane.gridSelectionChanged([id(other)])
        organise.tab = .details
        check(organise.details?.url.path == id(other) && organise.details?.pane == .source, "the Details tab shows the chosen file")
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(to: out.appendingPathComponent("organise-details.png"))
        // The Map & Timeline pane (R-4401): hidden until shown, following the folder pane worked in last.
        check(!model.isShowing(.organiseMap), "the Map & Timeline pane starts hidden")
        model.setShowing(.organiseMap, true)
        model.noteOrganiseFocus(.organiseTarget)
        let followsTarget = model.lastOrganiseFolderPane == .organiseTarget
        model.noteOrganiseFocus(.organiseMap)
        check(followsTarget && model.lastOrganiseFolderPane == .organiseTarget, "the map follows the folder pane, not itself")
        model.noteOrganiseFocus(.organiseSource)
        try? await Task.sleep(for: .seconds(1.5))
        snapshot(to: out.appendingPathComponent("organise-map.png"))
        model.setShowing(.organiseMap, false)
        organise.tab = .sort
        model.section = .collect
        note("organise: \(failures.isEmpty ? "PASS" : "FAIL \(failures)")")
    }

    /// Profile views (D-113, section 40), offline: which folders offer the Profile view, how their files group, that nothing
    /// is fetched, with a snapshot of each layout for a person to look at.
    private func exerciseProfiles(library: URL, out: URL) async {
        let app = AppModel.shared
        let fm = FileManager.default
        let base = library.appendingPathComponent("profiles", isDirectory: true)
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            note("profile: \(ok ? "ok" : "FAIL") \(what)")
            if !ok { failures.append(what) }
        }
        var colour = 10
        func file(_ path: String, _ meta: [String: Any]?) {
            let url = base.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            colour += 1
            if url.pathExtension == "mp4" {
                try? fm.copyItem(at: out.appendingPathComponent("clip.mp4"), to: url)
            } else {
                try? Self.jpeg(colour).write(to: url)
            }
            if let meta { try? JSONSerialization.data(withJSONObject: meta).write(to: Sidecar.sidecarURL(for: url)) }
        }
        try? await Self.writeTestClip(to: out.appendingPathComponent("clip.mp4"))
        for (name, count) in [("alice", 6), ("bob", 3)] {
            func ig(_ sub: String, _ post: String, num: Int = 1, count: Int = 1, day: Int, extra: [String: Any] = [:]) -> [String: Any] {
                ["category": "instagram", "subcategory": sub, "username": name, "post_id": "\(name)\(post)",
                 "media_id": "\(name)\(post)\(num)",
                 "num": num, "count": count, "date": String(format: "2024-%02d-01 10:00:00", day)].merging(extra) { $1 }
            }
            for index in 1 ... count {
                file("accounts/\(name)/posts/p\(index).jpg", ig("posts", "p\(index)", day: index,
                                                               extra: ["description": "Post \(index) #saved", "location_name": "Lisbon"]))
            }
            file("accounts/\(name)/posts/p1-2.jpg", ig("posts", "p1", num: 2, count: 2, day: 1))
            file("accounts/\(name)/posts/pinned.jpg", ig("posts", "pin", day: 1, extra: ["pinned": true]))
            file("accounts/\(name)/reels/r1.mp4", ig("reels", "r1", day: 7, extra: ["product_type": "clips", "duration": 4.0]))
            file("accounts/\(name)/stories/s1.jpg", ig("stories", "s1", day: 9))
            file("accounts/\(name)/highlights/Trips/cover.jpg", ig("highlights", "h1", day: 8,
                                                                  extra: ["highlight_title": "Trips", "highlight_cover": true]))
            file("accounts/\(name)/highlights/Trips/1.jpg", ig("highlights", "h1", num: 2, day: 8, extra: ["highlight_title": "Trips"]))
            file("accounts/\(name)/profile pictures/me.jpg", ig("avatar", "av", day: 9, extra: ["author": name.capitalized]))
        }
        for index in 1 ... 3 {
            file("Channel X/v\(index).mp4", ["category": "youtube", "subcategory": "video", "username": "Channel X", "post_id": "v\(index)",
                                             "date": "2024-0\(index)-01 10:00:00", "title": "Video \(index)", "duration": 4,
                                             "playlist_title": "Trips", "playlist_index": index])
        }
        for index in 1 ... 3 {
            file("feed/t\(index).jpg", ["category": "twitter", "subcategory": "user", "username": "carol", "post_id": "t\(index)",
                                        "date": "2024-0\(index)-01 10:00:00", "description": "Tweet \(index)"])
            file("board/b\(index).jpg", ["category": "pinterest", "subcategory": "board", "username": "dee", "community": "Kitchen",
                                         "post_id": "b\(index)", "title": "Pin \(index)"])
        }
        file("plain/photo.jpg", nil)

        let sockets = Self.socketCount()
        model.section = .organise
        try? await Task.sleep(for: .seconds(1))
        let pane = model.organise.source
        func open(_ name: String) async -> ProfileSource? {
            model.organise.open(base.appendingPathComponent(name))
            await waitUntil(timeout: 20) { pane.profileSource != nil || pane.folder?.lastPathComponent == name && !pane.loading }
            try? await Task.sleep(for: .milliseconds(600))
            return pane.profileSource
        }
        let accounts = await open("accounts")
        check(accounts?.kind == .profile && accounts?.sources.map(\.name) == ["alice", "bob"],
              "a folder of two accounts offers Profile with both (\(accounts?.sources.map(\.name) ?? []))")
        check(model.availableViewModes(for: .organiseSource).contains(.profile), "Profile is in the pane's views")
        model.setViewMode(.profile, for: .organiseSource)
        try? await Task.sleep(for: .seconds(3))
        snapshot(to: out.appendingPathComponent("profile-instagram.png"))
        if let alice = accounts?.sources.first, case let .profile(profile) = ProfileBuilder.build(alice, kind: .profile).content {
            check(profile.posts.first?.pinned == true && profile.posts.count == 7 && profile.posts.last?.media.count == 2,
                  "alice: pinned first, 7 posts, the oldest a carousel of 2 (\(profile.posts.count))")
            check(profile.reels.count == 1 && profile.highlights.first?.cover?.url.lastPathComponent == "cover.jpg"
                && profile.storyDays.count == 1 && profile.avatars.count == 1,
                  "alice: a Reel, the saved highlight cover, a story, a picture")
        } else {
            check(false, "alice's profile could be built")
        }
        for (name, kind) in [("Channel X", ProfileKind.channel), ("feed", .timeline), ("board", .board)] {
            let found = await open(name)
            check(found?.kind == kind && model.viewMode(for: .organiseSource) == .profile, "\(name) shows as \(kind.rawValue)")
            try? await Task.sleep(for: .seconds(2))
            snapshot(to: out.appendingPathComponent("profile-\(kind.rawValue).png"))
        }
        _ = await open("plain")
        check(pane.profileSource == nil && !model.availableViewModes(for: .organiseSource).contains(.profile)
            && model.viewMode(for: .organiseSource) == .icon, "a plain folder offers no Profile view and shows icons")
        check(Self.socketCount() <= sockets, "no network sockets opened (\(sockets) before, \(Self.socketCount()) after)")
        model.setViewMode(.icon, for: .organiseSource)
        note("profile: \(failures.isEmpty ? "PASS" : "FAIL \(failures.count): \(failures.joined(separator: "; "))")")
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
