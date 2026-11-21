import CryptoKit
import Foundation
import MediaPullCore
import MediaPullLibrary

/// One file to import; a Live Photo clip names its photo, so it is placed under the photo's name (R-4104).
public struct ImportItem: Sendable, Equatable {
    public var entry: DeviceEntry
    public var clipOf: String?

    public init(entry: DeviceEntry, clipOf: String? = nil) {
        self.entry = entry
        self.clipOf = clipOf
    }
}

/// What an import will copy and what it skips (R-4104, R-4105). Pure, so it is tested without a device.
public enum ImportPlan {
    public struct Result: Sendable, Equatable {
        public var items: [ImportItem]
        /// Imported before, or already in the destination.
        public var skipped: Int
        /// Live Photo clips left out because the option is off.
        public var clipsLeftOut: Int
    }

    /// A file of this name and size in the destination counts as imported (R-4105).
    public static func existingKey(name: String, size: Int64) -> String {
        "\(name.precomposedStringWithCanonicalMapping.lowercased())|\(size)"
    }

    /// Member id → lead id for the units among the entries (R-4206), by pair key: a RAW leads the JPEG, HEIC or HEIF of the
    /// same shot and its clip; otherwise a photo leads its clip (a Live Photo).
    public static func clips(in entries: [DeviceEntry]) -> [String: String] {
        var out: [String: String] = [:]
        let grouped = Dictionary(grouping: entries.filter { $0.pairKey != nil && $0.isMedia }) { $0.pairKey! }
        for group in grouped.values {
            let sorted = group.sorted { $0.name < $1.name }
            guard let lead = sorted.first(where: { $0.format == .raw }) ?? sorted.first(where: { $0.kind == .image }) else { continue }
            for member in sorted where member.id != lead.id && (member.kind == .video || lead.format == .raw && member.kind == .image) {
                out[member.id] = lead.id
            }
        }
        return out
    }

    /// `imported`: keys from the record of this device; `existing`: `existingKey` of the files in the destination.
    public static func make(_ entries: [DeviceEntry], imported: Set<String>, existing: Set<String>, includeClips: Bool) -> Result {
        let media = entries.filter(\.isMedia)
        let clips = clips(in: media)
        let wanted = { (entry: DeviceEntry) in
            !imported.contains(entry.importKey) && !existing.contains(existingKey(name: entry.name, size: entry.size))
        }
        var items: [ImportItem] = []
        var skipped = 0, leftOut = 0
        var clipsByPhoto: [String: [DeviceEntry]] = [:]
        for entry in media {
            if let photo = clips[entry.id] {
                // The JPEG of a RAW always comes along; only Live Photo clips are optional.
                if includeClips || entry.kind != .video { clipsByPhoto[photo, default: []].append(entry) } else { leftOut += 1 }
            }
        }
        for entry in media where clips[entry.id] == nil {
            let photoWanted = wanted(entry)
            if photoWanted { items.append(ImportItem(entry: entry)) } else { skipped += 1 }
            for clip in clipsByPhoto[entry.id] ?? [] {
                if wanted(clip) {
                    // Placed under the photo's name only when the photo comes in the same import.
                    items.append(ImportItem(entry: clip, clipOf: photoWanted ? entry.id : nil))
                } else {
                    skipped += 1
                }
            }
        }
        return Result(items: items, skipped: skipped, clipsLeftOut: leftOut)
    }
}

