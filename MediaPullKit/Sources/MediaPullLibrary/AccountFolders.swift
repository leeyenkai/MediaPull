import Foundation
import MediaPullCore
import MediaPullEngines

/// Folders that hold an Instagram account (D-78): recognised from their own metadata files, so a folder that was renamed,
/// moved in the Finder or made before MediaPull kept records is still an account folder.
public enum AccountFolders {
    public struct Match: Sendable, Hashable {
        public var account: String
        public var folder: URL

        public init(account: String, folder: URL) {
            self.account = account
            self.folder = folder
        }
    }

    /// The folders a pull sorts an account into (D-54).
    static let typeFolders: Set<String> = ["posts", "reels", "stories", "highlights", "profile pictures", "tagged", "reposts"]

    /// The account folder `folder` is, or is inside (D-78). Climbing from `folder` while everything sampled below still
    /// belongs to one account, the account folder is the nearest folder named after the account or holding its type
    /// folders, or else the highest one holding the account's own files. A folder with no media (an empty one, a web-saves one) never makes
    /// its
    /// parent an account folder. Without a library root the climb stops at the home folder and after a few levels.
    public static func detect(_ folder: URL, stopAt root: URL?) -> Match? {
        var current = folder.standardizedFileURL
        let top = root?.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var account: String?
        var found: Match?
        var levels = 0
        while let here = dominantAccount(in: current), account == nil || here == account {
            account = here
            // A folder named after the account that holds only its media is its folder, whatever is inside.
            if current.lastPathComponent.lowercased() == here {
                found = Match(account: here, folder: current)
                break
            }
            if let kind = accountFolderKind(current, account: here) {
                found = Match(account: here, folder: current)
                if kind == .typeFolders { break }
            }
            levels += 1
            let parent = current.deletingLastPathComponent()
            if current.path == top || current.path == "/" || parent.path == home || current.path == home { break }
            if let top, !(parent.path == top || parent.path.hasPrefix(top + "/")) { break }
            if top == nil, levels >= 4 { break }
            current = parent
        }
        return found
    }

    enum FolderKind { case typeFolders, ownFiles }

    /// Whether `folder` itself is `account`'s folder: it holds the account's type folders, or the account's own files.
    static func accountFolderKind(_ folder: URL, account: String) -> FolderKind? {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
            ?? []
        for entry in entries where typeFolders.contains(entry.lastPathComponent.lowercased()) {
            if dominantAccount(in: entry) == account { return .typeFolders }
        }
        let own = entries.filter { $0.pathExtension.lowercased() != "json" && MediaFormat.fromExtension($0.pathExtension) != nil }
        if !own.isEmpty, sampledAccount(own.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(12)) == account {
            return .ownFiles
        }
        return nil
    }

    /// The account four in five of these media files belong to, by their metadata files.
    static func sampledAccount(_ files: some Collection<URL>) -> String? {
        var counts: [String: Int] = [:]
        for file in files {
            if let user = instagramUser(of: file) { counts[user, default: 0] += 1 }
        }
        guard let best = counts.max(by: { $0.value < $1.value }), best.value * 5 >= files.count * 4 else { return nil }
        return best.key
    }

