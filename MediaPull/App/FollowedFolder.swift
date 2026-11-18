import Foundation
import MediaPullCore
import MediaPullLibrary

/// A folder chosen now and used later (a queued download, Download All's later entries, Retry): where it is when used,
/// followed through its bookmark when it was renamed or moved, and nil when it went to the Trash or is gone. Nothing is
/// ever saved to, or made again at, a path the folder left (D-90, audit 7, C7-M4).
struct FollowedFolder: Sendable {
    let url: URL
    let bookmark: Data?

    init(_ url: URL) {
        self.url = url
        bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func now() async -> URL? {
        let url = url, bookmark = bookmark
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            if OperationJournal.isFolder(url), !FileFlags.isInTrash(url) { return url }
            var stale = false
            guard let bookmark, let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                OperationJournal.isFolder(found), !FileFlags.isInTrash(found) else { return nil }
            return found.standardizedFileURL
        }.value
    }

    static func goneMessage(_ url: URL) -> String {
        "“\(url.lastPathComponent)” is no longer there. It may have been moved to the Trash."
    }
}
