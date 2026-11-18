import Foundation
import MediaPullCore

/// Save As (D-108): a download goes exactly into the folder the person chose, and what that folder already holds is judged
/// from that folder alone, never from other folders' memory.
public enum ExactFolder {
    /// What a folder holds, read from its metadata files: the engine keys of gallery items and the ids of videos.
    public struct Held: Sendable, Equatable {
        public var keys: Set<String> = []
        public var videoIDs: Set<String> = []

        public init(keys: Set<String> = [], videoIDs: Set<String> = []) {
            self.keys = keys
            self.videoIDs = videoIDs
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
            held.keys.insert("\(category):\(post)")
            if let num = text("num") { held.keys.insert("\(category):\(post):\(num)") }
            if ["video", "audio"].contains(metadata["subcategory"] as? String ?? "") { held.videoIDs.insert(post) }
        }
        return held
    }

    /// The folder inside `parent` for one entry of Download All As… (D-108): a folder there that already holds the Instagram
    /// account `account`, else one named `name` (when it holds no other account's media), else a new numbered one. Never
    /// outside `parent`. The folder is not made here.
    public static func entryFolder(named name: String, account: String?, in parent: URL) -> URL {
        let fm = FileManager.default
        if let account = account?.lowercased() {
            let children = ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                                                         options: [.skipsHiddenFiles])) ?? [])
                .filter { OperationJournal.isFolder($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let held = children.first(where: { AccountFolders.dominantAccount(in: $0) == account }) { return held }
        }
        let named = parent.appendingPathComponent(FileNaming.safeTopFolder(name.nonEmpty ?? "Download"), isDirectory: true)
        guard fm.fileExists(atPath: named.path) else { return named }
        if let account = account?.lowercased(), let other = AccountFolders.dominantAccount(in: named), other != account {
            return AccountFolders.newFolder(named: name, in: parent)
        }
        return named
    }

    /// The folder for the stories of `owner` from the stories tray, inside the chosen folder: one there that holds the
    /// owner's media, else a new one named after the owner.
    public static func ownerFolder(_ owner: String, in folder: URL) -> (folder: URL, exists: Bool) {
        let found = entryFolder(named: owner, account: owner, in: folder)
        return (found, FileManager.default.fileExists(atPath: found.path))
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
    }
}
