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
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let bookmarks = (try? Data(contentsOf: folder.appendingPathComponent("bookmarks.json")))
                    .flatMap { try? decoder.decode(BookmarkCollection.self, from: $0) }
                let history = (try? Data(contentsOf: folder.appendingPathComponent("history.json")))
                    .flatMap { try? decoder.decode(BrowsingHistory.self, from: $0) }
                return (bookmarks, history)
            }.value
            // Anything recorded before loading finished is kept on top of what was on disk.
            if var stored = result.1 {
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
        guard rememberHistory else { return }
        history.updateTitle(url, title: title)
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
        history.clear(since: range.since)
        scheduleSave()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard let folder, loaded else { return }
        saveTask?.cancel()
        let bookmarks = bookmarks
        let history = history
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
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
    }
}
