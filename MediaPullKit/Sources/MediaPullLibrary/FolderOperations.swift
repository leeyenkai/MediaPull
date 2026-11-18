import Foundation
import MediaPullCore

// MARK: Plans (SPEC section 38)

public struct PlannedMove: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case move, clone }

    public var source: URL
    public var destination: URL
    public var kind: Kind

    public init(source: URL, destination: URL, kind: Kind = .move) {
        self.source = source
        self.destination = destination
        self.kind = kind
    }
}

/// What an operation will do, shown in the preview sheet before anything moves (R-3805).
public struct OrganisePlan: Sendable {
    public var title: String
    public var root: URL
    public var foldersToCreate: [URL] = []
    public var moves: [PlannedMove] = []
    /// Folders moved to the Trash at the end, only if no files are left in them.
    public var foldersToTrash: [URL] = []
    public var itemsToTrash: [URL] = []
    public var unsorted = 0
    public var renamed = 0
    public var unchanged = 0
    /// Folders that must still be there when the plan runs: a merge into a folder trashed or renamed since its preview
    /// stops rather than making the folder again (audit 4, B4-M1).
    public var requiredFolders: [URL] = []
    /// A plan works inside its root, which must be there when it runs (audit 5, B5-M1): a folder renamed, moved or
    /// trashed since, even before the plan was made, is never made again (audit 7, B7-m2). Only a plan that says so makes
    /// its root (a copy into a new folder).
    public var createsRoot = false

    public init(title: String, root: URL) {
        self.title = title
        self.root = root
    }

    public var isEmpty: Bool {
        moves.isEmpty && foldersToTrash.isEmpty && itemsToTrash.isEmpty && foldersToCreate.isEmpty
    }

    public var cloneCount: Int {
        moves.filter { $0.kind == .clone }.count
    }

    /// Destination folders with their file counts, largest first, for the preview.
    public var destinations: [(folder: URL, files: [URL])] {
        var byFolder: [URL: [URL]] = [:]
        for move in moves {
            byFolder[move.destination.deletingLastPathComponent().standardizedFileURL, default: []].append(move.source)
        }
        return byFolder.map { ($0.key, $0.value) }.sorted { $0.files.count == $1.files.count ? $0.folder.path < $1.folder.path
            : $0.files.count > $1.files.count
        }
    }

    /// Whether the copies take no extra space: the volume clones files and every source is on it. Copies from another
    /// volume are full copies.
    public var clonesAreFree: Bool {
        let keys: Set<URLResourceKey> = [.volumeSupportsFileCloningKey, .volumeIdentifierKey]
        guard let values = try? root.resourceValues(forKeys: keys), values.volumeSupportsFileCloning == true,
              let volume = values.volumeIdentifier as? NSObject
        else { return false }
        return moves.filter { $0.kind == .clone }.allSatisfy { move in
            (try? move.source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject) == volume
        }
    }

    /// Whether the plan moves, renames or trashes one of `folders` or a folder that holds one. Library folders change only
    /// through the Library's own commands, so their saves, records and analysis follow; copies leave the source as it was
    /// and are allowed (audit 4, B4-M2).
    public func changes(anyOf folders: [URL]) -> Bool {
        let keys = folders.map(Self.key)
        func touches(_ url: URL) -> Bool {
            let key = Self.key(url)
            return keys.contains { $0 == key || $0.hasPrefix(key + "/") }
        }
        return itemsToTrash.contains(where: touches) || foldersToTrash.contains(where: touches)
            || moves.contains { $0.kind != .clone && touches($0.source) }
    }

    /// Paths compared as a Mac volume does: letter case and Unicode form aside.
    static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Where each moved item ends up, keyed by its standardized path, following renames through temporary names.
    public var finalDestinations: [String: URL] {
        // Played in order: each place remembers which original item is there now.
        var origin: [String: String] = [:]
        var places: [String: URL] = [:]
        for move in moves where move.kind == .move {
            let from = move.source.standardizedFileURL.path, to = move.destination.standardizedFileURL.path
            origin[to] = origin.removeValue(forKey: from) ?? from
            places.removeValue(forKey: from)
            places[to] = move.destination
        }
        var result: [String: URL] = [:]
        for (place, item) in origin {
            if let url = places[place] { result[item] = url }
        }
        return result
    }