/// What was imported from one device (R-4105), in Application Support: never in a library folder (R-601).
public actor ImportedIndex {
    struct Stored: Codable {
        var device: String
        var keys: [String]
        /// Version 2: where each imported file was placed, so a later delete from the device can check the copy is still
        /// there and whole (Phase 5). Records from before have none, and never allow a delete.
        var placed: [String: Placed]?
    }

    /// A placed copy: a reference that follows it through moves and renames on its volume, its size and checksum.
    public struct Placed: Codable, Sendable, Equatable {
        public var reference: String
        public var size: Int64
        public var sha256: String
    }

    public nonisolated let url: URL
    let deviceName: String
    private var keys: Set<String> = []
    private var placed: [String: Placed] = [:]
    private var unsaved = 0

    public init(folder: URL, device: DeviceIdentity) {
        let digest = SHA256.hash(data: Data(device.key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        url = folder.appendingPathComponent("\(digest).json")
        deviceName = device.name
        let stored = Self.read(url)
        keys = Set(stored?.keys ?? [])
        placed = stored?.placed ?? [:]
    }

    /// A file that cannot be read is set aside, never written over.
    static func read(_ url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) { return stored }
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
        // lint:allow silent-write the record is MediaPull's own; without it Import New still skips files in the destination
        try? FileManager.default.moveItem(at: url, to: aside)
        return nil
    }

    /// Where the copy of `key` is now, when it is still the copy that was placed (same size and checksum).
    public func verifiedCopy(of key: String) -> URL? {
        guard let record = placed[key], let path = OperationJournal.resolve(record.reference) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value, size == record.size,
              (try? Self.sha256(of: url)) == record.sha256
        else { return nil }
        return url
    }

    public func all() -> Set<String> { keys }

    public func contains(_ key: String) -> Bool { keys.contains(key) }

    /// Saved every 20 files and at the end, so a stop part way loses at most a few (the destination check covers those).
    public func record(_ key: String, placedAt url: URL? = nil) {
        if let url, let reference = OperationJournal.reference(url.path),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
           let sha = try? Self.sha256(of: url)
        {
            placed[key] = Placed(reference: reference, size: size, sha256: sha)
        }
        guard keys.insert(key).inserted || url != nil else { return }
        unsaved += 1
        if unsaved >= 20 { save() }
    }

    public func save() {
        unsaved = 0
        let stored = Stored(device: deviceName, keys: keys.sorted(), placed: placed)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // lint:allow silent-write the record is MediaPull's own; without it Import New still skips files in the destination
        try? data.write(to: url, options: .atomic)
    }

    /// The file's SHA-256, read a megabyte at a time.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func forget() {
        keys = []
        placed = [:]
        unsaved = 0
        try? FileManager.default.removeItem(at: url)
    }
}

/// Copies files off a device into a folder (R-4104): staged on the destination's volume, size checked, dated, then placed
/// with `FileOps` so nothing is overwritten.
public enum DeviceImporter {
    public struct Outcome: Sendable {
        public var placed: [URL] = []
        public var failed: [(entry: DeviceEntry, message: String)] = []
        public var cancelled = false
    }

    public static func run(_ items: [ImportItem], from source: any DeviceSource, into destination: URL, index: ImportedIndex,
                           progress: @escaping @Sendable (_ done: Int, _ total: Int, _ current: String) -> Void) async -> Outcome
    {
        var outcome = Outcome()
        var placedNames: [String: String] = [:]
        defer { Task { await index.save() } }
        for (number, item) in items.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            progress(number, items.count, item.entry.name)
            do {
                let placed = try await importOne(item, from: source, into: destination, photoNames: placedNames)
                placedNames[item.entry.id] = placed.deletingPathExtension().lastPathComponent
                outcome.placed.append(placed)
                await index.record(item.entry.importKey, placedAt: placed)
            } catch is CancellationError {
                outcome.cancelled = true
                break
            } catch {
                if isDisconnect(error) {
                    for rest in items[number...] {
                        outcome.failed.append((rest.entry, DeviceError.disconnected.localizedDescription))
                    }
                    break
                }
                outcome.failed.append((item.entry, error.localizedDescription))
            }
        }
        progress(items.count, items.count, "")
        await index.save()
        return outcome
    }

    static func isDisconnect(_ error: any Error) -> Bool {
        if let error = error as? DeviceError, error == .disconnected { return true }
        if let error = error as? MTPError, error == .disconnected { return true }
        return false
    }

    /// The device's name made safe; a clip takes its photo's placed name with its own extension.
    public static func name(for item: ImportItem, photoNames: [String: String]) -> String {
        let ext = (item.entry.name as NSString).pathExtension
        if let photo = item.clipOf, let base = photoNames[photo] {
            return FileNaming.sanitize(ext.isEmpty ? base : "\(base).\(ext)")
        }
        let name = FileNaming.sanitize(item.entry.name)
        return name.isEmpty ? "Imported.\(ext.isEmpty ? "dat" : ext)" : name
    }

    static func importOne(_ item: ImportItem, from source: any DeviceSource, into destination: URL,
                          photoNames: [String: String]) async throws -> URL
    {
        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: staging) }
        let name = name(for: item, photoNames: photoNames)
        let staged = staging.appendingPathComponent(name)
        try await source.download(item.entry, to: staged) { _ in }
        let got = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? -1
        if item.entry.size > 0, got != item.entry.size { throw DeviceError.sizeMismatch(expected: item.entry.size, got: got) }
        if let taken = item.entry.taken {
            try? fm.setAttributes([.creationDate: taken, .modificationDate: taken], ofItemAtPath: staged.path)
        }
        // A clip joins the photo it was imported with; anything else takes a name no other shot there has.
        return try await FileOps.place(staged, as: destination.appendingPathComponent(name), with: .none, joining: item.clipOf != nil).url
    }
}
