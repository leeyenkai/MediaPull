import Foundation

/// A drive plugged into the Mac (R-4301).
public struct DriveInfo: Sendable, Hashable, Identifiable {
    public var url: URL
    public var name: String
    /// The volume's UUID; exFAT and FAT cards have one too (spike S3).
    public var uuid: String?
    public var isReadOnly: Bool
    /// A camera card: a `DCIM` folder at its top (R-4303).
    public var isCameraCard: Bool

    public var id: String { uuid ?? url.path }

    public init(url: URL, name: String, uuid: String?, isReadOnly: Bool, isCameraCard: Bool) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.isReadOnly = isReadOnly
        self.isCameraCard = isCameraCard
    }
}

/// Mounted volumes, told apart by UUID, never by name (R-4305).
public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
    ]

    /// Drives a person plugs in: ejectable, removable or external, local and browsable, never the startup disk.
    public static func drives() -> [DriveInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(drive).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func drive(_ url: URL) -> DriveInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsRootFileSystem != true,
              values.volumeIsLocal != false, values.volumeIsBrowsable != false,
              values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsInternal == false
        else { return nil }
        var isFolder: ObjCBool = false
        let dcim = url.appendingPathComponent("DCIM").path
        let card = FileManager.default.fileExists(atPath: dcim, isDirectory: &isFolder) && isFolder.boolValue
        return DriveInfo(url: url, name: values.volumeName ?? url.lastPathComponent, uuid: values.volumeUUIDString,
                         isReadOnly: values.volumeIsReadOnly == true, isCameraCard: card)
    }

    /// The UUID of the volume `url` is on, or nil when it is not there.
    public static func uuid(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    /// `/Volumes/<name>` for a path on a mounted or unmounted drive, or nil for the startup disk.
    public static func mountPoint(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.first == "Volumes", parts.count > 1 else { return nil }
        return "/Volumes/\(parts[1])"
    }

    /// Whether a path that is missing is gone for good (R-4305): only when the drive mounted where it was is the one drive
    /// ever seen there; with another drive of the same name, or one never seen, it is kept. Off the drives, it is gone.
    public static func isGone(_ path: String, seen: [String: Set<String>], mountedUUID: (String) -> String?) -> Bool {
        if FileManager.default.fileExists(atPath: path) { return false }
        guard let mount = mountPoint(of: path) else { return true }
        guard let current = mountedUUID(mount) else { return false }
        return seen[mount] == [current]
    }
}

/// The volumes seen at each mount point (`/Volumes/<name>` → UUIDs), kept in Application Support (R-4305).
public final class VolumeTable: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var seen: [String: Set<String>]

    public init(url: URL?) {
        self.url = url
        seen = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }

    public var snapshot: [String: Set<String>] {
        lock.withLock { seen }
    }

    /// Notes the drives mounted now.
    public func note(_ drives: [DriveInfo]) {
        let changed = lock.withLock { () -> Bool in
            var changed = false
            for drive in drives {
                guard let uuid = drive.uuid else { continue }
                changed = seen[drive.url.path, default: []].insert(uuid).inserted || changed
            }
            return changed
        }
        guard changed, let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // lint:allow silent-write MediaPull's own table; without it nothing is pruned on drives
        try? data.write(to: url, options: .atomic)
    }
}
