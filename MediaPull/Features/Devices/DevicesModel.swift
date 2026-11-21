import AppKit
import MediaPullCore
import MediaPullDevices
import MediaPullEngines
import MediaPullLibrary

/// The phones and cameras plugged in (R-4101, R-4102), shared by every window. The camera framework is only asked once the
/// Devices section is first shown, so MediaPull never holds a phone the person is using elsewhere until then.
@Observable
final class DeviceCenter {
    private(set) var devices: [ConnectedDevice] = []
    @ObservationIgnored private var browser: DeviceBrowser?
    /// Stand-in devices for the offline self-test (`--selftest-devices`); never real hardware.
    @ObservationIgnored var standIns: [ConnectedDevice] = [] {
        didSet { publish(browser?.devices ?? []) }
    }
    /// Camera cards (drives with a DCIM folder, R-4303), read as folders.
    @ObservationIgnored private var cards: [ConnectedDevice] = []
    @ObservationIgnored private var cardSources: [String: FolderDeviceSource] = [:]

    /// The record of imports, in Application Support (R-4105); the self-test keeps its own.
    let recordsFolder: URL = SelfTestRunner.isActive
        ? FileManager.default.temporaryDirectory.appendingPathComponent("MediaPull-selftest-devices-\(UUID().uuidString)")
        : EnginePaths.defaultSupport.appendingPathComponent("Devices", isDirectory: true)

    func start() {
        guard browser == nil, !SelfTestRunner.isActive else { return }
        let browser = DeviceBrowser()
        browser.onChange = { [weak self] in self?.publish($0) }
        self.browser = browser
        browser.start()
    }

    private func publish(_ found: [ConnectedDevice]) {
        devices = standIns + cards + found
    }

    /// Drives came or went: camera cards are devices too, known by their volume UUID so the record of imports follows the
    /// card, not its name (R-4303).
    func drivesChanged(_ drives: [DriveInfo]) {
        var sources: [String: FolderDeviceSource] = [:]
        cards = drives.filter(\.isCameraCard).map { drive in
            let id = "volume:\(drive.id)"
            let source = cardSources[id] ?? FolderDeviceSource(
                root: drive.url, identity: DeviceIdentity(name: drive.name, serial: id, vendorID: 0, productID: 0)
            )
            sources[id] = source
            return ConnectedDevice(id: id, name: drive.name, symbol: "sdcard", isApple: false, state: .ready(source))
        }
        cardSources = sources
        publish(browser?.devices ?? [])
    }

    func index(for source: any DeviceSource) -> ImportedIndex {
        ImportedIndex(folder: recordsFolder, device: source.identity)
    }
}

/// One window's Devices section: the chosen device and folder, its media, and imports (SPEC section 41).
@Observable
final class DevicesModel: MediaListOwner {
    @ObservationIgnored weak var window: WindowModel?
    private var app: AppModel { .shared }
    private var center: DeviceCenter { app.deviceCenter }

    var deviceID: String? {
        didSet { if deviceID != oldValue { openDevice() } }
    }

    var storages: [DeviceStorage] = []
    var storageID: String?
    /// The folders opened from the top of the storage, the last one shown.
    var path: [DeviceEntry] = []
    var entries: [DeviceEntry] = []
    var loading = false
    var loadError: String?
    var selection: Set<String> = []
    var revision = 0
    var cellSize: CGFloat = 132
    var message: String?
    /// Keys of what was imported from the device shown (R-4105), for the ticks.
    var imported: Set<String> = []
    var importJob: Job?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnails: [String: CGImage] = [:]
    @ObservationIgnored var onListChildrenLoaded: ((String) -> Void)?

    var device: ConnectedDevice? { center.devices.first { $0.id == deviceID } }

    var source: (any DeviceSource)? {
        if case let .ready(source) = device?.state { return source }
        return nil
    }

    var destination: URL? {
        app.preferences.deviceImportFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? app.defaultRoot?.url
    }

    var media: [DeviceEntry] { entries.filter(\.isMedia) }
    var folders: [DeviceEntry] { entries.filter(\.isFolder) }

    /// The section was shown: the camera framework starts looking, and the first device opens.
    func shown() {
        center.start()
        pickDevice()
    }

    /// Devices came or went: keep the chosen one while it is there, else take the first.
    func pickDevice() {
        if let deviceID, center.devices.contains(where: { $0.id == deviceID }) {
            if source != nil, storages.isEmpty, !loading { openDevice() }
            return
        }
        deviceID = center.devices.first?.id
        if deviceID == nil { clear() }
    }

    private func clear() {
        loadTask?.cancel()
        storages = []
        storageID = nil
        path = []
        entries = []
        selection = []
        imported = []
        thumbnails = [:]
        revision += 1
    }

