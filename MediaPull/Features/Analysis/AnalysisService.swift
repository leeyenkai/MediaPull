import Foundation
import IOKit.ps
import MediaPullAnalysis
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullMedia
import MediaPullNet
import MediaPullStore
import Observation

/// Analyses library folders in the background and answers the Library, Organise and People views (SPEC sections 36 to 39).
@Observable
final class AnalysisService {
    /// Bumped when new results arrive, at most every couple of seconds.
    var revision = 0
    var peopleRevision = 0
    /// Files in the Trash that Undo can still bring back, kept out of People until then.
    @ObservationIgnored var heldPaths: Set<String> = []
    var progress: (done: Int, total: Int)?
    var pauseReason: String?
    var userPaused = false
    var isRunning = false
    var people: [PersonInfo] = []
    /// Names suggested from folder names, per unnamed person (R-3905).
    var suggestions: [UUID: String] = [:]
    private(set) var analysedCount = 0
    private(set) var modelsLoaded = false
    /// Set when the analysis database could not be opened and was set aside (Settings > Analysis says so).
    private(set) var storeProblem: String?

    @ObservationIgnored private(set) var store: AnalysisStore?
    @ObservationIgnored private var analyzer: Analyzer?
    @ObservationIgnored private var imageVectors: VectorStore?
    @ObservationIgnored private var faceVectors: VectorStore?
    @ObservationIgnored private var subjectClassifier: SubjectClassifier?
    @ObservationIgnored private var subjectsKey: [String]?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var regroupTask: Task<Void, Never>?
    /// Loads the models and reads the vector files; deletions wait for it, so files it reads are never brought back.
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Moves noted before the database is open (a library folder renamed in the Finder while MediaPull was quit, found at
    /// launch): applied when it opens, before the first scan, so the files are not taken for new ones (audit 8, B8-m5).
    @ObservationIgnored private var waitingMoves: [(from: String, to: String)] = []
    /// The moves last given to the database, so later ones are applied after them, in the order they happened.
    @ObservationIgnored private var movesApplied: Task<Void, Never>?
    /// Where the vector files live (a temporary folder for self-tests).
    @ObservationIgnored private var vectorFolder = AnalysisService.folder
    /// Deletions under way; no scan starts while one runs, so nothing is written into data being deleted.
    @ObservationIgnored private var deletions = 0
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var job: Job?
    @ObservationIgnored private lazy var watcher = FolderWatcher { [weak self] paths in self?.foldersChanged(paths) }
    /// Extra folders to analyse and watch: folders open in Organise.
    @ObservationIgnored var extraFolders: Set<String> = [] {
        didSet {
            if extraFolders != oldValue {
                updateWatch(); schedule(after: .seconds(1))
            }
        }
    }

    /// Listeners for changed folders (the Library and Organise panes reload their folder).
    @ObservationIgnored var onFolderChange: [UUID: ([String]) -> Void] = [:]

    private var app: AppModel {
        .shared
    }

    private var preferences: Preferences {
        app.preferences
    }

    nonisolated static var folder: URL {
        EnginePaths.defaultSupport.appendingPathComponent("Analysis", isDirectory: true)
    }

    /// The bundled place table for a file's nearest place (D-59, D-110), loaded once, on first use, off the main actor.
    nonisolated static let places: OfflineGeocoder? = modelsFolder.flatMap { folder in
        ModelManifest.load(from: folder)?.places.flatMap { OfflineGeocoder(table: folder.appendingPathComponent($0)) }
    }

    /// The bundled models, or the build cache in development builds.
    nonisolated static var modelsFolder: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path)
        {
            return bundled
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MediaPullBuild/models/bundle")
        return FileManager.default.fileExists(atPath: cache.appendingPathComponent("manifest.json").path) ? cache : nil
    }

    var faceThreshold: Float {
        Float((analyzer?.faceEncoder?.spec.matchThreshold).map(Double.init) ?? 0.3) + Float(preferences.faceMatchAdjustment)
    }

    /// Reads `modelsLoaded`, which is observed (the analyzer is not), so views update once the models finish loading.
    var canSearchByMeaning: Bool {
        modelsLoaded && analyzer?.imageText != nil
    }

    // MARK: Start