    static func instagramUser(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: Sidecar.sidecarURL(for: file)), data.count < 1 << 20,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], (json["category"] as? String) == "instagram",
              let user = (json["username"] as? String)?.lowercased(), !user.isEmpty
        else { return nil }
        return user
    }

    /// The account four in five of a sample of `folder`'s media files belong to, by their metadata files. Every sampled
    /// file votes, so web saves and pictures without metadata beside an account's folder keep their parent from being taken
    /// for it. The sample is spread over the folder's own files and each subfolder, so a folder of several accounts is never
    /// taken for its first one.
    static func dominantAccount(in folder: URL) -> String? {
        let fm = FileManager.default
        var counts: [String: Int] = [:]
        var seen = 0
        func vote(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { return false }
            seen += 1
            let sidecar = Sidecar.sidecarURL(for: url)
            guard let data = try? Data(contentsOf: sidecar), data.count < 1 << 20,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["category"] as? String) == "instagram", let user = (json["username"] as? String)?.lowercased(), !user.isEmpty
            else { return true }
            counts[user, default: 0] += 1
            return true
        }
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles]))?
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        var own = 0
        for file in entries where own < 12 {
            if vote(file) { own += 1 }
        }
        let subfolders = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && $0.lastPathComponent != SaveTarget.accountDetailsFolder
        }
        for subfolder in subfolders.prefix(40) where seen < 80 {
            var taken = 0
            let walker = fm.enumerator(at: subfolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL, taken < 6 {
                if vote(url) { taken += 1 }
            }
        }
        guard seen > 0, let best = counts.max(by: { $0.value < $1.value }), best.value * 5 >= seen * 4 else { return nil }
        return best.key
    }

    /// What an account folder holds: every Instagram item's identities (D-79), and how many posts and Reels it has.
    public struct Index: Sendable {
        public var identities: Set<String> = []
        public var files = 0

        public init() {}
    }

    /// Reads every file's metadata file when it has one (names alone are trusted only without one: a custom naming template
    /// can put another id where the default puts the media's). Includes every subfolder: Organise sorts, group photos and
    /// moved files all count.
    public static func index(_ folder: URL) -> Index {
        var index = Index()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
            index.files += 1
            let sidecar = Sidecar.sidecarURL(for: url)
            let metadata = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            // The metadata says which item a file is; the name is read only when the metadata does not name the media
            // itself (files saved before 1.8, or no metadata at all).
            if let metadata, (metadata["category"] as? String) == "instagram" {
                index.identities.formUnion(InstagramIdentity.identities(fileName: "", metadata: metadata))
                if metadata["media_id"] == nil { index.identities.formUnion(InstagramIdentity.identities(fileName: name)) }
            } else {
                index.identities.formUnion(InstagramIdentity.identities(fileName: name))
            }
        }
        return index
    }

    /// Whether an account folder keeps posts, Reels and profile pictures in folders of their own, from what it holds;
    /// nil when it holds neither kind yet (Settings decides).
    public static func sortsByType(_ folder: URL) -> Bool? {
        let fm = FileManager.default
        for name in ["posts", "reels", "profile pictures"] where fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
            return true
        }
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        if entries.contains(where: { InstagramIdentity.nameSuffices($0) }) { return false }
        return nil
    }

    /// Where a pull of `account` into `saveFolder` goes (D-78): the account's folder when the save folder is it, is inside
    /// it, or contains it (searched three levels down, never inside another account's folder), else a folder named after
    /// the account that is already there, else nil for a new folder. An account folder is never made inside another
    /// account's folder: then the new one goes beside it.
    public static func resolveTarget(account: String, saveFolder: URL, root: URL?) -> (existing: URL?, parent: URL) {
        let account = account.lowercased()
        if let match = detect(saveFolder, stopAt: root) {
            if match.account == account { return (match.folder, match.folder.deletingLastPathComponent()) }
            return (nil, match.folder.deletingLastPathComponent())
        }
        let fm = FileManager.default
        func subfolders(_ folder: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                // The account's name first at each level, then the rest in order.
                .sorted { ($0.lastPathComponent.lowercased() == account ? 0 : 1, $0.lastPathComponent) <
                    ($1.lastPathComponent.lowercased() == account ? 0 : 1, $1.lastPathComponent) }
        }
        var level = subfolders(saveFolder)
        var visited = 0
        for _ in 0 ..< 3 where !level.isEmpty {
            var next: [URL] = []
            for folder in level where visited < 300 {
                visited += 1
                guard let owner = dominantAccount(in: folder) else {
                    next += subfolders(folder) // several accounts, or none: look inside
                    continue
                }
                guard owner == account else { continue } // another account's folder is never entered
                if let match = detect(folder, stopAt: saveFolder), match.account == account { return (match.folder, saveFolder) }
            }
            level = next
        }
        // A folder named after the account that holds nothing recognisable (Plain layout, older saves) is still its folder.
        let named = saveFolder.appendingPathComponent(FileNaming.safeTopFolder(account), isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: named.path, isDirectory: &isDirectory), isDirectory.boolValue, dominantAccount(in: named) == nil {
            return (named, saveFolder)
        }
        return (nil, saveFolder)
    }
}