    private func openDevice() {
        clear()
        guard let source else { return }
        loading = true
        loadTask = Task { [weak self] in
            let found = (try? await source.storages()) ?? []
            let keys = await self?.center.index(for: source).all() ?? []
            guard let self, !Task.isCancelled, self.source === source else { return }
            self.storages = found
            self.imported = keys
            self.storageID = found.first?.id
            self.load()
        }
    }

    func openStorage(_ id: String) {
        storageID = id
        path = []
        load()
    }

    func open(_ folder: DeviceEntry) {
        guard folder.isFolder else { return }
        path.append(folder)
        load()
    }

    /// Back to a folder on the path; -1 is the top of the storage.
    func goUp(to index: Int) {
        path = Array(path.prefix(index + 1))
        load()
    }

    func load() {
        loadTask?.cancel()
        guard let source, let storageID else {
            loading = false
            return
        }
        loading = true
        loadError = nil
        let folder = DeviceFolder(storage: storageID, ref: path.last?.ref)
        loadTask = Task { [weak self] in
            let result = await Result { try await source.children(of: folder) }
            guard let self, !Task.isCancelled else { return }
            switch result {
            case let .success(listed):
                self.entries = listed.sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
            case let .failure(error):
                self.entries = []
                self.loadError = error.localizedDescription
            }
            self.selection = []
            self.loading = false
            self.revision += 1
        }
    }

    var gridSections: [GridSection] { [GridSection(id: "device", title: "", ids: entries.map(\.id))] }

    func entry(_ id: String) -> DeviceEntry? { entries.first { $0.id == id } }

    // MARK: Import (R-4104 to R-4106)

    func importSelected() {
        let chosen = entries.filter { selection.contains($0.id) }
        let files = chosen.filter(\.isMedia)
        let folders = chosen.filter(\.isFolder)
        startImport(title: "Import from \(device?.name ?? "device")", files: files, folders: folders, onlyNew: false)
    }

    /// Everything in the folder shown and below it that was not imported before.
    func importNew() {
        startImport(title: "Import new from \(device?.name ?? "device")", files: media, folders: folders, onlyNew: true)
    }

    private func startImport(title: String, files: [DeviceEntry], folders: [DeviceEntry], onlyNew: Bool) {
        guard let source, let destination, importJob?.state.isActive != true else { return }
        let job = Job(kind: .importing, title: title)
        job.destination = destination
        job.state = .running
        app.jobs.add(job)
        importJob = job
        let index = center.index(for: source)
        let includeClips = app.preferences.includeLivePhotoClips
        let storage = storageID ?? "0"
        job.task = Task { [weak self] in
            job.currentItem = "Looking for media"
            var all = files
            all += await Self.walk(folders, in: storage, source: source)
            // Clips sit beside their photos; a clip chosen alone still pairs with a photo in the same listing.
            let imported = onlyNew ? await index.all() : []
            let existing = await Task.detached(priority: .userInitiated) { Self.existingKeys(in: destination) }.value
            let plan = ImportPlan.make(all, imported: imported, existing: onlyNew ? existing : [], includeClips: includeClips)
            job.total = plan.items.count
            job.skipped = 0
            if plan.skipped > 0 { job.notes.append("\(plan.skipped) imported before, or already in “\(destination.lastPathComponent)”") }
            if plan.clipsLeftOut > 0 {
                job.notes.append("\(plan.clipsLeftOut) Live Photo clip\(plan.clipsLeftOut == 1 ? "" : "s") left out")
            }
            await self?.run(plan.items, from: source, into: destination, index: index, job: job)
        }
    }

    private func run(_ items: [ImportItem], from source: any DeviceSource, into destination: URL, index: ImportedIndex, job: Job) async {
        let outcome = await DeviceImporter.run(items, from: source, into: destination, index: index) { done, total, current in
            Task { @MainActor in
                job.saved = done
                job.total = total
                job.currentItem = current.isEmpty ? nil : current
            }
        }
        job.saved = outcome.placed.count
        job.failed = outcome.failed.count
        job.failures = outcome.failed.map { ($0.entry.id, "\($0.entry.name): \($0.message)") }
        imported = await index.all()
        revision += 1
        if !outcome.failed.isEmpty {
            let failedItems = items.filter { item in outcome.failed.contains { $0.entry.id == item.entry.id } }
            job.retry = { [weak self] in
                job.retryStarting = false
                job.failed = 0
                job.state = .running
                job.task = Task { await self?.run(failedItems, from: source, into: destination, index: index, job: job) }
            }
        }
        let state: JobState = outcome.cancelled ? .cancelled
            : outcome.failed.isEmpty ? .completed : .failed("\(outcome.failed.count) not imported")
        app.jobs.finish(job, state)
        if !outcome.placed.isEmpty { app.libraryRevision += 1 }
    }

