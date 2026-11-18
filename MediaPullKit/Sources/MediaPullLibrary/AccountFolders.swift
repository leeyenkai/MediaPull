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
        // Hashtags/<tag> and Saved posts hold many accounts' posts: never an account's folder, nor anything in them.
        if collectionFolder(containing: current, root: root) != nil { return nil }
        let top = root?.standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var account: String?
        var found: Match?
        var levels = 0
        while let here = dominantAccount(in: current), account == nil || here == account {
            account = here
            let name = current.lastPathComponent.lowercased()
            let parent = current.deletingLastPathComponent()
            // A highlight's title is never the account's folder, even when it is the account's name or a type's ("Stories").
            let inHighlights = parent.lastPathComponent.lowercased() == "highlights"
            let parentInside = top.map { parent.path == $0 || parent.path.hasPrefix($0 + "/") } ?? (parent.path != home)
            if typeFolders.contains(name), !inHighlights {
                // A type folder of the account's belongs to the folder above it, even when that folder holds other things
                // too (another account inside a library folder that is an account's, web saves): that is its folder.
                if parentInside {
                    found = Match(account: here, folder: parent.standardizedFileURL)
                    break
                }
            } else if inHighlights {
                // keep climbing
            } else if name == here {
                // A folder named after the account that holds only its media is its folder, whatever is inside.
                found = Match(account: here, folder: current)
                break
            } else if let kind = accountFolderKind(current, account: here) {
                found = Match(account: here, folder: current)
                if kind == .typeFolders { break }
            }
            levels += 1
            if current.path == top || current.path == "/" || parent.path == home || current.path == home { break }
            if let top, !(parent.path == top || parent.path.hasPrefix(top + "/")) { break }
            if top == nil, levels >= 4 { break }
            current = parent
        }
        return found
    }

    enum FolderKind { case typeFolders, ownFiles }

    /// The Hashtags or Saved posts folder `folder` is, or is inside (below `root` when there is one).
    public static func collectionFolder(containing folder: URL, root: URL?) -> URL? {
        let names = [SaveTarget.tagsFolder, SaveTarget.savedFolder].map { $0.lowercased() }
        var current = folder.standardizedFileURL
        let top = root?.standardizedFileURL.path
        while current.path != "/", current.path != top {
            if names.contains(current.lastPathComponent.lowercased()) { return current }
            current = current.deletingLastPathComponent()
        }
        return nil
    }

    /// A free name for a new account folder: the account's own, or numbered when a folder of that name holds something
    /// else (another account's files).
    public static func newFolder(named name: String, in parent: URL) -> URL {
        let base = FileNaming.safeTopFolder(name)
        var folder = parent.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base) \(number)", isDirectory: true)
            number += 1
        }
        return folder
    }

    /// Whether `folder` itself is `account`'s folder: it holds the account's type folders, or the account's own files.
    static func accountFolderKind(_ folder: URL, account: String) -> FolderKind? {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))
            ?? []
        for entry in entries where typeFolders.contains(entry.lastPathComponent.lowercased()) {
            // A type folder of the account's, or an empty one (its files sorted elsewhere) in a folder of the account's.
            if dominantAccount(in: entry) == account || !holdsMedia(entry) { return .typeFolders }
        }
        let own = entries.filter { $0.pathExtension.lowercased() != "json" && MediaFormat.fromExtension($0.pathExtension) != nil }
        if !own.isEmpty, sampledAccount(own.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(12)) == account {
            return .ownFiles
        }
        return nil
    }

    static func holdsMedia(_ folder: URL) -> Bool {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            if url.pathExtension.lowercased() != "json", MediaFormat.fromExtension(url.pathExtension) != nil { return true }
        }
        return false
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
        let sidecar = Sidecar.sidecarURL(for: file)
        guard !FileFlags.isDataless(sidecar), let data = try? Data(contentsOf: sidecar), data.count < 1 << 20,
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
            let sidecar = Sidecar.sidecarURL(for: url)
            // Metadata kept only in iCloud is not read (it would be downloaded): that file is not sampled.
            guard ext != "json", MediaFormat.fromExtension(ext) != nil, !FileFlags.isDataless(sidecar) else { return false }
            seen += 1
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
            let walker = fm.enumerator(at: subfolder, includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
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
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
            index.files += 1
            let sidecar = Sidecar.sidecarURL(for: url)
            // Metadata kept only in iCloud is not read (it would be downloaded): the name says what it can.
            let metadata = FileFlags.isDataless(sidecar) ? nil
                : (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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
        // Media directly in the folder (Archive or Plain names): it keeps everything flat.
        if entries.contains(where: { ($0 as NSString).pathExtension.lowercased() != "json"
                && MediaFormat.fromExtension(($0 as NSString).pathExtension) != nil })
        {
            return false
        }
        return nil
    }

    /// Where a pull of `account` into `saveFolder` goes (D-78): the account's folder when the save folder is it, is inside
    /// it, or contains it (searched three levels down, never inside another account's folder), else a folder named after
    /// the account that is already there, else nil for a new folder. An account folder is never made inside another
    /// account's folder: then the new one goes beside it.
    public static func resolveTarget(account: String, saveFolder: URL, root: URL?) -> (existing: URL?, parent: URL) {
        let account = account.lowercased()
        // From inside Hashtags or Saved posts, an account's folder goes beside that folder.
        if let collection = collectionFolder(containing: saveFolder, root: root) {
            return resolveTarget(account: account, saveFolder: collection.deletingLastPathComponent(), root: root)
        }
        if let match = detect(saveFolder, stopAt: root) {
            if match.account == account { return (match.folder, match.folder.deletingLastPathComponent()) }
            // Beside the other account's folder; when that folder is the library folder itself, inside it, never outside
            // the library.
            let isRoot = root.map { $0.standardizedFileURL.path == match.folder.standardizedFileURL.path } ?? false
            return (nil, isRoot ? match.folder : match.folder.deletingLastPathComponent())
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
                let lowered = folder.lastPathComponent.lowercased()
                if [SaveTarget.tagsFolder, SaveTarget.savedFolder].map({ $0.lowercased() }).contains(lowered) { continue }
                guard let owner = dominantAccount(in: folder) else {
                    next += subfolders(folder) // several accounts, or none: look inside
                    continue
                }
                guard owner == account else { continue } // another account's folder is never entered
                if let match = detect(folder, stopAt: saveFolder), match.account == account { return (match.folder, saveFolder) }
                next += subfolders(folder) // everything here is the account's: its folder may be further down
            }
            level = next
        }
        // A folder named after the account that holds nothing recognisable (Plain layout, older saves) is still its folder.
        // Found by its real spelling, whatever the letter case.
        let wanted = FileNaming.safeTopFolder(account).lowercased()
        // Hashtags and Saved posts are never an account's folder, even one named like them (audit 6, A6-m5).
        let collections = [SaveTarget.tagsFolder, SaveTarget.savedFolder].map { $0.lowercased() }
        if !collections.contains(wanted),
           let named = subfolders(saveFolder).first(where: { $0.lastPathComponent.lowercased() == wanted }),
           dominantAccount(in: named) == nil
        {
            return (named, saveFolder)
        }
        return (nil, saveFolder)
    }
}

