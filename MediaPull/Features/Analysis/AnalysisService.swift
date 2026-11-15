import Foundation
import IOKit.ps
import MediaPullAnalysis
import MediaPullCore
import MediaPullEngines
import MediaPullLibrary
import MediaPullNet
import MediaPullStore
import Observation

/// Analyses library folders in the background and answers the Library, Organise and People views (SPEC sections 36 to 39).
@Observable
final class AnalysisService {
    /// Bumped when new results arrive, at most every couple of seconds.
    var revision = 0
    var peopleRevision = 0
    var progress: (done: Int, total: Int)?
    var pauseReason: String?
    var userPaused = false
    var isRunning = false
    var people: [PersonInfo] = []
    /// Names suggested from folder names, per unnamed person (R-3905).
    var suggestions: [UUID: String] = [:]
    private(set) var analysedCount = 0
    private(set) var modelsLoaded = false

    @ObservationIgnored private(set) var store: AnalysisStore?
    @ObservationIgnored private var analyzer: Analyzer?
    @ObservationIgnored private var imageVectors: VectorStore?
    @ObservationIgnored private var faceVectors: VectorStore?
    @ObservationIgnored private var subjects: SubjectClassifier?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
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

    var canSearchByMeaning: Bool {
        analyzer?.imageText != nil
    }

    // MARK: Start

    func start(inMemory: Bool = false) {
        guard store == nil else { return }
        store = try? AnalysisStore.make(folder: inMemory ? nil : Self.folder)
        // Self-tests keep their vectors out of the real Analysis folder.
        let folder = inMemory ? FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaPull-selftest-analysis-\(UUID().uuidString)")
            : Self.folder
        Task {
            let models = Self.modelsFolder
            let loaded = await Task.detached(priority: .utility) { Analyzer(modelsFolder: models) }.value
            analyzer = loaded
            if let dim = loaded.imageText?.dimension, let id = loaded.imageText?.spec.id {
                imageVectors = VectorStore(folder: folder, name: "image-\(id)", dimension: dim)
            }
            if let face = loaded.faceEncoder?.spec {
                faceVectors = VectorStore(folder: folder, name: "faces-\(face.id)", dimension: face.dimension, excludeFromBackup: true)
            }
            modelsLoaded = true
            analysedCount = await store?.fileCount() ?? 0
            await refreshPeople()
            updateWatch()
            schedule(after: .seconds(3))
        }
    }

    func updateWatch() {
        watcher.watch(scanFolders.map(\.path))
    }

    /// Library roots (minus those excluded in Settings) and folders open in Organise.
    var scanFolders: [URL] {
        let roots = app.roots.compactMap { $0.resolvedURL()?.url }.filter { !preferences.analysisExcludedRoots.contains($0.path) }
        return roots + extraFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter { folder in !roots.contains { folder.path.hasPrefix($0.path + "/") || folder.path == $0.path } }
    }