    /// Media in these folders and every folder below them.
    private static func walk(_ folders: [DeviceEntry], in storage: String, source: any DeviceSource) async -> [DeviceEntry] {
        var out: [DeviceEntry] = []
        var queue = folders
        while let folder = queue.first {
            queue.removeFirst()
            guard !Task.isCancelled else { break }
            let children = (try? await source.children(of: DeviceFolder(storage: storage, ref: folder.ref))) ?? []
            out += children.filter(\.isMedia)
            queue += children.filter(\.isFolder)
        }
        return out
    }

    /// Name and size of each file already in the destination (R-4105).
    nonisolated static func existingKeys(in folder: URL) -> Set<String> {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        // lint:allow main-io called from a detached task only
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return Set(urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return ImportPlan.existingKey(name: url.lastPathComponent, size: Int64(values.fileSize ?? 0))
        })
    }

    func forgetImports() {
        guard let source else { return }
        let alert = NSAlert()
        alert.messageText = "Forget what was imported from “\(source.identity.name)”?"
        alert.informativeText = "Import New will then bring in every file again, except those already in the destination folder. "
            + "Nothing on the device or in your folders changes."
        alert.addButton(withTitle: "Forget Imports")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = center.index(for: source)
        Task {
            await index.forget()
            imported = []
            revision += 1
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Import Here"
        panel.directoryURL = destination
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useDestination(url)
    }

    func useDestination(_ url: URL?) {
        app.preferences.deviceImportFolder = url.flatMap { $0 == app.defaultRoot?.url ? nil : $0.path }
    }

    func organiseDestination() {
        guard let destination, let window else { return }
        window.section = .organise
        window.organise.open(destination)
    }

    // MARK: Grid and list owner

    func gridInfo(_ id: String) -> GridCellInfo? {
        guard let entry = entry(id) else { return nil }
        if entry.isFolder {
            var info = GridCellInfo(title: entry.name, detail: "Folder", secondary: "")
            info.placeholderSymbol = "folder.fill"
            return info
        }
        var info = GridCellInfo(title: entry.name, detail: entry.format?.label ?? entry.fileExtension.uppercased(),
                                secondary: Format.bytes(entry.size))
        if entry.kind == .video { info.kindSymbol = "play.fill"; info.placeholderSymbol = "film" }
        if imported.contains(entry.importKey) {
            info.dimmed = true
            info.stateSymbol = "checkmark.circle.fill"
            info.stateColor = .secondaryLabelColor
        }
        info.stamp = "\(imported.contains(entry.importKey))"
        return info
    }

    func gridThumbnail(_ id: String, maxPixel: Int) async -> CGImage? {
        if let cached = thumbnails[id] { return cached }
        guard let source, let entry = entry(id), entry.isMedia else { return nil }
        let image = await source.thumbnail(entry, maxPixel: maxPixel)
        if let image { thumbnails[id] = image }
        return image
    }

    func gridSelectionChanged(_ ids: Set<String>) { selection = ids }

    func gridActivate(_ id: String) {
        if let entry = entry(id), entry.isFolder { open(entry) }
    }

    /// Quick Look would need the whole file; the device is only read on import.
    func gridQuickLook() {}
    func gridWriter(_: String) -> NSPasteboardWriting? { nil }

    func gridMenu(_ ids: Set<String>) -> NSMenu? {
        let chosen = entries.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        let menu = NSMenu()
        if chosen.count == 1, let folder = chosen.first, folder.isFolder {
            menu.addItem(ActionMenuItem("Open") { [weak self] in self?.open(folder) })
        }
        menu.addItem(ActionMenuItem("Import \(chosen.count == 1 ? "“\(chosen[0].name)”" : "\(chosen.count) Items")") { [weak self] in
            self?.selection = ids
            self?.importSelected()
        })
        return menu
    }

    func gridAppeared(_: String) {}
    var gridAcceptsDrops: Bool { false }
    func gridAcceptDrop(_: NSPasteboard, operation _: NSDragOperation) -> Bool { false }
    func gridMagnify(_ amount: CGFloat) { cellSize = min(320, max(72, cellSize * (1 + amount))) }
    func gridFocused() { window?.focusedPane = .devicesMedia }

    var listColumns: [ListColumn] { [.name, .date, .size, .kind] }

    func listText(_ id: String, _ column: ListColumn) -> String {
        guard let entry = entry(id) else { return "" }
        switch column {
        case .name: return entry.name
        case .date: return entry.taken.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        case .size: return entry.isFolder ? "" : Format.bytes(entry.size)
        case .kind:
            if entry.isFolder { return "Folder" }
            return (entry.format?.label ?? entry.fileExtension.uppercased()) + (imported.contains(entry.importKey) ? " · Imported" : "")
        default: return ""
        }
    }

    var listSort: (column: ListColumn, ascending: Bool)? { (.name, true) }
    func listSortChanged(_: ListColumn, ascending _: Bool) {}
    func listCanSort(_: ListColumn) -> Bool { false }
}
