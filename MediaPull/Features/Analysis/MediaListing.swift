import Foundation
import MediaPullCore

/// Lists the media files of a folder for the Library and Organise grids, with what their metadata files say.
nonisolated enum MediaListing {
    static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                         .tagNamesKey, .isPackageKey]

    /// The most media files a listing holds (the budget in `scripts/perf-budgets.json`); beyond it `limited` is true.
    static let limit = 50000

    /// Media files in `folder` (and below it with `recursive`), the number of subfolders directly inside it, those
    /// subfolders by name (packages are files, not folders), and whether the listing stopped at `limit` media files.
    @concurrent
    static func load(_ folder: URL, recursive: Bool, limit: Int = MediaListing.limit) async
        -> (entries: [MediaEntry], folders: Int, subfolders: [URL], limited: Bool)
    {
        let fm = FileManager.default
        var urls: [URL] = []
        var folders = 0
        var subfolders: [URL] = []
        // lint:allow main-io @concurrent: runs off the main actor
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        for url in top {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true else {
                continue
            }
            folders += 1
            if values.isPackage != true { subfolders.append(url) }
        }
        subfolders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if recursive {
            // lint:allow main-io @concurrent: runs off the main actor
            let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            // Only media files count toward the limit: metadata files and other files would otherwise halve it.
            var media = 0
            while let url = walker?.nextObject() as? URL {
                if Task.isCancelled {
                    return ([], folders, subfolders, false)
                }
                let ext = url.pathExtension.lowercased()
                guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
                if media == limit { return (entries(urls), folders, subfolders, true) }
                media += 1
                urls.append(url)
            }
        } else {
            // The same cap for one folder as for a folder and its subfolders: media files count, others do not.
            let media = top.filter { $0.pathExtension.lowercased() != "json" && MediaFormat.fromExtension($0.pathExtension) != nil }
            if media.count > limit { return (entries(Array(media.prefix(limit))), folders, subfolders, true) }
            urls = media
        }
        return (entries(urls), folders, subfolders, false)
    }

    private static func entries(_ urls: [URL]) -> [MediaEntry] {
        let fm = FileManager.default
        var entries: [MediaEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext != "json", let format = MediaFormat.fromExtension(ext) else { continue }
            let sidecar = Sidecar.sidecarURL(for: url)
            // A metadata file kept only in iCloud is not read: reading it would download it (audit 3, B3-m6).
            let source = fm.fileExists(atPath: sidecar.path) && !FileFlags.isDataless(sidecar) ? SourceInfo.read(sidecarOf: url) : nil
            var entry = MediaEntry(url: url, size: Int64(values.fileSize ?? 0), created: values.creationDate,
                                   modified: values.contentModificationDate ?? .distantPast, format: format, source: source)
            entry.finderTags = values.tagNames ?? []
            entries.append(entry)
        }
        return entries
    }
}
