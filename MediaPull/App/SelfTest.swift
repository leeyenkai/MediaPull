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
        if let folder = Self.value(after: "--selftest-analyse") {
            await exerciseAnalysis(source: URL(fileURLWithPath: folder, isDirectory: true), library: library, out: out)
            NSApp.terminate(nil)
            return
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
        if let page = Self.value(after: "--selftest-video-download").flatMap(URL.init(string:)) {
            await exerciseVideoDownload(page: page, library: library, out: out)
        }
        if let account = Self.value(after: "--selftest-pullsheet") {
            model.showDownloads("@\(account)")
            try? await Task.sleep(for: .seconds(4))
            snapshot(to: out.appendingPathComponent("downloads-instagram.png"))
            note("downloads pane shown for @\(account)")
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
        try? await Task.sleep(for: .seconds(2))
        snapshot(to: out.appendingPathComponent("window-saved.png"))

        if CommandLine.arguments.contains("--selftest-edit") { await exerciseEditor(library: library, out: out) }
        if CommandLine.arguments.contains("--selftest-duplicates") { await exerciseDuplicates(library: library, out: out) }
        if CommandLine.arguments.contains("--selftest-video") { await exerciseVideo(library: library, out: out) }
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
        if let small { try? ImageEditing.write(small, format: .jpeg, metadataFrom: nil, to: folder.appendingPathComponent("resized copy.jpg")) }
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

    /// Looks up a video page's formats, shows them in the Downloads pane, then saves it as 360p H.264 and as audio only.
    private func exerciseVideoDownload(page: URL, library: URL, out: URL) async {
        let app = AppModel.shared
        guard case let .success(info) = await app.engines.videoInfo(for: page) else {
            note("video download: lookup failed")
            return
        }
        let heights = VideoDownloadFormat.allCases.map { "\($0.rawValue) \($0.heights(in: info.formats).map(String.init).joined(separator: "/"))" }
        note("video download: \(info.title) by \(info.uploader ?? "?"), \(info.formats.count) formats; \(heights.joined(separator: "; "))")
        model.showDownloads(page.absoluteString)
        try? await Task.sleep(for: .seconds(8))
        snapshot(to: out.appendingPathComponent("downloads-video.png"))
        guard let root = app.root(containing: library) else { return }
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
        for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.contains("test clip") && file.pathExtension != "json" {
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

    /// Sockets the app process has open; analysis must not open any (R-513).
    static func socketCount() -> Int {
        let pid = getpid()
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return -1 }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        return fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride).filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }.count
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
            note("sample: \(sample.labels.prefix(5).map { "\($0.identifier) \(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")); "
                + "colour \(sample.colour?.rawValue ?? "none"); faces \(sample.faces.count)")
        }
        for query in ["bus", "a person playing tennis", "skiing in the snow", "dog"] {
            let scores = await app.analysis.meaningScores(query, entries: entries)
            var q = LibraryQuery()
            q.search = query
            let found = q.apply(entries, context: .init(similarity: scores, similarityFloor: AnalysisService.floor(for: scores))).flatMap(\.items)
            note("search “\(query)”: \(found.count) results, first \(found.prefix(3).map(\.name).joined(separator: ", "))")
        }
        let similar = await app.analysis.similarGroups(entries)
        note("similar sets: \(Set(similar.values).count) sets covering \(similar.count) files")
        note("people: \(app.analysis.people.filter { $0.faceCount > 0 }.map { "\($0.displayName) (\($0.faceCount))" }.prefix(8).joined(separator: ", ")); "
            + "suggested names: \(app.analysis.suggestions.values.sorted().joined(separator: ", "))")

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

        // Copy to a separate target: the source must stay exactly as it was.
        let sortedCopy = library.appendingPathComponent("Sorted copy", isDirectory: true)
        try? FileManager.default.createDirectory(at: sortedCopy, withIntermediateDirectories: true)
        model.organise.open(sortedCopy, in: model.organise.target)
        model.organise.moveToTarget = false
        model.organise.autoSort(.date)
        await waitUntil(timeout: 60) { self.model.organise.pending != nil }
        if let pending = model.organise.pending {
            try? await Task.sleep(for: .seconds(1))
            snapshot(to: out.appendingPathComponent("organise-copy-preview.png"))
            model.organise.execute(pending.plan)
            await waitUntil(timeout: 120) { self.model.organise.working == nil }
            let copies = FolderOperations.mediaFiles(in: sortedCopy, recursive: true).count
            note("copy to target: \(copies) copies in \(Set(FolderOperations.mediaFiles(in: sortedCopy, recursive: true).map { $0.deletingLastPathComponent() }).count) folders; "
                + "source unchanged: \(checksums() == before)")
            snapshot(to: out.appendingPathComponent("organise-copied.png"))
            if let entry = model.organise.history.first {
                model.organise.undo(entry)
                await waitUntil(timeout: 120) { self.model.organise.working == nil }
            }
            note("copy undone: \(FolderOperations.mediaFiles(in: sortedCopy, recursive: true).count) copies left")
        } else {
            note("copy preview: no plan (\(model.organise.message ?? "no message"))")
        }

        // In place: sort by subject, then undo.
        model.organise.open(test, in: model.organise.target)
        model.organise.autoSort(.subject)
        await waitUntil(timeout: 60) { self.model.organise.pending != nil }
        if let pending = model.organise.pending {
            note("preview: \(pending.plan.title), \(pending.plan.moves.count) moves into \(pending.plan.destinations.count) folders, "
                + "\(pending.plan.unsorted) unsorted: " + pending.plan.destinations.prefix(6).map { "\($0.folder.lastPathComponent) \($0.files.count)" }
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
        note("face data deleted: \(app.analysis.people.isEmpty)")
        writeLog(to: out)
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