    public var cloneBytes: Int64 {
        moves.filter { $0.kind == .clone }.reduce(0) { total, move in
            total + Int64((try? move.source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}

/// Where a photo of several people goes when sorting by person (D-64).
public enum GroupPhotoPlacement: String, Codable, Sendable, CaseIterable {
    case everyPerson, sharedFolder, firstPerson

    public var label: String {
        switch self {
        case .everyPerson: "In every person's folder"
        case .sharedFolder: "In a shared Group photos folder"
        case .firstPerson: "In the first person's folder only"
        }
    }
}

public enum FolderNames {
    public static let unsorted = "Unsorted"
    public static let groupPhotos = "Group photos"
    public static let screenshots = "Screenshots"
    public static let photos = "Photos"

    /// A folder name that is safe on disk and never one of the reserved names (R-1505).
    public static func safe(_ name: String) -> String {
        let clean = FileNaming.sanitize(name, maxBytes: 120).trimmingCharacters(in: .whitespaces)
        let base = clean.isEmpty ? "Untitled" : clean
        return FileNaming.reservedFolders.contains(base.lowercased()) ? "_" + base : base
    }
}

public enum FolderOperations {
    static let ignored: Set<String> = [".DS_Store", ".localized"]

    /// Media files in a folder (sidecars and hidden files excluded), optionally in every subfolder too.
    public static func mediaFiles(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        var result: [URL] = []
        if recursive {
            let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL {
                if isMedia(url) {
                    result.append(url)
                }
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            result = items.filter(isMedia)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func isMedia(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
        let ext = url.pathExtension.lowercased()
        guard ext != "json", let format = MediaFormat.fromExtension(ext) else { return false }
        return [.image, .animatedImage, .video, .vector].contains(format.kind)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// A folder that is not a package: packages (a photo library, an app) are single items, never opened up and merged.
    static func isPlainFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// The items of a selection that are not inside another selected folder: a folder moved, copied or trashed takes
    /// what is inside it along, so those items are not planned again (audit 4, B4-m13).
    public static func outermost(_ items: [URL]) -> [URL] {
        let paths = Set(items.map { $0.standardizedFileURL.path })
        var seen = Set<String>()
        return items.filter { item in
            let path = item.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            var parent = (path as NSString).deletingLastPathComponent
            while parent != "/", !parent.isEmpty {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    static func children(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))
            ?? []).filter { $0.pathExtension.lowercased() != "json" || !hasMedia(forSidecar: $0) }
    }

    /// `photo.jpg.json` belongs to `photo.jpg` and moves with it.
    static func hasMedia(forSidecar url: URL) -> Bool {
        let media = url.deletingPathExtension()
        return !media.pathExtension.isEmpty && FileManager.default.fileExists(atPath: media.path)
    }

    // MARK: Collisions

    /// Whether two folder paths name the same folder: equal, or (on a case-insensitive volume) differing only in letter
    /// case or Unicode form, which the volume treats as one name.
    public static func samePlace(_ a: URL, _ b: URL) -> Bool {
        let x = a.standardizedFileURL.path, y = b.standardizedFileURL.path
        if x == y { return true }
        guard x.precomposedStringWithCanonicalMapping.lowercased() == y.precomposedStringWithCanonicalMapping.lowercased() else {
            return false
        }
        return OperationJournal.sameFile(x, y)
    }

    /// Picks a free name in `folder`, numbering `name 2.jpg`, `name 3.jpg` so an Archive date prefix stays first.
    public static func freeDestination(for name: String, in folder: URL, taken: inout Set<String>) -> (url: URL, renamed: Bool) {
        let ns = name as NSString
        let stem = ns.deletingPathExtension, ext = ns.pathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            let url = folder.appendingPathComponent(candidate)
            let key = OrganisePlan.key(url)
            if !taken.contains(key), !FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.fileExists(atPath: Sidecar.sidecarURL(for: url).path) || ext.isEmpty
            {
                taken.insert(key)
                return (url, n > 1)
            }
            n += 1
        }
    }

    // MARK: Folder operations (R-3803)

    /// Every media file from all subfolders moved up into `folder`; emptied subfolders go to the Trash.
    public static func flatten(_ folder: URL) -> OrganisePlan {
        var plan = OrganisePlan(title: "Flatten \(folder.lastPathComponent)", root: folder)
        var taken = Set<String>()
        let top = folder.standardizedFileURL
        for file in mediaFiles(in: folder, recursive: true) where file.deletingLastPathComponent().standardizedFileURL != top {
            let dest = freeDestination(for: file.lastPathComponent, in: folder, taken: &taken)
            if dest.renamed {
                plan.renamed += 1
            }
            plan.moves.append(PlannedMove(source: file, destination: dest.url))
        }
        plan.foldersToTrash = children(folder).filter(isDirectory)
        return plan
    }

    /// Each subfolder's contents moved up one level into its parent; the emptied subfolders go to the Trash.
    public static func removeSubfolders(_ subfolders: [URL]) -> OrganisePlan {
        let root = subfolders.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        var plan = OrganisePlan(
            title: subfolders.count == 1 ? "Remove \(subfolders[0].lastPathComponent)" : "Remove \(subfolders.count) Folders",
            root: root
        )
        var taken = Set<String>()
        for folder in subfolders {
            let parent = folder.deletingLastPathComponent()
            for child in children(folder) {
                let dest = freeDestination(for: child.lastPathComponent, in: parent, taken: &taken)
                if dest.renamed {
                    plan.renamed += 1
                }
                plan.moves.append(PlannedMove(source: child, destination: dest.url))
            }
            plan.foldersToTrash.append(folder)
        }
        return plan
    }

    /// `source`'s contents moved into `target`; folders with the same name are merged too. `source` then goes to the Trash.
    public static func merge(_ source: URL, into target: URL) -> OrganisePlan {
        var plan = OrganisePlan(title: "Merge \(source.lastPathComponent) into \(target.lastPathComponent)", root: target)
        guard !contains(source, target), !contains(target, source) else { return plan }
        plan.requiredFolders = [source, target]
        var taken = Set<String>()
        func merge(_ from: URL, _ to: URL) {
            for child in children(from) {
                let existing = to.appendingPathComponent(child.lastPathComponent)
                if isPlainFolder(child), isPlainFolder(existing) {
                    merge(child, existing)
                    plan.foldersToTrash.append(child)
                } else {
                    let dest = freeDestination(for: child.lastPathComponent, in: to, taken: &taken)
                    if dest.renamed {
                        plan.renamed += 1
                    }
                    plan.moves.append(PlannedMove(source: child, destination: dest.url))
                }
            }
        }
        merge(source, target)
        plan.foldersToTrash.append(source)
        return plan
    }

    /// Whether `url` is `folder` or lies inside it. A folder is never moved, copied or merged into itself, which would
    /// recurse until the path is too long.
    static func contains(_ folder: URL, _ url: URL) -> Bool {
        let top = folder.standardizedFileURL.path, path = url.standardizedFileURL.path
        return path == top || path.hasPrefix(top.hasSuffix("/") ? top : top + "/")
    }

    public static func move(_ items: [URL], to folder: URL) -> OrganisePlan {
        let items = outermost(items)
        var plan = OrganisePlan(title: items.count == 1 ? "Move \(items[0].lastPathComponent)" : "Move \(items.count) Items", root: folder)
        var taken = Set<String>()
        let target = folder.standardizedFileURL
        for item in items where item.deletingLastPathComponent().standardizedFileURL != target && !contains(item, folder) {
            let dest = freeDestination(for: item.lastPathComponent, in: folder, taken: &taken)
            if dest.renamed {
                plan.renamed += 1
            }
            plan.moves.append(PlannedMove(source: item, destination: dest.url))
        }
        return plan
    }

    /// Copies (APFS clones where possible) into `folder`, leaving the originals where they are.
    public static func copy(_ items: [URL], to folder: URL) -> OrganisePlan {
        let items = outermost(items)
        var plan = OrganisePlan(title: items.count == 1 ? "Copy \(items[0].lastPathComponent)" : "Copy \(items.count) Items", root: folder)
        var taken = Set<String>()
        for item in items where !contains(item, folder) {
            let dest = freeDestination(for: item.lastPathComponent, in: folder, taken: &taken)
            if dest.renamed { plan.renamed += 1 }
            plan.moves.append(PlannedMove(source: item, destination: dest.url, kind: .clone))
        }
        return plan
    }

    public static func trash(_ items: [URL]) -> OrganisePlan {
        let items = outermost(items)
        var plan = OrganisePlan(
            title: items.count == 1 ? "Move \(items[0].lastPathComponent) to Trash" : "Move \(items.count) Items to Trash",
            root: items.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        )
        plan.itemsToTrash = items
        return plan
    }

    public static func newFolder(named name: String, in parent: URL) -> OrganisePlan {
        var plan = OrganisePlan(title: "New Folder", root: parent)
        var taken = Set<String>()
        plan.foldersToCreate = [freeDestination(for: FolderNames.safe(name), in: parent, taken: &taken).url]
        return plan
    }

    public static func rename(_ item: URL, to name: String) -> OrganisePlan {
        let isFolder = isDirectory(item)
        let ext = item.pathExtension
        var newName = isFolder ? FolderNames.safe(name) : FileNaming.sanitize(name, maxBytes: 240)
        if !isFolder, !ext.isEmpty, (newName as NSString).pathExtension.lowercased() != ext.lowercased() {
            newName += ".\(ext)"
        }
        var plan = OrganisePlan(title: "Rename \(item.lastPathComponent)", root: item.deletingLastPathComponent())
        guard newName != item.lastPathComponent, !newName.isEmpty else { return plan }
        // A change of case only finds the item itself under the new name on case-insensitive volumes; it is not a collision.
        let direct = item.deletingLastPathComponent().appendingPathComponent(newName)
        if OperationJournal.sameFile(item.path, direct.path) {
            plan.moves = [PlannedMove(source: item, destination: direct)]
            return plan
        }
        var taken = Set<String>()
        let dest = freeDestination(for: newName, in: item.deletingLastPathComponent(), taken: &taken)
        plan.moves = [PlannedMove(source: item, destination: dest.url)]
        return plan
    }

    /// Several files renamed by one pattern (R-3808): `{name}` is the old name without its extension, `{n}` the file's
    /// place in `files` (padded to the same width), `{date}` its modification date. Extensions are kept, names are made
    /// safe, and a name taken by a file outside the rename gets a number. A name another file of the rename gives up is
    /// free: when files swap names they go through temporary names, in one operation. Metadata files follow their media.
    public static func batchRename(_ files: [URL], pattern: String) -> OrganisePlan {
        var plan = OrganisePlan(title: "Rename \(files.count) Files",
                                root: files.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/"))
        let fm = FileManager.default
        // The names each file asks for first; a file whose name stays as it is keeps it, so that name is not free.
        let wanted: [(file: URL, stem: String)] = files.enumerated().map { index, file in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (file, FileNaming.sanitize(batchName(pattern, stem: file.deletingPathExtension().lastPathComponent, index: index,
                                                        count: files.count, date: date), maxBytes: 230))
        }
        let keeping = Set(wanted.filter { item in
            item.stem.isEmpty || item.stem + (item.file.pathExtension.isEmpty ? "" : "." + item.file.pathExtension)
                == item.file.lastPathComponent
        }.map { OrganisePlan.key($0.file) })
        let vacated = Set(files.map { OrganisePlan.key($0) }).subtracting(keeping)
        var chosen = keeping
        func free(_ url: URL) -> Bool {
            let key = OrganisePlan.key(url)
            guard !chosen.contains(key) else { return false }
            if vacated.contains(key) { return true }
            return !fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: Sidecar.sidecarURL(for: url).path)
        }
        var renames: [(source: URL, destination: URL)] = []
        for (file, stem) in wanted {
            guard !stem.isEmpty else { continue }
            let ext = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
            let folder = file.deletingLastPathComponent()
            var destination = folder.appendingPathComponent(stem + ext)
            var counter = 2
            while !free(destination), OrganisePlan.key(destination) != OrganisePlan.key(file) {
                destination = folder.appendingPathComponent("\(stem) \(counter)\(ext)")
                counter += 1
            }
            chosen.insert(OrganisePlan.key(destination))
            if destination.lastPathComponent == file.lastPathComponent {
                plan.unchanged += 1
                continue
            }
            renames.append((file, destination))
            plan.renamed += 1
        }
        // A destination another file still holds when it is reached needs two steps: everything to a temporary name first.
        let sources = Set(renames.map { OrganisePlan.key($0.source) })
        let swaps = renames.contains { sources.contains(OrganisePlan.key($0.destination)) }
        if swaps {
            let stamp = UUID().uuidString.prefix(8)
            let temporary = renames.enumerated().map { index, rename in
                rename.source.deletingLastPathComponent()
                    .appendingPathComponent(".mediapull-rename-\(stamp)-\(index)" + (rename.source.pathExtension.isEmpty ? "" : "." +
                        rename.source.pathExtension))
            }
            plan.moves = zip(renames, temporary).map { PlannedMove(source: $0.source, destination: $1) }
                + zip(renames, temporary).map { PlannedMove(source: $1, destination: $0.destination) }
        } else {
            plan.moves = renames.map { PlannedMove(source: $0.source, destination: $0.destination) }
        }
        return plan
    }

    /// The first `limit` files' names after `batchRename`, as it will really name them (collision numbers included);
    /// nil for a file that keeps its name (audit 4, B4-m14).
    public static func batchRenamePreview(_ files: [URL], pattern: String, limit: Int = 4) -> [(old: String, new: String?)] {
        let finals = batchRename(files, pattern: pattern).finalDestinations
        return files.prefix(limit).map { file in
            (file.lastPathComponent, finals[file.standardizedFileURL.path]?.lastPathComponent)
        }
    }

    public static func batchName(_ pattern: String, stem: String, index: Int, count: Int, date: Date?) -> String {
        let width = String(max(count, 1)).count
        let number = String(index + 1)
        // The day as the person sees it, in their time zone, always written the same way.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = date.map(formatter.string(from:)) ?? ""
        return pattern.replacingOccurrences(of: "{name}", with: stem)
            .replacingOccurrences(of: "{n}", with: String(repeating: "0", count: max(0, width - number.count)) + number)
            .replacingOccurrences(of: "{date}", with: day)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Automatic sorts

    /// Files sorted into folders below `root`. `assign` gives each file its destination folders as path components:
    /// none sends it to `Unsorted/` (or leaves it, if `keepUnsorted`), several make clones (D-64).
    public static func sort(_ files: [URL], into root: URL, title: String, keepUnsorted: Bool = false, copy: Bool = false,
                            assign: (URL) -> [[String]]) -> OrganisePlan
    {
        var plan = OrganisePlan(title: title, root: root)
        var taken = Set<String>()
        var created = Set<String>()
        var respelled = Set<String>()
        for file in files {
            var targets = assign(file)
            if targets.isEmpty {
                plan.unsorted += 1
                if keepUnsorted {
                    plan.unchanged += 1; continue
                }
                targets = [[FolderNames.unsorted]]
            }
            var first = true
            for components in targets {
                let folder = components.map(FolderNames.safe).reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
                let parent = file.deletingLastPathComponent()
                if samePlace(folder, parent) {
                    // Already there; on a case-insensitive volume the folder may only be spelled differently ("alice" for
                    // a person now named "Alice"): the folder is renamed once, and its files stay put.
                    if folder.standardizedFileURL.path != parent.standardizedFileURL.path,
                       respelled.insert(parent.standardizedFileURL.path).inserted
                    {
                        plan.moves.append(PlannedMove(source: parent, destination: folder))
                    }
                    if first {
                        plan.unchanged += 1
                    }
                    first = false
                    continue
                }
                var path = root
                for part in components.map(FolderNames.safe) {
                    path.appendPathComponent(part, isDirectory: true)
                    if !FileManager.default.fileExists(atPath: path.path),
                       created.insert(path.path).inserted
                    {
                        plan.foldersToCreate.append(path)
                    }
                }
                let dest = freeDestination(for: file.lastPathComponent, in: folder, taken: &taken)
                if dest.renamed {
                    plan.renamed += 1
                }
                // Copying leaves the source folder as it was: every placement is a clone (D-68).
                plan.moves.append(PlannedMove(source: file, destination: dest.url, kind: first && !copy ? .move : .clone))
                first = false
            }
        }
        // A clone must be made before its source moves away.
        plan.moves.sort { $0.kind == .clone && $1.kind == .move }
        return plan
    }
}

/// The folder each item goes to for the automatic sorts that need no outside knowledge.
public enum SortRules {
    /// Folder names follow the Mac's time zone, so a morning photo is filed under its own day, not UTC's.
    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormats.utc(format)
        formatter.timeZone = timeZone
        return formatter
    }

    public static func byDate(_ item: MediaEntry, timeZone: TimeZone = .current) -> [[String]] {
        // Calendar fields, not two formatters per file: sorting thousands of files by date stays quick.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month], from: item.date)
        let year = String(format: "%04d", parts.year ?? 0)
        return [[year, year + String(format: "-%02d", parts.month ?? 0)]]
    }

    public static func bySource(_ item: MediaEntry) -> [[String]] {
        guard let name = item.source?.sourceName else { return [] }
        return [[name]]
    }

    public static func byScreenshot(_ item: MediaEntry) -> [[String]] {
        guard let record = item.record else { return [] }
        return [[record.isScreenshot ? FolderNames.screenshots : FolderNames.photos]]
    }

    public static func byPlace(_ item: MediaEntry) -> [[String]] {
        guard let place = item.record?.place else { return [] }
        return [[place.country, place.city]]
    }

    /// One folder per event: the first day, and the place when known.
    public static func eventFolders(_ items: [MediaEntry], gap: TimeInterval, timeZone: TimeZone = .current) -> [String: [[String]]] {
        let day = formatter("yyyy-MM-dd", timeZone), year = formatter("yyyy", timeZone)
        var query = LibraryQuery()
        query.eventGap = gap
        var result: [String: [[String]]] = [:]
        var used: [String: Int] = [:]
        for section in query.events(items).reversed() {
            guard let first = section.items.first else { continue }
            var name = day.string(from: first.date)
            if let city = section.items.compactMap({ $0.record?.place?.city }).first {
                name += " \(city)"
            }
            used[name, default: 0] += 1
            if used[name]! > 1 {
                name += " (\(used[name]!))"
            }
            for item in section.items {
                result[item.path] = [[year.string(from: first.date), name]]
            }
        }
        return result
    }

    /// Person folders for one file, following the group photo setting (D-64).
    public static func personFolders(names: [String], placement: GroupPhotoPlacement) -> [[String]] {
        guard !names.isEmpty else { return [] }
        if names.count == 1 {
            return [[names[0]]]
        }
        switch placement {
        case .everyPerson: return names.map { [$0] }
        case .sharedFolder: return [[FolderNames.groupPhotos]]
        case .firstPerson: return [[names[0]]]
        }
    }
}
