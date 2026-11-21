import Foundation
import MediaPullCore

/// Every file move, copy and trash outside the operation journal (D-107): the editors, the Converter, Library imports that
/// convert, side files beside videos, account documents and a page download that replaces a file. The rules are kept here
/// once instead of at each call site: off the main actor, the metadata file follows its media, names compared as the volume
/// compares them, nothing overwritten (an orphaned metadata file included), the replaced file checked just before it goes
/// to the Trash, and the original put back when a step fails.
public enum FileOps {
    /// What makes a metadata file stand for one item (D-79): a copy, a trim or a frame drops them (D-105).
    public static let identityKeys = ["media_id", "post_id", "num", "count", "shortcode", "post_shortcode"]
    /// What gives an item its place in a profile (D-111): a copy is not the pinned post, the highlight's cover or a playlist's
    /// entry (R3-m4).
    public static let roleKeys = ["pinned", "highlight_cover", "playlist_index"]

    // MARK: Names

    /// How the volume holding `folder` compares names: Unicode-normalised, and case-insensitive unless the volume is
    /// case-sensitive.
    public static func nameKey(for folder: URL) -> (String) -> String {
        var probe = folder
        // A folder that is not there yet is on the volume of the nearest folder above it.
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let caseSensitive = (try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        return caseSensitive
            ? { $0.precomposedStringWithCanonicalMapping }
            : { $0.precomposedStringWithCanonicalMapping.lowercased() }
    }

    /// Whether two paths name the same place on their volume ("Photo.jpg" and "photo.jpg" on most Mac volumes).
    public static func sameName(_ a: URL, _ b: URL) -> Bool {
        let a = a.standardizedFileURL, b = b.standardizedFileURL
        let key = nameKey(for: a.deletingLastPathComponent())
        return key(a.path) == key(b.path)
    }

    /// A free name for `wanted`: neither the file nor a metadata file of that name may be there, so a later metadata write
    /// never replaces an orphaned one (R-1402). `replacing` is a file a change replaces: its own name and its own metadata
    /// file do not count as taken, compared as the volume compares, so a case-only rename keeps its metadata file.
    public static func freeName(for wanted: URL, replacing: URL? = nil) -> URL {
        let fm = FileManager.default
        func ours(_ candidate: URL, _ own: URL?) -> Bool { own.map { sameName(candidate, $0) } ?? false }
        func free(_ candidate: URL) -> Bool {
            let sidecar = Sidecar.sidecarURL(for: candidate)
            return (!fm.fileExists(atPath: candidate.path) || ours(candidate, replacing))
                && (!fm.fileExists(atPath: sidecar.path) || ours(sidecar, replacing.map(Sidecar.sidecarURL(for:))))
        }
        for candidate in candidates(for: wanted) where free(candidate) {
            return candidate
        }
        return wanted
    }

    /// `wanted`, then "stem 2.ext", "stem 3.ext" and so on (at most 10,000).
    static func candidates(for wanted: URL) -> some Sequence<URL> {
        let folder = wanted.deletingLastPathComponent()
        let stem = wanted.deletingPathExtension().lastPathComponent, ext = wanted.pathExtension
        return (1 ... 10000).lazy.map { n in
            n == 1 ? wanted : folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
        }
    }

    // MARK: Metadata

    /// A value written into a metadata file.
    public enum MetadataValue: Sendable, Equatable {
        case int(Int), double(Double), string(String), bool(Bool), doubles([Double])

        var json: Any {
            switch self {
            case let .int(value): value
            case let .double(value): value
            case let .string(value): value
            case let .bool(value): value
            case let .doubles(value): value
            }
        }
    }

    /// How a media file's metadata changes on the way to a new file.
    public struct MetadataChange: Sendable {
        public var values: [String: MetadataValue]
        public var dropping: [String]
        /// A copy is an item of its own: it never stands for the original, so the identity keys go (D-105).
        public var isCopy: Bool

        public init(values: [String: MetadataValue] = [:], dropping: [String] = [], isCopy: Bool) {
            self.values = values
            self.dropping = dropping
            self.isCopy = isCopy
        }
    }

    /// The metadata file of `source` with `change` applied, as file contents; nil when `source` has none. A metadata file
    /// that is not a JSON object follows as it is, except into a copy, which gets none.
    public static func metadata(of source: URL, applying change: MetadataChange) throws -> Data? {
        let sidecar = Sidecar.sidecarURL(for: source)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        let data = try Data(contentsOf: sidecar)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return change.isCopy ? nil : data
        }
        for key in change.dropping + (change.isCopy ? identityKeys + roleKeys : []) {
            object[key] = nil
        }
        for (key, value) in change.values {
            object[key] = value.json
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Placing

    /// Renames `source` to `target` only when nothing is there; on another volume it is copied beside `target` first and
    /// then renamed the same way, and the source removed after. Never replaces anything.
    public static func renameExclusive(_ source: URL, to target: URL) throws {
        if try exclusiveOrMove(source, to: target) { return }
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try fm.copyItem(at: source, to: staged)
        // The second step lands on the target's volume, which may be an exFAT card (R-4305).
        guard try exclusiveOrMove(staged, to: target) else { throw error(EXDEV, target) }
        try fm.removeItem(at: source)
    }

    /// An exclusive rename, or on a volume without them (exFAT, FAT, some network shares) a plain move once the name is
    /// checked free; neither replaces a file. False when the two are on different volumes.
    static func exclusiveOrMove(_ source: URL, to target: URL) throws -> Bool {
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return true }
        let code = errno
        if code == ENOTSUP || code == EINVAL {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw error(EEXIST, target) }
            try FileManager.default.moveItem(at: source, to: target)
            return true
        }
        guard code == EXDEV else { throw error(code, target) }
        return false
    }

