import Foundation
import MediaPullCore
import SwiftData

// MARK: Models (SPEC section 36, D-60, D-61)

public enum AnalysisSchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    public static var models: [any PersistentModel.Type] {
        [AnalysedFileModel.self, FilePathModel.self, PersonModel.self, FaceModel.self]
    }

    /// Results for one file content, keyed by checksum so copies and moves share them.
    @Model
    public final class AnalysedFileModel {
        @Attribute(.unique) public var sha256: String
        public var version: Int
        public var payload: Data

        public init(sha256: String, version: Int, payload: Data) {
            self.sha256 = sha256
            self.version = version
            self.payload = payload
        }
    }

    /// Where a file is, and the size and date it had when its checksum was taken.
    @Model
    public final class FilePathModel {
        @Attribute(.unique) public var path: String
        public var sha256: String
        public var size: Int64
        public var modified: Date

        public init(path: String, sha256: String, size: Int64, modified: Date) {
            self.path = path
            self.sha256 = sha256
            self.size = size
            self.modified = modified
        }
    }

    @Model
    public final class PersonModel {
        @Attribute(.unique) public var id: UUID
        public var name: String?
        public var number: Int
        public var dismissedSuggestion: String?
        public var createdAt: Date

        public init(id: UUID, number: Int) {
            self.id = id
            self.number = number
            createdAt = Date()
        }
    }

    /// One face in one file content. `rejected` holds people this face is not (R-3904).
    @Model
    public final class FaceModel {
        @Attribute(.unique) public var key: String
        public var sha256: String
        public var vectorRow: Int
        public var quality: Float
        public var pixelSize: Double
        public var personID: UUID?
        public var pinned: Bool
        public var rejected: [UUID]

        public init(key: String, sha256: String, vectorRow: Int, quality: Float, pixelSize: Double) {
            self.key = key
            self.sha256 = sha256
            self.vectorRow = vectorRow
            self.quality = quality
            self.pixelSize = pixelSize
            pinned = false
            rejected = []
        }
    }
}

public typealias AnalysedFileModel = AnalysisSchemaV1.AnalysedFileModel
public typealias FilePathModel = AnalysisSchemaV1.FilePathModel
public typealias PersonModel = AnalysisSchemaV1.PersonModel
public typealias FaceModel = AnalysisSchemaV1.FaceModel

public enum AnalysisMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [AnalysisSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

// MARK: Sendable values

public struct FileState: Sendable, Hashable {
    public var sha256: String
    public var size: Int64
    public var modified: Date
    public var version: Int?
    public var factsVersion: Int?
    /// From the stored record: whether it has an image embedding, whether faces were checked for people, and whether
    /// it found any faces. Nil when nothing is stored for the checksum.
    public var hasEmbedding: Bool?
    public var peopleChecked: Bool?
    public var hasFaces: Bool?
}

/// The few fields a scan needs from a stored record; decoding these skips building labels, text and facts.
private struct RecordFlags: Decodable {
    struct Skipped: Decodable {}
    var factsVersion: Int?
    var hasEmbedding: Bool
    var peopleChecked: Bool?
    var faces: [Skipped]
}

public struct PersonInfo: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String?
    public var number: Int
    public var faceCount: Int
    public var dismissedSuggestion: String?
    /// Photos in the Trash that Undo can still bring back (not in `faceCount`, audit 7, B7-m5).
    public var heldCount = 0

    public var displayName: String {
        name?.isEmpty == false ? name! : "Person \(number)"
    }
}

public struct FaceInfo: Sendable, Hashable {
    public var key: String
    public var sha256: String
    public var vectorRow: Int
    public var quality: Float
    public var personID: UUID?
    public var pinned: Bool
    public var rejected: [UUID]
}

public struct NewFace: Sendable {
    public var key: String
    public var vectorRow: Int
    public var quality: Float
    public var pixelSize: Double

    public init(key: String, vectorRow: Int, quality: Float, pixelSize: Double) {
        self.key = key
        self.vectorRow = vectorRow
        self.quality = quality
        self.pixelSize = pixelSize
    }
}

// MARK: Repository

