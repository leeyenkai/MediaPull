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
    /// Where the things this change touched are now: each path in its steps (an item, or the folder an item came from)
    /// with a reference to the file or folder that was there, which follows it through renames, moves and the Trash. Undo
    /// and Redo find things by these, never by a path another folder may have taken since (audit 8, B8-M1). Nil before
    /// round 8 of the 1.8 audits: paths only.
    public var places: [String: String]?

    /// Media files moved or copied, for the history list.
    public var fileCount: Int {
        // An undone change still names the files it moved (audit 7, B7-m7).
        (undone ? undoneSteps ?? steps : steps).filter {
            switch $0 {
            case let .move(from, _, _, _), let .clone(from, _, _): !from.hasSuffix(".json")
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

    /// Files MediaPull moved to the Trash that Undo can still put back (the item is still in the Trash): records about them
    /// wait until then (audit 4, B4-m12).
    public func restorablePaths() -> Set<String> {
        var paths = Set<String>()
        for entry in entries() where !entry.undone {
            for case let .trash(original, trashed) in entry.steps where fm.fileExists(atPath: trashed) {
                paths.insert(original)
            }
        }
        return paths
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

    /// One entry, read from its own file rather than from every journal.
    public func entry(_ id: UUID) -> JournalEntry? {
        (try? Data(contentsOf: url(for: id))).flatMap { try? Self.decoder.decode(JournalEntry.self, from: $0) }
    }

    /// Writes the entry's journal; false when it could not be written (a full disk), so `run` can say the change cannot
    /// be undone instead of failing quietly.
    @discardableResult
    func save(_ entry: JournalEntry) -> Bool {
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
        for move in plan.moves {
            if Task.isCancelled {
                break
            }
            do {
                try makeMissingFolders(move.destination.deletingLastPathComponent(), allowed: allowed, entry: &entry)
                let sidecar = MediaFiles.companion(of: move.source)
                switch move.kind {
                case .move:
                    try moveItem(move.source, to: move.destination, entry: &entry)
                    if let sidecar { try moveItem(sidecar, to: Sidecar.sidecarURL(for: move.destination), entry: &entry) }
                case .clone:
                    try cloneItem(move.source, to: move.destination, entry: &entry)
                    if let sidecar { try cloneItem(sidecar, to: Sidecar.sidecarURL(for: move.destination), entry: &entry) }
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
                let sidecar = MediaFiles.companion(of: item)
                try trashItem(item, entry: &entry)
                if let sidecar { try trashItem(sidecar, entry: &entry) }
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
        Self.note(to.path, at: to.path, in: &entry)
        Self.note(from.deletingLastPathComponent().path, at: from.deletingLastPathComponent().path, in: &entry)
    }

    // MARK: Places

    /// A reference to the file or folder at `path`, which keeps naming it when it is renamed, moved or put in the Trash.
    static func reference(_ path: String) -> String? {
        guard let ref = CFURLCreateFileReferenceURL(nil, URL(fileURLWithPath: path) as CFURL, nil)?.takeRetainedValue() else {
            return nil
        }
        return CFURLGetString(ref) as String
    }

    /// Where a reference's file or folder is now; nil when it is gone (or its disk is not connected).
    static func resolve(_ reference: String) -> String? {
        guard let url = CFURLCreateWithString(nil, reference as CFString, nil),
              let path = CFURLCreateFilePathURL(nil, url, nil)?.takeRetainedValue() else { return nil }
        return (path as URL).standardizedFileURL.path
    }

    /// Remembers that the thing now at `current` is what the step path `key` names.
    static func note(_ key: String, at current: String, in entry: inout JournalEntry) {
        guard let ref = reference(current) else { return }
        var places = entry.places ?? [:]
        places[key] = ref
        entry.places = places
    }

    /// Where the thing a step path names is now: followed by its reference; in the Trash counts as gone. A path with no
    /// reference (older journals), or one whose reference no longer resolves (deleted, or a disk reconnected), is taken
    /// as it is.
    func locate(_ key: String, in entry: JournalEntry) -> String? {
        if let ref = entry.places?[key], let now = Self.resolve(ref) {
            return FileFlags.isInTrash(URL(fileURLWithPath: now)) ? nil : now
        }
        return fm.fileExists(atPath: key) ? key : nil
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
        for created in missing.reversed() {
            try fm.createDirectory(at: created, withIntermediateDirectories: false)
            entry.steps.append(.makeFolder(created.path))
        }
    }

    /// Where a step's item goes again on Redo: into its folder where that is now, or a folder the change makes itself.
    /// Nil when that folder went away (it is never made again elsewhere).
    func destination(_ path: String, allowed: Set<String>, entry: inout JournalEntry) throws -> URL? {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        if let now = locate(folder.path, in: entry), Self.isFolder(URL(fileURLWithPath: now)) {
            return URL(fileURLWithPath: now).appendingPathComponent(url.lastPathComponent)
        }
        guard allowed.contains(folder.standardizedFileURL.path) else { return nil }
        try makeMissingFolders(folder, allowed: allowed, entry: &entry)
        return url
    }

    func cloneItem(_ from: URL, to: URL, entry: inout JournalEntry) throws {
        // COPYFILE_CLONE makes an APFS clone where the volume supports it, and a full copy elsewhere.
        let existed = fm.fileExists(atPath: to.path)
        if copyfile(from.path, to.path, nil, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_ALL | COPYFILE_RECURSIVE)) != 0 {
            // A copy that failed part-way (a full disk) is not journaled, so undo could never remove what it left.
            if !existed { try? fm.removeItem(at: to) }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path])
        }
        entry.steps.append(.clone(from: from.path, to: to.path, files: Self.stamps(of: to)))
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
        try fm.trashItem(at: item, resultingItemURL: &trashed)
        entry.steps.append(.trash(original: item.path, trashed: (trashed as URL?)?.path ?? ""))
        Self.note(item.deletingLastPathComponent().path, at: item.deletingLastPathComponent().path, in: &entry)
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
    public func undo(_ id: UUID) -> UndoReport {
        guard var entry = entry(id), !entry.undone else { return UndoReport(
            restored: 0,
            skipped: [],
            moves: []
        ) }
        var report = UndoReport(restored: 0, skipped: [], moves: [])
        var left: [[JournalStep]] = []
        var undoneUnits: [[JournalStep]] = []
        // A metadata file is undone with its media and only when the media went back, so the two stay together.
        for unit in Self.units(entry.steps).reversed() {
            guard undo(unit[0], entry: &entry, report: &report) else {
                if canRetry(unit[0], entry: entry) { left.append(unit) }
                continue
            }
            for step in unit.dropFirst() {
                undo(step, entry: &entry, report: &report)
            }
            undoneUnits.append(unit)
        }
        entry.undoneSteps = undoneUnits.reversed().flatMap { $0 }
        // Steps whose folder is missing altogether (a drive that is not connected) stay in the entry, so Undo can be tried
        // again later; files changed or deleted since are reported and left. The entry is undone when nothing is left.
        entry.steps = left.reversed().flatMap { $0 }
        entry.undone = left.isEmpty
        save(entry)
        return report
    }

    /// Redo: does again what the last undo of `id` put back, recording the new steps so it can be undone once more. Items
    /// that changed or are in the way since are left and reported.
    public func redo(_ id: UUID) -> UndoReport {
        var report = UndoReport(restored: 0, skipped: [], moves: [])
        guard var entry = entry(id), let steps = entry.undoneSteps, !steps.isEmpty else { return report }
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
        for unit in Self.units(steps) {
            guard redo(unit[0], allowed: allowed, entry: &entry, report: &report) else { continue }
            for step in unit.dropFirst() {
                redo(step, allowed: allowed, entry: &entry, report: &report)
            }
        }
        entry.undone = false
        entry.undoneSteps = nil
        save(entry)
        return report
    }

    @discardableResult
    func redo(_ step: JournalStep, allowed: Set<String>, entry: inout JournalEntry, report: inout UndoReport) -> Bool {
        do {
            switch step {
            case let .makeFolder(path):
                if !fm.fileExists(atPath: path) {
                    try fm.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: false)
                    entry.steps.append(.makeFolder(path))
                }
                return true
            case let .move(from, to, _, _):
                // The item where it is now, into the folder it went to where that is now (audit 8, B8-M1, B8-m1).
                guard let now = locate(from, in: entry) else {
                    report.skipped.append("\(URL(fileURLWithPath: from).lastPathComponent) is no longer at \(from)")
                    return false
                }
                guard let target = try destination(to, allowed: allowed, entry: &entry) else {
                    report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent): its folder is no longer there")
                    return false
                }
                guard !fm.fileExists(atPath: target.path) || Self.sameFile(now, target.path) else {
                    report.skipped.append("\(target.lastPathComponent): another file now has that name")
                    return false
                }
                try moveItem(URL(fileURLWithPath: now), to: target, entry: &entry)
                if !to.hasSuffix(".json") { report.restored += 1 }
                report.moves.append((now, target.path))
                return true
            case let .clone(from, to, _):
                guard let source = locate(from, in: entry), let target = try destination(to, allowed: allowed, entry: &entry),
                      !fm.fileExists(atPath: target.path) else {
                    report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent) could not be copied again")
                    return false
                }
                try cloneItem(URL(fileURLWithPath: source), to: target, entry: &entry)
                if !to.hasSuffix(".json") { report.restored += 1 }
                return true
            case let .trash(original, _):
                guard let now = locate(original, in: entry) else { return true }
                try trashItem(URL(fileURLWithPath: now), entry: &entry)
                if !original.hasSuffix(".json") { report.restored += 1 }
                return true
            }
        } catch {
            report.skipped.append(error.localizedDescription)
            return false
        }
    }

    /// Whether a step that could not be undone might be later: its file's folder is not there at all.
    private func canRetry(_ step: JournalStep, entry: JournalEntry) -> Bool {
        switch step {
        case let .move(from, to, _, _):
            locate(to, in: entry) == nil || locate(URL(fileURLWithPath: from).deletingLastPathComponent().path, in: entry) == nil
        case let .clone(_, to, _): !fm.fileExists(atPath: URL(fileURLWithPath: to).deletingLastPathComponent().path)
        case let .trash(original, _): locate(URL(fileURLWithPath: original).deletingLastPathComponent().path, in: entry) == nil
        case .makeFolder: false
        }
    }

    /// Steps grouped so each media step is followed by the step for its metadata file, as `run` records them.
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
            if let last = units.last, last.count == 1, let media = source(last[0]), let path = source(step),
               Sidecar.sidecarURL(for: URL(fileURLWithPath: media)).path == path
            {
                units[units.count - 1].append(step)
            } else {
                units.append([step])
            }
        }
        return units
    }

    /// Reverses one step. Returns whether it was put back (or there was nothing to put back), so its metadata file may follow.
    @discardableResult
    func undo(_ step: JournalStep, entry: inout JournalEntry, report: inout UndoReport) -> Bool {
        switch step {
        case let .makeFolder(path):
            // Only an empty folder this operation made is removed; anything put in it since keeps it.
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: path), Self.holdsNoFiles(url), (try? fm.contentsOfDirectory(atPath: path))?
                .allSatisfy(FolderOperations.ignored.contains) == true
            {
                try? fm.removeItem(at: url)
            }
            return true
        case let .move(from, to, size, modified):
            // The item where it is now, and the folder it came from where that is now (audit 8, B8-M1).
            guard let now = locate(to, in: entry) else {
                report.skipped.append("\(URL(fileURLWithPath: to).lastPathComponent) is no longer at \(to)")
                return false
            }
            let dest = URL(fileURLWithPath: now)
            if let size {
                let values = try? dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if values?.fileSize.map(Int64.init) != size
                    || abs((values?.contentModificationDate ?? .distantPast).timeIntervalSince(modified ?? .distantPast)) > 1
                {
                    report.skipped.append("\(dest.lastPathComponent) changed since, so it was left in place")
                    return false
                }
            }
            // Undo never makes a folder: one deleted or put in the Trash since is not made again at its old path; the item
            // stays where it is and Undo can be tried again (audit 6, B6-M1).
            let fromURL = URL(fileURLWithPath: from)
            guard let homePath = locate(fromURL.deletingLastPathComponent().path, in: entry), Self.isFolder(URL(fileURLWithPath: homePath))
            else {
                report.skipped.append("\(dest.lastPathComponent) was left where it is: its folder "
                    + "“\(fromURL.deletingLastPathComponent().lastPathComponent)” is no longer there")
                return false
            }
            let back = URL(fileURLWithPath: homePath).appendingPathComponent(fromURL.lastPathComponent)
            guard !fm.fileExists(atPath: back.path) || Self.sameFile(back.path, now) else {
                report.skipped.append("\(dest.lastPathComponent): another file now has its old name")
                return false
            }
            do {
                try fm.moveItem(at: dest, to: back)
                if !to.hasSuffix(".json") {
                    report.restored += 1
                }
                report.moves.append((now, back.path))
                // For Redo: the item is back at its old place, and the folder it left is where it is now.
                Self.note(from, at: back.path, in: &entry)
                Self.note(URL(fileURLWithPath: to).deletingLastPathComponent().path, at: dest.deletingLastPathComponent().path,
                          in: &entry)
                return true
            } catch {
                report.skipped.append("\(dest.lastPathComponent): \(error.localizedDescription)")
                return false
            }
        case let .clone(from, to, files):
            // Copies go to the Trash rather than being deleted (R-3804), and only those nobody changed since: an
            // imported photo that was edited afterwards stays (R-3806).
            guard let copyNow = locate(to, in: entry) else { return true }
            let target = URL(fileURLWithPath: copyNow)
            let recorded = files ?? Self.stamps(of: URL(fileURLWithPath: from)) ?? []
            let changed = Self.changedFiles(in: target, recorded: recorded)
            if changed.isEmpty {
                do {
                    try fm.trashItem(at: target, resultingItemURL: nil)
                    if !to.hasSuffix(".json") {
                        report.restored += 1
                    }
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
                    if fm.fileExists(atPath: file.path) { try? fm.trashItem(at: file, resultingItemURL: nil) }
                }
            }
            report.skipped.append(changed.count == 1 && changed[0].isEmpty
                ? "\(target.lastPathComponent) changed since it was copied, so it was kept"
                : "\(changed.count) file\(changed.count == 1 ? "" : "s") in \(target.lastPathComponent) "
                    + "changed or were added since, so they were kept")
            return false
        case let .trash(original, trashed):
            let name = URL(fileURLWithPath: original).lastPathComponent
            guard !trashed.isEmpty, fm.fileExists(atPath: trashed) else {
                report.skipped.append("\(name) is no longer in the Trash")
                return false
            }
            let originalURL = URL(fileURLWithPath: original)
            guard let homePath = locate(originalURL.deletingLastPathComponent().path, in: entry),
                  Self.isFolder(URL(fileURLWithPath: homePath))
            else {
                report.skipped.append("\(name) was left in the Trash: its folder "
                    + "“\(originalURL.deletingLastPathComponent().lastPathComponent)” is no longer there")
                return false
            }
            let back = URL(fileURLWithPath: homePath).appendingPathComponent(name)
            guard !fm.fileExists(atPath: back.path) else {
                report.skipped.append("\(name) exists again")
                return false
            }
            do {
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: back)
                Self.note(original, at: back.path, in: &entry)
                if !original.hasSuffix(".json") {
                    report.restored += 1
                }
                return true
            } catch {
                report.skipped.append("\(name): \(error.localizedDescription)")
                return false
            }
        }
    }
}
