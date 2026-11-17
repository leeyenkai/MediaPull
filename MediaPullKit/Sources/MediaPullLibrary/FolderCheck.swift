import Foundation
import ImageIO
import MediaPullCore
import MediaPullNet

/// Check Folder (R-1713): what in a folder no longer matches what was saved. Reads every file with a metadata file once to
/// compare its checksum; changes nothing.
public enum FolderCheck {
    public struct Report: Sendable, Equatable {
        public var folder: URL
        public var checked = 0
        /// Metadata files whose media file is gone.
        public var orphanedMetadata: [URL] = []
        /// Media files without a metadata file (counted in Archive folders only, where every file has one).
        public var withoutMetadata: [URL] = []
        /// Files whose checksum differs from the one recorded when they were saved: edited since, or damaged.
        public var changed: [URL] = []
        /// Files iCloud keeps only in the cloud, which could not be read.
        public var notDownloaded: [URL] = []

        public var isClean: Bool { orphanedMetadata.isEmpty && withoutMetadata.isEmpty && changed.isEmpty && notDownloaded.isEmpty }
    }

    public static func run(_ folder: URL, archive: Bool, progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> Report {
        var report = Report(folder: folder)
        let fm = FileManager.default
        var media: [URL] = []
        var metadata: [URL] = []
        let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [])
        while let url = walker?.nextObject() as? URL {
            if Task.isCancelled { return report }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                // Account documents are not media; hidden folders are not the person's.
                if name.hasPrefix(".") || name == SaveTarget.accountDetailsFolder { walker?.skipDescendants() }
                continue
            }
            if name.hasPrefix(".") {
                if name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    report.notDownloaded.append(url.deletingLastPathComponent().appendingPathComponent(real))
                }
                continue
            }
            if Sidecar.isSidecarName(name) {
                metadata.append(url)
            } else if url.pathExtension.lowercased() != "json", MediaFormat.fromExtension(url.pathExtension) != nil {
                media.append(url)
            }
        }
        let placeholders = Set(report.notDownloaded.map(\.path))
        let mediaPaths = Set(media.map(\.path))
        for sidecar in metadata {
            let mediaPath = String(sidecar.path.dropLast(".json".count))
            if !mediaPaths.contains(mediaPath), !placeholders.contains(mediaPath) { report.orphanedMetadata.append(sidecar) }
        }
        // Files saved without metadata on purpose: formats that never get one (D-56), and a video's thumbnail, named after it.
        let videoStems = Set(media.filter { MediaFormat.fromExtension($0.pathExtension)?.kind == .video }
            .map { $0.deletingPathExtension().path })
        func expectsMetadata(_ file: URL) -> Bool {
            guard let format = MediaFormat.fromExtension(file.pathExtension), SavePipeline.archiveFormats.contains(format) else {
                return false
            }
            return !(format.kind == .image && videoStems.contains(file.deletingPathExtension().path))
        }
        let total = media.count
        for (done, file) in media.enumerated() {
            if Task.isCancelled { return report }
            if done % 20 == 0 { progress(done, total) }
            if FileFlags.isDataless(file) {
                report.notDownloaded.append(file)
                continue
            }
            report.checked += 1
            let sidecar = Sidecar.sidecarURL(for: file)
            guard let data = try? Data(contentsOf: sidecar) else {
                if archive, expectsMetadata(file) { report.withoutMetadata.append(file) }
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let recorded = json["sha256"] as? String, !recorded.isEmpty
            else { continue }
            if let actual = try? FileHasher.sha256(of: file), actual != recorded { report.changed.append(file) }
        }
        progress(total, total)
        for key in [\Report.orphanedMetadata, \.withoutMetadata, \.changed, \.notDownloaded] {
            report[keyPath: key].sort { $0.path < $1.path }
        }
        return report
    }
}

/// How many media files a folder holds, with its subfolders, and their total size (R-1714).
public struct FolderStats: Sendable, Equatable {
    public var files = 0
    public var bytes: Int64 = 0

    public static func measure(_ folder: URL) -> FolderStats {
        var stats = FolderStats()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                    options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true
            else { continue }
            stats.files += 1
            stats.bytes += Int64(values.fileSize ?? 0)
        }
        return stats
    }
}

/// Trash Extra Copies (R-3305): which file of each duplicate group stays.
public enum ExtraCopies {
    public struct Candidate: Sendable, Equatable {
        public var url: URL
        public var pixels: Int
        public var hasMetadata: Bool
        public var created: Date
        public var bytes: Int64

        public init(url: URL, pixels: Int, hasMetadata: Bool, created: Date, bytes: Int64) {
            self.url = url
            self.pixels = pixels
            self.hasMetadata = hasMetadata
            self.created = created
            self.bytes = bytes
        }
    }

    /// The copy to keep: the most pixels, then one with a metadata file, then the oldest, then the shortest path.
    public static func keeper(_ candidates: [Candidate]) -> Candidate? {
        candidates.min { a, b in
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            if a.hasMetadata != b.hasMetadata { return a.hasMetadata }
            if a.created != b.created { return a.created < b.created }
            if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
            return a.url.path < b.url.path
        }
    }

    /// What one press of Trash Extra Copies moves to the Trash, and how much space that frees. Each group is the copies in
    /// the folder shown; one of them stays.
    public static func plan(_ groups: [[URL]]) -> (trash: [URL], bytes: Int64) {
        var trash: [URL] = []
        var bytes: Int64 = 0
        for members in groups where members.count > 1 {
            let candidates = members.compactMap(candidate)
            guard candidates.count == members.count, let keep = keeper(candidates) else { continue }
            for other in candidates where other.url != keep.url {
                trash.append(other.url)
                bytes += other.bytes
            }
        }
        return (trash, bytes)
    }

    static func candidate(_ url: URL) -> Candidate? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey]), let size = values.fileSize
        else { return nil }
        var pixels = 0
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        {
            pixels = width * height
        }
        let hasMetadata = FileManager.default.fileExists(atPath: Sidecar.sidecarURL(for: url).path)
        return Candidate(url: url, pixels: pixels, hasMetadata: hasMetadata, created: values.creationDate ?? .distantFuture,
                         bytes: Int64(size))
    }
}
