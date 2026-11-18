import Foundation
import MediaPullCore
import SwiftData

// MARK: Models (versioned schema, SPEC 6.2)

public enum StoreSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] {
        [LibraryRootModel.self, InstagramAccountModel.self, ArchiveEntryModel.self, JobRecordModel.self]
    }

    @Model
    public final class LibraryRootModel {
        @Attribute(.unique) public var id: UUID
        public var name: String
        public var path: String
        public var bookmark: Data
        public var layout: String
        public var isDefault: Bool
        public var createdAt: Date
        public var sortIndex: Int

        public init(id: UUID, name: String, path: String, bookmark: Data, layout: String, isDefault: Bool, sortIndex: Int) {
            self.id = id
            self.name = name
            self.path = path
            self.bookmark = bookmark
            self.layout = layout
            self.isDefault = isDefault
            createdAt = Date()
            self.sortIndex = sortIndex
        }
    }

    @Model
    public final class InstagramAccountModel {
        @Attribute(.unique) public var username: String
        public var userID: String
        public var fullName: String
        public var optionsJSON: Data
        public var newestSavedDate: Date
        public var resumeCursor: String
        public var lastPullAt: Date
        public var lastResult: String

        public init(username: String) {
            self.username = username
            userID = ""
            fullName = ""
            optionsJSON = Data()
            newestSavedDate = .distantPast
            resumeCursor = ""
            lastPullAt = .distantPast
            lastResult = ""
        }
    }

    @Model
    public final class ArchiveEntryModel {
        @Attribute(.unique) public var key: String
        public var account: String
        public var path: String
        public var sha256: String
        public var savedAt: Date

        public init(key: String, account: String, path: String, sha256: String) {
            self.key = key
            self.account = account
            self.path = path
            self.sha256 = sha256
            savedAt = Date()
        }
    }

    @Model
    public final class JobRecordModel {
        @Attribute(.unique) public var id: UUID
        public var kind: String
        public var title: String
        public var status: String
        public var summary: String
        public var startedAt: Date
        public var finishedAt: Date

        public init(id: UUID, kind: String, title: String, status: String, summary: String, startedAt: Date, finishedAt: Date) {
            self.id = id
            self.kind = kind
            self.title = title
            self.status = status
            self.summary = summary
            self.startedAt = startedAt
            self.finishedAt = finishedAt
        }
    }
}

public typealias LibraryRootModel = StoreSchemaV1.LibraryRootModel
public typealias InstagramAccountModel = StoreSchemaV1.InstagramAccountModel
public typealias ArchiveEntryModel = StoreSchemaV1.ArchiveEntryModel
public typealias JobRecordModel = StoreSchemaV1.JobRecordModel

public enum StoreMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [StoreSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: Sendable values

public struct LibraryRootInfo: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data
    public var layout: SaveLayout
    public var isDefault: Bool

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// The folder this root points at, following the bookmark if the folder moved.
    public func resolvedURL() -> (url: URL, stale: Bool)? {
        var stale = false
        // Never mounts a network volume or shows a prompt: this runs at launch and whenever the app comes forward.
        if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
        {
            return (url, stale)
        }
        if FileManager.default.fileExists(atPath: path) { return (url, false) }
        return nil
    }
}

public struct InstagramAccountInfo: Sendable, Equatable {
    public var username: String
    public var userID: String
    public var fullName: String
    public var options: PullOptions?
    public var newestSavedDate: Date?
    public var resumeCursor: String?
    public var lastPullAt: Date?
    public var lastResult: String
}

public struct PullOptions: Codable, Sendable, Equatable {
    public var content: Set<InstagramContent>
    /// No longer read: the save folder decides the layout (D-70). Kept, and still written, so options stored by
    /// earlier versions decode and earlier versions can read new ones.
    public var layout: SaveLayout
    public var rootID: UUID?
    public var pacing: PacingPreset

    public init(content: Set<InstagramContent>, layout: SaveLayout = .archive, rootID: UUID?, pacing: PacingPreset) {
        self.content = content
        self.layout = layout
        self.rootID = rootID
        self.pacing = pacing
    }
}

public struct JobRecordInfo: Identifiable, Sendable {
    public var id: UUID
    public var kind: String
    public var title: String
    public var status: String
    public var summary: String
    public var startedAt: Date
    public var finishedAt: Date

