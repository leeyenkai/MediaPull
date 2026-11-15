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
}

public struct PersonInfo: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String?
    public var number: Int
    public var faceCount: Int
    public var dismissedSuggestion: String?

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
    public func states(for paths: [String]) -> [String: FileState] {
        let wanted = Set(paths)
        let rows = (try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? []
        var versions: [String: Int] = [:]
        for file in (try? modelContext.fetch(FetchDescriptor<AnalysedFileModel>())) ?? [] {
            versions[file.sha256] = file.version
        }
        var out: [String: FileState] = [:]
        for row in rows where wanted.contains(row.path) {
            out[row.path] = FileState(sha256: row.sha256, size: row.size, modified: row.modified, version: versions[row.sha256])
        }
        return out
    }

    public func records(for paths: [String]) -> [String: AnalysisRecord] {
        let wanted = Set(paths)
        let rows = ((try? modelContext.fetch(FetchDescriptor<FilePathModel>())) ?? []).filter { wanted.contains($0.path) }
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
        let map = Dictionary(moves.map { ($0.from, $0.to) }, uniquingKeysWith: { _, b in b })
        let froms = Set(map.keys)
        let predicate = #Predicate<FilePathModel> { froms.contains($0.path) }
        for row in (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? [] {
            guard let to = map[row.path] else { continue }
            let toPath = to
            let clash = #Predicate<FilePathModel> { $0.path == toPath }
            for old in (try? modelContext.fetch(FetchDescriptor(predicate: clash))) ?? [] where old !== row {
                modelContext.delete(old)
            }
            row.path = to
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

    public func faces() -> [FaceInfo] {
        ((try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? []).map {
            FaceInfo(key: $0.key, sha256: $0.sha256, vectorRow: $0.vectorRow, quality: $0.quality, personID: $0.personID, pinned: $0.pinned,
                     rejected: $0.rejected)
        }
    }

    public func people() -> [PersonInfo] {
        var counts: [UUID: Int] = [:]
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            if let id = face.personID {
                counts[id, default: 0] += 1
            }
        }
        return ((try? modelContext.fetch(FetchDescriptor<PersonModel>(sortBy: [SortDescriptor(\.number)]))) ?? []).map {
            PersonInfo(
                id: $0.id,
                name: $0.name,
                number: $0.number,
                faceCount: counts[$0.id] ?? 0,
                dismissedSuggestion: $0.dismissedSuggestion
            )
        }
    }

    /// Applies the grouping: face key → person. New person ids are created as needed and numbered in order of size.
    public func applyAssignments(_ assignments: [String: UUID?]) {
        let faces = (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? []
        var known = Set(((try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? []).map(\.id))
        var next = (((try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? []).map(\.number).max() ?? 0) + 1
        var newCounts: [UUID: Int] = [:]
        for face in faces {
            guard let assigned = assignments[face.key] else { continue }
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
        for person in (try? modelContext.fetch(FetchDescriptor<PersonModel>())) ?? [] where counts[person.id] == nil && person.name == nil {
            modelContext.delete(person)
        }
        try? modelContext.save()
    }

    public func rename(person id: UUID, to name: String?) {
        let predicate = #Predicate<PersonModel> { $0.id == id }
        guard let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        person.name = trimmed?.isEmpty == false ? trimmed : nil
        try? modelContext.save()
    }

    public func dismissSuggestion(person id: UUID, name: String) {
        let predicate = #Predicate<PersonModel> { $0.id == id }
        guard let person = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first else { return }
        person.dismissedSuggestion = name
        try? modelContext.save()
    }

    /// Merge: every face of `other` becomes `into`'s, pinned so regrouping keeps them together.
    public func merge(_ other: UUID, into target: UUID) {
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] where face.personID == other || face.personID == target {
            face.personID = target
            face.pinned = true
            face.rejected.removeAll { $0 == target }
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