    func start(inMemory: Bool = false, ffmpeg: FFmpeg? = nil) {
        guard store == nil else { return }
        let probe: MediaFactsReader.AudioProbe? = ffmpeg.map { ffmpeg in { @Sendable url in await ffmpeg.audioTags(url) } }
        let hash: (@Sendable (URL) async -> String?)? = ffmpeg.map { ffmpeg in { @Sendable url in await ffmpeg.audioStreamHash(url) } }
        store = Self.openStore(inMemory: inMemory) { [weak self] problem in self?.storeProblem = problem }
        if let store, !waitingMoves.isEmpty {
            let moves = waitingMoves
            waitingMoves = []
            movesApplied = Task { await store.movePaths(moves) }
        }
        // Self-tests keep their vectors out of the real Analysis folder.
        let folder = inMemory ? FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPull-selftest-analysis-\(UUID().uuidString)")
            : Self.folder
        vectorFolder = folder
        loadTask = Task {
            let models = Self.modelsFolder
            // The vector stores read their whole files when made (hundreds of MB for a large library): off the main actor.
            let (loaded, images, faces) = await Task.detached(priority: .utility) { () -> (Analyzer, VectorStore?, VectorStore?) in
                let loaded = Analyzer(modelsFolder: models, audioProbe: probe, audioHash: hash)
                let images = loaded.imageText.map { VectorStore(folder: folder, name: "image-\($0.spec.id)", dimension: $0.dimension) }
                let faces = loaded.faceEncoder.map {
                    VectorStore(folder: folder, name: "faces-\($0.spec.id)", dimension: $0.spec.dimension, excludeFromBackup: true)
                }
                // Vectors of a model that has been replaced are never read again (lifecycle, SPEC 6.3).
                let inUse = [loaded.imageText.map { "image-\($0.spec.id)" }, loaded.faceEncoder.map { "faces-\($0.spec.id)" }]
                Self.removeOtherVectorFiles(in: folder, keeping: inUse.compactMap(\.self), modelsLoaded: loaded.imageText != nil)
                return (loaded, images, faces)
            }.value
            await movesApplied?.value
            analyzer = loaded
            imageVectors = images
            faceVectors = faces
            modelsLoaded = true
            analysedCount = await store?.fileCount() ?? 0
            await refreshPeople()
            updateWatch()
            schedule(after: .seconds(3))
        }
    }