    public init(id: UUID, kind: String, title: String, status: String, summary: String, startedAt: Date, finishedAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

/// Recorded moves applied in order to stored paths. A folder moves as one step, so a path below a moved folder follows it.
struct PathMoves {
    let moves: [(from: String, to: String)]
    let indices: [String: [Int]]

    init(_ moves: [(from: String, to: String)]) {
        self.moves = moves
        var indices: [String: [Int]] = [:]
        for (i, move) in moves.enumerated() {
            indices[move.from, default: []].append(i)
        }
        self.indices = indices
    }

    /// Where `path` is after the moves, or nil when none of them touched it.
    func destination(of path: String) -> String? {
        var current = path
        var after = -1
        while true {
            // The earliest later move of this path or of a folder above it.
            var best: (index: Int, from: String)?
            var candidate = current
            while true {
                if let i = indices[candidate]?.first(where: { $0 > after }), i < best?.index ?? .max {
                    best = (i, candidate)
                }
                let parent = (candidate as NSString).deletingLastPathComponent
                if parent == candidate || parent.isEmpty { break }
                candidate = parent
            }
            guard let best else { break }
            current = moves[best.index].to + String(current.dropFirst(best.from.count))
            after = best.index
        }
        return after >= 0 ? current : nil
    }
}

// MARK: Repository

/// All SwiftData access goes through this actor (SPEC 4.4).
@ModelActor
public actor AppStore {
    public static func make(inMemory: Bool = false) throws -> AppStore {
        let schema = Schema(versionedSchema: StoreSchemaV1.self)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            let folder = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("MediaPull", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("MediaPull.store"))
        }
        let container = try ModelContainer(for: schema, migrationPlan: StoreMigrationPlan.self, configurations: [configuration])
        return AppStore(modelContainer: container)
    }

    // MARK: Library roots

    public func roots() -> [LibraryRootInfo] {
        let models = (try? modelContext.fetch(FetchDescriptor<LibraryRootModel>(sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        return models.map(Self.info)
    }

    static func info(_ model: LibraryRootModel) -> LibraryRootInfo {
        LibraryRootInfo(id: model.id, name: model.name, path: model.path, bookmark: model.bookmark,
                        layout: SaveLayout(rawValue: model.layout) ?? .archive, isDefault: model.isDefault)
    }

    @discardableResult
    public func addRoot(url: URL, name: String? = nil, layout: SaveLayout, makeDefault: Bool) throws -> LibraryRootInfo {
        let existing = (try? modelContext.fetch(FetchDescriptor<LibraryRootModel>())) ?? []
        if let match = existing.first(where: { $0.path == url.standardizedFileURL.path }) {
            if makeDefault { setDefault(match.id) }
            return Self.info(match)
        }
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        let model = LibraryRootModel(
            id: UUID(), name: name ?? url.lastPathComponent, path: url.standardizedFileURL.path, bookmark: bookmark,
            layout: layout.rawValue, isDefault: makeDefault || existing.isEmpty, sortIndex: existing.count
        )
        if model.isDefault {
            for other in existing {
                other.isDefault = false
            }
        }
        modelContext.insert(model)
        try modelContext.save()
        return Self.info(model)
    }

    public func removeRoot(_ id: UUID) {
        guard let models = try? modelContext.fetch(FetchDescriptor<LibraryRootModel>()) else { return }
        for model in models where model.id == id {
            modelContext.delete(model)
        }
        let remaining = models.filter { $0.id != id }
        if !remaining.contains(where: \.isDefault), let first = remaining.first { first.isDefault = true }
        try? modelContext.save()
    }

    public func updateRoot(_ id: UUID, name: String? = nil, layout: SaveLayout? = nil, path: String? = nil, bookmark: Data? = nil) {
        guard let models = try? modelContext.fetch(FetchDescriptor<LibraryRootModel>()),
              let model = models.first(where: { $0.id == id })
        else { return }
        if let name { model.name = name }
        if let layout { model.layout = layout.rawValue }
        if let path { model.path = path }
        if let bookmark { model.bookmark = bookmark }
        try? modelContext.save()
    }

    public func setDefault(_ id: UUID) {
        guard let models = try? modelContext.fetch(FetchDescriptor<LibraryRootModel>()) else { return }
        for model in models {
            model.isDefault = model.id == id
        }
        try? modelContext.save()
    }

    // MARK: Instagram accounts

    public func account(_ username: String) -> InstagramAccountInfo? {
        let name = username.lowercased()
        let descriptor = FetchDescriptor<InstagramAccountModel>(predicate: #Predicate { $0.username == name })
        guard let model = try? modelContext.fetch(descriptor).first else { return nil }
        return Self.info(model)
    }

    public func accounts() -> [InstagramAccountInfo] {
        let models = (try? modelContext.fetch(
            FetchDescriptor<InstagramAccountModel>(sortBy: [SortDescriptor(\.lastPullAt, order: .reverse)])
        )) ?? []
        return models.map(Self.info)
    }

    static func info(_ model: InstagramAccountModel) -> InstagramAccountInfo {
        InstagramAccountInfo(
            username: model.username, userID: model.userID, fullName: model.fullName,
            options: try? JSONDecoder().decode(PullOptions.self, from: model.optionsJSON),
            newestSavedDate: model.newestSavedDate == .distantPast ? nil : model.newestSavedDate,
            resumeCursor: model.resumeCursor.isEmpty ? nil : model.resumeCursor,
            lastPullAt: model.lastPullAt == .distantPast ? nil : model.lastPullAt, lastResult: model.lastResult
        )
    }

    private func accountModel(_ username: String) -> InstagramAccountModel {
        let name = username.lowercased()
        let descriptor = FetchDescriptor<InstagramAccountModel>(predicate: #Predicate { $0.username == name })
        if let model = try? modelContext.fetch(descriptor).first { return model }
        let model = InstagramAccountModel(username: name)
        modelContext.insert(model)
        return model
    }

    public func updateAccount(_ username: String, userID: String? = nil, fullName: String? = nil, options: PullOptions? = nil,
                              newestSavedDate: Date? = nil, resumeCursor: String?? = nil, lastResult: String? = nil,
                              pulledNow: Bool = false)
    {
        let model = accountModel(username)
        if let userID, !userID.isEmpty { model.userID = userID }
        if let fullName { model.fullName = fullName }
        if let options, let data = try? JSONEncoder().encode(options) { model.optionsJSON = data }
        if let newestSavedDate, newestSavedDate > model.newestSavedDate { model.newestSavedDate = newestSavedDate }
        if let resumeCursor { model.resumeCursor = resumeCursor ?? "" }
        if let lastResult { model.lastResult = lastResult }
        if pulledNow { model.lastPullAt = Date() }
        try? modelContext.save()
    }

    // MARK: Archive

    public func knownKeys(account: String) -> Set<String> {
        let name = account.lowercased()
        let descriptor = FetchDescriptor<ArchiveEntryModel>(predicate: #Predicate { $0.account == name })
        let models = (try? modelContext.fetch(descriptor)) ?? []
        return Set(models.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.key))
    }

    public func isArchived(_ key: String) -> String? {
        let descriptor = FetchDescriptor<ArchiveEntryModel>(predicate: #Predicate { $0.key == key })
        guard let model = try? modelContext.fetch(descriptor).first, FileManager.default.fileExists(atPath: model.path) else { return nil }
        return model.path
    }

    /// The saved file of each key that has one still on disk, looked up in one query per thousand keys.
    public func archivedPaths(for keys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var start = 0
        while start < keys.count {
            let chunk = Array(keys[start ..< min(start + 1000, keys.count)])
            start += 1000
            let descriptor = FetchDescriptor<ArchiveEntryModel>(predicate: #Predicate { chunk.contains($0.key) })
            for model in (try? modelContext.fetch(descriptor)) ?? [] where FileManager.default.fileExists(atPath: model.path) {
                result[model.key] = model.path
            }
        }
        return result
    }

    /// Keeps archive entries pointing at files Organise moved, including files inside moved or renamed folders (R-3804).
    public func moveArchivePaths(_ moves: [(from: String, to: String)]) {
        guard !moves.isEmpty else { return }
        let remap = PathMoves(moves)
        for model in (try? modelContext.fetch(FetchDescriptor<ArchiveEntryModel>())) ?? [] {
            if let to = remap.destination(of: model.path) { model.path = to }
        }
        try? modelContext.save()
    }

    /// Lifecycle (SPEC 6.3): archive entries whose file is gone (on a mounted disk) and accounts nothing refers to that were
    /// last pulled over a year ago. `keepAccounts` are accounts with a remembered folder.
    /// `recordedFolders` are account folders with a record, which remembers their Instagram items itself; `restorable` are
    /// files in the Trash that Undo can still put back.
    public func prune(keepAccounts: Set<String>, recordedFolders: [String] = [], restorable: Set<String> = [], now: Date = Date()) {
        let fm = FileManager.default
        let entries = (try? modelContext.fetch(FetchDescriptor<ArchiveEntryModel>())) ?? []
        let recorded = recordedFolders.map { $0.precomposedStringWithCanonicalMapping.lowercased() + "/" }
        var referenced = Set<String>()
        for entry in entries {
            // Instagram entries are what 1.7 remembered of files saved and deleted since: they wait until a folder's record
            // takes them over (takeInstagramKeys), so an Update never brings those files back (audit 3, C3-M1). Under a
            // folder with a record they are that record's to keep (audit 4, C4-m2).
            let path = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            let waiting = entry.key.hasPrefix("ig:") && !recorded.contains { path.hasPrefix($0) }
            if waiting || fm.fileExists(atPath: entry.path) || !Self.volumeMounted(entry.path) || restorable.contains(entry.path) {
                referenced.insert(entry.account)
            } else {
                modelContext.delete(entry)
            }
        }
        let yearAgo = now.addingTimeInterval(-365 * 24 * 3600)
        let accounts = (try? modelContext.fetch(FetchDescriptor<InstagramAccountModel>())) ?? []
        for account in accounts where account.lastPullAt < yearAgo && !referenced.contains(account.username)
            && !keepAccounts.contains(account.username)
        {
            modelContext.delete(account)
        }
        try? modelContext.save()
    }

    /// The Instagram items saved into a folder before it had a record (versions before 1.8), deleted since or not; the
    /// entries of deleted files are removed once handed over.
    public func takeInstagramKeys(account: String, under folder: String) -> Set<String> {
        let name = account.lowercased()
        let prefix = folder.precomposedStringWithCanonicalMapping.lowercased() + "/"
        let descriptor = FetchDescriptor<ArchiveEntryModel>(predicate: #Predicate { $0.account == name })
        let entries = ((try? modelContext.fetch(descriptor)) ?? []).filter {
            $0.key.hasPrefix("ig:") && $0.path.precomposedStringWithCanonicalMapping.lowercased().hasPrefix(prefix)
        }
        for entry in entries where !FileManager.default.fileExists(atPath: entry.path) && Self.volumeMounted(entry.path) {
            modelContext.delete(entry)
        }
        try? modelContext.save()
        return Set(entries.map(\.key))
    }

    static func volumeMounted(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    public func recordArchive(key: String, account: String, path: String, sha256: String) {
        let descriptor = FetchDescriptor<ArchiveEntryModel>(predicate: #Predicate { $0.key == key })
        if let model = try? modelContext.fetch(descriptor).first {
            model.path = path
            model.sha256 = sha256
            model.account = account.lowercased()
            model.savedAt = Date()
        } else {
            modelContext.insert(ArchiveEntryModel(key: key, account: account.lowercased(), path: path, sha256: sha256))
        }
        try? modelContext.save()
    }

    // MARK: Jobs

    public func recordJob(_ record: JobRecordInfo) {
        modelContext.insert(JobRecordModel(id: record.id, kind: record.kind, title: record.title, status: record.status,
                                           summary: record.summary, startedAt: record.startedAt, finishedAt: record.finishedAt))
        if let all = try? modelContext.fetch(FetchDescriptor<JobRecordModel>(sortBy: [SortDescriptor(\.finishedAt, order: .reverse)])),
           all.count > 500
        {
            for old in all.dropFirst(500) {
                modelContext.delete(old)
            }
        }
        try? modelContext.save()
    }

    public func recentJobs(limit: Int = 50) -> [JobRecordInfo] {
        var descriptor = FetchDescriptor<JobRecordModel>(sortBy: [SortDescriptor(\.finishedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return ((try? modelContext.fetch(descriptor)) ?? []).map {
            JobRecordInfo(id: $0.id, kind: $0.kind, title: $0.title, status: $0.status, summary: $0.summary, startedAt: $0.startedAt,
                          finishedAt: $0.finishedAt)
        }
    }
}