/// Analysis results and face data, in their own store file so they can be rebuilt or deleted on their own (D-60, D-61).
@ModelActor
public actor AnalysisStore {
    public static func make(folder: URL?) throws -> AnalysisStore {
        let schema = Schema(versionedSchema: AnalysisSchemaV1.self)
        let configuration: ModelConfiguration
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("Analysis.store"))
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        let container = try ModelContainer(for: schema, migrationPlan: AnalysisMigrationPlan.self, configurations: [configuration])
        return AnalysisStore(modelContainer: container)
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    // MARK: Files

    /// What is known about these paths: their checksum, size and date when analysed, and the record version.
    /// The stored rows for these paths, fetched by path in batches rather than reading the whole table: panes reload
    /// often (every folder change) and a library can hold many thousands of paths.
    private func pathRows(_ paths: [String]) -> [FilePathModel] {
        var rows: [FilePathModel] = []
        let unique = Array(Set(paths))
        for start in stride(from: 0, to: unique.count, by: 500) {
            let batch = Array(unique[start ..< min(start + 500, unique.count)])
            let predicate = #Predicate<FilePathModel> { batch.contains($0.path) }
            rows += (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        }
        return rows
    }

    /// Only the records of these paths are read, in one pass on this actor.
    public func states(for paths: [String]) -> [String: FileState] {
        let rows = pathRows(paths)
        let shas = Set(rows.map(\.sha256))
        var stored: [String: (version: Int, flags: RecordFlags?)] = [:]
        let predicate = #Predicate<AnalysedFileModel> { shas.contains($0.sha256) }
        for file in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            stored[file.sha256] = (file.version, try? Self.decoder.decode(RecordFlags.self, from: file.payload))
        }
        var out: [String: FileState] = [:]
        for row in rows {
            let record = stored[row.sha256]
            out[row.path] = FileState(
                sha256: row.sha256,
                size: row.size,
                modified: row.modified,
                version: record?.version,
                factsVersion: record?.flags?.factsVersion,
                hasEmbedding: record?.flags?.hasEmbedding,
                peopleChecked: record?.flags?.peopleChecked,
                hasFaces: record?.flags.map { !$0.faces.isEmpty }
            )
        }
        return out
    }

    public func records(for paths: [String]) -> [String: AnalysisRecord] {
        let rows = pathRows(paths)
        let shas = Set(rows.map(\.sha256))
        var bySha: [String: AnalysisRecord] = [:]
        let predicate = #Predicate<AnalysedFileModel> { shas.contains($0.sha256) }
        for file in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            bySha[file.sha256] = try? Self.decoder.decode(AnalysisRecord.self, from: file.payload)
        }
        var out: [String: AnalysisRecord] = [:]
        for row in rows {
            out[row.path] = bySha[row.sha256]
        }
        return out
    }

    public func record(sha256: String) -> AnalysisRecord? {
        let predicate = #Predicate<AnalysedFileModel> { $0.sha256 == sha256 }
        guard let file = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return nil }
        return try? Self.decoder.decode(AnalysisRecord.self, from: file.payload)
    }

    /// Up to `limit` photos of one person: each face's key, a path that holds it and its box. Reads only that person's
    /// faces and their paths, so the People list does not go through the whole library for each row.
    public func faceExamples(of person: UUID, limit: Int = .max) -> [(key: String, path: String, box: FaceBox?)] {
        let wanted: UUID? = person
        var descriptor = FetchDescriptor<FaceModel>(predicate: #Predicate { $0.personID == wanted }, sortBy: [SortDescriptor(\.key)])
        if limit < .max { descriptor.fetchLimit = limit * 4 }
        var out: [(key: String, path: String, box: FaceBox?)] = []
        for face in (try? modelContext.fetch(descriptor)) ?? [] where out.count < limit {
            let sha = face.sha256
            var paths = FetchDescriptor<FilePathModel>(predicate: #Predicate { $0.sha256 == sha }, sortBy: [SortDescriptor(\.path)])
            if heldPaths.isEmpty { paths.fetchLimit = 1 }
            guard let path = (try? modelContext.fetch(paths))?.first(where: { !heldPaths.contains($0.path) })?.path else { continue }
            let faceKey = String(face.key.split(separator: "|").last ?? "")
            out.append((face.key, path, record(sha256: sha)?.faces.first { $0.key == faceKey }))
        }
        return out
    }

    /// All paths for each checksum, for search over everything analysed.
    public func allPaths() -> [String: String] {
        Dictionary(((try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? []).map { ($0.path, $0.sha256) },
                   uniquingKeysWith: { a, _ in a })
    }

    public func setPath(_ path: String, sha256: String, size: Int64, modified: Date) {
        let predicate = #Predicate<FilePathModel> { $0.path == path }
        if let row = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            row.sha256 = sha256
            row.size = size
            row.modified = modified
        } else {
            modelContext.insert(FilePathModel(path: path, sha256: sha256, size: size, modified: modified))
        }
        try? modelContext.save()
    }

    public func save(_ record: AnalysisRecord) {
        guard let payload = try? Self.encoder.encode(record) else { return }
        let sha = record.sha256
        let predicate = #Predicate<AnalysedFileModel> { $0.sha256 == sha }
        if let file = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            file.version = record.version
            file.payload = payload
        } else {
            modelContext.insert(AnalysedFileModel(sha256: sha, version: record.version, payload: payload))
        }
        try? modelContext.save()
    }

    /// Keeps records pointing at files that Organise or the Library moved (R-3804).
    public func movePaths(_ moves: [(from: String, to: String)]) {
        guard !moves.isEmpty else { return }
        let remap = PathMoves(moves)
        let rows = (try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? []
        let moved = rows.compactMap { row in remap.destination(of: row.path).map { (row: row, to: $0) } }
        guard !moved.isEmpty else { return }
        // Paths are unique: a row already at a destination gives way, and of two rows moved to one path the last wins.
        let movedRows = Set(moved.map { ObjectIdentifier($0.row) })
        let destinations = Set(moved.map(\.to))
        for row in rows where !movedRows.contains(ObjectIdentifier(row)) && destinations.contains(row.path) {
            modelContext.delete(row)
        }
        var placed = Set<String>()
        for (row, to) in moved.reversed() {
            if placed.insert(to).inserted {
                row.path = to
            } else {
                modelContext.delete(row)
            }
        }
        try? modelContext.save()
    }

    /// Forgets paths that no longer exist. Results stay with their checksum in case the file comes back.
    public func forget(paths: [String]) {
        let gone = Set(paths)
        let predicate = #Predicate<FilePathModel> { gone.contains($0.path) }
        for row in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            modelContext.delete(row)
        }
        try? modelContext.save()
    }

    /// After a scan: results and faces of content no known path holds any more (deleted, or moved out of every scanned
    /// folder). Faces are biometric data and are not kept for files that are gone (D-61); people left with no faces and
    /// no name go too. Returns the face keys and checksums whose vectors must be removed.
    public func pruneOrphans() -> (faceKeys: [String], sha256s: [String]) {
        let live = Set(((try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? []).map(\.sha256))
        var shas: [String] = []
        for file in (try? modelContext.fetch(FetchDescriptor<AnalysedFileModel>())) ?? [] where !live.contains(file.sha256) {
            shas.append(file.sha256)
            modelContext.delete(file)
        }
        var faceKeys: [String] = []
        var remaining: [UUID: Int] = [:]
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            if live.contains(face.sha256) {
                if let id = face.personID { remaining[id, default: 0] += 1 }
            } else {
                faceKeys.append(face.key)
                modelContext.delete(face)
            }
        }
        if !faceKeys.isEmpty {
            for person in (try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? [] where remaining[person.id] == nil && person.name == nil {
                modelContext.delete(person)
            }
        }
        try? modelContext.save()
        return (faceKeys, shas)
    }

    public func fileCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<AnalysedFileModel>())) ?? 0
    }

    /// Delete All Analysis Data: results, paths, faces and people.
    public func deleteAll() {
        try? modelContext.delete(model: FaceModel.self)
        try? modelContext.delete(model: PersonModel.self)
        try? modelContext.delete(model: FilePathModel.self)
        try? modelContext.delete(model: AnalysedFileModel.self)
        try? modelContext.save()
    }

    /// Analyse Again: drops results so every file is analysed again. Paths, faces, people, names and corrections stay;
    /// faces found again have the same keys, so they keep their person.
    public func deleteResults() {
        try? modelContext.delete(model: AnalysedFileModel.self)
        try? modelContext.save()
    }

    /// A file edited in place (R-4506, D-126): its results, faces, people and corrections are copied from its old content to
    /// its new one, so no model runs again; the copy's facts are marked to be read again. Copied, not moved: another file
    /// with the old content keeps its own, and pruning removes what no file holds. Returns the face keys copied, old to
    /// new, so their vectors can be copied too (`setFaceRows`).
    public func rekey(from old: String, to new: String) -> [(old: String, new: String)] {
        guard old != new, var record = record(sha256: old) else { return [] }
        record.sha256 = new
        record.factsVersion = 0
        if self.record(sha256: new) == nil { save(record) }
        var pairs: [(old: String, new: String)] = []
        let predicate = #Predicate<FaceModel> { $0.sha256 == old }
        for face in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            let suffix = face.key.split(separator: "|", maxSplits: 1).last.map(String.init) ?? face.key
            let key = "\(new)|\(suffix)"
            let existing = #Predicate<FaceModel> { $0.key == key }
            guard (try? modelContext.fetch(FetchDescriptor(predicate: existing)).first) == nil else { continue }
            let copy = FaceModel(key: key, sha256: new, vectorRow: face.vectorRow, quality: face.quality, pixelSize: face.pixelSize)
            copy.personID = face.personID
            copy.pinned = face.pinned
            copy.rejected = face.rejected
            modelContext.insert(copy)
            pairs.append((face.key, key))
        }
        try? modelContext.save()
        return pairs
    }

    /// Vector rows of copied faces, by key.
    public func setFaceRows(_ rows: [String: Int]) {
        guard !rows.isEmpty else { return }
        let keys = Array(rows.keys)
        let predicate = #Predicate<FaceModel> { keys.contains($0.key) }
        for face in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            if let row = rows[face.key] { face.vectorRow = row }
        }
        try? modelContext.save()
    }

    // MARK: Faces and people (section 39)

    public func addFaces(_ faces: [NewFace], sha256: String) {
        for face in faces {
            let key = "\(sha256)|\(face.key)"
            let predicate = #Predicate<FaceModel> { $0.key == key }
            if (try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first) != nil {
                continue
            }
            modelContext.insert(FaceModel(
                key: key,
                sha256: sha256,
                vectorRow: face.vectorRow,
                quality: face.quality,
                pixelSize: face.pixelSize
            ))
        }
        try? modelContext.save()
    }

    /// In key order, so grouping (which breaks ties by input order) gives the same people on every run.
    public func faces() -> [FaceInfo] {
        ((try? modelContext.fetch(FetchDescriptor<FaceModel>(sortBy: [SortDescriptor(\.key)]))) ?? []).map {
            FaceInfo(
                key: $0.key,
                sha256: $0.sha256,
                vectorRow: $0.vectorRow,
                quality: $0.quality,
                personID: $0.personID,
                pinned: $0.pinned,
                rejected: $0.rejected
            )
        }
    }

    /// Paths of files in the Trash that Undo can still put back: their faces and corrections are kept, but they are not
    /// counted or shown in People until they are back (audit 6, B6-m7).
    private var heldPaths: Set<String> = []

    public func setHeld(_ paths: Set<String>) {
        heldPaths = paths
    }

    public func people() -> [PersonInfo] {
        var counts: [UUID: Int] = [:]
        // Checksums some file on disk holds; nil when nothing is held, so every face counts.
        let shown: Set<String>? = heldPaths.isEmpty ? nil : Set(((try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? [])
            .filter { !heldPaths.contains($0.path) }.map(\.sha256))
        var held: [UUID: Int] = [:]
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            guard let id = face.personID else { continue }
            if shown?.contains(face.sha256) ?? true { counts[id, default: 0] += 1 } else { held[id, default: 0] += 1 }
        }
        return ((try? modelContext.fetch(FetchDescriptor<PersonModel>(sortBy: [SortDescriptor(\.number)]))) ?? []).map {
            var person = PersonInfo(
                id: $0.id,
                name: $0.name,
                number: $0.number,
                faceCount: counts[$0.id] ?? 0,
                dismissedSuggestion: $0.dismissedSuggestion
            )
            person.heldCount = held[$0.id] ?? 0
            return person
        }
    }

    /// Applies the grouping: face key → person. New person ids are created as needed and numbered in order of size.
    /// With `snapshot`, nothing is applied (and false returned) when the faces changed since it was taken, so a grouping
    /// worked out from old faces never overwrites newer corrections.
    @discardableResult
    public func applyAssignments(_ assignments: [String: UUID?], ifUnchangedSince snapshot: [FaceInfo]? = nil) -> Bool {
        if let snapshot, Set(faces()) != Set(snapshot) {
            return false
        }
        let faces = (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? []
        var known = Set(((try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? []).map(\.id))
        var next = (((try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? []).map(\.number).max() ?? 0) + 1
        var newCounts: [UUID: Int] = [:]
        var successors: [UUID: Set<UUID>] = [:]
        for face in faces {
            guard let assigned = assignments[face.key] else { continue }
            if let old = face.personID, let id = assigned {
                successors[old, default: []].insert(id)
            }
            face.personID = assigned
            if let id = assigned, !known.contains(id) {
                newCounts[id, default: 0] += 1
            }
        }
        for (id, _) in newCounts.sorted(by: { $0.value > $1.value }) {
            modelContext.insert(PersonModel(id: id, number: next))
            known.insert(id)
            next += 1
        }
        // People left with no faces are removed, unless they have a name.
        var counts: [UUID: Int] = [:]
        for face in faces {
            if let id = face.personID {
                counts[id, default: 0] += 1
            }
        }
        var removed = Set<UUID>()
        for person in (try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? [] where counts[person.id] == nil && person.name == nil {
            removed.insert(person.id)
            modelContext.delete(person)
        }
        // "Not This Person" follows the faces of a person regrouping replaced, so the correction survives (R-3904).
        for face in faces where !removed.isDisjoint(with: face.rejected) {
            let inherited = face.rejected.filter(removed.contains).flatMap { successors[$0] ?? [] }
            for id in Set(inherited) where !face.rejected.contains(id) && id != face.personID {
                face.rejected.append(id)
            }
        }
        try? modelContext.save()
        return true
    }

    public func rename(person id: UUID, to name: String?) {
        let predicate = #Predicate<PersonModel> { $0.id == id }
        guard let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        person.name = trimmed?.isEmpty == false ? trimmed : nil
        try? modelContext.save()
    }

    /// Forgets a person none of whose photos are left: a named person is otherwise kept, so the People list offers this
    /// (audit 4, B4-m9). A person who still has faces is kept; returns whether the person was removed.
    @discardableResult
    public func forget(person id: UUID) -> Bool {
        let faces = (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? []
        guard !faces.contains(where: { $0.personID == id }) else { return false }
        let predicate = #Predicate<PersonModel> { $0.id == id }
        guard let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return false }
        modelContext.delete(person)
        for face in faces where face.rejected.contains(id) {
            face.rejected.removeAll { $0 == id }
        }
        try? modelContext.save()
        return true
    }

    public func dismissSuggestion(person id: UUID, name: String) {
        let predicate = #Predicate<PersonModel> { $0.id == id }
        guard let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return }
        person.dismissedSuggestion = name
        try? modelContext.save()
    }

    /// Merge: every face of `other` becomes `into`'s, pinned so regrouping keeps them together.
    public func merge(_ other: UUID, into target: UUID) {
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            if face.personID == other || face.personID == target {
                face.personID = target
                face.pinned = true
                face.rejected.removeAll { $0 == target }
            } else if face.rejected.contains(other), !face.rejected.contains(target) {
                face.rejected.append(target)
            }
        }
        let predicate = #Predicate<PersonModel> { $0.id == other }
        if let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first {
            if let name = person.name,
               let target = try? modelContext.fetch(FetchDescriptor(predicate: #Predicate<PersonModel> { $0.id == target })).first,
               target.name == nil
            {
                target.name = name
            }
            modelContext.delete(person)
        }
        try? modelContext.save()
    }

    /// Split: the chosen faces become a new person that will not be merged back.
    public func split(faceKeys: [String], from person: UUID) -> UUID {
        let id = UUID()
        let next = (((try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? []).map(\.number).max() ?? 0) + 1
        modelContext.insert(PersonModel(id: id, number: next))
        let keys = Set(faceKeys)
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] where keys.contains(face.key) {
            face.personID = id
            face.pinned = true
            if !face.rejected.contains(person) {
                face.rejected.append(person)
            }
        }
        try? modelContext.save()
        return id
    }

    /// "Not This Person": the face leaves the person and is never put back with them.
    public func reject(faceKeys: [String], from person: UUID) {
        let keys = Set(faceKeys)
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] where keys.contains(face.key) {
            if face.personID == person {
                face.personID = nil
            }
            face.pinned = false
            if !face.rejected.contains(person) {
                face.rejected.append(person)
            }
        }
        try? modelContext.save()
    }

    /// The people in each file content, for the People filter and Sort by Person.
    public func peopleBySha() -> [String: [UUID]] {
        var out: [String: [UUID]] = [:]
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            if let id = face.personID, !(out[face.sha256]?.contains(id) ?? false) {
                out[face.sha256, default: []].append(id)
            }
        }
        return out
    }

    /// Delete All Face Data (D-61): faces, people, names and corrections. Face boxes in records stay, without identities.
    public func deleteAllFaceData() {
        try? modelContext.delete(model: FaceModel.self)
        try? modelContext.delete(model: PersonModel.self)
        // Files are checked for people again only after a new opt-in.
        for file in (try? modelContext.fetch(FetchDescriptor<AnalysedFileModel>())) ?? [] {
            guard var record = try? Self.decoder.decode(AnalysisRecord.self, from: file.payload), record.peopleChecked else { continue }
            record.peopleChecked = false
            if let payload = try? Self.encoder.encode(record) {
                file.payload = payload
            }
        }
        try? modelContext.save()
    }
}
