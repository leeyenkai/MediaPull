import Foundation
import MediaPullCore
import MediaPullLibrary

/// The text of a list view cell for a folder pane's files and folders (R-1709).
enum ListText {
    /// A folder shows its name, how many media files it holds and their total size (R-1714), measured in the background;
    /// `measured` is called with the folder once its size is known, so its row can be shown again.
    static func folder(_ id: String, _ column: ListColumn, measured: ((String) -> Void)? = nil) -> String {
        switch column {
        case .name: return URL(fileURLWithPath: id).lastPathComponent
        case .kind:
            guard let stats = FolderSizes.shared.stats(id, measured: measured) else { return "Folder" }
            return "Folder, \(stats.files.formatted()) item\(stats.files == 1 ? "" : "s")"
        case .size:
            return FolderSizes.shared.stats(id, measured: measured).map { Format.bytes($0.bytes) } ?? "--"
        default: return "--"
        }
    }

    /// `measured` is a pixel size read for the grid when analysis has not given one yet.
    static func entry(_ entry: MediaEntry, _ column: ListColumn, measured: PixelSize? = nil) -> String {
        switch column {
        case .name: entry.name
        case .date: entry.date.formatted(date: .abbreviated, time: .shortened)
        case .size: Format.bytes(entry.size)
        case .dimensions:
            if let facts = entry.facts, let width = facts.pixelWidth, let height = facts.pixelHeight { "\(width) × \(height)" } else {
                measured.map { "\($0.width) × \($0.height)" } ?? ""
            }
        case .kind: entry.format?.label ?? entry.url.pathExtension.uppercased()
        case .duration: entry.facts?.duration.map(Format.duration) ?? ""
        case .source: entry.source?.sourceName ?? ""
        case .found: ""
        case .tags: entry.finderTags.joined(separator: ", ")
        }
    }
}

/// Folder sizes for List view (R-1714): each folder is measured once, off the main actor and one at a time, and measured
/// again after any change to files MediaPull knows of.
@MainActor
final class FolderSizes {
    static let shared = FolderSizes()
    private var known: [String: FolderStats] = [:]
    private var queue: [(path: String, measured: (String) -> Void)] = []
    private var queued: Set<String> = []
    private var running = false
    private var revision = -1

    func stats(_ path: String, measured: ((String) -> Void)?) -> FolderStats? {
        let app = AppModel.shared
        let current = app.libraryRevision &+ app.fileChangeRevision
        if current != revision {
            known.removeAll()
            revision = current
        }
        if let stats = known[path] { return stats }
        if let measured, queued.insert(path).inserted {
            queue.append((path, measured))
            next()
        }
        return nil
    }

    private func next() {
        guard !running, !queue.isEmpty else { return }
        running = true
        let (path, measured) = queue.removeFirst()
        let started = revision
        Task {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let stats = await Task.detached(priority: .utility) { FolderStats.measure(folder) }.value
            queued.remove(path)
            // A measurement made before files changed is dropped; the row is drawn again either way, so it asks again.
            if started == revision { known[path] = stats }
            measured(path)
            running = false
            next()
        }
    }
}
