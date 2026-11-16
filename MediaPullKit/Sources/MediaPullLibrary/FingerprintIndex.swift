import Foundation
import MediaPullNet

/// Finds files with identical content in a folder. Only files of the same byte size are ever
/// hashed, and hashes are cached by path, size and modification date across launches.
public actor FingerprintIndex {
    struct Entry: Codable {
        var size: Int64
        var modified: Double
        var sha256: String
    }

    private var entries: [String: Entry] = [:]
    private let storeURL: URL?
    private var dirty = false
    private var saveScheduled = false

    public init(storeURL: URL?) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        }
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "jxl", "bmp", "tif", "tiff", "ico", "svg", "mp4", "m4v", "mov",
        "webm", "mkv", "mp3", "m4a", "aac", "ogg", "opus", "wav", "flac",
    ]

    /// An existing file in `folder` (and, if `recursive`, its subfolders) with this content.
    public func duplicate(sha256: String, size: Int64, in folder: URL, recursive: Bool) -> URL? {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var candidates: [URL] = []
        if recursive {
            guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { return nil }
            for case let url as URL in enumerator {
                candidates.append(url)
            }
        } else {
            candidates = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles])) ?? []
        }
        for url in candidates where Self.mediaExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let fileSize = values.fileSize, Int64(fileSize) == size
            else { continue }
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let entry = entries[url.path], entry.size == size, entry.modified == modified {
                if entry.sha256 == sha256 { return url }
                continue
            }
            guard let hash = try? FileHasher.sha256(of: url) else { continue }
            entries[url.path] = Entry(size: size, modified: modified, sha256: hash)
            dirty = true
            if hash == sha256 { scheduleSave(); return url }
        }
        scheduleSave()
        return nil
    }

    private var reserved = Set<String>()

    /// Claims the right to place content with this checksum in `folder`, so two concurrent saves of
    /// identical content cannot both write a file. Returns false while another save holds it.
    public func reserve(sha256: String, in folder: URL) -> Bool {
        reserved.insert(folder.standardizedFileURL.path + "\u{0}" + sha256).inserted
    }

    public func unreserve(sha256: String, in folder: URL) {
        reserved.remove(folder.standardizedFileURL.path + "\u{0}" + sha256)
    }

    public func record(_ url: URL, sha256: String) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize
        else { return }
        entries[url.path] = Entry(size: Int64(size), modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, sha256: sha256)
        dirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        guard dirty, !saveScheduled, storeURL != nil else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            self.persist()
        }
    }

    private var prunedAt = 0

    public func persist() {
        saveScheduled = false
        guard dirty, let storeURL else { return }
        // Forget files that no longer exist, so the cache does not grow forever. Checking every entry is slow, so it
        // happens when the cache has grown by a tenth since the last check, not at every save.
        if entries.count > 50000, entries.count > prunedAt + prunedAt / 10 {
            entries = entries.filter { FileManager.default.fileExists(atPath: $0.key) }
            prunedAt = entries.count
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storeURL, options: .atomic)
            dirty = false
        }
    }
}
