import Foundation
import MediaPullCore

/// Lists the media files of a folder for the Library and Organise grids, with what their metadata files say.
nonisolated enum MediaListing {
    static let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                                         .isPackageKey]

    /// Media files in `folder` (and below it with `recursive`), the number of subfolders directly inside it, and those
    /// subfolders by name (packages are files, not folders).
    @concurrent
    static func load(_ folder: URL, recursive: Bool, limit: Int = 50000) async
        -> (entries: [MediaEntry], folders: Int, subfolders: [URL])
    {
        let fm = FileManager.default
        var urls: [URL] = []
        var folders = 0
        var subfolders: [URL] = []
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
            let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL, urls.count < limit {
                if Task.isCancelled {
                    return ([], folders, subfolders)
                }
                urls.append(url)
            }
        } else {
            urls = top
        }
        var entries: [MediaEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext != "json", let format = MediaFormat.fromExtension(ext) else { continue }
            let sidecar = Sidecar.sidecarURL(for: url)
            let source = fm.fileExists(atPath: sidecar.path) ? SourceInfo.read(sidecarOf: url) : nil
            entries.append(MediaEntry(url: url, size: Int64(values.fileSize ?? 0), created: values.creationDate,
                                      modified: values.contentModificationDate ?? .distantPast, format: format, source: source))
        }
        return (entries, folders, subfolders)
    }
}
