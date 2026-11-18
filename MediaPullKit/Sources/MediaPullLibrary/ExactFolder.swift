import Foundation
import MediaPullCore

/// Save As (D-108): a download goes exactly into the folder the person chose, and what that folder already holds is judged
/// from that folder alone, never from other folders' memory.
public enum ExactFolder {
    /// What a folder holds, read from its metadata files: the engine keys of gallery items and the ids of videos.
    public struct Held: Sendable, Equatable {
        public var keys: Set<String> = []
        public var videoIDs: Set<String> = []
        /// Audio saved from video sites (`subcategory` audio), apart from videos (B25-m3).
        public var audioIDs: Set<String> = []

        public init(keys: Set<String> = [], videoIDs: Set<String> = [], audioIDs: Set<String> = []) {
            self.keys = keys
            self.videoIDs = videoIDs
            self.audioIDs = audioIDs
        }
    }

    /// The keys a gallery download gives its items (`<category>:<media id>`, `<category>:<id>:<num>`, `<category>:<id>`)
    /// and the ids of saved videos, from the metadata files in `folder` and its subfolders. Instagram items are known by
    /// their folder index instead (D-79). Metadata kept only in iCloud is not read (it would be downloaded).
    public static func held(in folder: URL, limit: Int = 50000) -> Held {
        var held = Held()
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var seen = 0
        while let url = walker?.nextObject() as? URL, seen < limit {
            let ext = url.pathExtension.lowercased()
            guard ext != "json", MediaFormat.fromExtension(ext) != nil else { continue }
            seen += 1
            let sidecar = Sidecar.sidecarURL(for: url)
            guard !FileFlags.isDataless(sidecar),
                  let data = try? Data(contentsOf: sidecar),
                  let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            held.formUnion(keys(of: metadata))
        }
        return held
    }

    /// The keys one metadata file stands for.
    public static func keys(of metadata: [String: Any]) -> Held {
        var held = Held()
        guard let category = (metadata["category"] as? String)?.nonEmpty, category != "instagram" else { return held }
        func text(_ key: String) -> String? {
            if let value = metadata[key] as? String { return value.nonEmpty }
            if let value = metadata[key] as? NSNumber { return value.stringValue }
            return nil
        }
        if let media = text("media_id") { held.keys.insert("\(category):\(media)") }
        if let post = text("post_id") {
            // As the engine keys an item: with its number in the post when it has one other than 0, by the post alone when it
            // is numbered 0 (D-75). A metadata file without a number cannot say which (the number is left out when a site gives
            // no count), so it is not taken as held: it is downloaded again and dropped as a copy (D-108 rule 3, B24-M1,
            // B25-M1).
            switch text("num") {
            case "0"?: held.keys.insert("\(category):\(post)")
            case let num?: held.keys.insert("\(category):\(post):\(num)")
            case nil: break
            }
            switch metadata["subcategory"] as? String {
            case "video"?: held.videoIDs.insert(post)
            case "audio"?: held.audioIDs.insert(post)
            default: break
            }
        }
        return held
    }

    /// The folder inside `parent` for one entry of Download All As… (D-108 rule 4): the one named after the entry, found by
    /// that name alone and reused whenever it is there, whatever it holds; a numbered one when a file has the name. Never
    /// outside `parent`. The folder is not made here.
    public static func entryFolder(named name: String, in parent: URL) -> URL {
        let named = parent.appendingPathComponent(FileNaming.safeTopFolder(name.nonEmpty ?? "Download"), isDirectory: true)
        guard FileManager.default.fileExists(atPath: named.path), !OperationJournal.isFolder(named) else { return named }
        return AccountFolders.newFolder(named: name, in: parent)
    }

    /// Whether `path` is `folder` or inside it, compared as the volume compares names.
    public static func contains(_ folder: URL, _ path: String) -> Bool {
        let key = FileOps.nameKey(for: folder)
        let top = key(folder.standardizedFileURL.path), inner = key(URL(fileURLWithPath: path).standardizedFileURL.path)
        return inner == top || inner.hasPrefix(top + "/")
    }
}

extension ExactFolder.Held {
    mutating func formUnion(_ other: ExactFolder.Held) {
        keys.formUnion(other.keys)
        videoIDs.formUnion(other.videoIDs)
        audioIDs.formUnion(other.audioIDs)
    }
}
