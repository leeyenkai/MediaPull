import Foundation

/// A saved page (SPEC R-806).
public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var added: Date

    public init(id: UUID = UUID(), title: String, url: URL, added: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.added = added
    }
}

public struct BookmarkFolder: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bookmarks: [Bookmark]

    public init(id: UUID = UUID(), name: String, bookmarks: [Bookmark] = []) {
        self.id = id
        self.name = name
        self.bookmarks = bookmarks
    }
}

/// Bookmarks in named folders. There is always at least one folder; the first one is where new
/// bookmarks go unless another is chosen.
public struct BookmarkCollection: Codable, Equatable, Sendable {
    public private(set) var folders: [BookmarkFolder]

    public init(folders: [BookmarkFolder] = []) {
        self.folders = folders.isEmpty ? [BookmarkFolder(name: "Favourites")] : folders
    }

    public static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var string = components?.string ?? url.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        return string
    }

    public func bookmark(for url: URL) -> (folder: BookmarkFolder, bookmark: Bookmark)? {
        let key = Self.key(url)
        for folder in folders {
            if let bookmark = folder.bookmarks.first(where: { Self.key($0.url) == key }) { return (folder, bookmark) }
        }
        return nil
    }

    @discardableResult
    public mutating func add(title: String, url: URL, to folderID: UUID? = nil) -> Bookmark {
        if let existing = bookmark(for: url) { return existing.bookmark }
        let index = folderID.flatMap { id in folders.firstIndex { $0.id == id } } ?? 0
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: clean.isEmpty ? (url.host ?? url.absoluteString) : clean, url: url)
        folders[index].bookmarks.append(bookmark)
        return bookmark
    }

    public mutating func remove(_ bookmarkID: UUID) {
        for index in folders.indices {
            folders[index].bookmarks.removeAll { $0.id == bookmarkID }
        }
    }

    public mutating func rename(_ bookmarkID: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        for folder in folders.indices {
            if let index = folders[folder].bookmarks.firstIndex(where: { $0.id == bookmarkID }) {
                folders[folder].bookmarks[index].title = clean
            }
        }
    }

    public mutating func move(_ bookmarkID: UUID, to folderID: UUID) {
        guard let target = folders.firstIndex(where: { $0.id == folderID }) else { return }
        for folder in folders.indices {
            if let index = folders[folder].bookmarks.firstIndex(where: { $0.id == bookmarkID }) {
                guard folder != target else { return }
                let bookmark = folders[folder].bookmarks.remove(at: index)
                folders[target].bookmarks.append(bookmark)
                return
            }
        }
    }

    @discardableResult
    public mutating func addFolder(named name: String) -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = clean.isEmpty ? "New Folder" : clean
        var number = 2
        while folders.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(clean.isEmpty ? "New Folder" : clean) \(number)"
            number += 1
        }
        let folder = BookmarkFolder(name: candidate)
        folders.append(folder)
        return folder.id
    }

    public mutating func renameFolder(_ folderID: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[index].name = clean
    }

    /// Removes a folder and the bookmarks in it. The last folder is emptied instead.
    public mutating func removeFolder(_ folderID: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        if folders.count == 1 {
            folders[0].bookmarks = []
        } else {
            folders.remove(at: index)
        }
    }

    public mutating func moveFolder(_ folderID: UUID, by offset: Int) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let target = min(max(index + offset, 0), folders.count - 1)
        guard target != index else { return }
        folders.swapAt(index, target)
    }
}

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var lastVisit: Date
    public var visits: Int

    public init(id: UUID = UUID(), url: URL, title: String, lastVisit: Date, visits: Int = 1) {
        self.id = id
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visits = visits
    }
}

/// Pages visited in the browser pane, most recent first, one entry per address (SPEC R-807).
/// Kept only on this Mac.
public struct BrowsingHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [HistoryEntry]
    public static let limit = 5000

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    public mutating func record(_ url: URL, title: String, at date: Date = Date()) {
        guard url.scheme == "https" || url.scheme == "http" else { return }
        let key = BookmarkCollection.key(url)
        var entry = HistoryEntry(url: url, title: title, lastVisit: date)
        if let index = entries.firstIndex(where: { BookmarkCollection.key($0.url) == key }) {
            entry = entries.remove(at: index)
            entry.url = url
            entry.lastVisit = date
            entry.visits += 1
            if !title.isEmpty { entry.title = title }
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func updateTitle(_ url: URL, title: String) {
        guard !title.isEmpty else { return }
        let key = BookmarkCollection.key(url)
        if let index = entries.prefix(50).firstIndex(where: { BookmarkCollection.key($0.url) == key }) {
            entries[index].title = title
        }
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Clears visits since `date`, or everything when `date` is nil.
    public mutating func clear(since date: Date? = nil) {
        guard let date else {
            entries = []
            return
        }
        entries.removeAll { $0.lastVisit >= date }
    }

    public func matching(_ text: String) -> [HistoryEntry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    /// Entries grouped by calendar day, newest day first.
    public static func groupedByDay(_ entries: [HistoryEntry], calendar: Calendar = .current) -> [(day: Date, entries: [HistoryEntry])] {
        var groups: [(day: Date, entries: [HistoryEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.lastVisit)
            if let last = groups.indices.last, groups[last].day == day {
                groups[last].entries.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups
    }
}
