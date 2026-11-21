import AppKit
import MediaPullCore
import MediaPullEdit
import MediaPullEngines
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import SwiftUI

/// The tools of the Inspector (R-4601), by the kind of file open.
enum EditTab: String, CaseIterable, Identifiable {
    case trim, sound, adjust, crop, frame, text, export

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trim: "Trim & Speed"
        case .sound: "Edit"
        case .adjust: "Adjust"
        case .crop: "Crop"
        case .frame: "Frame"
        case .text: "Text & Shapes"
        case .export: "Export"
        }
    }
}

/// Edit/Frame (section 46): the folder shown in Media, the file open on the Canvas, its recipe, and Export. The original
/// is only read (R-4602); the recipe is saved as the person works and changes to it are undone with ⌘Z.
@Observable
final class EditModel: MediaGridOwner {
    @ObservationIgnored weak var window: WindowModel?

    // MARK: Media pane

    var folder: URL?
    var entries: [MediaEntry] = []
    var selection: Set<String> = []
    var cellSize: CGFloat = 96
    var revision = 0
    var loadingFolder = false
    /// Files with a recipe, marked in the Media pane.
    var editedPaths: Set<String> = []

    // MARK: The open file

    var current: URL?
    var kind: MediaKind?
    var recipe: EditRecipe?
    var preview: CGImage?
    /// The picture turned and straightened but not cropped, shown while cropping.
    var cropImage: CGImage?
    var showingBefore = false {
        didSet { if showingBefore != oldValue { render() } }
    }

    var tab: EditTab = .adjust {
        didSet {
            guard tab != oldValue else { return }
            // The timeline is cut from the original; leaving it stops the sound, which has no control elsewhere.
            if tab == .trim, playingResult { loadPlayer() }
            if oldValue == .trim, kind == .video { player.player.pause() }
            render()
        }
    }

    var loadingFile = false
    var loadError: String?
    var lookPreviews: [LookName: CGImage] = [:]
    /// The layer chosen on the canvas or in the list.
    var selectedLayer: UUID?
    /// Where Export puts files: nil beside the original.
    var exportFolder: URL?
    var exporting = false
    /// Text layers whose font is not on this Mac (R-4607).
    var missingFonts: [String] = []
    /// Picture layers whose file is gone: drawn without them, and said so.
    var missingPictures: [String] = []
    /// The canvas's size in points, set by the Canvas pane, so previews are rendered at the size shown.
    var canvasSize = CGSize(width: 900, height: 700) {
        didSet {
            if abs(canvasSize.width - oldValue.width) > 40 || abs(canvasSize.height - oldValue.height) > 40 { render() }
        }
    }