    /// Every library folder is watched, including those left out of analysis, so every pane updates live when files
    /// change in the Finder (R-1704); only `scanFolders` are analysed.
    func updateWatch() {
        let roots = app.roots.filter { !app.missingRoots.contains($0.id) }.map(\.url)
        // Watched only, not analysed: a window's save folder outside the library, so its tree follows the Finder too.
        let others = app.windows.compactMap(\.library.otherFolder)
        let extras = (extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) } + others)
            .filter { folder in !roots.contains { folder.path.hasPrefix($0.path + "/") || folder.path == $0.path } }
        watcher.watch(Array(Set((roots + extras).map(\.path))))
    }

    /// Library roots (minus those excluded in Settings) and folders open in Organise.
    var scanFolders: [URL] {
        // Root paths are kept current by AppModel.followRootLocations (bookmarks resolved off the main actor); a root that
        // cannot be found is left out, so its files are not taken for deleted.
        let roots = app.roots.filter { !app.missingRoots.contains($0.id) }.map(\.url)
            .filter { !preferences.analysisExcludedRoots.contains($0.path) }
        return roots + extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { folder in !roots.contains { folder.path.hasPrefix($0.path + "/") || folder.path == $0.path } }
    }

    private func foldersChanged(_ paths: [String]) {
        for listener in onFolderChange.values {
            listener(paths)
        }
        // Only changes in analysed folders mean work; a watched save folder outside them (a busy home folder, say) would
        // otherwise keep putting the scan off (audit 3, B3-m4).
        let analysed = scanFolders.map(\.path)
        if paths.contains(where: { path in analysed.contains { path == $0 || path.hasPrefix($0 + "/") } }) {
            schedule(after: .seconds(4))
        }
    }

    /// Runs a scan soon, coalescing bursts of changes.
    func schedule(after delay: Duration = .seconds(2)) {
        guard preferences.analysisEnabled, modelsLoaded else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            if isRunning {
                rescanRequested = true
            } else {
                runScan()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        if !paused {
            schedule(after: .milliseconds(100))
        }
    }

    // MARK: Scanning

    /// Files that gave no picture to embed (damaged, or a video format the system cannot open). Without this they would be
    /// hashed and analysed again on every scan; they are tried again after the next launch.
    @ObservationIgnored private var noPicture: Set<String> = []

    private struct Work: Sendable {
        var url: URL
        var size: Int64
        var modified: Date
        /// Analysed by the current models but with facts read an older way: only the facts are read again (R-4210).
        var factsOnly = false
    }

    private func runScan() {
        guard let store, let analyzer, deletions == 0 else { return }
        isRunning = true
        let folders = scanFolders
        let wantFaces = preferences.facesEnabled && analyzer.faceEncoder != nil
        let images = imageVectors, faces = faceVectors
        // Every library folder is remembered, including one whose disk is not connected and one left out of analysis in
        // Settings; so are recent Organise folders. Only folders removed from the library are forgotten (audit 2, B2-M1).
        let keep = preferences.recentOrganiseFolders + app.roots.map(\.path)
        // A library folder that is missing for now (in the Trash, on a disk not connected) may come back: nothing under it
        // is forgotten, so its people and corrections survive (audit 3, B3-M2).
        let holding = app.roots.filter { app.missingRoots.contains($0.id) }.map(\.path)
        let journal = app.journal
        scanTask = Task { [weak self] in
            let skip = self?.noPicture ?? []
            var (work, gone) = await Self.findWork(folders: folders, store: store, wantFaces: wantFaces, embeddings: images != nil,
                                                   noPicture: skip, keep: keep, holding: holding)
            // Files MediaPull moved to the Trash that Undo can still put back keep their faces and corrections until the
            // Trash lets them go (audit 5, B5-M3).
            var held = Set<String>()
            if !gone.isEmpty {
                let restorable = await journal.restorablePaths()
                if !restorable.isEmpty {
                    held = Set(gone.filter { restorable.containsPathOrParent(of: $0) })
                    gone.removeAll { held.contains($0) }
                }
            }
            await store.setHeld(held)
            await store.forget(paths: gone)
            guard let self else { return }
            if held != self.heldPaths {
                self.heldPaths = held
                await self.refreshPeople()
            }
            if !work.isEmpty {
                beginJob(total: work.count)
                job?.task = scanTask
            }
            var done = 0
            var newFaces = 0
            var lastBump = Date()
            var iterator = work.makeIterator()
            await withTaskGroup(of: (path: String, faces: Int, noPicture: Bool).self) { group in
                func next() async -> Bool {
                    guard let item = iterator.next() else { return false }
                    await self.waitWhilePaused()
                    if Task.isCancelled {
                        return false
                    }
                    // Read for every file, so turning recognition off stops it at once, in the middle of a scan (R-3901).
                    let enabled = await self.preferences.facesEnabled
                    let facesNow = wantFaces ? enabled : false
                    // Utility, not background: background priority was throttled about tenfold in the benchmark.
                    group.addTask(priority: .utility) {
                        let result = await Self.process(item, analyzer: analyzer, store: store, images: images, faces: faces,
                                                        wantFaces: facesNow)
                        return (item.url.path, result.faces, result.noPicture)
                    }
                    return true
                }
                for _ in 0 ..< 2 {
                    _ = await next()
                }
                while let result = await group.next() {
                    done += 1
                    newFaces += result.faces
                    if result.noPicture { self.noPicture.insert(result.path) }
                    self.progress = (done, work.count)
                    self.job?.saved = done
                    self.job?.fraction = Double(done) / Double(max(work.count, 1))
                    self.job?.summaryOverride = "\(done) of \(work.count) analysed"
                    if Date().timeIntervalSince(lastBump) > 2 {
                        lastBump = Date()
                        self.revision += 1
                    }
                    if await !next(), Task.isCancelled {
                        break
                    }
                }
            }
            progress = nil
            if !Task.isCancelled, deletions == 0 {
                let pruned = await store.pruneOrphans()
                await faces?.remove(pruned.faceKeys)
                await images?.remove(pruned.sha256s)
                if !pruned.faceKeys.isEmpty { await refreshPeople() }
            }
            analysedCount = await store.fileCount()
            revision += 1
            finishJob(cancelled: Task.isCancelled)
            if newFaces > 0 || (wantFaces && people.isEmpty) {
                await regroupFaces(full: false)
            }
            isRunning = false
            if rescanRequested {
                rescanRequested = false
                schedule(after: .seconds(1))
            }
        }
    }

    /// Files that need analysing (new, changed, analysed by an older version, or not yet checked for people), and paths gone from disk.
    @concurrent
    private static func findWork(folders: [URL], store: AnalysisStore, wantFaces: Bool, embeddings: Bool,
                                 noPicture: Set<String>, keep: [String], holding: [String]) async -> ([Work], [String])
    {
        var files: [Work] = []
        for folder in folders {
            for url in FolderOperations.mediaFiles(in: folder, recursive: true) {
                // Audio is analysed for its facts only (R-4205).
                guard let format = MediaFormat.fromExtension(url.pathExtension), [.image, .video, .audio].contains(format.kind),
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                files.append(Work(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
        }
        let paths = files.map(\.url.path)
        let states = await store.states(for: paths)
        var work: [Work] = []
        // A file kept only in iCloud is on the list (so it is not taken for deleted) but not read: reading downloads it.
        for file in files where !FileFlags.isDataless(file.url) {
            guard let state = states[file.url.path], state.size == file.size, abs(state.modified.timeIntervalSince(file.modified)) < 1,
                  state.version == AnalysisRecord.currentVersion else { work.append(file); continue }
            if (state.factsVersion ?? 0) < AnalysisRecord.currentFactsVersion {
                var refresh = file
                refresh.factsOnly = true
                work.append(refresh)
                continue
            }
            if (wantFaces && state.peopleChecked == false && state.hasFaces == true) ||
                (embeddings && state.hasEmbedding == false && !noPicture.contains(file.url.path))
            {
                work.append(file)
            }
        }
        // Paths the store knows that are no longer on disk. A folder that cannot be listed (an ejected disk, a folder
        // privacy settings block) proves nothing, so its paths are kept. Outside every scanned folder, only recent Organise
        // folders are remembered (to open again quickly): anything else, a folder removed from the library, is forgotten
        // with its faces (SPEC 6.3, D-61); recent folders' paths are kept while their disk is not mounted.
        let fm = FileManager.default
        let reachable = folders.filter { fm.isReadableFile(atPath: $0.path) }
        let unreachable = folders.filter { !fm.isReadableFile(atPath: $0.path) }
        let known = await store.allPaths().keys
        let onDisk = Set(paths)
        let gone = known.filter { path in
            guard !onDisk.contains(path) else { return false }
            if reachable.contains(where: { path.hasPrefix($0.path + "/") }) { return true }
            if unreachable.contains(where: { path.hasPrefix($0.path + "/") }) { return false }
            if holding.contains(where: { path.hasPrefix($0 + "/") }) { return false }
            guard keep.contains(where: { path.hasPrefix($0 + "/") }) else { return true }
            return Self.isGoneOutsideScan(path)
        }
        return (work, Array(gone))
    }

    /// Analyses one file, or only records its path when the same content was analysed before. Returns the faces added.
    @concurrent
    private static func process(_ item: Work, analyzer: Analyzer, store: AnalysisStore, images: VectorStore?, faces: VectorStore?,
                                wantFaces: Bool) async -> (faces: Int, noPicture: Bool)
    {
        guard let sha = try? FileHasher.sha256(of: item.url) else { return (0, false) }
        let existing = await store.record(sha256: sha)
        if let existing, existing.version == AnalysisRecord.currentVersion,
           (existing.factsVersion ?? 0) < AnalysisRecord.currentFactsVersion,
           item.factsOnly || (existing.hasEmbedding || images == nil)
        {
            // Facts read an older way are read again; the models' results stay (R-4210).
            await store.save(await analyzer.refreshFacts(item.url, record: existing))
            await store.setPath(item.url.path, sha256: sha, size: item.size, modified: item.modified)
            if item.factsOnly { return (0, false) }
        }
        if let existing = await store.record(sha256: sha), existing.version == AnalysisRecord.currentVersion,
           !(wantFaces && !existing.peopleChecked && !existing.faces.isEmpty), existing.hasEmbedding || images == nil
            || existing.facts.format?.kind == .audio
        {
            await store.setPath(item.url.path, sha256: sha, size: item.size, modified: item.modified)
            return (0, false)
        }
        let output = await analyzer.analyse(item.url, sha256: sha, recogniseFaces: wantFaces)
        var record = output.record
        record.peopleChecked = wantFaces
        if let embedding = output.embedding, let images {
            await images.put(sha, embedding)
        }
        var added: [NewFace] = []
        if let faces {
            for face in output.faces {
                guard let row = await faces.put("\(sha)|\(face.key)", face.embedding) else { continue }
                added.append(NewFace(key: face.key, vectorRow: row, quality: face.box.quality ?? 0.5, pixelSize: face.box.pixelSize))
            }
        }
        // Faces first and the record last: a record saying people were checked must never exist without its faces,
        // or a quit in between would skip the file for good.
        if !added.isEmpty {
            await store.addFaces(added, sha256: sha)
        }
        await store.setPath(item.url.path, sha256: sha, size: item.size, modified: item.modified)
        await store.save(record)
        return (added.count, images != nil && output.embedding == nil)
    }

    /// Waits while analysis is paused by the person, by Low Power Mode, by heat or (if set) by running on battery (R-3603).
    private func waitWhilePaused() async {
        while !Task.isCancelled {
            let reason: String? = if userPaused {
                "Paused"
            } else if ProcessInfo.processInfo.isLowPowerModeEnabled {
                "Paused in Low Power Mode"
            } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                "Paused while the Mac is hot"
            } else if preferences.analysisPauseOnBattery, Self.onBattery() {
                "Paused on battery"
            } else {
                nil
            }
            pauseReason = reason
            if let job {
                job.state = reason == nil ? .running : .paused
            }
            guard reason != nil else { return }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    private func beginJob(total: Int) {
        let job = Job(kind: .analyse, title: "Analysing library media")
        job.total = total
        job.state = .running
        job.summaryOverride = "0 of \(total) analysed"
        job.pauseToggle = { [weak self] in
            guard let self else { return }
            setPaused(!userPaused)
        }
        app.jobs.add(job)
        self.job = job
    }

    private func finishJob(cancelled: Bool) {
        guard let job else { return }
        app.jobs.finish(job, cancelled ? .cancelled : .completed)
        self.job = nil
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: Answers for the views

    /// Adds analysis results to listed files.
    func attach(_ entries: [MediaEntry]) async -> [MediaEntry] {
        guard let store, !entries.isEmpty else { return entries }
        let records = await store.records(for: entries.map(\.path))
        return entries.map { entry in
            var e = entry
            e.record = records[entry.path]
            return e
        }
    }

    /// Similarity of each file to a free-text query (R-3704).
    func meaningScores(_ query: String, entries: [MediaEntry]) async -> [String: Float] {
        guard let analyzer, let imageVectors, analyzer.imageText != nil, query.count >= 2 else { return [:] }
        let text = await Task.detached(priority: .userInitiated) { analyzer.embed(text: query) }.value
        guard let text else { return [:] }
        let shas = entries.compactMap { e in e.record.map { (e.path, $0.sha256) } }
        let scores = await imageVectors.similarities(to: text, keys: shas.map(\.1))
        return Dictionary(shas.compactMap { path, sha in scores[sha].map { (path, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The minimum similarity for a free-text match, and how far below the best match results may fall (benchmark: the best
    /// match for a query scores about 0.3, unrelated photos about 0.1; D-67).
    static let meaningFloor: Float = 0.16
    static let meaningSpread: Float = 0.06

    static func floor(for scores: [String: Float]) -> Float {
        max(meaningFloor, (scores.values.max() ?? 0) - meaningSpread)
    }

    /// How close two embeddings must be to form a visually similar set (R-3705). In the benchmark one unrelated photo in
    /// a hundred had a neighbour above 0.93 in 3,000 photos, so sets start at 0.92.
    static let similarThreshold: Float = 0.92

    func similarGroups(_ entries: [MediaEntry]) async -> [String: Int] {
        guard let imageVectors else { return [:] }
        var paths: [String] = []
        var vectors: [[Float]] = []
        for entry in entries.prefix(20000) {
            guard let sha = entry.record?.sha256, let vector = await imageVectors.vector(sha) else { continue }
            paths.append(entry.path)
            vectors.append(vector)
        }
        let threshold = Self.similarThreshold
        let groups = await Task.detached(priority: .userInitiated) { SimilarSets.groups(vectors, threshold: threshold) }.value
        var out: [String: Int] = [:]
        for (i, group) in groups.enumerated() {
            if let group {
                out[paths[i]] = group
            }
        }
        return out
    }

    /// The people recognised in each file.
    func peopleByPath(_ entries: [MediaEntry]) async -> [String: Set<UUID>] {
        guard let store, preferences.facesEnabled else { return [:] }
        let bySha = await store.peopleBySha()
        var out: [String: Set<UUID>] = [:]
        for entry in entries {
            if let sha = entry.record?.sha256, let ids = bySha[sha] {
                out[entry.path] = Set(ids)
            }
        }
        return out
    }

    /// The best subject for each file with its confidence (R-3706).
    /// Audio files under `root` with their stream hash, for "Same audio" duplicates (R-4205).
    func audioStreamHashes(under root: URL) async -> [String: String] {
        guard let store else { return [:] }
        let prefix = root.standardizedFileURL.path + "/"
        let audio = await store.allPaths().keys.filter {
            $0.hasPrefix(prefix) && MediaFormat.fromExtension(($0 as NSString).pathExtension)?.kind == .audio
        }
        guard !audio.isEmpty else { return [:] }
        return await store.records(for: Array(audio)).compactMapValues { $0.facts.audio?.streamHash }
    }

    func subjects(for entries: [MediaEntry]) async -> [String: (String, Float)] {
        guard let analyzer, let encoder = analyzer.imageText, let imageVectors else { return [:] }
        let custom = preferences.customSubjects
        if subjectClassifier == nil || subjectsKey != custom {
            subjectClassifier = await Task.detached(priority: .userInitiated) { SubjectClassifier(encoder: encoder, custom: custom) }.value
            subjectsKey = custom
        }
        guard let classifier = subjectClassifier else { return [:] }
        var out: [String: (String, Float)] = [:]
        for entry in entries {
            guard let sha = entry.record?.sha256, let vector = await imageVectors.vector(sha),
                  let result = classifier.classify(vector) else { continue }
            out[entry.path] = result
        }
        return out
    }

    /// Keeps results pointing at files that moved (R-3804).
    func noteMoves(_ moves: [(from: String, to: String)]) async {
        guard let store else {
            waitingMoves += moves
            return
        }
        let previous = movesApplied
        let task = Task {
            await previous?.value
            await store.movePaths(moves)
        }
        movesApplied = task
        await task.value
        revision += 1
    }

    // MARK: People (section 39)

    /// Regroups faces. Runs one at a time (scan end, Regroup and a Matching change can overlap), and a result worked out
    /// from faces that changed meanwhile (a correction, new faces, a deletion) is thrown away and worked out again.
    func regroupFaces(full: Bool) async {
        let previous = regroupTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRegroup(full: full)
        }
        regroupTask = task
        await task.value
    }

    private func performRegroup(full: Bool) async {
        for _ in 0 ..< 3 {
            guard let store, let faceVectors, preferences.facesEnabled else { return }
            let faces = await store.faces()
            let named = await Set(store.people().filter { $0.name != nil }.map(\.id))
            var input: [FaceGrouping.Face] = []
            for face in faces {
                // By key, not row: rows move when vectors of deleted files are removed.
                guard let vector = await faceVectors.vector(face.key) else { continue }
                input.append(FaceGrouping.Face(
                    key: face.key,
                    vector: vector,
                    quality: face.quality,
                    personID: face.personID,
                    pinned: face.pinned,
                    rejected: Set(face.rejected)
                ))
            }
            let threshold = faceThreshold
            let changes = await Task.detached(priority: .utility) {
                FaceGrouping.group(input, threshold: threshold, minimumGroup: 2, regroup: full, named: named)
            }.value
            if changes.isEmpty || !preferences.facesEnabled {
                break
            }
            if await store.applyAssignments(changes, ifUnchangedSince: faces) {
                break
            }
        }
        await refreshPeople()
    }

    func refreshPeople() async {
        guard let store else { return }
        people = await store.people()
        peopleRevision += 1
        forgetUnknownPeople()
        await refreshSuggestions()
    }

    /// People merged, regrouped or deleted no longer exist: filters naming them would show nothing and could not be
    /// unticked, so they are dropped from every pane's query (R-3703).
    func forgetUnknownPeople() {
        let known = preferences.facesEnabled ? Set(people.map(\.id)) : []
        for window in app.windows {
            for query in [\WindowModel.library.query, \WindowModel.organise.source.query, \WindowModel.organise.target.query]
                where !window[keyPath: query].filter.people.isSubset(of: known)
            {
                window[keyPath: query].filter.people.formIntersection(known)
            }
        }
    }

    /// Folder-name suggestions for unnamed people (R-3905).
    private func refreshSuggestions() async {
        guard let store, preferences.facesEnabled else { suggestions = [:]; return }
        let unnamed = people.filter { $0.name == nil }
        guard !unnamed.isEmpty else { suggestions = [:]; return }
        let paths = await store.allPaths()
        let peopleBySha = await store.peopleBySha()
        let accounts = Set(app.engines.accounts.keys.map { $0.lowercased() })
        // Folders MediaPull knows hold an account, whatever they are called (D-78): never a person's name (R-3905).
        let accountFolders = app.accountFolderList.map(\.path)
        // Thousands of paths and folder checks: worked out off the main actor (R-3905).
        suggestions = await Task.detached(priority: .utility) {
            Self.suggestNames(unnamed: unnamed, paths: paths, peopleBySha: peopleBySha, accounts: accounts,
                              accountFolders: accountFolders)
        }.value
    }

    nonisolated private static func suggestNames(
        unnamed: [PersonInfo],
        paths: [String: String],
        peopleBySha: [String: [UUID]],
        accounts: Set<String>,
        accountFolders: [String] = []
    ) -> [UUID: String]
    {
        let pathsBySha = Dictionary(grouping: paths, by: \.value).mapValues { $0.map(\.key) }
        var folderCounts: [String: Int] = [:]
        var photosByPerson: [UUID: [String]] = [:]
        for (sha, ids) in peopleBySha {
            for path in pathsBySha[sha] ?? [] {
                for id in ids {
                    photosByPerson[id, default: []].append(path)
                }
                var folder = (path as NSString).deletingLastPathComponent
                for _ in 0 ..< 3 where folder.count > 1 {
                    folderCounts[folder, default: 0] += 1
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
        }
        // Each folder is checked once, however many photos are in it.
        var isAccountFolder: [String: Bool] = [:]
        func accountFolder(_ folder: String) -> Bool {
            if let known = isAccountFolder[folder] { return known }
            let name = (folder as NSString).lastPathComponent.lowercased()
            let types = ["posts", "reels", "stories", "highlights", "tagged", "reposts", "profile pictures"]
            let found = accounts.contains(name) || accountFolders.contains { folder == $0 || folder.hasPrefix($0 + "/") }
                || types.contains { child in FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(child)) }
            isAccountFolder[folder] = found
            return found
        }
        var result: [UUID: String] = [:]
        for person in unnamed {
            let photos = photosByPerson[person.id] ?? []
            var accountFolders = Set<String>()
            for path in photos {
                var folder = (path as NSString).deletingLastPathComponent
                for _ in 0 ..< 3 where folder.count > 1 {
                    if accountFolder(folder) { accountFolders.insert(folder) }
                    folder = (folder as NSString).deletingLastPathComponent
                }
            }
            if let name = NameSuggestion.suggest(personPhotos: photos, peoplePhotosByFolder: folderCounts, accountFolders: accountFolders),
               name != person.dismissedSuggestion
            {
                result[person.id] = name
            }
        }
        return result
    }

    func rename(_ person: UUID, to name: String?) async {
        await store?.rename(person: person, to: name)
        await refreshPeople()
    }

    /// A named person with no photos left is removed from the People list (audit 4, B4-m9).
    func forget(_ person: UUID) async {
        await store?.forget(person: person)
        await refreshPeople()
    }

    func dismissSuggestion(_ person: UUID) async {
        guard let name = suggestions[person] else { return }
        await store?.dismissSuggestion(person: person, name: name)
        await refreshPeople()
    }

    func merge(_ other: UUID, into target: UUID) async {
        await store?.merge(other, into: target)
        await refreshPeople()
    }

    func split(_ faceKeys: [String], from person: UUID) async {
        _ = await store?.split(faceKeys: faceKeys, from: person)
        await refreshPeople()
    }

    func notThisPerson(_ faceKeys: [String], person: UUID) async {
        await store?.reject(faceKeys: faceKeys, from: person)
        await refreshPeople()
    }

    /// Faces of one person with the paths of their files, for the People view.
    /// `limit`: a person's row needs only one face, so it does not read every record of every face.
    func faces(of person: UUID, limit: Int = .max) async -> [(key: String, path: String, box: FaceBox?)] {
        guard let store else { return [] }
        // On the store's actor, not the main one: only this person's faces and their paths are read.
        return await store.faceExamples(of: person, limit: limit)
    }

    /// Turns recognising people on, after the opt-in sheet (D-61).
    func enableFaces() {
        preferences.facesEnabled = true
        schedule(after: .milliseconds(200))
    }

    /// Stops the scan and waits for the files it is analysing, which would otherwise write records, face vectors and faces
    /// after the data they belong to was deleted (D-61). No scan starts until the deletion ends.
    private func stopScanForDeletion() async {
        deletions += 1
        // A load still reading vector files would otherwise hand them back after they were deleted.
        await loadTask?.value
        scheduled?.cancel()
        scanTask?.cancel()
        await scanTask?.value
    }

    /// Delete All Face Data: faces, people, names, corrections and face vectors, in one step (D-61).
    func deleteAllFaceData(turnOff: Bool = true) async {
        if turnOff {
            preferences.facesEnabled = false
        }
        await stopScanForDeletion()
        await store?.deleteAllFaceData()
        await faceVectors?.deleteAll()
        // Every face vector file, including those of an earlier face model or ones no store has loaded (D-61).
        await Self.removeVectorFiles(prefix: "faces-", in: vectorFolder)
        await Self.removeSetAsideStores(in: Self.folder)
        deletions -= 1
        // Files are checked for people again only after a new opt-in.
        people = []
        suggestions = [:]
        peopleRevision += 1
        forgetUnknownPeople()
    }

    /// Delete All Analysis Data: everything in the Analysis folder.
    func deleteAllAnalysis() async {
        await stopScanForDeletion()
        await store?.deleteAll()
        await imageVectors?.deleteAll()
        await faceVectors?.deleteAll()
        await Self.removeVectorFiles(prefix: "faces-", in: vectorFolder)
        await Self.removeVectorFiles(prefix: "image-", in: vectorFolder)
        await Self.removeSetAsideStores(in: Self.folder)
        deletions -= 1
        people = []
        suggestions = [:]
        analysedCount = 0
        revision += 1
        peopleRevision += 1
        forgetUnknownPeople()
    }

    /// Analyse Again: every file is analysed again from scratch. People, names and corrections are kept (faces found
    /// again keep their keys and so their person); only results and image embeddings are dropped.
    func analyseAgain() async {
        await stopScanForDeletion()
        await store?.deleteResults()
        await imageVectors?.deleteAll()
        deletions -= 1
        analysedCount = 0
        revision += 1
        schedule(after: .milliseconds(200))
    }

    /// The vector files with this prefix (for self-tests).
    func vectorFileNames(prefix: String) -> [String] {
        // lint:allow main-io self-test check of a small folder
        ((try? FileManager.default.contentsOfDirectory(atPath: vectorFolder.path)) ?? []).filter { $0.hasPrefix(prefix) }
    }

    /// What a query needs besides the files themselves: similarity to the search, visually similar sets and the people in
    /// each file. One place for the Library, Organise and folders opened in a list, so every view filters alike. The
    /// search is debounced by the caller; nil when the work was cancelled.
    func queryContext(for query: LibraryQuery, entries: [MediaEntry]) async -> LibraryQuery.Context {
        var context = LibraryQuery.Context(similarityFloor: Self.meaningFloor)
        if !query.search.trimmingCharacters(in: .whitespaces).isEmpty {
            context.similarity = await meaningScores(query.search, entries: entries)
            context.similarityFloor = Self.floor(for: context.similarity)
        }
        if query.sort == .similar || query.filter.similarOnly { context.similarGroups = await similarGroups(entries) }
        if !query.filter.people.isEmpty { context.people = await peopleByPath(entries) }
        return context
    }

    /// Opens the analysis database. One that cannot be opened (damaged, or from a newer version) is set aside and a new
    /// one started, so analysis never stops silently; its results can be made again, while face names and corrections
    /// stay in the set-aside copy.
    private static func openStore(inMemory: Bool, report: @escaping (String) -> Void) -> AnalysisStore? {
        if inMemory { return try? AnalysisStore.make(folder: nil) }
        do {
            return try AnalysisStore.make(folder: folder)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let fm = FileManager.default
            // lint:allow main-io a few database files, once, at launch after a failure
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix("Analysis.store") {
                // lint:allow silent-write app-data best effort, a few files once after a failure; a fresh database matters
                try? fm.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent("\(name).damaged-\(stamp)"))
            }
            do {
                let store = try AnalysisStore.make(folder: folder)
                report("The analysis database could not be opened (\(error.localizedDescription)). It was set aside and "
                    + "analysis started again; names given to people are in the set-aside copy.")
                return store
            } catch {
                report("Analysis is off: its database could not be opened (\(error.localizedDescription)).")
                return nil
            }
        }
    }

    /// A path outside the scanned folders is gone only when its disk is mounted and the file is missing.
    nonisolated static func isGoneOutsideScan(_ path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.first == "Volumes", parts.count > 1 {
            return fm.fileExists(atPath: "/Volumes/\(parts[1])")
        }
        return true
    }

    /// Removes vector files of other models than the ones in use. Only when the models loaded: without them, nothing is
    /// known to be replaced.
    nonisolated static func removeOtherVectorFiles(in folder: URL, keeping: [String], modelsLoaded: Bool) {
        guard modelsLoaded else { return }
        let fm = FileManager.default
        // lint:allow main-io called only from the detached task that loads the models
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let vectorFiles = names.filter {
            ($0.hasPrefix("image-") || $0.hasPrefix("faces-")) && ($0.hasSuffix(".vec") || $0.hasSuffix(".ids"))
        }
        for name in vectorFiles {
            let base = (name as NSString).deletingPathExtension
            guard !keeping.contains(base) else { continue }
            // Face vectors of an earlier model go only when face recognition has a model now; image ones likewise.
            if base.hasPrefix("faces-"), !keeping.contains(where: { $0.hasPrefix("faces-") }) { continue }
            if base.hasPrefix("image-"), !keeping.contains(where: { $0.hasPrefix("image-") }) { continue }
            // lint:allow silent-write a vector file that stays is only taken up again by Delete All
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Removes `<prefix>*.vec` and `.ids` files, whichever model wrote them.
    @concurrent
    nonisolated static func removeVectorFiles(prefix: String, in folder: URL) async {
        let fm = FileManager.default
        // lint:allow main-io runs off the main actor (@concurrent)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && (name.hasSuffix(".vec") || name.hasSuffix(".ids")) {
            // lint:allow silent-write a file that is already gone needs no report; one that stays is caught by the test
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Database copies set aside after a failure to open (openStore) hold faces, people and names too: deleting the data
    /// deletes them (D-61).
    @concurrent
    nonisolated static func removeSetAsideStores(in folder: URL) async {
        let fm = FileManager.default
        // lint:allow main-io runs off the main actor (@concurrent)
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("Analysis.store") && name.contains(".damaged-") {
            // lint:allow silent-write a file that is already gone needs no report
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
