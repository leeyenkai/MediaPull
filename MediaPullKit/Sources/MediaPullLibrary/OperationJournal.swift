import Foundation
import MediaPullCore

/// One thing an Organise operation did, recorded so it can be undone (D-63).
public enum JournalStep: Codable, Sendable, Hashable {
    case makeFolder(String)
    case move(from: String, to: String, size: Int64?, modified: Date?)
    case clone(from: String, to: String)
    case trash(original: String, trashed: String)
}

public struct JournalEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var root: String
    public var date: Date
    public var steps: [JournalStep]
    public var failures: [String]
    public var undone: Bool
    public var finished: Bool

    /// Media files moved or copied, for the history list.
    public var fileCount: Int {
        steps.filter {
            switch $0 {
            case let .move(from, _, _, _), let .clone(from, _): !from.hasSuffix(".json")
            default: false
            }
        }.count
    }

    /// Paths that moved, so records keyed by path can follow them.
    public var moves: [(from: String, to: String)] {
        steps.compactMap {
            if case let .move(from, to, _, _) = $0 {
                (from, to)
            } else {
                nil
            }
        }
    }
}

public struct UndoReport: Sendable {
    public var restored: Int
    public var skipped: [String]
    public var moves: [(from: String, to: String)]
}

/// Runs Organise plans and keeps their journals in Application Support, so every operation can be undone after relaunch (R-3806).
public actor OperationJournal {
    let folder: URL
    let fm = FileManager.default

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public static var defaultFolder: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("MediaPull/Organise", isDirectory: true)
    }

    // MARK: History

    public func entries() -> [JournalEntry] {
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(JournalEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    /// Forgets journals older than `days` (the files they describe are untouched).
    public func prune(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for entry in entries() where entry.date < cutoff {
            try? fm.removeItem(at: url(for: entry.id))
        }
    }

    func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ entry: JournalEntry) {
        if let data = try? Self.encoder.encode(entry) {
            try? data.write(to: url(for: entry.id), options: .atomic)
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Running a plan

    /// Carries out `plan`. Progress is (done, total). Cancelling stops between files; what was done stays undoable.
    public func run(_ plan: OrganisePlan, progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> JournalEntry {
        var entry = JournalEntry(id: UUID(), title: plan.title, root: plan.root.path, date: Date(), steps: [], failures: [],
                                 undone: false, finished: false)
        let total = plan.foldersToCreate.count + plan.moves.count + plan.itemsToTrash.count + plan.foldersToTrash.count
        var done = 0
        func tick() {
            done += 1
            progress(done, total)
            if done % 50 == 0 {
                save(entry)
            }
        }
        save(entry)
        for folder in plan.foldersToCreate {
            if Task.isCancelled {
                break
            }
            if !fm.fileExists(atPath: folder.path) {
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                    entry.steps.append(.makeFolder(folder.path))
                } catch { entry.failures.append("\(folder.lastPathComponent): \(error.localizedDescription)") }
            }
            tick()
        }
        for move in plan.moves {
            if Task.isCancelled {
                break
            }
            do {
                try fm.createDirectory(at: move.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch move.kind {
                case .move:
                    try moveItem(move.source, to: move.destination, entry: &entry)
                    let sidecar = Sidecar.sidecarURL(for: move.source)
                    if fm.fileExists(atPath: sidecar.path) {
                        try moveItem(sidecar, to: Sidecar.sidecarURL(for: move.destination), entry: &entry)
                    }
                case .clone:
                    try cloneItem(move.source, to: move.destination, entry: &entry)
                    let sidecar = Sidecar.sidecarURL(for: move.source)
                    if fm.fileExists(atPath: sidecar.path) {
                        try cloneItem(sidecar, to: Sidecar.sidecarURL(for: move.destination), entry: &entry)
                    }
                }
            } catch {
                entry.failures.append("\(move.source.lastPathComponent): \(error.localizedDescription)")
            }
            tick()
        }
        for item in plan.itemsToTrash {
            if Task.isCancelled {
                break
            }
            do {
                try trashItem(item, entry: &entry)
                let sidecar = Sidecar.sidecarURL(for: item)
                if fm.fileExists(atPath: sidecar.path) {
                    try trashItem(sidecar, entry: &entry)
                }
            } catch { entry.failures.append("\(item.lastPathComponent): \(error.localizedDescription)") }
            tick()
        }
        for folder in plan.foldersToTrash {
            if Task.isCancelled {
                break
            }
            if fm.fileExists(atPath: folder.path), Self.holdsNoFiles(folder) {
                do { try trashItem(folder, entry: &entry) } catch {
                    entry.failures.append("\(folder.lastPathComponent): \(error.localizedDescription)")
                }
            }
            tick()
        }
        entry.finished = !Task.isCancelled
        save(entry)
        return entry
    }

    /// True when a folder holds no files at any depth (ignoring Finder's own files), so trashing it loses nothing.
    static func holdsNoFiles(_ folder: URL) -> Bool {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if FolderOperations.ignored.contains(url.lastPathComponent) {
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return false
            }
        }
        return true
    }

    func moveItem(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        try fm.moveItem(at: from, to: to)
        let values = try? to.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let isFolder = values?.isDirectory == true
        entry.steps.append(.move(from: from.path, to: to.path, size: isFolder ? nil : values?.fileSize.map(Int64.init),
                                 modified: isFolder ? nil : values?.contentModificationDate))
    }

    func cloneItem(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        // COPYFILE_CLONE makes an APFS clone where the volume supports it, and a full copy elsewhere.
        if copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_RECURSIVE)) != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
        }
        entry.steps.append(.clone(from: from.path, to: to.path))
    }

    func trashItem(_ item: URL, entry: inout JournalEntry) throws {
        var trashed: NSURL?
        try fm.trashItem(at: item, resultingItemURL: &trashed)
        entry.steps.append(.trash(original: item.path, trashed: (trashed as URL?)?.path ?? ""))
    }

    // MARK: Undo

    /// Reverses an entry's steps, newest first. Files changed or moved since are left where they are and reported.
    public func undo(_ id: UUID) -> UndoReport {
        guard var entry = entries().first(where: { $0.id == id }), !entry.undone else { return UndoReport(
            restored: 0,
            skipped: [],
            moves: []
        ) }
        var restored = 0
        var skipped: [String] = []
        var moves: [(String, String)] = []
        for step in entry.steps.reversed() {
            switch step {
            case let .makeFolder(path):
                // Only an empty folder this operation made is removed; anything put in it since keeps it.
                let url = URL(fileURLWithPath: path)
                if fm.fileExists(atPath: path), Self.holdsNoFiles(url), (try? fm.contentsOfDirectory(atPath: path))?
                    .allSatisfy(FolderOperations.ignored.contains) == true
                {
                    try? fm.removeItem(at: url)
                }
            case let .move(from, to, size, modified):
                let dest = URL(fileURLWithPath: to)
                guard fm.fileExists(atPath: to) else { skipped.append("\(dest.lastPathComponent) is no longer at \(to)"); continue }
                if let size {
                    let values = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if values?.fileSize.map(Int64.init) != size
                        || abs((values?.contentModificationDate ?? .distantPast).timeIntervalSince(modified ?? .distantPast)) > 1
                    {
                        skipped.append("\(dest.lastPathComponent) changed since, so it was left in place")
                        continue
                    }
                }
                guard !fm.fileExists(atPath: from)
                else { skipped.append("\(dest.lastPathComponent): another file now has its old name"); continue }
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: from).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: dest, to: URL(fileURLWithPath: from))
                    if !to.hasSuffix(".json") {
                        restored += 1
                    }
                    moves.append((to, from))
                } catch { skipped.append("\(dest.lastPathComponent): \(error.localizedDescription)") }
            case let .clone(_, to):
                // The copy goes to the Trash rather than being deleted (R-3804).
                if fm.fileExists(atPath: to) {
                    do {
                        try fm.trashItem(at: URL(fileURLWithPath: to), resultingItemURL: nil)
                        if !to.hasSuffix(".json") {
                            restored += 1
                        }
                    } catch { skipped.append("\(URL(fileURLWithPath: to).lastPathComponent): \(error.localizedDescription)") }
                }
            case let .trash(original, trashed):
                guard !trashed.isEmpty, fm.fileExists(atPath: trashed) else {
                    skipped.append("\(URL(fileURLWithPath: original).lastPathComponent) is no longer in the Trash")
                    continue
                }
                guard !fm.fileExists(atPath: original)
                else { skipped.append("\(URL(fileURLWithPath: original).lastPathComponent) exists again"); continue }
                do {
                    try fm.createDirectory(
                        at: URL(fileURLWithPath: original).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fm.moveItem(at: URL(fileURLWithPath: trashed), to: URL(fileURLWithPath: original))
                    if !original.hasSuffix(".json") {
                        restored += 1
                    }
                } catch { skipped.append("\(URL(fileURLWithPath: original).lastPathComponent): \(error.localizedDescription)") }
            }
        }
        entry.undone = true
        save(entry)
        return UndoReport(restored: restored, skipped: skipped, moves: moves)
    }
}