/// What MediaPull remembers about each account folder (D-79): the items it ever saved there (so items deleted on purpose
/// stay deleted on Update), where an interrupted update stopped, and when the folder was last updated. One small JSON
/// file per folder in Application Support, found again through a bookmark when the folder moves.
/// A place in an account's posts listing from which posts may still be missing (D-87): where a walk stopped part way.
public struct ResumePlace: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    /// The engine's position in the posts listing, newest first.
    public var cursor: String
    /// True when posts may be missing all the way to the oldest (a walk with no early stop stopped here); false when the
    /// missing posts end where the folder's known posts begin (an update stopped here), so continuing may stop there too.
    public var untilEnd: Bool
    /// Continued as Find Missing: what the folder lacks, deleted files included (D-79).
    public var findMissing: Bool

    public init(id: UUID = UUID(), cursor: String, untilEnd: Bool, findMissing: Bool = false) {
        self.id = id
        self.cursor = cursor
        self.untilEnd = untilEnd
        self.findMissing = findMissing
    }
}

public struct AccountFolderRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var account: String
    public var path: String
    public var bookmark: Data?
    public var keys: Set<String>
    /// Written by 1.8 builds before D-87: one place, taken over into `places` when read.
    public var cursor: String?
    public var cursorFindMissing: Bool?
    /// Where posts may still be missing, in the order to continue them (D-87).
    public var places: [ResumePlace]?
    public var lastUpdate: Date?
    public var lastResult: String?
    /// The Instagram user id of the account this folder holds: a name taken over by someone else is never pulled into it
    /// (SPEC 23, audit 4, C4-M4).
    public var userID: String?
    /// The folder's identity on its disk (device and file number), which stays through renames and moves and the Trash:
    /// another folder made later at the same path is told apart from it (audit 6, C6-m2). Nil for older records.
    public var folderNumber: String?

    /// Whether an update or Find Missing stopped part way and can be continued.
    public var stoppedPartWay: Bool { !(places ?? []).isEmpty }

    public init(account: String, folder: URL) {
        id = UUID()
        self.account = account.lowercased()
        path = folder.standardizedFileURL.path
        bookmark = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        folderNumber = Self.number(of: folder)
        keys = []
    }

    static func number(of folder: URL) -> String? {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

public actor AccountFolderStore {
    let folder: URL
    private var records: [UUID: AccountFolderRecord] = [:]
    /// Paths of folders MediaPull renamed or moved this session, so a job queued with the old path still finds its folder.
    private var formerPaths: [String: UUID] = [:]
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
            if let cursor = record.cursor, (record.places ?? []).isEmpty {
                record.places = [ResumePlace(cursor: cursor, untilEnd: true, findMissing: record.cursorFindMissing ?? false)]
                record.cursor = nil
                record.cursorFindMissing = nil
                save(record)
            }
            records[record.id] = record
        }
        followMoves()
        // A folder deleted for good forgets its record; one on a disk that is not connected, or in the Trash (it can still be
        // put back), keeps it (lifecycle, SPEC 6.3).
        for record in records.values where !FileManager.default.fileExists(atPath: record.path) && Self.volumeMounted(record.path) {
            if let url = Self.resolve(record), FileManager.default.fileExists(atPath: url.path) { continue }
            forget(record.id)
        }
        // Two records of one folder (a move found twice, a change of letter case) become one, with the items of both.
        let grouped = Dictionary(grouping: records.values) { "\($0.account)\u{0}\(Self.key($0.path))" }
        for (_, same) in grouped where same.count > 1 {
            let sorted = same.sorted { ($0.lastUpdate ?? .distantPast) > ($1.lastUpdate ?? .distantPast) }
            var kept = sorted[0]
            for other in sorted.dropFirst() {
                kept.keys.formUnion(other.keys)
                // Where either stopped part way stays (audit 4, A4-m3).
                let keptIDs = Set((kept.places ?? []).map(\.id))
                let more = (other.places ?? []).filter { !keptIDs.contains($0.id) }
                if !more.isEmpty { kept.places = (kept.places ?? []) + more }
                if kept.lastResult == nil { kept.lastResult = other.lastResult }
                if kept.userID == nil { kept.userID = other.userID }
                forget(other.id)
            }
            records[kept.id] = kept
            save(kept)
        }
    }

    /// Folders renamed or moved in the Finder are found again through their bookmarks, while MediaPull runs too, including
    /// a change of letter case only (the old spelling still "exists" on most Mac volumes). A folder in the Trash is not
    /// followed there: it is gone for now, and its record waits in case it is put back.
    private func followMoves() {
        for (id, var record) in records {
            guard let url = Self.resolve(record), !FileFlags.isInTrash(url) else { continue }
            let path = url.standardizedFileURL.path
            guard path != record.path, FileManager.default.fileExists(atPath: path) else { continue }
            // A job queued with the old path still finds it (audit 6, C6-M2).
            formerPaths[Self.key(record.path)] = id
            record.path = path
            record.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            records[id] = record
            save(record)
        }
    }

    static func resolve(_ record: AccountFolderRecord) -> URL? {
        var stale = false
        guard let bookmark = record.bookmark else { return nil }
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }

    /// Paths compared as the Mac's usual volumes compare them: without regard to letter case or Unicode form.
    public static func key(_ path: String) -> String {
        // Standardizing drops "/private" only while the path exists, so a folder moved away would get another key; the
        // prefix is dropped either way.
        var path = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            path = String(path.dropFirst("/private".count))
        }
        return path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Where a remembered folder is now (after Finder moves while running), or nil when it is gone.
    /// Where the folder of record `id` is now (followed through Finder and MediaPull moves); nil when it is gone or in the
    /// Trash. A running pull checks this, so it never recreates a folder renamed or trashed meanwhile (audit 4, A4-M5).
    public func currentFolder(of id: UUID) -> URL? {
        load()
        followMoves()
        guard let record = records[id], FileManager.default.fileExists(atPath: record.path),
              !FileFlags.isInTrash(URL(fileURLWithPath: record.path)) else { return nil }
        return URL(fileURLWithPath: record.path, isDirectory: true)
    }

    /// Where the folder a job was given is now. A folder MediaPull renamed or moved since is found by its former path
    /// (audit 5, C5-M4); one in the Trash counts as gone.
    public func currentFolder(for url: URL) -> URL? {
        load()
        let key = Self.key(url.path)
        var ids = records.values.filter { Self.key($0.path) == key }.map(\.id)
        if let id = formerPaths[key] { ids.append(id) }
        followMoves()
        for id in ids {
            if let record = records[id], FileManager.default.fileExists(atPath: record.path),
               !FileFlags.isInTrash(URL(fileURLWithPath: record.path))
            {
                return URL(fileURLWithPath: record.path, isDirectory: true)
            }
        }
        return FileManager.default.fileExists(atPath: url.path) && !FileFlags.isInTrash(url) ? url : nil
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
        let key = Self.key(url.path)
        followMoves()
        // A record of another folder that was at this path (since trashed or deleted) belongs to that folder: a new folder
        // made at the path starts afresh, with none of its places, items or account id (audit 6, C6-m2). The old record
        // goes: nothing can be put back at a path another folder now holds.
        let number = AccountFolderRecord.number(of: url)
        for other in records.values where Self.key(other.path) == key && other.account == account.lowercased()
            && other.folderNumber != nil && number != nil && other.folderNumber != number
        {
            forget(other.id)
        }
        if var existing = records.values.first(where: { Self.key($0.path) == key && $0.account == account.lowercased() }) {
            if existing.folderNumber == nil, let number {
                existing.folderNumber = number
                records[existing.id] = existing
                save(existing)
            }
            // The folder's spelling as it is now.
            let path = url.standardizedFileURL.path
            // The bookmark is made again from the folder in hand: one made for an earlier folder at this path (now in the
            // Trash) still resolves here by path, but would follow the old folder after a rename (audit 4, C4-m6).
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if existing.path != path || (bookmark != nil && bookmark != existing.bookmark) {
                existing.path = path
                if let bookmark { existing.bookmark = bookmark }
                records[existing.id] = existing
                save(existing)
            }
            return existing
        }
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

    /// Adds a place, or moves it on when one with its id is already there (D-87).
    public func setPlace(_ place: ResumePlace, in id: UUID) {
        guard var record = records[id] else { return }
        var places = record.places ?? []
        if let index = places.firstIndex(where: { $0.id == place.id }) { places[index] = place } else { places.append(place) }
        record.places = places
        records[id] = record
        save(record)
    }

    public func removePlace(_ placeID: UUID, in id: UUID) {
        guard var record = records[id], (record.places ?? []).contains(where: { $0.id == placeID }) else { return }
        record.places?.removeAll { $0.id == placeID }
        records[id] = record
        save(record)
    }

    /// A walk from the top with no early stop covers everything after its own place: it replaces all others.
    public func replacePlaces(with places: [ResumePlace], in id: UUID) {
        guard var record = records[id] else { return }
        record.places = places
        records[id] = record
        save(record)
    }

    /// The place as it is now, or nil when it is gone (continued or replaced meanwhile).
    public func place(_ placeID: UUID, in id: UUID) -> ResumePlace? {
        load()
        return records[id]?.places?.first { $0.id == placeID }
    }

    public func update(_ id: UUID, lastUpdate: Date? = nil, lastResult: String? = nil, userID: String? = nil) {
        guard var record = records[id] else { return }
        if let lastUpdate { record.lastUpdate = lastUpdate }
        if let lastResult { record.lastResult = lastResult }
        if let userID, !userID.isEmpty { record.userID = userID }
        records[id] = record
        save(record)
    }

    /// Folders renamed or moved inside MediaPull keep their record.
    public func moveFolders(_ moves: [(from: String, to: String)]) {
        load()
        for (id, var record) in records {
            // Compared by key: the journal and the record may spell one path differently ("/private", letter case, Unicode).
            for (from, to) in moves {
                let path = Self.key(record.path), old = Self.key(from)
                guard path == old || path.hasPrefix(old + "/") else { continue }
                formerPaths[path] = id
                let depth = URL(fileURLWithPath: path).pathComponents.count - URL(fileURLWithPath: old).pathComponents.count
                let below = URL(fileURLWithPath: record.path).pathComponents.suffix(depth)
                record.path = below.reduce(URL(fileURLWithPath: to, isDirectory: true)) { $0.appendingPathComponent($1) }.path
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
