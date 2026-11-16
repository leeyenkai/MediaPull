import Foundation
import MediaPullCore
import Observation

/// Bookmarks and history for the browser pane (SPEC R-806, R-807). Kept in two small JSON files in
/// Application Support, never sent anywhere. Self-tests use memory only.
@Observable
final class BrowsingStore {
    private(set) var bookmarks = BookmarkCollection()
    private(set) var history = BrowsingHistory()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private var loaded = false
    /// Set when bookmarks change before the stored ones are loaded, so the stored ones do not overwrite them.
    @ObservationIgnored private var bookmarksEdited = false
    /// History cleared before the stored history was loaded: applied to it, so cleared pages do not come back.
    @ObservationIgnored private var clearsBeforeLoad: [Date?] = []
    @ObservationIgnored private var unsaved = false

    init(persistent: Bool) {
        folder = persistent
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaPull/Browser", isDirectory: true)
            : nil
        guard let folder else {
            loaded = true
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (BookmarkCollection?, BrowsingHistory?) in
                (
                    Self.read(BookmarkCollection.self, "bookmarks.json", in: folder),
                    Self.read(BrowsingHistory.self, "history.json", in: folder)
                )
            }.value
            // Anything recorded before loading finished is kept on top of what was on disk.
            if var stored = result.1 {
                for since in clearsBeforeLoad { stored.clear(since: since) }
                for entry in history.entries.reversed() {
                    stored.record(entry.url, title: entry.title, at: entry.lastVisit)
                }
                history = stored
            }
            if let stored = result.0, !bookmarksEdited { bookmarks = stored }
            loaded = true
            scheduleSave()
        }
    }

    var rememberHistory: Bool { AppModel.shared.preferences.rememberHistory }

    // MARK: Bookmarks

    func bookmark(for url: URL?) -> (folder: BookmarkFolder, bookmark: Bookmark)? {
        url.flatMap { bookmarks.bookmark(for: $0) }
    }

    @discardableResult
    func addBookmark(title: String, url: URL, folder: UUID? = nil) -> Bookmark {
        let bookmark = bookmarks.add(title: title, url: url, to: folder)
        bookmarksEdited = true
        scheduleSave()
        return bookmark
    }

    func edit(_ change: (inout BookmarkCollection) -> Void) {
        change(&bookmarks)
        bookmarksEdited = true
        scheduleSave()
    }

    // MARK: History

    func recordVisit(_ url: URL, title: String) {
        guard rememberHistory else { return }
        history.record(url, title: title)
        scheduleSave()
    }

    func updateTitle(_ url: URL, title: String) {
        guard rememberHistory, history.updateTitle(url, title: title) else { return }
        scheduleSave()
    }

    func removeHistory(_ id: UUID) {
        history.remove(id)
        scheduleSave()
    }

    enum ClearRange: CaseIterable, Identifiable {
        case lastHour, today, todayAndYesterday, all

        var id: Self { self }

        var label: String {
            switch self {
            case .lastHour: "The Last Hour"
            case .today: "Today"
            case .todayAndYesterday: "Today and Yesterday"
            case .all: "All History"
            }
        }

        var since: Date? {
            let calendar = Calendar.current
            switch self {
            case .lastHour: return Date().addingTimeInterval(-3600)
            case .today: return calendar.startOfDay(for: Date())
            case .todayAndYesterday: return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
            case .all: return nil
            }
        }
    }

    func clearHistory(_ range: ClearRange) {
        let since = range.since
        history.clear(since: since)
        if !loaded { clearsBeforeLoad.append(since) }
        scheduleSave()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard let folder, loaded else { return }
        unsaved = true
        saveTask?.cancel()
        let bookmarks = bookmarks
        let history = history
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            Self.write(bookmarks, history, to: folder)
        }
    }

    /// Writes what is not saved yet at once; the app calls this when it quits, inside the one-second delay.
    func flush() {
        guard let folder, loaded, unsaved else { return }
        saveTask?.cancel()
        Self.write(bookmarks, history, to: folder)
        unsaved = false
    }

    nonisolated private static func write(_ bookmarks: BookmarkCollection, _ history: BrowsingHistory, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(bookmarks) {
            try? data.write(to: folder.appendingPathComponent("bookmarks.json"), options: .atomic)
        }
        if let data = try? encoder.encode(history) {
            try? data.write(to: folder.appendingPathComponent("history.json"), options: .atomic)
        }
    }

    /// A file that exists but cannot be read is set aside (name.damaged-<date>.json), never written over.
    nonisolated private static func read<Value: Decodable>(_ type: Value.Type, _ name: String, in folder: URL) -> Value? {
        let file = folder.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let value = try? decoder.decode(type, from: data) { return value }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = folder.appendingPathComponent((name as NSString).deletingPathExtension + ".damaged-\(stamp).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return nil
    }
}
