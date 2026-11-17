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

    /// The account folder `folder` is, or is inside: the highest folder (up to `root`) whose metadata files name one
    /// Instagram account for at least four in five of a sample. Nil for a folder of several accounts or none.
    public static func detect(_ folder: URL, stopAt root: URL?) -> Match? {
        var current = folder.standardizedFileURL
        let top = root?.standardizedFileURL.path
        var found: Match?
        while true {
            if let account = dominantAccount(in: current) {
                if let found, found.account != account { break }
                found = Match(account: account, folder: current)
            } else if found != nil {
                break // above the account's folder: a folder of several accounts
            }
            guard current.path != top, current.path != "/" else { break }
            let parent = current.deletingLastPathComponent()
            if let top, !(parent.path == top || parent.path.hasPrefix(top + "/")) { break }
            current = parent
        }
        return found.map(narrowed)
    }

    /// A folder whose only content is one subfolder of the same account (a library holding one account) is not the
    /// account's folder: that subfolder is.
    static func narrowed(_ match: Match) -> Match {
        var folder = match.folder
        while true {
            let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles])) ?? []
            let subfolders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            let ownMedia = entries.contains {
                MediaFormat.fromExtension($0.pathExtension) != nil && $0.pathExtension.lowercased() != "json"
            }
            let typeFolder = subfolders.contains { ["posts", "reels", "stories", "highlights", "profile pictures", "tagged", "reposts"]
                .contains($0.lastPathComponent.lowercased()) }
            guard !ownMedia, !typeFolder, subfolders.count == 1, dominantAccount(in: subfolders[0]) == match.account else { break }
            folder = subfolders[0].standardizedFileURL
        }
        return Match(account: match.account, folder: folder)
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

    /// Reads names only, except for files whose name does not say which item they are (renamed ones, profile pictures),
    /// whose metadata file is read. Includes every subfolder: Organise sorts, group photos and moved files all count.
    public static func index(_ folder: URL) -> Index {
        var index = Index()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
            index.files += 1
            var metadata: [String: Any]?
            if !InstagramIdentity.nameSuffices(name) {
                let sidecar = Sidecar.sidecarURL(for: url)
                metadata = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            index.identities.formUnion(InstagramIdentity.identities(fileName: name, metadata: metadata))
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

    /// Where a pull of `account` into `saveFolder` goes: the save folder itself when it is (or is inside) that account's
    /// folder, a folder of the account inside the save folder whatever it is called, or nil for a new folder. An account
    /// folder is never made inside another account's folder: then the new one goes beside it.
    public static func resolveTarget(account: String, saveFolder: URL, root: URL?) -> (existing: URL?, parent: URL) {
        let account = account.lowercased()
        if let match = detect(saveFolder, stopAt: root) {
            if match.account == account { return (match.folder, match.folder.deletingLastPathComponent()) }
            return (nil, match.folder.deletingLastPathComponent())
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: saveFolder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        let named = children.first { $0.lastPathComponent.lowercased() == account }
        for child in ([named].compactMap(\.self) + children.filter { $0 != named })
            where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        {
            if dominantAccount(in: child) == account { return (child, saveFolder) }
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
            guard var record = (try? Data(contentsOf: file)).flatMap({ try? JSONDecoder().decode(AccountFolderRecord.self, from: $0) })
            else { continue }
            // A folder moved or renamed in the Finder is found again through its bookmark.
            var stale = false
            if let bookmark = record.bookmark,
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                  bookmarkDataIsStale: &stale), url.standardizedFileURL.path != record.path
            {
                record.path = url.standardizedFileURL.path
                record.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                save(record)
            }
            records[record.id] = record
        }
    }

    /// The record of an account's folder, made when there is none yet.
    public func record(account: String, folder url: URL) -> AccountFolderRecord {
        load()
        let path = url.standardizedFileURL.path
        if let existing = records.values.first(where: { $0.path == path && $0.account == account.lowercased() }) { return existing }
        let record = AccountFolderRecord(account: account, folder: url)
        records[record.id] = record
        save(record)
        return record
    }

    /// Every remembered account folder that still exists.
    public func all() -> [AccountFolderRecord] {
        load()
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
