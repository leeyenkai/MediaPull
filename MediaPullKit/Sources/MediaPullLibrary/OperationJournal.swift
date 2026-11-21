import Foundation
import MediaPullCore

/// One thing an Organise operation did, recorded so it can be undone (D-63).
public enum JournalStep: Codable, Sendable, Hashable {
    case makeFolder(String)
    case move(from: String, to: String, size: Int64?, modified: Date?)
    /// `files` records each copied file's size and date (relative paths; "" for a single file), so undo only takes back
    /// copies nobody changed since. Journals from before 1.8 have none.
    case clone(from: String, to: String, files: [CopyStamp]?)
    case trash(original: String, trashed: String)
}

public struct CopyStamp: Codable, Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var modified: Date

    public init(path: String, size: Int64, modified: Date) {
        self.path = path
        self.size = size
        self.modified = modified
    }
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
    /// The steps the last undo put back, in their original order, so Redo can do them again (nil before 1.8).
    public var undoneSteps: [JournalStep]?
    /// What was at each path of its steps (an item, the folder it came from, a copy, a folder made, an item in the Trash):
    /// the volume's UUID and the file number, which stay through reconnecting a disk. Undo and Redo act on a path only
    /// while the same file or folder is there; anything renamed, moved, replaced or changed since is left where it is and
    /// reported (R-3806, D-93). Nil for older journals: paths only.
    public var identities: [String: String]?
    /// Folders the change moved to the Trash only because they were left empty: Redo moves them again only while empty.
    public var emptiedFolders: [String]?
    /// An editor Replace (D-107): the hidden names the edited file and its metadata file wait under beside the original
    /// until the original is in the Trash. Never left there: Undo sends what is under them to the Trash.
    public var edits: [String]?
    /// What Undo of a Replace sent to the Trash from those names, by name, so Redo can bring it back first.
    public var parked: [String: String]?

    /// Media files moved or copied, for the history list.
    public var fileCount: Int {
        // An undone change still names the files it moved (audit 7, B7-m7).
        // A partly undone change counts both parts (audit 15, B15-m6).
        // A unit (a file with its metadata file, or a RAW+JPEG pair) is one (R-4206).
        OperationJournal.units(undone ? undoneSteps ?? steps : steps + (undoneSteps ?? [])).filter {
            switch $0[0] {
            // A rename through a temporary name is one file, not two (audit 12, B12-m2).
            case let .move(from, to, _, _): !from.hasSuffix(".json") && !OperationJournal.isTemporary(to)
            case let .clone(from, _, _): !from.hasSuffix(".json")
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
    /// Steps done (files and folders), so "nothing was done" can be told apart from a folder made again (audit 9, B9-m2).
    public var done = 0
    /// The journal could not be written afterwards (a full disk), so the change may not be undone or redone again. Kept
    /// apart from `skipped`, which lists items (audit 13, B13-m5).
    public var unsaved = false
    /// Stopped part way (cancelled, or the app quit): what was done is recorded, the rest can be done later (R-3807).
    public var stopped = false

    public init(restored: Int, skipped: [String], moves: [(from: String, to: String)]) {
        self.restored = restored
        self.skipped = skipped
        self.moves = moves
    }
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

    /// Files MediaPull moved to the Trash that Undo can still put back (the item is still in the Trash): records about them
    /// wait until then (audit 4, B4-m12).
    public func restorablePaths() -> Set<String> {
        var paths = Set<String>()
        for entry in entries() where !entry.undone {
            // Only the item the change trashed, not another item put in the Trash later under its name (audit 12, B12-m5).
            for case let .trash(original, trashed) in entry.steps where fm.fileExists(atPath: trashed) && isSame(trashed, in: entry) {
                paths.insert(original)
            }
        }
        return paths
    }

    /// Forgets journals older than `days` (the files they describe are untouched).
    public func prune(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        // Never a change that still holds items under temporary names: it is taken back first (audit 19, C19-m1).
        for entry in entries() where entry.date < cutoff && !Self.hiddenPresent(entry) {
            try? fm.removeItem(at: url(for: entry.id))
        }
        pruneRemade(before: cutoff)
    }

    func url(for id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString).json")
    }

    /// One entry, read from its own file rather than from every journal.
    public func entry(_ id: UUID) -> JournalEntry? {
        (try? Data(contentsOf: url(for: id))).flatMap { try? Self.decoder.decode(JournalEntry.self, from: $0) }
    }

    /// Writes the entry's journal; false when it could not be written (a full disk), so `run` can say the change cannot
    /// be undone instead of failing quietly.
    @discardableResult
    func save(_ entry: JournalEntry) -> Bool {
        saveRemade()
        guard let data = try? Self.encoder.encode(entry) else { return false }
        do {
            try data.write(to: url(for: entry.id), options: .atomic)
            return true
        } catch {
            return false
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
        // A folder the plan relies on that went away since its preview is never made again (audit 4, B4-M1). Every plan
        // works inside its root, so a root renamed, moved or trashed since (in the Finder or in another pane) stops it
        // too: making the missing folders would recreate it at its old path (audit 5, B5-M1, B5-M2).
        // A plan that makes its root makes only that, never the folders above it (audit 6, B6-m1).
        let required = [plan.createsRoot ? plan.root.deletingLastPathComponent() : plan.root] + plan.requiredFolders
        if let missing = required.first(where: { !Self.isFolder($0) }) {
            entry.failures = ["“\(missing.lastPathComponent)” is no longer there, so nothing was changed."]
            entry.finished = true
            return entry
        }
        // Only the folders the plan makes (and its root, when nobody had made it yet) may be made; any other destination
        // folder that went away since the preview (renamed, moved, trashed) fails its items instead (audit 7, B7-M2).
        let allowed = Set((plan.foldersToCreate + (plan.createsRoot ? [plan.root] : [])).map(\.standardizedFileURL.path))
        let total = plan.foldersToCreate.count + plan.moves.count + plan.itemsToTrash.count + plan.foldersToTrash.count
        var done = 0
        var lastSave = Date()
        // A quit mid-operation must leave every step it took undoable (R-3807). Small journals are saved after every
        // item; large ones, whose saves grow with them, a few times a second.
        var journalFailed = false
        func tick() {
            done += 1
            progress(done, total)
            if entry.steps.count < 200 || Date().timeIntervalSince(lastSave) >= 0.2 {
                if !save(entry), !journalFailed {
                    journalFailed = true
                    entry.failures.append("The undo record could not be saved, so this change may not be undoable.")
                }
                lastSave = Date()
            }
        }
        save(entry)
        for folder in plan.foldersToCreate {
            if Task.isCancelled {
                break
            }
            // Level by level, and only the levels the plan makes: a folder above them renamed or trashed since the
            // preview is never made again (audit 8, B8-M2).
            do { try makeMissingFolders(folder, allowed: allowed, entry: &entry) } catch {
                entry.failures.append("\(folder.lastPathComponent): \(error.localizedDescription)")
            }
            tick()
        }
        // A file's unit goes with it: members, edit files and metadata files (R-4206). A member the plan also names on its
        // own has already gone with its lead.
        let units = UnitFiles()
        var carried = Set<String>()
        for move in plan.moves {
            if Task.isCancelled {
                break
            }
            if carried.contains(move.source.standardizedFileURL.path) {
                tick()
                continue
            }
            do {
                try makeMissingFolders(move.destination.deletingLastPathComponent(), allowed: allowed, entry: &entry)
                let companions = units.companionMoves(of: move.source, to: move.destination)
                switch move.kind {
                case .move:
                    try moveItem(move.source, to: move.destination, entry: &entry)
                    for companion in companions {
                        try moveItem(companion.from, to: companion.to, entry: &entry)
                    }
                    units.forget(move.source.deletingLastPathComponent())
                case .clone:
                    try cloneItem(move.source, to: move.destination, entry: &entry)
                    let within = plan.accountFolders.first { Self.inside(move.source, $0) && Self.inside(move.destination, $0) }
                    for companion in companions {
                        if within != nil, companion.from.pathExtension.lowercased() == "json" {
                            try copyWithoutIdentity(companion.from, to: companion.to, entry: &entry)
                        } else {
                            try cloneItem(companion.from, to: companion.to, entry: &entry)
                        }
                    }
                }
                units.forget(move.destination.deletingLastPathComponent())
                carried.formUnion(companions.map(\.from.standardizedFileURL.path))
            } catch {
                entry.failures.append("\(move.source.lastPathComponent): \(error.localizedDescription)")
            }
            tick()
        }
        for item in plan.itemsToTrash {
            if Task.isCancelled {
                break
            }
            if carried.contains(item.standardizedFileURL.path) {
                tick()
                continue
            }
            do {
                let companions = units.companions(of: item)
                try trashItem(item, entry: &entry)
                for companion in companions {
                    try trashItem(companion, entry: &entry)
                }
                units.forget(item.deletingLastPathComponent())
                carried.formUnion(companions.map(\.standardizedFileURL.path))
            } catch { entry.failures.append("\(item.lastPathComponent): \(error.localizedDescription)") }
            tick()
        }
        for folder in plan.foldersToTrash {
            if Task.isCancelled {
                break
            }
            if fm.fileExists(atPath: folder.path), Self.holdsNoFiles(folder) {
                entry.emptiedFolders = (entry.emptiedFolders ?? []) + [folder.path]
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

    public static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
        note(to.path, in: &entry)
        note(from.deletingLastPathComponent().path, in: &entry)
    }

    // MARK: Identities

    /// A reference to the file or folder at `path`, which keeps naming it when it is renamed, moved or put in the Trash.
    public static func reference(_ path: String) -> String? {
        guard let ref = CFURLCreateFileReferenceURL(nil, URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else {
            return nil
        }
        return CFURLGetString(ref) as String
    }

    /// Where a reference's file or folder is now; nil when it is gone (or its disk is not connected).
    public static func resolve(_ reference: String) -> String? {
        guard let url = CFURLCreateWithString(nil, reference as CFString, nil),
              let path = CFURLCreateFilePathURL(nil, url, nil)?.takeRetainedValue() else { return nil }
        return (path as URL).standardizedFileURL.path
    }

    /// Remembers what is at `path` now (or at `current`, when the thing a step names went elsewhere). A folder or copy made
    /// again by Redo is a new file: the identity it replaces is remembered as it, so later changes that rely on it still
    /// find it (audit 11, B11-M2).
    func note(_ path: String, at current: String? = nil, in entry: inout JournalEntry) {
        guard let identity = AccountFolderRecord.number(of: URL(fileURLWithPath: current ?? path)) else { return }
        // In place: copying the table for every step made large changes slow in proportion to their square (audit 14,
        // B14-m6).
        if entry.identities == nil { entry.identities = [:] }
        entry.identities![path] = identity
    }

    /// A folder or copy made again (by Redo) at `path`: its new identity stands for the one it replaces.
    func noteRemade(_ path: String, in entry: inout JournalEntry) {
        let old = entry.identities?[path]
        note(path, in: &entry)
        if let old, let new = entry.identities?[path], old != new {
            loadRemade()
            if remade[old] == nil { remadeOrder.append(old) }
            remade[old] = new
            remadeDates[old] = Date()
            remadeChanged = true
        }
    }

    /// The map outlives the session: History's Redo can run after a relaunch (audit 14, B14-M1). Pairs are kept in the
    /// order they were made, with when, and go with the journals they serve (audit 15, B15-m2, B15-m7).
    private func loadRemade() {
        guard !remadeLoaded else { return }
        remadeLoaded = true
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("remade.plist")),
              let rows = try? PropertyListDecoder().decode([RemadePair].self, from: data) else { return }
        for row in rows {
            remade[row.old] = row.new
            remadeDates[row.old] = row.date
        }
        remadeOrder = rows.map(\.old)
    }

    private func saveRemade() {
        guard remadeChanged else { return }
        remadeChanged = false
        let rows = remadeOrder.compactMap { old in remade[old].map { RemadePair(old: old, new: $0, date: remadeDates[old] ?? Date()) } }
        if let data = try? PropertyListEncoder().encode(rows) {
            // lint:allow silent-write only Redo across a relaunch relies on it
            try? data.write(to: folder.appendingPathComponent("remade.plist"), options: .atomic)
        }
    }

    /// Forgets pairs older than the journals kept.
    private func pruneRemade(before cutoff: Date) {
        loadRemade()
        let old = remadeOrder.filter { (remadeDates[$0] ?? .distantPast) < cutoff }
        guard !old.isEmpty else { return }
        for key in old {
            remade[key] = nil
            remadeDates[key] = nil
        }
        remadeOrder.removeAll { remade[$0] == nil }
        remadeChanged = true
        saveRemade()
    }

    struct RemadePair: Codable {
        var old: String
        var new: String
        var date: Date
    }

    /// Tests stop an Undo or Redo after this many items, as Cancel does at that point (audit 16, C16-m5).
    var stopsAfter: Int?

    func stop(after count: Int?) {
        stopsAfter = count
    }

    /// Tests make a Replace fail once the original is in the Trash, as a full disk would.
    var failsAfterTrash = false

    func failReplace(afterTrash: Bool) {
        failsAfterTrash = afterTrash
    }

    private var remadeLoaded = false
    private var remadeChanged = false
    private var remadeOrder: [String] = []
    private var remadeDates: [String: Date] = [:]

    /// Identities of folders and copies made again by Redo, by the identity they replace (this session: Redo lives in it).
    private var remade: [String: String] = [:]

    /// Names under a temporary name (a swap of names) are never shown to the person: the name it had is.
    /// Temporary names a change's steps use that hold an item now.
    static func temporaryPathsPresent(_ steps: [JournalStep]) -> Set<String> {
        Set(steps.flatMap(temporaryPaths).filter { FileManager.default.fileExists(atPath: $0) })
    }

    static func temporaryPaths(_ step: JournalStep) -> [String] {
        guard case let .move(from, to, _, _) = step else { return [] }
        return [from, to].filter(isTemporary)
    }

    /// The temporary names a unit touched, as they are after it.
    static func update(_ hidden: inout Set<String>?, after unit: [JournalStep]) {
        for path in unit.flatMap(temporaryPaths) {
            if FileManager.default.fileExists(atPath: path) { hidden?.insert(path) } else { hidden?.remove(path) }
        }
    }

    /// Changes that left items under temporary names (MediaPull stopped mid-way, a crash): taken back at launch (audit 17,
    /// B17-M1, C17-M2).
    public func stranded() -> [UUID] {
        entries().filter { !$0.undone && Self.hiddenPresent($0) }.map(\.id)
    }

    static func isTemporary(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix(".mediapull-rename-") || name.hasPrefix(editPrefix)
    }

    /// The hidden name an edit waits under beside the file it replaces (D-107).
    static let editPrefix = ".mediapull-edit-"

    /// Hidden names of a change that hold an item now: a swap of names part way, or a Replace part way.
    static func hiddenPresent(_ entry: JournalEntry) -> Bool {
        !temporaryPathsPresent(entry.steps).isEmpty || (entry.edits ?? []).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The name to show for a step's item: never a temporary name, but the name it had (`otherwise`) (B11-m2).
    static func shownName(_ path: String, otherwise: String? = nil) -> String {
        isTemporary(path) ? URL(fileURLWithPath: otherwise ?? path).lastPathComponent : URL(fileURLWithPath: path).lastPathComponent
    }

    /// During one Undo: items put back under another name because theirs was taken, by the path they came from.
    private var fallbacks: [String: String] = [:]

    /// Whether the file or folder at `path` is the one the change noted there. A path with nothing noted (older journals,
    /// volumes without a UUID) is taken as it is.
    func isSame(_ path: String, in entry: JournalEntry) -> Bool {
        guard fm.fileExists(atPath: path) else { return false }
        loadRemade()
        guard var noted = entry.identities?[path], let now = AccountFolderRecord.number(of: URL(fileURLWithPath: path)) else {
            return true
        }
        var seen = Set<String>()
        while noted != now, let next = remade[noted], seen.insert(noted).inserted {
            noted = next
        }
        return noted == now
    }

    /// Creates a destination folder that is not there (deleted after the preview) and journals each folder it makes, so
    /// Undo removes them again once they are empty.
    func makeMissingFolders(_ folder: URL, allowed: Set<String>, entry: inout JournalEntry) throws {
        var missing: [URL] = []
        var current = folder.standardizedFileURL
        while !fm.fileExists(atPath: current.path), current.path != "/" {
            guard allowed.contains(current.path) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "“\(current.lastPathComponent)” is no longer there, so this was not changed.",
                ])
            }
            missing.append(current)
            current = current.deletingLastPathComponent()
        }
        // Built only inside the folder the change made them in, never inside another folder that took its name (audit 12,
        // B12-m1).
        if !missing.isEmpty, !isSame(current.path, in: entry) {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "“\(current.lastPathComponent)” is another folder now, so this was not changed.",
            ])
        }
        if !missing.isEmpty { note(current.path, in: &entry) }
        for created in missing.reversed() {
            try fm.createDirectory(at: created, withIntermediateDirectories: false)
            entry.steps.append(.makeFolder(created.path))
            noteRemade(created.path, in: &entry)
        }
    }

    static func inside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// A copy of a metadata file without the keys that make its media an item of a post (D-105), for a copy made inside the
    /// account folder that holds the original (R-4209). Journaled as a copy, so Undo takes it away.
    func copyWithoutIdentity(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        guard let data = try FileOps.metadata(of: from.deletingPathExtension(), applying: .init(values: [:], isCopy: true)) else {
            return try cloneItem(from, to: to, entry: &entry)
        }
        try FileOps.writeNew(data, to: to)
        entry.steps.append(.clone(from: from.path, to: to.path, files: Self.stamps(of: to)))
        noteRemade(to.path, in: &entry)
    }

    func cloneItem(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        // COPYFILE_CLONE makes an APFS clone where the volume supports it, and a full copy elsewhere.
        let existed = fm.fileExists(atPath: to.path)
        // Never into an item that took the name since the plan was made: a folder would be copied inside it, and Undo would
        // take that item for the copy (audit 19, B19-m1).
        if existed { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: to.path]) }
        if copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_RECURSIVE)) != 0 {
            // A copy that failed part-way (a full disk) is not journaled, so undo could never remove what it left.
            if !existed { try? fm.removeItem(at: to) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
        }
        entry.steps.append(.clone(from: from.path, to: to.path, files: Self.stamps(of: to)))
        noteRemade(to.path, in: &entry)
        // Each item a copied folder holds, so a later change to one of them is found again when Redo copies the folder
        // again, and nothing else is (audit 12, B12-M1; audit 13, B13-m1).
        if Self.isFolder(to), let items = fm.enumerator(atPath: to.path) {
            for case let item as String in items {
                noteRemade(to.appendingPathComponent(item).path, in: &entry)
            }
        }
        note(from.path, in: &entry)
        // The folder it went into, so Redo never copies into another folder of that name (audit 10, B10-m5, C10-m1).
        note(to.deletingLastPathComponent().path, in: &entry)
    }

    /// Size and date of a file, or of every file inside a folder (relative paths); nil when it cannot be read.
    static func stamps(of url: URL) -> [CopyStamp]? {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.isDirectory != true {
            return [CopyStamp(path: "", size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)]
        }
        var out: [CopyStamp] = []
        let base = url.standardizedFileURL.path + "/"
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let file = walker?.nextObject() as? URL {
            guard let item = try? file.resourceValues(forKeys: Set(keys)), item.isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            out.append(CopyStamp(path: relative, size: Int64(item.fileSize ?? 0), modified: item.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// Files (relative paths; "" for the item itself) that differ from what was copied, or were added since.
    static func changedFiles(in url: URL, recorded: [CopyStamp]) -> [String] {
        guard let now = stamps(of: url) else { return [] }
        guard !recorded.isEmpty else { return now.map(\.path) }
        let before = Dictionary(recorded.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return now.filter { stamp in
            guard let old = before[stamp.path], !FolderOperations.ignored.contains(URL(fileURLWithPath: stamp.path).lastPathComponent)
            else { return !FolderOperations.ignored.contains(URL(fileURLWithPath: stamp.path).lastPathComponent) }
            return old.size != stamp.size || abs(old.modified.timeIntervalSince(stamp.modified)) > 1
        }.map(\.path)
    }

    func trashItem(_ item: URL, entry: inout JournalEntry) throws {
        var trashed: NSURL?
        do {
            try fm.trashItem(at: item, resultingItemURL: &trashed)
        } catch CocoaError.featureUnsupported {
            // Some drives (a FAT card, a disk image) have no Trash; nothing is ever deleted instead (R-4305).
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This drive has no Trash, so nothing was moved."])
        }
        let inTrash = (trashed as URL?)?.path ?? ""
        entry.steps.append(.trash(original: item.path, trashed: inTrash))
        note(item.deletingLastPathComponent().path, in: &entry)
        // What is in the Trash under that name: another item trashed later with the same name is never taken for it
        // (audit 9, B9-M2).
        if !inTrash.isEmpty { note(inTrash, in: &entry) }
        // Where an item went in the Trash cannot be found again, so it is saved soon: at once for the first 200 steps, then
        // at most five times a second (rewriting a long entry after every item would write gigabytes for a large Trash).
        if entry.steps.count < 200 || Date().timeIntervalSince(lastTrashSave) >= 0.2 {
            save(entry)
            lastTrashSave = Date()
        }
    }

    private var lastTrashSave = Date.distantPast

    /// Whether two paths name the same file, as a case-only rename's old and new names do on most Mac volumes.
    static func sameFile(_ a: String, _ b: String) -> Bool {
        guard a.precomposedStringWithCanonicalMapping.lowercased() == b.precomposedStringWithCanonicalMapping.lowercased() else {
            return false
        }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = try? URL(fileURLWithPath: a).resourceValues(forKeys: key).fileResourceIdentifier,
              let second = try? URL(fileURLWithPath: b).resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    // MARK: Undo

    /// Reverses an entry's steps, newest first. Files changed or moved since are left where they are and reported.
    public func undo(_ id: UUID, progress: (@Sendable (Double) -> Void)? = nil) -> UndoReport {
        undo(id, park: true, progress: progress)
    }

    /// `park`: an edit a Replace placed goes to the Trash once it is back under its hidden name (D-107). A Replace that
    /// failed part way keeps it there instead, to put it back where it came from.
    func undo(_ id: UUID, park: Bool, progress: (@Sendable (Double) -> Void)? = nil) -> UndoReport {
        guard var entry = entry(id), !entry.undone else { return UndoReport(
            restored: 0,
            skipped: [],
            moves: []
        ) }
        var report = UndoReport(restored: 0, skipped: [], moves: [])
        // A change that changed nothing (its files went away before it ran) has nothing to undo: it is simply undone
        // (audit 14, B14-m2).
        guard !entry.steps.isEmpty else {
            if park { report.skipped += parkEdits(&entry) }
            entry.undone = true
            report.done = 1
            if !save(entry) { report.unsaved = true }
            return report
        }
        // An editor Replace is undone only when its original can come back: otherwise the edit stays where it is, never
        // sent to the Trash with nothing in its place (R1-M1).
        if park, entry.edits != nil, let refusal = replaceUndoRefusal(entry) {
            report.skipped.append(refusal)
            return report
        }
        var left: [[JournalStep]] = []
        var undoneUnits: [[JournalStep]] = []
        fallbacks = [:]
        let unchanged = entry
        let units = Self.units(entry.steps)
        var visited = 0
        var keptFolders: [[JournalStep]] = []
        var checkpoint = Date()
        // A metadata file is undone with its media and only when the media went back, so the two stay together.
        var hidden: Set<String>?
        for unit in units.reversed() {
            // Stopped between items (Cancel in Activity, Quit): what was undone is recorded (R-3807, audit 15, B15-M1); never
            // while an item is under a temporary name (audit 17, C17-M2).
            if Task.isCancelled || stopsAfter.map({ visited >= $0 }) == true {
                if hidden == nil { hidden = Self.temporaryPathsPresent(entry.steps) }
                if hidden?.isEmpty ?? true {
                    report.stopped = true
                    break
                }
            }
            visited += 1
            if visited % 50 == 0 { progress?(Double(visited) / Double(units.count)) }
            defer { if hidden != nil { Self.update(&hidden, after: unit) } }
            if undo(unit[0], entry: &entry, report: &report) {
                for step in unit.dropFirst() {
                    undo(step, companion: true, entry: &entry, report: &report)
                }
                undoneUnits.append(unit)
            } else if canRetry(unit[0], entry: entry) {
                left.append(unit)
            } else if case .makeFolder = unit[0] {
                keptFolders.append(unit)
            }
            // Saved as it goes, so a quit part way leaves the change partly undone, never wrong (B15-M1).
            if report.done > 0, Date().timeIntervalSince(checkpoint) >= 0.5 {
                var part = entry
                // In the order the final save uses, so folders still come after their items (audit 16, B16-m1).
                part.steps = units.dropLast(visited).flatMap { $0 } + (left + keptFolders).reversed().flatMap { $0 }
                part.undoneSteps = undoneUnits.reversed().flatMap { $0 } + (unchanged.undoneSteps ?? [])
                part.undone = false
                save(part)
                checkpoint = Date()
            }
        }
        // A folder the change made that still holds an item left for later goes with that item (audit 15, B15-m4).
        let later = units.dropLast(visited).flatMap { $0 }
        if !left.isEmpty || !later.isEmpty { left += keptFolders }
        // Nothing undone: the change stays as it was, so Undo can be tried again once what was in the way is gone (audit 13,
        // B13-m4).
        guard report.done > 0 else {
            if !save(unchanged) { report.unsaved = true }
            return report
        }
        if park { report.skipped += parkEdits(&entry) }
        // A second part of a change undone later joins what Redo does again, never replaces it (audit 14, B14-m1).
        entry.undoneSteps = undoneUnits.reversed().flatMap { $0 } + (entry.undoneSteps ?? [])
        // Steps whose folder is missing altogether (a drive that is not connected) stay in the entry, so Undo can be tried
        // again later; files changed or deleted since are reported and left. The entry is undone when nothing is left.
        entry.steps = later + left.reversed().flatMap { $0 }
        entry.undone = entry.steps.isEmpty
        if !save(entry) { report.unsaved = true }
        return report
    }

    /// Redo: does again what the last undo of `id` put back, recording the new steps so it can be undone once more. Items
    /// that changed or are in the way since are left and reported.
    public func redo(_ id: UUID, progress: (@Sendable (Double) -> Void)? = nil) -> UndoReport {
        var report = UndoReport(restored: 0, skipped: [], moves: [])
        guard var entry = entry(id), let steps = entry.undoneSteps, !steps.isEmpty else { return report }
        fallbacks = [:]
        // As when it first ran: a folder it worked in that went away since is never made again (audit 6, B6-M1).
        // Folders the change made itself (its root among them) are made again; no others (audit 7, B7-m1).
        let allowed = Set(steps.compactMap { step -> String? in
            if case let .makeFolder(path) = step { URL(fileURLWithPath: path).standardizedFileURL.path } else { nil }
        })
        let root = URL(fileURLWithPath: entry.root).standardizedFileURL
        guard Self.isFolder(root) || (allowed.contains(root.path) && Self.isFolder(root.deletingLastPathComponent())) else {
            report.skipped.append("“\(URL(fileURLWithPath: entry.root).lastPathComponent)” is no longer there, so nothing was done again.")
            return report
        }
        // A Replace's edit comes back from the Trash first; without it the original is never trashed again.
        guard unparkEdits(&entry, report: &report) else { return report }
        let unchanged = entry
        let before = entry.steps.count
        let units = Self.units(steps)
        var visited = 0
        // The first item is saved at once, so a crash right away still leaves a change that is found at launch (C18-m2).
        var checkpoint = Date.distantPast
        let isFile = { (step: JournalStep) -> Bool in if case .makeFolder = step { false } else { true } }
        var hidden: Set<String>?
        for unit in units {
            // As Undo: stopped between items, never while an item is under a temporary name, and saved as it goes (R-3807,
            // audit 15, B15-M1; audit 17, C17-M2).
            if Task.isCancelled || stopsAfter.map({ visited >= $0 }) == true {
                if hidden == nil { hidden = Self.temporaryPathsPresent(entry.steps + steps) }
                if hidden?.isEmpty ?? true {
                    report.stopped = true
                    break
                }
            }
            visited += 1
            if visited % 50 == 0 { progress?(Double(visited) / Double(units.count)) }
            defer { if hidden != nil { Self.update(&hidden, after: unit) } }
            if redo(unit[0], allowed: allowed, entry: &entry, report: &report) {
                for step in unit.dropFirst() {
                    redo(step, companion: true, allowed: allowed, entry: &entry, report: &report)
                }
            }
            if Date().timeIntervalSince(checkpoint) >= 0.5, entry.steps[before...].contains(where: isFile) {
                var part = entry
                part.undoneSteps = units.dropFirst(visited).flatMap { $0 }
                part.undone = false
                save(part)
                checkpoint = Date()
            }
        }
        let notReached = units.dropFirst(visited).flatMap { $0 }
        // A change with files of which none was done again makes no empty folders either: those just made are removed
        // again, and the change stays undone, so Redo can be tried once what was in the way is gone (audit 12, B12-m4;
        // audit 13, B13-m2).
        let made = entry.steps[before...]
        let hasFiles = steps.contains(where: isFile)
        let filesDone = made.contains(where: isFile)
        guard report.done > 0, filesDone || !hasFiles else {
            for case let .makeFolder(path) in made.reversed() where Self.holdsNoFiles(URL(fileURLWithPath: path)) {
                try? fm.removeItem(atPath: path)
            }
            report.done = 0
            // An edit brought back from the Trash for this goes back to it, never left under its hidden name.
            var kept = unchanged
            report.skipped += parkEdits(&kept)
            if !save(kept) { report.unsaved = true }
            return report
        }
        entry.undone = false
        entry.undoneSteps = notReached.isEmpty ? nil : notReached
        if !save(entry) { report.unsaved = true }
        return report
    }

    /// Said when a journal could not be written after Undo or Redo (a full disk), so a later Undo is not trusted blindly
    /// (audit 12, B12-m7).
    public static let unsavedNote = "MediaPull could not record this, so it may not be possible to undo or redo it again."

    @discardableResult
    func redo(_ step: JournalStep, companion: Bool = false, allowed: Set<String>, entry: inout JournalEntry,
              report: inout UndoReport) -> Bool
    {
        // As Undo: only the same things in the same places, and only folders the change made itself (D-93).
        do {
            switch step {
            case let .makeFolder(path):
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                // Inside the folder it was made in, not another folder of that name (C10-m1); counted only when made (B10-m6).
                guard !fm.fileExists(atPath: parent) || isSame(parent, in: entry) || allowed.contains(parent) else {
                    report.skipped.append("\(Self.shownName(path)) was not made again: its folder is another folder now")
                    return false
                }
                if !fm.fileExists(atPath: path) {
                    try makeMissingFolders(URL(fileURLWithPath: path), allowed: allowed, entry: &entry)
                    report.done += 1
                }
                return true
            case let .move(from, to, _, _):
                guard isSame(from, in: entry) else {
                    // A temporary name is never shown; nor is a name the item was only going to get (B12-m3).
                    let name = Self.isTemporary(from) ? "A renamed file" : Self.shownName(from)
                    report.skipped.append(fm.fileExists(atPath: from) ? "\(name) was changed since, so it was left as it is"
                        : "\(name) is no longer where it was, so it was left")
                    return false
                }
                let folder = URL(fileURLWithPath: to).deletingLastPathComponent()
                if fm.fileExists(atPath: folder.path) {
                    guard isSame(folder.path, in: entry) else {
                        report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent): its folder “\(folder.lastPathComponent)” "
                            + "is another folder now")
                        return false
                    }
                } else {
                    try makeMissingFolders(folder, allowed: allowed, entry: &entry)
                }
                var target = URL(fileURLWithPath: to)
                if companion, let media = fallbacks.first(where: { Self.isCompanion(to, of: $0.key) }) {
                    target = folder.appendingPathComponent(MediaUnits.renamed(target.lastPathComponent,
                                                                              lead: (media.key as NSString).lastPathComponent,
                                                                              newLead: (media.value as NSString).lastPathComponent))
                } else if fm.fileExists(atPath: to), !Self.sameFile(from, to) {
                    // As on Undo: an item under a temporary name is never left hidden (audit 11, B11-M1).
                    guard Self.isTemporary(from) else {
                        report.skipped.append("\(target.lastPathComponent): another file now has that name")
                        return false
                    }
                    var taken = Set<String>()
                    target = FolderOperations.freeDestination(for: target.lastPathComponent, in: folder, taken: &taken).url
                    fallbacks[to] = target.path
                    report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent) was given the name \(target.lastPathComponent): "
                        + "its name is taken")
                }
                try moveItem(URL(fileURLWithPath: from), to: target, entry: &entry)
                if !companion, !Self.isTemporary(target.path) { report.restored += 1 }
                report.done += 1
                report.moves.append((from, target.path))
                return true
            case let .clone(from, to, _):
                let folder = URL(fileURLWithPath: to).deletingLastPathComponent()
                guard isSame(from, in: entry), !fm.fileExists(atPath: to),
                      fm.fileExists(atPath: folder.path) ? isSame(folder.path, in: entry) : allowed.contains(folder.path) else {
                    report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent) could not be copied again")
                    return false
                }
                if !fm.fileExists(atPath: folder.path) { try makeMissingFolders(folder, allowed: allowed, entry: &entry) }
                try cloneItem(URL(fileURLWithPath: from), to: URL(fileURLWithPath: to), entry: &entry)
                if !companion { report.restored += 1 }
                report.done += 1
                return true
            case let .trash(original, _):
                guard fm.fileExists(atPath: original) else { return true }
                guard isSame(original, in: entry) else {
                    report.skipped.append("\(URL(fileURLWithPath: original).lastPathComponent) is another item now, so it was left")
                    return false
                }
                // A folder the change trashed because it was left empty goes again only while it is empty (audit 9, B9-M4).
                if entry.emptiedFolders?.contains(original) == true, !Self.holdsNoFiles(URL(fileURLWithPath: original)) {
                    report.skipped.append("\(URL(fileURLWithPath: original).lastPathComponent) holds files now, so it was kept")
                    return false
                }
                try trashItem(URL(fileURLWithPath: original), entry: &entry)
                // A Replace counts its one file once, when the edit takes its place.
                if !companion, entry.edits == nil { report.restored += 1 }
                report.done += 1
                return true
            }
        } catch {
            report.skipped.append(error.localizedDescription)
            return false
        }
    }

    /// Whether a step that could not be undone might be later: a folder it needs is not there at all (a disk not
    /// connected), as opposed to a file changed, moved or replaced since.
    private func canRetry(_ step: JournalStep, entry _: JournalEntry) -> Bool {
        switch step {
        case let .move(from, to, _, _):
            !fm.fileExists(atPath: URL(fileURLWithPath: to).deletingLastPathComponent().path)
                || !fm.fileExists(atPath: URL(fileURLWithPath: from).deletingLastPathComponent().path)
        case let .clone(_, to, _): !fm.fileExists(atPath: URL(fileURLWithPath: to).deletingLastPathComponent().path)
        case let .trash(original, _): !fm.fileExists(atPath: URL(fileURLWithPath: original).deletingLastPathComponent().path)
        case .makeFolder: false
        }
    }

    /// Steps grouped so each media step is followed by the step for its metadata file, as `run` records them.
    /// Whether `path` is a companion of the file at `lead` (same folder, named after it, R-4206).
    static func isCompanion(_ path: String, of lead: String) -> Bool {
        (path as NSString).deletingLastPathComponent == (lead as NSString).deletingLastPathComponent
            && MediaUnits.isCompanionName((path as NSString).lastPathComponent, ofLead: (lead as NSString).lastPathComponent)
    }

    static func units(_ steps: [JournalStep]) -> [[JournalStep]] {
        func source(_ step: JournalStep) -> String? {
            switch step {
            case let .move(from, _, _, _), let .clone(from, _, _): from
            case let .trash(original, _): original
            case .makeFolder: nil
            }
        }
        var units: [[JournalStep]] = []
        for step in steps {
            // A file's companions (its unit's members, edit files and metadata files, R-4206) follow it in the same folder.
            if let last = units.last, let media = source(last[0]), let path = source(step),
               (media as NSString).deletingLastPathComponent == (path as NSString).deletingLastPathComponent,
               MediaUnits.isCompanionName((path as NSString).lastPathComponent, ofLead: (media as NSString).lastPathComponent)
            {
                units[units.count - 1].append(step)
            } else {
                units.append([step])
            }
        }
        return units
    }

    /// Reverses one step, only on the same things in the same places (R-3806, D-93): a file renamed, moved, replaced or
    /// changed since, or a folder that is another folder now, is left where it is and reported; no folder is ever made.
    /// Returns whether it was put back (or there was nothing to put back), so its metadata file may follow.
    @discardableResult
    func undo(_ step: JournalStep, companion: Bool = false, entry: inout JournalEntry, report: inout UndoReport) -> Bool {
        switch step {
        case let .makeFolder(path):
            // Only the empty folder this change made is removed. One that holds something now is kept, and Redo does not
            // make it again (audit 9, B9-m3); another folder at its path is not this one (B9-M3).
            let url = URL(fileURLWithPath: path)
            // Not there as made (renamed, replaced or deleted since): left alone, and Redo does not make it again (audit 10,
            // B10-m1).
            guard fm.fileExists(atPath: path), isSame(path, in: entry) else { return false }
            guard Self.holdsNoFiles(url), (try? fm.contentsOfDirectory(atPath: path))?.allSatisfy(FolderOperations.ignored.contains) == true
            else { return false }
            try? fm.removeItem(at: url)
            report.done += 1
            return true
        case let .move(from, to, size, modified):
            let dest = URL(fileURLWithPath: to)
            guard isSame(to, in: entry) else {
                report.skipped.append(fm.fileExists(atPath: to)
                    ? "\(Self.shownName(to, otherwise: from)) was changed since, so it was left as it is"
                    : "\(Self.shownName(to, otherwise: from)) is no longer where the change put it, so it was left where it is")
                return false
            }
            if let size {
                let values = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if values?.fileSize.map(Int64.init) != size
                    || abs((values?.contentModificationDate ?? .distantPast).timeIntervalSince(modified ?? .distantPast)) > 1
                {
                    report.skipped.append("\(dest.lastPathComponent) changed since, so it was left in place")
                    return false
                }
            }
            // Undo never makes a folder, nor puts things into another folder that took the old one's name (B6-M1, B8-M1).
            let home = URL(fileURLWithPath: from).deletingLastPathComponent()
            guard Self.isFolder(home), isSame(home.path, in: entry) else {
                report.skipped.append("\(dest.lastPathComponent) was left where it is: its folder “\(home.lastPathComponent)” "
                    + "is no longer there")
                return false
            }
            var back = URL(fileURLWithPath: from)
            // A companion (metadata file, unit member, R-4206) goes with its file, under the name its file went back to.
            if companion, let media = fallbacks.first(where: { Self.isCompanion(from, of: $0.key) }) {
                back = home.appendingPathComponent(MediaUnits.renamed(back.lastPathComponent,
                                                                     lead: (media.key as NSString).lastPathComponent,
                                                                     newLead: (media.value as NSString).lastPathComponent))
            } else if fm.fileExists(atPath: from), !Self.sameFile(from, to) {
                // Its old name is taken. An item under a temporary name (a rename that swapped names) is never left hidden:
                // it gets a free name beside its old one (audit 10, B10-M1); anything else stays where it is.
                guard Self.isTemporary(to) else {
                    report.skipped.append("\(dest.lastPathComponent): another file now has its old name")
                    return false
                }
                var taken = Set<String>()
                back = FolderOperations.freeDestination(for: back.lastPathComponent, in: home, taken: &taken).url
                fallbacks[from] = back.path
                report.skipped.append("\(Self.shownName(from)) was put back as \(back.lastPathComponent): its name is taken")
            }
            do {
                try fm.moveItem(at: dest, to: back)
                if !companion, !Self.isTemporary(back.path) { report.restored += 1 }
                report.done += 1
                report.moves.append((to, back.path))
                // For Redo: what is back at its old place (or under the free name it got), and the folder it left (B11-m1).
                note(from, at: back.path == from ? nil : back.path, in: &entry)
                note(dest.deletingLastPathComponent().path, in: &entry)
                return true
            } catch {
                report.skipped.append("\(dest.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        case let .clone(from, to, files):
            // Copies go to the Trash rather than being deleted (R-3804), and only those nobody changed, moved or replaced
            // since: an imported photo that was edited afterwards stays (R-3806).
            guard fm.fileExists(atPath: to) else {
                report.skipped.append("The copy \(URL(fileURLWithPath: to).lastPathComponent) is no longer at \(to), so it was left")
                return false
            }
            let target = URL(fileURLWithPath: to)
            guard isSame(to, in: entry) else {
                report.skipped.append("\(target.lastPathComponent) is another file now, so it was kept")
                return false
            }
            let recorded = files ?? Self.stamps(of: URL(fileURLWithPath: from)) ?? []
            let changed = Self.changedFiles(in: target, recorded: recorded)
            if changed.isEmpty {
                do {
                    try fm.trashItem(at: target, resultingItemURL: nil)
                    if !companion { report.restored += 1 }
                    report.done += 1
                    return true
                } catch {
                    report.skipped.append("\(target.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
            }
            // A copied folder: unchanged files go to the Trash, the rest stay where they are.
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let changedSet = Set(changed)
                for stamp in recorded where !stamp.path.isEmpty && !changedSet.contains(stamp.path) {
                    let file = target.appendingPathComponent(stamp.path)
                    if fm.fileExists(atPath: file.path), (try? fm.trashItem(at: file, resultingItemURL: nil)) != nil {
                        // What was taken back counts as undone (audit 11, B11-m3).
                        report.done += 1
                        report.restored += 1
                    }
                }
            }
            report.skipped.append(changed.count == 1 && changed[0].isEmpty
                ? "\(target.lastPathComponent) changed since it was copied, so it was kept"
                : changed.count == 1 ? "1 file in \(target.lastPathComponent) changed or was added since, so it was kept"
                    : "\(changed.count) files in \(target.lastPathComponent) changed or were added since, so they were kept")
            return false
        case let .trash(original, trashed):
            let name = URL(fileURLWithPath: original).lastPathComponent
            // The item this change put in the Trash, not another one trashed later under that name (audit 9, B9-M2).
            guard !trashed.isEmpty, isSame(trashed, in: entry) else {
                report.skipped.append("\(name) is no longer in the Trash")
                return false
            }
            let home = URL(fileURLWithPath: original).deletingLastPathComponent()
            guard Self.isFolder(home), isSame(home.path, in: entry) else {
                report.skipped.append("\(name) was left in the Trash: its folder “\(home.lastPathComponent)” is no longer there")
                return false
            }
            guard !fm.fileExists(atPath: original) else {
                report.skipped.append("\(name) exists again")
                return false
            }
            do {
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: URL(fileURLWithPath: original))
                if !companion { report.restored += 1 }
                report.done += 1
                note(original, in: &entry)
                return true
            } catch {
                report.skipped.append("\(name): \(error.localizedDescription)")
                return false
            }
        }
    }

    // MARK: Editor Replace (D-107)

    /// Replaces `original` with `edit` (an edited image, a trimmed video) as one change ⌘Z takes back: the edit and its new
    /// metadata wait beside the original under hidden names (a full copy when the edit is on another disk, so the original
    /// is never trashed for a copy that fails or is cut short), the original is checked to be the file that was opened
    /// just before it and its metadata file go to the Trash, then the edit takes a free name at `wanted` (the original's
    /// own name is free again, whatever its case). A failure part way puts the original back and the edit where it was.
    public func replace(_ original: URL, identity: String?, with edit: URL, named wanted: URL, metadata: Data?, title: String)
        throws -> JournalEntry
    {
        let folder = wanted.deletingLastPathComponent()
        let hidden = folder.appendingPathComponent("\(Self.editPrefix)\(UUID().uuidString).\(wanted.pathExtension)")
        let hiddenMetadata = Sidecar.sidecarURL(for: hidden)
        var entry = JournalEntry(id: UUID(), title: title, root: folder.path, date: Date(), steps: [], failures: [],
                                 undone: false, finished: false)
        entry.edits = [hidden.path] + (metadata == nil ? [] : [hiddenMetadata.path])
        // Recorded before anything moves, so a crash part way is found and taken back at launch.
        guard save(entry) else {
            let message = "The undo record could not be saved, so nothing was changed."
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func discard() { try? fm.removeItem(at: url(for: entry.id)) }
        do {
            try FileOps.renameExclusive(edit, to: hidden)
        } catch {
            discard()
            throw error
        }
        func unstage() {
            try? FileOps.renameExclusive(hidden, to: edit) // lint:allow silent-write the error being thrown is what is reported
            try? fm.removeItem(at: hiddenMetadata)
        }
        do {
            if let metadata { try FileOps.writeNew(metadata, to: hiddenMetadata) }
            guard FileOps.isStill(original, identity) else { throw FileOps.changedError(original) }
        } catch {
            unstage()
            discard()
            throw error
        }
        do {
            let sidecar = MediaFiles.companion(of: original)
            try trashItem(original, entry: &entry)
            if let sidecar { try trashItem(sidecar, entry: &entry) }
            if failsAfterTrash { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Stopped for a test."]) }
            let target = FileOps.freeName(for: wanted, replacing: original)
            try moveItemExclusive(hidden, to: target, entry: &entry)
            // Saved after each step, so a crash between them leaves a record Undo can take back whole (R1-m1).
            save(entry)
            if metadata != nil { try moveItemExclusive(hiddenMetadata, to: Sidecar.sidecarURL(for: target), entry: &entry) }
            entry.finished = true
            save(entry)
            return entry
        } catch {
            save(entry)
            let report = undo(entry.id, park: false)
            unstage()
            if report.skipped.isEmpty, !FileManager.default.fileExists(atPath: hidden.path) { discard() }
            let note = report.skipped.isEmpty ? "" : " " + report.skipped.joined(separator: " ")
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription + note])
        }
    }

    /// As `moveItem`, but never over a file another change put at `to` meanwhile.
    func moveItemExclusive(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        try FileOps.renameExclusive(from, to: to)
        let values = try? to.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        entry.steps.append(.move(from: from.path, to: to.path, size: values?.fileSize.map(Int64.init),
                                 modified: values?.contentModificationDate))
        note(to.path, in: &entry)
        note(from.deletingLastPathComponent().path, in: &entry)
    }

    /// After Undo of a Replace: what is back under the hidden names goes to the Trash under a name the person can see
    /// (`<name> (edited).<ext>`, R1-m6), remembered for Redo. Returns what could not be done.
    @discardableResult
    func parkEdits(_ entry: inout JournalEntry) -> [String] {
        var problems: [String] = []
        let present = (entry.edits ?? []).filter { fm.fileExists(atPath: $0) }
        guard !present.isEmpty else { return problems }
        // The name the edit had in the library, from the step that placed it.
        // The name the edit had in the library (or the original's, when it was never placed), never a hidden name.
        let placed = entry.steps.lazy.compactMap { step -> String? in
            switch step {
            case let .move(from, to, _, _) where Self.isTemporary(from) && !from.hasSuffix(".json"): to
            case let .trash(original, _) where !original.hasSuffix(".json"): original
            default: nil
            }
        }.first
        let fallback = URL(fileURLWithPath: present[0]).deletingLastPathComponent()
            .appendingPathComponent("Edit.\(URL(fileURLWithPath: present.first { !$0.hasSuffix(".json") } ?? present[0]).pathExtension)")
        let shown = placed.map { URL(fileURLWithPath: $0) } ?? fallback
        let wanted = shown.deletingLastPathComponent()
            .appendingPathComponent("\(shown.deletingPathExtension().lastPathComponent) (edited).\(shown.pathExtension)")
        let visible = FileOps.freeName(for: wanted)
        for path in present.sorted(by: { !$0.hasSuffix(".json") && $1.hasSuffix(".json") }) {
            let hidden = URL(fileURLWithPath: path)
            let name = path.hasSuffix(".json") ? Sidecar.sidecarURL(for: visible) : visible
            var trashed: NSURL?
            do {
                try FileOps.renameExclusive(hidden, to: name)
                try fm.trashItem(at: name, resultingItemURL: &trashed)
            } catch {
                // Still beside the original under its hidden name: taken up again at the next launch.
                if fm.fileExists(atPath: name.path) {
                    try? FileOps.renameExclusive(name, to: hidden) // lint:allow silent-write reported below
                }
                problems.append("The edited version of “\(shown.lastPathComponent)” could not be moved to the Trash: "
                    + error.localizedDescription)
                continue
            }
            guard let inTrash = (trashed as URL?)?.path else { continue }
            if entry.parked == nil { entry.parked = [:] }
            entry.parked![path] = inTrash
            note(inTrash, in: &entry)
        }
        return problems
    }

    /// Whether Undo of a Replace could put the original back; the reason not, when it could not (R1-M1).
    func replaceUndoRefusal(_ entry: JournalEntry) -> String? {
        let trash = entry.steps.lazy.compactMap { step -> (original: String, trashed: String)? in
            if case let .trash(original, trashed) = step, !original.hasSuffix(".json") { return (original, trashed) }
            return nil
        }.first
        guard let trash else { return nil }
        let name = URL(fileURLWithPath: trash.original).lastPathComponent
        guard !trash.trashed.isEmpty, fm.fileExists(atPath: trash.trashed), isSame(trash.trashed, in: entry) else {
            return "“\(name)” is no longer in the Trash, so the edit was left in place."
        }
        let home = URL(fileURLWithPath: trash.original).deletingLastPathComponent()
        guard Self.isFolder(home), isSame(home.path, in: entry) else {
            return "The folder of “\(name)” is no longer there, so the edit was left in place."
        }
        // The original's name is free once the edit leaves it, unless another file has it.
        let placed = entry.steps.lazy.compactMap { step -> String? in
            if case let .move(from, to, _, _) = step, Self.isTemporary(from), !from.hasSuffix(".json") { return to }
            return nil
        }.first
        if fm.fileExists(atPath: trash.original), placed.map({ !Self.sameFile($0, trash.original) }) ?? true {
            return "Another file is called “\(name)” now, so the edit was left in place."
        }
        return nil
    }

    /// At launch: an undone Replace whose edit is still under its hidden name (a failure part way, a Trash that refused it)
    /// sends it to the Trash, so it is never left hidden in a folder (R1-m2).
    public func parkLeftoverEdits() -> [String] {
        var problems: [String] = []
        for var entry in entries() where entry.undone && (entry.edits ?? []).contains(where: { fm.fileExists(atPath: $0) }) {
            problems += parkEdits(&entry)
            save(entry)
        }
        return problems
    }

    /// Before Redo of a Replace: the edit comes back from the Trash to its hidden name. False (and nothing done) when it is
    /// no longer there as it was.
    func unparkEdits(_ entry: inout JournalEntry, report: inout UndoReport) -> Bool {
        guard let parked = entry.parked, !parked.isEmpty else { return true }
        let media = parked.keys.filter { !$0.hasSuffix(".json") }
        guard media.allSatisfy({ path in
            let inTrash = parked[path] ?? ""
            return !fm.fileExists(atPath: path) && fm.fileExists(atPath: inTrash) && isSame(inTrash, in: entry)
        }) else {
            report.skipped.append("The edited version is no longer in the Trash, so nothing was done again.")
            return false
        }
        for (path, inTrash) in parked.sorted(by: { $0.key < $1.key }) where !fm.fileExists(atPath: path) {
            do {
                try fm.moveItem(at: URL(fileURLWithPath: inTrash), to: URL(fileURLWithPath: path))
            } catch {
                guard path.hasSuffix(".json") else {
                    report.skipped.append("The edited version could not be taken out of the Trash, so nothing was done again.")
                    return false
                }
                report.skipped.append("The edited version's metadata file stayed in the Trash: \(error.localizedDescription)")
                continue
            }
            note(path, in: &entry)
        }
        entry.parked = nil
        return true
    }
}
