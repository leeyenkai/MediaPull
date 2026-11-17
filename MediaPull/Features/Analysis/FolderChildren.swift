import Foundation
import MediaPullCore

/// The folders of a folder pane's list view (R-1709): the subfolders shown above the files, and the contents of folders
/// opened in place with their disclosure triangle. Contents are read and sorted off the main actor, in the pane's order.
@MainActor
final class FolderChildren {
    /// The subfolders of the pane's folder, shown first in the list.
    private(set) var top: [String] = []
    fileprivate var folders: Set<String> = []
    private var children: [String: [String]] = [:]
    private var nested: [String: MediaEntry] = [:]
    private var loading: Set<String> = []
    /// Bumped by `reset` and `forgetContents`, so a read that finishes afterwards is dropped, and the list view knows
    /// the rows it holds for opened folders are out of date.
    private(set) var generation = 0
    var onLoaded: ((String) -> Void)?

    /// A new folder in the pane: its subfolders, and nothing opened yet.
    func reset(top subfolders: [URL]) {
        generation += 1
        top = subfolders.map(\.path)
        folders = Set(top)
        children = [:]
        nested = [:]
        loading = []
    }

    /// The sort or filters changed: opened folders are read again in the new order when next shown.
    func forgetContents() {
        generation += 1
        children = [:]
        loading = []
    }

    func isFolder(_ id: String) -> Bool { folders.contains(id) }

    /// A file inside an opened folder.
    func entry(_ id: String) -> MediaEntry? { nested[id] }

    /// A folder's subfolders and then its files; nil while they are read (`onLoaded` follows).
    func contents(of id: String, query: LibraryQuery) -> [String]? {
        if let known = children[id] { return known }
        guard !loading.contains(id) else { return nil }
        loading.insert(id)
        let started = generation
        // Search by meaning needs scores for every file; a list being searched is flat (R-1709), so opened folders only
        // sort and filter.
        let plain = { var plain = query; plain.search = ""; return plain }()
        Task { [weak self] in
            let listing = await MediaListing.load(URL(fileURLWithPath: id, isDirectory: true), recursive: false)
            let attached = await AppModel.shared.analysis.attach(listing.entries)
            // The same context as the pane's own files, so the People and Similar filters apply inside opened folders too.
            let context = await AppModel.shared.analysis.queryContext(for: plain, entries: attached)
            let sections = await Task.detached(priority: .userInitiated) {
                plain.apply(attached, context: context)
            }.value
            guard let self, self.generation == started else { return }
            let subfolders = listing.subfolders.map(\.path)
            self.folders.formUnion(subfolders)
            for entry in attached {
                self.nested[entry.path] = entry
            }
            self.children[id] = subfolders + sections.flatMap(\.items).map(\.path)
            self.loading.remove(id)
            self.onLoaded?(id)
        }
        return nil
    }
}

extension FolderChildren {
    /// Folders chosen in the column view, so the grid callbacks treat their ids as folders.
    func note(_ ids: [String]) { folders.formUnion(ids) }
}

extension MediaColumnsOwner {
    func columnContents(_ folder: URL) async -> (folders: [URL], files: [URL]) {
        let listing = await MediaListing.load(folder, recursive: false)
        let entries = listing.entries.map(\.url)
        let files = await Task.detached(priority: .userInitiated) {
            entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }.value
        return (listing.subfolders, files)
    }
}