    private func foldersChanged(_ paths: [String]) {
        for listener in onFolderChange.values {
            listener(paths)
        }
        schedule(after: .seconds(4))
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

    private struct Work: Sendable {
        var url: URL
        var size: Int64
        var modified: Date
    }

    private func runScan() {
        guard let store, let analyzer else { return }
        isRunning = true
        let folders = scanFolders
        let wantFaces = preferences.facesEnabled && analyzer.faceEncoder != nil
        let images = imageVectors, faces = faceVectors
        scanTask = Task { [weak self] in
            let (work, gone) = await Self.findWork(folders: folders, store: store, wantFaces: wantFaces, embeddings: images != nil)
            await store.forget(paths: gone)
            guard let self else { return }
            if !work.isEmpty {
                beginJob(total: work.count)
                job?.task = scanTask
            }
            var done = 0
            var newFaces = 0
            var lastBump = Date()
            var iterator = work.makeIterator()
            await withTaskGroup(of: Int.self) { group in
                func next() async -> Bool {
                    guard let item = iterator.next() else { return false }
                    await self.waitWhilePaused()
                    if Task.isCancelled {
                        return false
                    }
                    // Utility, not background: background priority was throttled about tenfold in the benchmark.
                    group.addTask(priority: .utility) {
                        await Self.process(item, analyzer: analyzer, store: store, images: images, faces: faces, wantFaces: wantFaces)
                    }
                    return true
                }
                for _ in 0 ..< 2 {
                    _ = await next()
                }
                while let added = await group.next() {
                    done += 1
                    newFaces += added
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
    private static func findWork(folders: [URL], store: AnalysisStore, wantFaces: Bool, embeddings: Bool) async -> ([Work], [String]) {
        var files: [Work] = []
        for folder in folders {
            for url in FolderOperations.mediaFiles(in: folder, recursive: true) {
                guard let format = MediaFormat.fromExtension(url.pathExtension), [.image, .video].contains(format.kind) || format == .gif,
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
                files.append(Work(url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
        }
        let paths = files.map(\.url.path)
        let states = await store.states(for: paths)
        var work: [Work] = []
        for file in files {
            guard let state = states[file.url.path], state.size == file.size, abs(state.modified.timeIntervalSince(file.modified)) < 1,
                  state.version == AnalysisRecord.currentVersion else { work.append(file); continue }
            if wantFaces || embeddings, let record = await store.record(sha256: state.sha256) {
                if (wantFaces && !record.peopleChecked && !record.faces.isEmpty) ||
                    (embeddings && !record.hasEmbedding)
                {
                    work.append(file)
                }
            }
        }
        // Paths the store knows below these folders that are no longer on disk.
        let known = await store.allPaths().keys
        let onDisk = Set(paths)
        let gone = known.filter { path in !onDisk.contains(path) && folders.contains { path.hasPrefix($0.path + "/") } }
        return (work, Array(gone))
    }

    /// Analyses one file, or only records its path when the same content was analysed before. Returns the faces added.
    @concurrent
    private static func process(_ item: Work, analyzer: Analyzer, store: AnalysisStore, images: VectorStore?, faces: VectorStore?,
                                wantFaces: Bool) async -> Int
    {
        guard let sha = try? FileHasher.sha256(of: item.url) else { return 0 }
        if let existing = await store.record(sha256: sha), existing.version == AnalysisRecord.currentVersion,
           !(wantFaces && !existing.peopleChecked && !existing.faces.isEmpty), existing.hasEmbedding || images == nil
        {
            await store.setPath(item.url.path, sha256: sha, size: item.size, modified: item.modified)
            return 0
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
                let row = await faces.put("\(sha)|\(face.key)", face.embedding)
                added.append(NewFace(key: face.key, vectorRow: row, quality: face.box.quality ?? 0.5, pixelSize: face.box.pixelSize))
            }
        }
        await store.save(record)
        await store.setPath(item.url.path, sha256: sha, size: item.size, modified: item.modified)
        if !added.isEmpty {
            await store.addFaces(added, sha256: sha)
        }
        return added.count
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
    func subjects(for entries: [MediaEntry]) async -> [String: (String, Float)] {
        guard let analyzer, let encoder = analyzer.imageText, let imageVectors else { return [:] }
        let custom = preferences.customSubjects
        if subjects == nil || subjects?.names.count != SubjectClassifier.standard.count + custom.count {
            subjects = await Task.detached(priority: .userInitiated) { SubjectClassifier(encoder: encoder, custom: custom) }.value
        }
        guard let classifier = subjects else { return [:] }
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
        await store?.movePaths(moves)
        revision += 1
    }

    // MARK: People (section 39)

    func regroupFaces(full: Bool) async {
        guard let store, let faceVectors, preferences.facesEnabled else { return }
        let faces = await store.faces()
        let named = Set(people.filter { $0.name != nil }.map(\.id))
        var input: [FaceGrouping.Face] = []
        for face in faces {
            guard let vector = await faceVectors.vector(row: face.vectorRow) else { continue }
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
        if !changes.isEmpty {
            await store.applyAssignments(changes)
        }
        await refreshPeople()
    }

    func refreshPeople() async {
        guard let store else { return }
        people = await store.people()
        peopleRevision += 1
        await refreshSuggestions()
    }

    /// Folder-name suggestions for unnamed people (R-3905).
    private func refreshSuggestions() async {
        guard let store, preferences.facesEnabled else { suggestions = [:]; return }
        let unnamed = people.filter { $0.name == nil }
        guard !unnamed.isEmpty else { suggestions = [:]; return }
        let pathsBySha = await Dictionary(grouping: store.allPaths(), by: \.value).mapValues { $0.map(\.key) }
        let peopleBySha = await store.peopleBySha()
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
        let accounts = Set(app.engines.accounts.keys.map { $0.lowercased() })
        var result: [UUID: String] = [:]
        for person in unnamed {
            let photos = photosByPerson[person.id] ?? []
            let accountFolders = Set(photos.flatMap { path -> [String] in
                var out: [String] = []
                var folder = (path as NSString).deletingLastPathComponent
                for _ in 0 ..< 3 where folder.count > 1 {
                    let name = (folder as NSString).lastPathComponent.lowercased()
                    let typeFolder = ["posts", "reels", "stories", "highlights", "tagged"].contains { child in
                        FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(child))
                    }
                    if accounts.contains(name) || typeFolder {
                        out.append(folder)
                    }
                    folder = (folder as NSString).deletingLastPathComponent
                }
                return out
            })
            if let name = NameSuggestion.suggest(personPhotos: photos, peoplePhotosByFolder: folderCounts, accountFolders: accountFolders),
               name != person.dismissedSuggestion
            {
                result[person.id] = name
            }
        }
        suggestions = result
    }

    func rename(_ person: UUID, to name: String?) async {
        await store?.rename(person: person, to: name)
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
    func faces(of person: UUID) async -> [(key: String, path: String, box: FaceBox?)] {
        guard let store else { return [] }
        let faces = await store.faces().filter { $0.personID == person }
        let paths = await Dictionary(grouping: store.allPaths(), by: \.value).mapValues { $0.map(\.key).sorted() }
        var out: [(String, String, FaceBox?)] = []
        for face in faces {
            guard let path = paths[face.sha256]?.first else { continue }
            let record = await store.record(sha256: face.sha256)
            let faceKey = String(face.key.split(separator: "|").last ?? "")
            out.append((face.key, path, record?.faces.first { $0.key == faceKey }))
        }
        return out.map { (key: $0.0, path: $0.1, box: $0.2) }
    }

    /// Turns recognising people on, after the opt-in sheet (D-61).
    func enableFaces() {
        preferences.facesEnabled = true
        schedule(after: .milliseconds(200))
    }

    /// Delete All Face Data: faces, people, names, corrections and face vectors, in one step (D-61).
    func deleteAllFaceData(turnOff: Bool = true) async {
        if turnOff {
            preferences.facesEnabled = false
        }
        cancelScan()
        await store?.deleteAllFaceData()
        await faceVectors?.deleteAll()
        // Files are checked for people again only after a new opt-in.
        people = []
        suggestions = [:]
        peopleRevision += 1
    }

    /// Delete All Analysis Data: everything in the Analysis folder.
    func deleteAllAnalysis() async {
        cancelScan()
        await store?.deleteAll()
        await imageVectors?.deleteAll()
        await faceVectors?.deleteAll()
        people = []
        suggestions = [:]
        analysedCount = 0
        revision += 1
        peopleRevision += 1
    }
}