    var message: String? {
        didSet {
            messageTask?.cancel()
            guard message != nil else { return }
            messageTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.message = nil
            }
        }
    }

    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private(set) var session: PhotoSession?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var gestureStart: EditRecipe?
    @ObservationIgnored private var renderGeneration = 0

    private var app: AppModel { .shared }

    var tabs: [EditTab] {
        switch kind {
        case .image: [.adjust, .crop, .frame, .text, .export]
        case .video: [.trim, .adjust, .crop, .frame, .text, .export]
        case .audio: [.sound, .export]
        default: []
        }
    }

    /// Plays videos and audio on the canvas.
    let player = EditPlayer()
    /// The open video's or audio file's length in seconds.
    var mediaDuration: Double = 0
    /// The video plays as edited, rather than the original the timeline is cut from.
    var playingResult = false
    /// Self-tests give the model an undo manager of their own, grouped by hand: with no user events, the window's
    /// manager never closes its groups.
    @ObservationIgnored var testUndoManager: UndoManager?
    var undoManager: UndoManager? { testUndoManager ?? window?.hostWindow?.undoManager }
    /// Settings copied for Paste Settings (R-4611).
    var copiedSettings: EditRecipe?
    /// The audio's waveform, 0 to 1 per slice.
    var waveform: [Float] = []
    /// A part of the audio dragged across, to keep or cut.
    var audioSelection: TimeRange?
    /// The audio file's own tags, shown where nothing new is typed.
    var currentTags: AudioTags?
    /// What the audio holds, by ffprobe (length, codec, depth).
    var audioSource: AudioSourceFormat?
    /// The waveform could not be read (a format the build cannot decode, or no ffmpeg).
    var waveformFailed = false
    @ObservationIgnored var waveformTask: Task<Void, Never>?

    // MARK: Opening

    /// The section was shown: the folder last used, else the window's save folder.
    func shown() {
        guard folder == nil else { return }
        if let saved = app.preferences.editFolder.map({ URL(fileURLWithPath: $0, isDirectory: true) }),
           FileManager.default.fileExists(atPath: saved.path)
        {
            show(folder: saved)
        } else {
            if let fallback = window?.saveFolder { show(folder: fallback) }
        }
    }

    /// Opens files in the section (R-4601): their folder in Media, the first on the Canvas.
    func open(_ files: [URL]) {
        guard let first = files.first else { return }
        window?.section = .edit
        show(folder: first.deletingLastPathComponent(), selecting: first)
        load(first)
    }

    func show(folder: URL, selecting file: URL? = nil) {
        let changed = self.folder?.standardizedFileURL != folder.standardizedFileURL
        self.folder = folder
        app.preferences.editFolder = folder.path
        if let file { selection = [file.path] }
        if changed || entries.isEmpty { reloadFolder() }
    }

    func reloadFolder() {
        guard let folder else { return }
        loadingFolder = true
        Task { [weak self] in
            let listed = await MediaListing.load(folder, recursive: false).entries
            let edited = await AppModel.shared.recipes.editedPaths()
            guard let self, self.folder == folder else { return }
            entries = listed.filter { !Self.editable([$0.url]).isEmpty }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            editedPaths = edited
            loadingFolder = false
            revision += 1
        }
    }

    /// Files changed somewhere (a move, a rename, an export placed here): the folder is listed again.
    func filesChanged() {
        guard folder != nil else { return }
        reloadFolder()
    }

    /// Opens a file on the Canvas with its recipe, or a new one.
    func load(_ url: URL) {
        guard url.standardizedFileURL != current?.standardizedFileURL else { return }
        flushSave()
        openTask?.cancel()
        current = url
        let format = MediaFormat.fromExtension(url.pathExtension)
        let previousKind = kind
        kind = format?.kind
        recipe = nil
        preview = nil
        cropImage = nil
        lookPreviews = [:]
        loadError = nil
        session = nil
        missingFonts = []
        missingPictures = []
        loadingFile = true
        playingResult = false
        mediaDuration = 0
        waveformTask?.cancel()
        waveform = []
        audioSelection = nil
        currentTags = nil
        player.stop()
        openTask = Task { [weak self] in
            let stored = await AppModel.shared.recipes.recipe(for: url)
            var duration = 0.0
            let opened: PhotoSession? = if format?.kind == .image, !MediaFormat.isSequenceExtension(url.pathExtension) {
                await Task.detached(priority: .userInitiated) { PhotoSession(url: url) }.value
            } else if format?.kind == .video {
                // A still of the video, edited like a photo; the timeline and export use the whole video.
                await {
                    duration = await Self.duration(of: url)
                    return await VideoComposer.frame(url, at: min(1, duration / 2)).map { PhotoSession(image: $0, url: url) }
                }()
            } else {
                nil
            }
            if format?.kind == .audio { duration = await Self.duration(of: url) }
            guard let self, !Task.isCancelled, current == url else { return }
            loadingFile = false
            guard let kind = format?.kind else { return }
            mediaDuration = duration
            recipe = stored ?? EditRecipe(source: EditSource(path: url.standardizedFileURL.path, kind: kind))
            // Another kind of file starts on its first tool (Trim for a video, Adjust for a photo).
            if previousKind != kind || !tabs.contains(tab), let first = tabs.first { tab = first }
            if kind == .video || kind == .audio {
                loadPlayer()
                if kind == .audio { loadWaveform() }
            }
            if kind == .image || kind == .video {
                guard let opened else {
                    loadError = kind == .video ? "This video could not be read." : "This picture could not be read."
                    return
                }
                session = opened
                render()
                renderLooks()
            }
        }
    }

    // MARK: Changing the recipe (R-4602)

    /// Applies a change to the recipe, saves it and draws it again. `undoable`: registered with ⌘Z now; a slider drag
    /// registers once, when it ends (`beginGesture`, `endGesture`).
    func change(undoable: Bool = true, _ body: (inout EditRecipe) -> Void) {
        guard var edited = recipe else { return }
        let before = edited
        body(&edited)
        guard edited != before else { return }
        recipe = edited
        if undoable, gestureStart == nil { registerUndo(before) }
        scheduleSave()
        render()
    }

    func beginGesture() {
        if gestureStart == nil { gestureStart = recipe }
    }

    func endGesture() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        if start != recipe { registerUndo(start) }
    }

    /// ⌘Z puts the recipe back as it was, for the file it belongs to, and ⇧⌘Z does it again.
    private func registerUndo(_ previous: EditRecipe) {
        guard let manager = undoManager, let now = recipe else { return }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(previous, redo: now) }
        }
        manager.setActionName("Edit")
    }

    private func restore(_ recipe: EditRecipe, redo: EditRecipe) {
        if let manager = undoManager {
            manager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.restore(redo, redo: recipe) }
            }
            manager.setActionName("Edit")
        }
        // The same recipe, wherever its file is now (it may have been renamed since).
        if recipe.id == self.recipe?.id || recipe.source.path == self.recipe?.source.path {
            self.recipe = recipe
            scheduleSave()
            render()
        } else {
            Task { await AppModel.shared.recipes.save(recipe); filesChanged() }
        }
    }

    /// Revert: the recipe goes and the photo is shown as it is (R-4602); ⌘Z brings it back.
    func revert() {
        guard let recipe else { return }
        change { $0 = EditRecipe(id: recipe.id, source: recipe.source) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard let recipe else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if await !AppModel.shared.recipes.save(recipe) {
                self?.message = "The edits could not be saved. Check that the disk has space."
            }
            // The look thumbnails show the photo as it is now.
            if self?.tab == .adjust { self?.renderLooks() }
            let edited = await AppModel.shared.recipes.editedPaths()
            guard let self, edited != editedPaths else { return }
            editedPaths = edited
            revision += 1
        }
    }

    /// Files MediaPull moved or renamed: the open file, its recipe and the Media folder follow (R-4602).
    func followMoves(_ moves: [(from: String, to: String)]) {
        guard !moves.isEmpty else { return }
        // Standardized (a doubled slash, a "."), as the model's own paths are.
        let remap = PathMoves(moves.map {
            (URL(fileURLWithPath: $0.from).standardizedFileURL.path, URL(fileURLWithPath: $0.to).standardizedFileURL.path)
        })
        // As written, or with links resolved (a folder reached through /var is /private/var to the journal).
        func destination(_ url: URL) -> String? {
            remap.destination(of: url.standardizedFileURL.path) ?? remap.destination(of: url.resolvingSymlinksInPath().path)
        }
        if let folder, let moved = destination(folder) {
            self.folder = URL(fileURLWithPath: moved, isDirectory: true)
            app.preferences.editFolder = moved
        }
        if let current, let moved = destination(current) {
            self.current = URL(fileURLWithPath: moved)
            recipe?.source.path = moved
        }
        selection = Set(selection.map { remap.destination(of: $0) ?? $0 })
        if let exportFolder, let moved = destination(exportFolder) { self.exportFolder = URL(fileURLWithPath: moved, isDirectory: true) }
    }

    /// Leaving the section: edits are saved, and ⌘Z elsewhere never undoes a recipe change out of sight (R-4602).
    func leftSection() {
        flushSave()
        undoManager?.removeAllActions(withTarget: self)
        player.player.pause()
        waveformTask?.cancel()
    }

    /// At quit: the last change is written at once.
    func saveBeforeQuit() {
        saveTask?.cancel()
        if let recipe { AppModel.shared.recipes.saveNow(recipe) }
    }

    /// Saves now (another file is opened, the window closes).
    func flushSave() {
        guard saveTask != nil, let recipe else { return }
        saveTask?.cancel()
        saveTask = nil
        Task {
            if await !AppModel.shared.recipes.save(recipe) {
                self.message = "The edits could not be saved. Check that the disk has space."
            }
            let edited = await AppModel.shared.recipes.editedPaths()
            self.editedPaths = edited
            self.revision += 1
        }
    }

    // MARK: Drawing

    /// Renders the canvas off the main actor at the size shown; a newer change replaces a render under way.
    func render() {
        guard let session, let recipe else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let scale = window?.hostWindow?.backingScaleFactor ?? 2
        let fit = CGSize(width: min(canvasSize.width * scale, PhotoSession.proxyEdge),
                         height: min(canvasSize.height * scale, PhotoSession.proxyEdge))
        let before = showingBefore, cropping = tab == .crop
        // One render at a time: a slider drag asks for many; the newest waits for the one under way and the rest are
        // dropped, so renders never pile up.
        let previous = renderTask
        renderTask = Task { [weak self] in
            await previous?.value
            guard let self, generation == renderGeneration else { return }
            let (image, uncropped, fonts, pictures) = await Task.detached(priority: .userInitiated) {
                () -> (CGImage?, CGImage?, [String], [String]) in
                let image = session.preview(recipe, fit: fit, before: before)
                let uncropped = cropping ? session.uncropped(recipe, fit: fit) : nil
                return (image, uncropped, FontLookup.missing(in: recipe.layers), FontLookup.missingPictures(in: recipe.layers))
            }.value
            // Shown even when a newer render waits: the canvas follows a drag instead of standing still; never another
            // file's.
            guard self.session === session else { return }
            preview = image
            cropImage = uncropped
            missingFonts = fonts
            missingPictures = pictures
        }
    }

    func renderLooks() {
        guard let session, let recipe else { return }
        Task { [weak self] in
            let previews = await Task.detached(priority: .utility) { () -> [LookName: CGImage] in
                var out: [LookName: CGImage] = [:]
                for look in LookName.allCases {
                    if let image = session.lookPreview(recipe, look: look, edge: 72) { out[look] = image }
                }
                return out
            }.value
            guard let self, self.session === session else { return }
            lookPreviews = previews
        }
    }

    /// Width over height of the picture the crop is chosen on.
    var cropRatio: Double {
        guard let session, let recipe else { return 1 }
        if let cropImage, cropImage.height > 0 { return Double(cropImage.width) / Double(cropImage.height) }
        return session.turnedRatio(recipe.geometry)
    }

    func setAspect(_ aspect: EditAspect) {
        let ratio = cropRatio
        change {
            $0.geometry.aspect = aspect
            if let wanted = aspect.ratio(original: ratio) {
                $0.geometry.crop = UnitRect.centred(ratio: wanted, in: CGSize(width: ratio, height: 1))
            } else if aspect == .free, $0.geometry.crop == nil {
                $0.geometry.crop = nil
            }
        }
    }

    /// A quarter turn; a chosen crop shape is kept, centred on the turned picture.
    func turn(by quarters: Int) {
        guard let session else { return }
        change { recipe in
            recipe.geometry.quarterTurns = ((recipe.geometry.quarterTurns + quarters) % 4 + 4) % 4
            let turned = session.turnedRatio(recipe.geometry)
            recipe.geometry.crop = recipe.geometry.aspect.ratio(original: turned).flatMap { wanted in
                recipe.geometry.aspect == .original ? nil : UnitRect.centred(ratio: wanted, in: CGSize(width: turned, height: 1))
            }
        }
    }

    // MARK: Export (R-4608)

    /// Writes the edited photo as a new file beside the original (or into the chosen folder), as a job.
    func export() {
        guard let url = current, let recipe, let kind, !exporting else { return }
        flushSave()
        let destination = exportFolder ?? url.deletingLastPathComponent()
        let job = Job(kind: .export, title: "Export “\(url.lastPathComponent)”")
        job.state = .running
        app.jobs.add(job)
        exporting = true
        let progress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                job.fraction = fraction
                job.summaryOverride = "\(Int((fraction * 100).rounded())) %"
            }
        }
        job.task = Task { [weak self] in
            let result: Result<URL, Error> = switch kind {
            case .video: await Self.exportVideo(url, recipe: recipe, into: destination, progress: progress)
            case .audio: await Self.exportAudio(url, recipe: recipe, into: destination, progress: progress)
            default: await Self.export(url, recipe: recipe, into: destination)
            }
            switch result {
            case let .success(placed):
                AppModel.shared.jobs.finish(job, .completed, notify: false)
                self?.message = "Exported “\(placed.lastPathComponent)”."
                AppModel.shared.fileChangeRevision += 1
            case let .failure(error) where error is CancellationError:
                AppModel.shared.jobs.finish(job, .cancelled, notify: false)
                self?.message = "Export stopped; nothing was written."
            case let .failure(error):
                AppModel.shared.jobs.finish(job, .failed(error.localizedDescription), notify: false)
                self?.message = error.localizedDescription
            }
            self?.exporting = false
        }
    }

    /// Renders and writes off the main actor, then places the file at a free name with a copy's metadata file (D-105).
    @concurrent
    nonisolated static func export(_ url: URL, recipe: EditRecipe, into folder: URL) async -> Result<URL, Error> {
        do {
            let fm = FileManager.default
            let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
            defer { try? fm.removeItem(at: staging) }
            let ext = recipe.export.format.fileExtension
            let stem = url.deletingPathExtension().lastPathComponent
            // Named as it will be placed, within the name budget, so a long name never fails to stage.
            let staged = staging.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: ext))
            let metadata = try await Task.detached(priority: .userInitiated) { () throws -> Data? in
                let size = try PhotoExporter.export(url, recipe: recipe, to: staged)
                let values: [String: FileOps.MetadataValue] = [
                    "edited": .bool(true), "sha256": .string(try FileHasher.sha256(of: staged)),
                    "width": .int(Int(size.width)), "height": .int(Int(size.height)),
                ]
                // Without the location when it is left out of the picture (R-4608).
                let dropping = recipe.export.keepLocation ? [] : ["location_name", "location_id", "location", "latitude", "longitude"]
                return try FileOps.metadata(of: url, applying: .init(values: values, dropping: dropping, isCopy: true))
            }.value
            let wanted = folder.appendingPathComponent(FileNaming.fileName(stem: "\(stem)-edited", ext: ext))
            let placed = try await FileOps.place(staged, as: wanted, with: metadata.map(FileOps.Companion.data) ?? .none)
            if let problem = placed.metadataProblem {
                return .failure(CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "Exported “\(placed.url.lastPathComponent)”, but its metadata file could not be "
                        + "written: \(problem)",
                ]))
            }
            return .success(placed.url)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Media grid

    var gridSections: [GridSection] { [GridSection(id: "edit", title: "", ids: entries.map(\.path))] }

    private func entry(_ id: String) -> MediaEntry? { entries.first { $0.path == id } }

    func gridInfo(_ id: String) -> GridCellInfo? {
        guard let entry = entry(id) else { return nil }
        var info = GridCellInfo(title: entry.name, detail: entry.format?.label ?? "", secondary: "")
        if entry.kind == .video { info.kindSymbol = "video.fill" }
        if entry.kind == .audio {
            info.kindSymbol = "waveform"
            info.placeholderSymbol = "waveform"
        }
        if editedPaths.contains(URL(fileURLWithPath: id).standardizedFileURL.path) {
            info.stateSymbol = "slider.horizontal.3"
            info.stateColor = .controlAccentColor
        }
        info.stamp = "\(entry.modified.timeIntervalSince1970)"
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        await app.thumbnails.localThumbnail(for: URL(fileURLWithPath: id), maxPixel: maxPixel)?.image
    }

    func gridSelectionChanged(_ ids: Set<String>) {
        selection = ids
        if ids.count == 1, let id = ids.first { load(URL(fileURLWithPath: id)) }
    }

    func gridActivate(_ id: String) { load(URL(fileURLWithPath: id)) }

    func gridQuickLook() {
        QuickLook.shared.show(selection.sorted().map { URL(fileURLWithPath: $0) })
    }

    func gridWriter(_ id: String) -> NSPasteboardWriting? { URL(fileURLWithPath: id) as NSURL }

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        let chosen = ids.sorted().map { URL(fileURLWithPath: $0) }
        guard !chosen.isEmpty else { return nil }
        let menu = NSMenu()
        for item in batchMenuItems(for: chosen) {
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(chosen) })
        let edited = chosen.filter { editedPaths.contains($0.standardizedFileURL.path) }
        if !edited.isEmpty {
            menu.addItem(ActionMenuItem(edited.count == 1 ? "Revert Edits" : "Revert Edits of \(edited.count) Files") { [weak self] in
                self?.revert(edited)
            })
        }
        return menu
    }

    /// Revert for files not open on the canvas: their recipes go (the original was never changed).
    /// Revert for several files: their recipes go as one change ⌘Z brings back (R-4602).
    func revert(_ files: [URL]) {
        flushSave()
        Task { [weak self] in
            var before: [(path: String, recipe: EditRecipe?)] = []
            for file in files {
                before.append((file.standardizedFileURL.path, await AppModel.shared.recipes.recipe(for: file)))
                await AppModel.shared.recipes.remove(file.path)
            }
            guard let self else { return }
            registerBatchUndo(before, name: "Revert Edits")
            reloadCurrentRecipe()
        }
    }

    func gridAppeared(_: String) {}

    var gridAcceptsDrops: Bool { true }

    /// Files dragged here open in the section (R-4601); nothing is copied.
    func gridAcceptDrop(_ pasteboard: NSPasteboard, operation _: NSDragOperation) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let media = Self.editable(urls)
        guard !media.isEmpty else { return false }
        open(media)
        return true
    }

    /// Photos (not image sequences), videos and audio: what Edit/Frame opens. A drawing or a stream address is not.
    nonisolated static func editable(_ files: [URL]) -> [URL] {
        files.filter { url in
            guard let kind = MediaFormat.fromExtension(url.pathExtension)?.kind else { return false }
            return [.image, .video, .audio].contains(kind) && !MediaFormat.isSequenceExtension(url.pathExtension)
        }
    }
}