/// What MediaPull remembers about each account folder (D-79): the items it ever saved there (so items deleted on purpose
/// stay deleted on Update), where an interrupted update stopped, and when the folder was last updated. One small JSON
/// file per folder in Application Support, found again through a bookmark when the folder moves.
public struct AccountFolderRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var account: String
    public var path: String
    public var bookmark: Data?
    public var keys: Set<String>
    public var cursor: String?
    public var lastUpdate: Date?
    public var lastResult: String?

    public init(account: String, folder: URL) {
        id = UUID()
        self.account = account.lowercased()
        path = folder.standardizedFileURL.path
        bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        keys = []
    }
}

public actor AccountFolderStore {
    let folder: URL
    private var records: [UUID: AccountFolderRecord] = [:]
    private var loaded = false

    public init(folder: URL) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        EnginePaths.defaultSupport.appendingPathComponent("AccountFolders", isDirectory: true)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let record = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(AccountFolderRecord.self, from: $0) })
            else { continue }
            records[record.id] = record
        }
        followMoves()
        // A folder deleted for good forgets its record; one on a disk that is not connected keeps it (lifecycle, SPEC 6.3).
        for record in records.values where !FileManager.default.fileExists(atPath: record.path) && Self.volumeMounted(record.path) {
            forget(record.id)
        }
        // Two records of one folder (a move found twice) become one, with the items of both.
        let grouped = Dictionary(grouping: records.values) { "\($0.account)\u{0}\($0.path)" }
        for (_, same) in grouped where same.count > 1 {
            let sorted = same.sorted { ($0.lastUpdate ?? .distantPast) > ($1.lastUpdate ?? .distantPast) }
            var kept = sorted[0]
            for other in sorted.dropFirst() {
                kept.keys.formUnion(other.keys)
                kept.cursor = kept.cursor ?? other.cursor
                forget(other.id)
            }
            records[kept.id] = kept
            save(kept)
        }
    }

    /// Folders renamed or moved in the Finder are found again through their bookmarks, while MediaPull runs too. A folder
    /// moved to the Trash counts as gone.
    private func followMoves() {
        for (id, var record) in records where !FileManager.default.fileExists(atPath: record.path) {
            var stale = false
            guard let bookmark = record.bookmark,
                  let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                     bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path), !url.pathComponents.contains(".Trash")
            else { continue }
            record.path = url.standardizedFileURL.path
            record.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            records[id] = record
            save(record)
        }
    }

    private func forget(_ id: UUID) {
        records[id] = nil
        // lint:allow silent-write a record that cannot be removed is only found again and pruned next time
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(id.uuidString).json"))
    }

    static func volumeMounted(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    /// The record of an account's folder, made when there is none yet.
    public func record(account: String, folder url: URL) -> AccountFolderRecord {
        load()
        let path = url.standardizedFileURL.path
        if !records.values.contains(where: { $0.path == path }) { followMoves() }
        if let existing = records.values.first(where: { $0.path == path && $0.account == account.lowercased() }) { return existing }
        let record = AccountFolderRecord(account: account, folder: url)
        records[record.id] = record
        save(record)
        return record
    }

    /// Every remembered account folder that still exists.
    public func all() -> [AccountFolderRecord] {
        load()
        followMoves()
        return records.values.filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.path < $1.path }
    }

    public func addKeys(_ keys: Set<String>, to id: UUID) {
        guard var record = records[id], !keys.isSubset(of: record.keys) else { return }
        record.keys.formUnion(keys)
        records[id] = record
        save(record)
    }

    public func update(_ id: UUID, cursor: String?? = nil, lastUpdate: Date? = nil, lastResult: String? = nil) {
        guard var record = records[id] else { return }
        if let cursor { record.cursor = cursor }
        if let lastUpdate { record.lastUpdate = lastUpdate }
        if let lastResult { record.lastResult = lastResult }
        records[id] = record
        save(record)
    }

    /// Folders renamed or moved inside MediaPull keep their record.
    public func moveFolders(_ moves: [(from: String, to: String)]) {
        load()
        for (id, var record) in records {
            for (from, to) in moves where record.path == from || record.path.hasPrefix(from + "/") {
                record.path = to + record.path.dropFirst(from.count)
                record.bookmark = try? URL(fileURLWithPath: record.path).bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                                                        relativeTo: nil)
                records[id] = record
                save(record)
            }
        }
    }

    private func save(_ record: AccountFolderRecord) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        // lint:allow silent-write losing this record only means an Update looks at the folder itself, which it always does
        try? data.write(to: folder.appendingPathComponent("\(record.id.uuidString).json"), options: .atomic)
    }
}