    static func error(_ code: Int32, _ target: URL) -> Error {
        code == EEXIST
            ? CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "“\(target.lastPathComponent)” is already there."])
            : POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// Writes `data` as a new file at `target`, whole or not at all, never over anything.
    public static func writeNew(_ data: Data, to target: URL) throws {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: target.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent)
        try data.write(to: staged)
        try renameExclusive(staged, to: target)
    }

    /// Where a file went, and what went wrong with its metadata file, if anything (the media file is kept either way).
    public struct Placed: Sendable {
        public var url: URL
        public var metadataProblem: String?
    }

    /// What goes beside a placed file.
    public enum Companion: Sendable {
        case none
        /// New metadata, written beside it.
        case data(Data)
        /// An existing metadata file, moved beside it.
        case file(URL)
    }

    /// Puts a new file (an edit, a frame, a conversion, a side file) under a free name at `wanted` with its metadata, and
    /// returns where it went. `keepSource` copies instead of moving. A name taken meanwhile by another save is skipped, and
    /// a failure leaves the source where it was.
    @concurrent
    public static func place(_ file: URL, as wanted: URL, with companion: Companion, keepSource: Bool = false,
                             makingFolder: Bool = false) async throws -> Placed
    {
        if makingFolder {
            try FileManager.default.createDirectory(at: wanted.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try placeNow(file, as: wanted, with: companion, keepSource: keepSource)
    }

    static func placeNow(_ file: URL, as wanted: URL, with companion: Companion, keepSource: Bool) throws -> Placed {
        let fm = FileManager.default
        let folder = wanted.deletingLastPathComponent()
        // Staged on the destination's volume first, so the final step is an exclusive rename that never replaces a file
        // another save put there after the name was checked.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(wanted.lastPathComponent)
        if keepSource { try fm.copyItem(at: file, to: staged) } else { try fm.moveItem(at: file, to: staged) }
        var placed: URL?
        do {
            for _ in 0 ..< 50 {
                let candidate = freeName(for: wanted)
                if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                    placed = candidate
                    break
                }
                let code = errno
                if code == ENOTSUP || code == EINVAL || code == EXDEV {
                    // No exclusive rename here (exFAT, some network shares), or the staging folder is on another volume: a
                    // plain move, which never replaces a file either.
                    do {
                        try fm.moveItem(at: staged, to: candidate)
                        placed = candidate
                        break
                    } catch CocoaError.fileWriteFileExists {
                        continue
                    }
                }
                guard code == EEXIST else { throw error(code, candidate) }
            }
            guard placed != nil else { throw error(EEXIST, wanted) }
        } catch {
            // The source comes back, so the save can be tried again; if it cannot, it is kept beside the destination under a
            // name of its own rather than removed with the staging folder (R1-m3).
            guard !keepSource else { throw error }
            if (try? fm.moveItem(at: staged, to: file)) == nil { // lint:allow silent-write the fallback below keeps it
                let rescue = freeName(for: folder.appendingPathComponent("Recovered \(wanted.lastPathComponent)"))
                if (try? fm.moveItem(at: staged, to: rescue)) != nil { // lint:allow silent-write reported in the error
                    let message = "\(error.localizedDescription) The file was kept as “\(rescue.lastPathComponent)”."
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
                }
            }
            throw error
        }
        let target = placed ?? wanted
        var problem: String?
        do {
            switch companion {
            case .none: break
            case let .data(data): try writeNew(data, to: Sidecar.sidecarURL(for: target))
            case let .file(sidecar):
                if keepSource {
                    try writeNew(Data(contentsOf: sidecar), to: Sidecar.sidecarURL(for: target))
                } else {
                    try renameExclusive(sidecar, to: Sidecar.sidecarURL(for: target))
                }
            }
        } catch {
            problem = error.localizedDescription
        }
        return Placed(url: target, metadataProblem: problem)
    }

    /// Copies a media file to a free name at `wanted`, with a copy of its metadata file that no longer identifies the item.
    @concurrent
    public static func copy(_ file: URL, as wanted: URL, change: MetadataChange = MetadataChange(isCopy: true)) async throws -> Placed {
        var change = change
        change.isCopy = true
        let data: Data?
        var problem: String?
        do { data = try metadata(of: file, applying: change) } catch {
            data = nil
            problem = error.localizedDescription
        }
        var placed = try placeNow(file, as: wanted, with: data.map(Companion.data) ?? .none, keepSource: true)
        if placed.metadataProblem == nil { placed.metadataProblem = problem }
        return placed
    }

    /// Moves a file and its metadata file to a free name at `wanted`.
    @concurrent
    public static func move(_ file: URL, to wanted: URL) async throws -> Placed {
        let sidecar = Sidecar.sidecarURL(for: file)
        let companion: Companion = file.pathExtension.lowercased() != "json"
            && FileManager.default.fileExists(atPath: sidecar.path) ? .file(sidecar) : .none
        return try placeNow(file, as: wanted, with: companion, keepSource: false)
    }

    // MARK: Trash

    /// Why a change did nothing: the file opened is gone, or another file has its name now.
    public static func changedError(_ url: URL) -> Error {
        let what = FileManager.default.fileExists(atPath: url.path)
            ? "is another file now (it was renamed or moved since it was opened)"
            : "is no longer there (it was moved or deleted since it was opened)"
        let message = "“\(url.lastPathComponent)” \(what), so nothing was changed."
        return CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Whether the file at `url` is still the one with `identity` (its volume UUID and file number); nil identity is not
    /// checked.
    public static func isStill(_ url: URL, _ identity: String?) -> Bool {
        identity == nil || AccountFolderRecord.number(of: url) == identity
    }

    /// Moves a file and its metadata file to the Trash. `identity`: the file must still be the one it was, checked just
    /// before it goes. If the metadata file cannot go, the file comes back, so the two stay together.
    @concurrent
    public static func trash(_ file: URL, identity: String? = nil) async throws {
        let fm = FileManager.default
        guard isStill(file, identity) else { throw changedError(file) }
        let sidecar = Sidecar.sidecarURL(for: file)
        let hasSidecar = file.pathExtension.lowercased() != "json" && fm.fileExists(atPath: sidecar.path)
        var trashed: NSURL?
        try fm.trashItem(at: file, resultingItemURL: &trashed)
        guard hasSidecar else { return }
        do {
            try fm.trashItem(at: sidecar, resultingItemURL: nil)
        } catch {
            if let back = trashed as URL? { try? fm.moveItem(at: back, to: file) } // lint:allow silent-write the error below is reported
            throw error
        }
    }
}