/// Fonts a recipe names that this Mac does not have (R-4607).
enum FontLookup {
    nonisolated static func missing(in layers: [Layer]) -> [String] {
        var out: [String] = []
        for layer in layers where !layer.hidden {
            guard case let .text(style) = layer.kind, LayerRenderer.font(style, canvasHeight: 100).missing,
                  !out.contains(style.family) else { continue }
            out.append(style.family)
        }
        return out
    }

    /// Picture layers whose file is no longer there.
    nonisolated static func missingPictures(in layers: [Layer]) -> [String] {
        layers.compactMap { layer in
            guard !layer.hidden, case let .image(path) = layer.kind, !FileManager.default.fileExists(atPath: path) else { return nil }
            return (path as NSString).lastPathComponent
        }
    }
}

extension WindowModel {
    /// "Open in Edit/Frame" (R-4601).
    func openInEdit(_ files: [URL]) {
        let media = EditModel.editable(files)
        guard !media.isEmpty else { return }
        edit.open(media)
    }

    func openInEditMenuItem(_ files: [URL]) -> NSMenuItem? {
        let media = EditModel.editable(files)
        guard !media.isEmpty else { return nil }
        return ActionMenuItem("Open in Edit/Frame") { [weak self] in self?.openInEdit(media) }
    }
}
