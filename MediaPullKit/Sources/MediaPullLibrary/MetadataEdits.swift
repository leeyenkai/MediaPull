import Foundation
import MediaPullCore
import MediaPullMedia
import MediaPullNet

/// A file a metadata edit wrote again in place: its new content, so analysis can follow it (R-4506).
public struct RewrittenFile: Sendable, Equatable {
    public var path: String
    public var sha256: String
    public var size: Int64
    public var modified: Date
}

/// What a metadata edit did (section 45).
public struct MetadataEditResult: Sendable {
    /// Nil when nothing changed.
    public var entry: JournalEntry?
    public var rewritten: [RewrittenFile] = []
    /// `.xmp` files written, so listings read them again.
    public var xmpWritten: [String] = []
    /// One line per file left as it was, with why.
    public var skipped: [String] = []
    /// Files changed (a unit counts once).
    public var changed = 0
}

public extension OperationJournal {
    /// Where an item's values live: its own file, for JPEG and HEIC with no `.xmp` beside them, else its `.xmp` (R-4502).
    struct MetadataPlace: Sendable, Equatable {
        /// The image files written in place (the lead and any image member), or none when `xmp` is used.
        public var files: [URL]
        public var xmp: URL?
        /// A MediaPull metadata file beside the item: its date is the post's (R-4504).
        public var hasMetadataFile: Bool
    }

    static func place(of lead: URL, names: [String]) -> MetadataPlace {
        let folder = lead.deletingLastPathComponent()
        let companions = MediaUnits.companions(ofLead: lead.lastPathComponent, in: names).map { folder.appendingPathComponent($0) }
        let images = [lead] + companions.filter { MediaFormat.fromExtension($0.pathExtension)?.kind == .image }
        let hasXMP = companions.contains { $0.pathExtension.lowercased() == "xmp" }
        let hasJSON = companions.contains { $0.pathExtension.lowercased() == "json" }
            || names.contains(Sidecar.sidecarURL(for: lead).lastPathComponent)
        if hasXMP || !images.allSatisfy(MetadataWriter.writesInFile) {
            return MetadataPlace(files: [], xmp: MetadataWriter.xmpURL(for: lead, existing: names), hasMetadataFile: hasJSON)
        }
        return MetadataPlace(files: images, xmp: nil, hasMetadataFile: hasJSON)
    }

    /// The values MediaPull shows for an item: its file's, with its `.xmp` over them (R-4502).
    static func currentValues(of lead: URL, place: MetadataPlace) -> MetadataValues {
        let own = MetadataWriter.values(of: lead)
        guard let xmp = place.xmp, let over = MetadataWriter.values(ofXMPAt: xmp) else { return own }
        return own.merging(over)
    }

    /// Applies `edit` to each item (a lead file; its unit comes along) as one change ⌘Z takes back (R-4501 to R-4505).
    /// Each file is written beside itself and checked before it replaces the original; an item whose file cannot be
    /// written in place losslessly gets a `.xmp` instead.
    func editMetadata(_ items: [URL], _ edit: MetadataEdit, title: String) -> MetadataEditResult {
        var result = MetadataEditResult()
        let folders = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let root = folders.count == 1 ? folders.first! : Self.commonFolder(Array(folders))
        var entry = JournalEntry(id: UUID(), title: title, root: root, date: Date(), steps: [], failures: [], undone: false,
                                 finished: false)
        var listed: [String: [String]] = [:]
        for lead in items {
            let folder = lead.deletingLastPathComponent()
            let names = listed[folder.path] ?? ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
            listed[folder.path] = names
            guard fm.fileExists(atPath: lead.path) else {
                result.skipped.append("“\(lead.lastPathComponent)” is no longer there.")
                continue
            }
            guard MediaFormat.fromExtension(lead.pathExtension)?.kind == .image, !MediaFormat.isSequenceExtension(lead.pathExtension) else {
                result.skipped.append("“\(lead.lastPathComponent)” is not a photo; only photos can be changed for now.")
                continue
            }
            let place = Self.place(of: lead, names: names)
            if edit.field == .taken, place.hasMetadataFile {
                result.skipped.append("“\(lead.lastPathComponent)” keeps the date of its post.")
                continue
            }
            let current = Self.currentValues(of: lead, place: place)
            guard edit.apply(to: current) != nil else { continue }
            do {
                if place.xmp == nil, try writeInPlace(place.files, edit, entry: &entry, result: &result) {
                    result.changed += 1
                    continue
                }
                let xmp = place.xmp ?? MetadataWriter.xmpURL(for: lead, existing: names)
                if try writeXMP(xmp, values: edit.apply(to: current), entry: &entry, result: &result) { result.changed += 1 }
            } catch {
                result.skipped.append("“\(lead.lastPathComponent)” was left as it was: \(error.localizedDescription)")
            }
        }
        entry.finished = true
        entry.swaps = nil
        guard !entry.steps.isEmpty else { return result }
        if !save(entry) { result.skipped.append(Self.unsavedNote) }
        result.entry = entry
        return result
    }

    /// The folder holding all of these.
    static func commonFolder(_ folders: [String]) -> String {
        var common = folders.first.map { $0.split(separator: "/").map(String.init) } ?? []
        for folder in folders.dropFirst() {
            let parts = folder.split(separator: "/").map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return "/" + common.joined(separator: "/")
    }
}

extension OperationJournal {
    /// Writes each file of a unit beside itself and checks it; only when every one passed are they put in place. False
    /// (nothing changed) when one could not be written losslessly, so the caller writes a `.xmp` instead.
    func writeInPlace(_ files: [URL], _ edit: MetadataEdit, entry: inout JournalEntry, result: inout MetadataEditResult) throws -> Bool {
        var staged: [(file: URL, copy: URL, before: MetadataValues, after: MetadataValues)] = []
        func discard() { for item in staged { try? fm.removeItem(at: item.copy) } }
        for file in files {
            let current = MetadataWriter.values(of: file)
            guard let after = edit.apply(to: current) else { continue }
            let copy = Self.hiddenName(beside: file)
            do {
                try MetadataWriter.writeCopy(of: file, setting: after, to: copy)
            } catch MetadataWriter.Failure.pictureChanged, MetadataWriter.Failure.valuesNotKept {
                discard()
                return false
            } catch {
                discard()
                throw error
            }
            staged.append((file, copy, current.only(after.fields), after))
        }
        guard !staged.isEmpty else { return false }
        for (index, item) in staged.enumerated() {
            do {
                let written = try putInPlace(item.copy, over: item.file, step: .metadata(path: item.file.path, before: item.before,
                                                                                            after: item.after, made: false), entry: &entry)
                result.rewritten.append(written)
            } catch {
                // The ones already in place stay, recorded; the rest are not written.
                for rest in staged[(index + 1)...] { try? fm.removeItem(at: rest.copy) }
                try? fm.removeItem(at: item.copy)
                throw error
            }
        }
        return true
    }

    /// Writes `values` into the `.xmp` (made when there is none), as one recorded step.
    func writeXMP(_ xmp: URL, values: MetadataValues?, entry: inout JournalEntry, result: inout MetadataEditResult) throws -> Bool {
        guard let values else { return false }
        let existing = try? Data(contentsOf: xmp)
        let before = existing.map { MetadataWriter.values(ofXMP: $0) } ?? MetadataValues()
        let data = try MetadataWriter.xmpData(setting: values, over: existing)
        let step = JournalStep.metadata(path: xmp.path, before: before.withFields(values.fields), after: values,
                                        made: existing == nil)
        try writeXMPData(data, to: xmp, exists: existing != nil, step: step, entry: &entry)
        result.xmpWritten.append(xmp.path)
        return true
    }

    func writeXMPData(_ data: Data, to xmp: URL, exists: Bool, step: JournalStep?, entry: inout JournalEntry) throws {
        let copy = Self.hiddenName(beside: xmp)
        try FileOps.writeNew(data, to: copy)
        do {
            if exists {
                _ = try putInPlace(copy, over: xmp, step: step, entry: &entry)
            } else {
                if let step { record(step, entry: &entry) }
                try FileOps.renameExclusive(copy, to: xmp)
                note(xmp.path, in: &entry)
            }
        } catch {
            try? fm.removeItem(at: copy)
            throw error
        }
    }

    func record(_ step: JournalStep, entry: inout JournalEntry) {
        entry.steps.append(step)
        save(entry)
    }

    /// `.mediapull-edit-<id>.<ext>` beside `file`: hidden, and taken back at launch if left (R-4503).
    static func hiddenName(beside file: URL, was: Bool = false) -> URL {
        file.deletingLastPathComponent()
            .appendingPathComponent("\(editPrefix)\(UUID().uuidString)\(was ? "-was" : "").\(file.pathExtension)")
    }

    /// Puts the checked copy in the file's place (R-4503): the file's extended attributes, creation date and permissions
    /// go to the copy, the step is recorded, then the two swap names in one step where the drive can, else through a
    /// hidden name; the old bytes are then removed. Recorded before anything moves, so a stop part way is settled.
    func putInPlace(_ copy: URL, over file: URL, step: JournalStep?, entry: inout JournalEntry) throws -> RewrittenFile {
        let identity = AccountFolderRecord.number(of: file)
        try Self.carryAttributes(from: file, to: copy)
        // Hashed before the swap: the copy is complete and checked.
        let sha = try FileHasher.sha256(of: copy)
        let was = Self.hiddenName(beside: file, was: true)
        if entry.swaps == nil { entry.swaps = [:] }
        entry.swaps![copy.path] = file.path
        entry.swaps![was.path] = file.path
        if let step { entry.steps.append(step) }
        guard save(entry) else {
            if step != nil { entry.steps.removeLast() }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The undo record could not be saved."])
        }
        if renamex_np(copy.path, file.path, UInt32(RENAME_SWAP)) != 0 {
            let code = errno
            guard code == ENOTSUP || code == EINVAL else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            // exFAT, FAT: the file steps aside under a hidden name, the copy takes its name.
            try FileOps.renameExclusive(file, to: was)
            do {
                try FileOps.renameExclusive(copy, to: file)
            } catch {
                try? FileOps.renameExclusive(was, to: file) // lint:allow silent-write the error being thrown is reported
                throw error
            }
        }
        // The old bytes (now under the copy's hidden name) go: the new file was proven to hold the same picture (D-125).
        try? fm.removeItem(at: copy)
        try? fm.removeItem(at: was)
        entry.swaps?[copy.path] = nil
        entry.swaps?[was.path] = nil
        noteReplaced(file.path, was: identity, in: &entry)
        save(entry)
        Self.updateMetadataChecksum(of: file, to: sha)
        // Read afresh (a URL keeps values it read before): what a scan will compare against.
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        return RewrittenFile(path: file.path, sha256: sha, size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
                             modified: attributes?[.modificationDate] as? Date ?? Date())
    }

    /// Finder tags and every other extended attribute, the creation date, permissions and flags travel to the new version.
    static func carryAttributes(from file: URL, to copy: URL) throws {
        let fm = FileManager.default
        let size = listxattr(file.path, nil, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            let got = listxattr(file.path, &buffer, size, XATTR_NOFOLLOW)
            let names = got > 0
                ? buffer[0 ..< got].split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
                : []
            for name in names {
                let length = getxattr(file.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard length >= 0 else { continue }
                var value = [UInt8](repeating: 0, count: length)
                guard getxattr(file.path, name, &value, length, 0, XATTR_NOFOLLOW) == length else { continue }
                setxattr(copy.path, name, value, length, 0, XATTR_NOFOLLOW)
            }
        }
        let attributes = try fm.attributesOfItem(atPath: file.path)
        var carried: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.creationDate, .posixPermissions, .immutable, .appendOnly, .extensionHidden] {
            if let value = attributes[key] { carried[key] = value }
        }
        try fm.setAttributes(carried, ofItemAtPath: copy.path)
    }

    /// A MediaPull metadata file's `sha256` follows its media's new content (R-4503); one without it is left alone.
    static func updateMetadataChecksum(of file: URL, to sha: String) {
        let sidecar = Sidecar.sidecarURL(for: file)
        guard let data = try? Data(contentsOf: sidecar),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], object["sha256"] is String,
              let updated = try? FileOps.metadata(of: file,
                                                  applying: FileOps.MetadataChange(values: ["sha256": .string(sha)], isCopy: false))
        else { return }
        // lint:allow silent-write Check Folder reports a checksum that did not follow
        try? updated.write(to: sidecar, options: .atomic)
    }

    /// Before anything else is done with a change: a metadata edit stopped part way is settled, so every photo is under
    /// its own name (R-4503). A photo that stepped aside comes back; leftover copies go.
    func settleSwaps(_ entry: inout JournalEntry) {
        guard let swaps = entry.swaps, !swaps.isEmpty else { return }
        // A photo that stepped aside first, so it gets its name back before a leftover copy is weighed.
        let ordered = swaps.sorted { $0.key.contains("-was.") && !$1.key.contains("-was.") }
        for (hidden, file) in ordered where fm.fileExists(atPath: hidden) {
            if hidden.contains("-was."), !fm.fileExists(atPath: file) {
                try? FileOps.renameExclusive(URL(fileURLWithPath: hidden), to: URL(fileURLWithPath: file)) // lint:allow silent-write
                // reported by the undo that follows, which finds the photo as it was
            } else if fm.fileExists(atPath: file) {
                try? fm.removeItem(atPath: hidden)
            }
        }
        entry.swaps = nil
        save(entry)
    }

    /// Undo and Redo of a metadata step: writes `values` back by the same writer and check, on the same file only
    /// (R-4505). `removing`: Undo of a `.xmp` the edit made sends it to the Trash. `again`: Redo records the step anew.
    func rewrite(_ path: String, with values: MetadataValues, removing made: Bool = false,
                 again: (before: MetadataValues, made: Bool)? = nil, entry: inout JournalEntry, report: inout UndoReport) -> Bool
    {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let isXMP = url.pathExtension.lowercased() == "xmp"
        // Redo of a `.xmp` the edit made: made again when Undo sent it to the Trash.
        if let again, again.made, isXMP, !fm.fileExists(atPath: path) {
            do {
                let data = try MetadataWriter.xmpData(setting: values, over: nil)
                try writeXMPData(data, to: url, exists: false, step: .metadata(path: path, before: again.before, after: values, made: true),
                                 entry: &entry)
                report.done += 1
                report.restored += 1
                return true
            } catch {
                report.skipped.append("“\(name)” was not written again: \(error.localizedDescription)")
                return false
            }
        }
        guard isSame(path, in: entry) else {
            report.skipped.append(fm.fileExists(atPath: path) ? "“\(name)” was changed since, so it was left as it is."
                : "“\(name)” is no longer there.")
            return false
        }
        do {
            if isXMP {
                let data = try MetadataWriter.xmpData(setting: values, over: try? Data(contentsOf: url))
                if made, again == nil, MetadataWriter.values(ofXMP: data).fields.isEmpty {
                    // A `.xmp` the edit made that holds nothing else now goes to the Trash, never deleted.
                    var trashed: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &trashed)
                } else {
                    let step = again.map { JournalStep.metadata(path: path, before: $0.before, after: values, made: $0.made) }
                    try writeXMPData(data, to: url, exists: true, step: step, entry: &entry)
                }
            } else {
                let copy = Self.hiddenName(beside: url)
                try MetadataWriter.writeCopy(of: url, setting: values, to: copy)
                let step = again.map { JournalStep.metadata(path: path, before: $0.before, after: values, made: false) }
                do {
                    report.rewritten.append(try putInPlace(copy, over: url, step: step, entry: &entry))
                } catch {
                    try? fm.removeItem(at: copy)
                    throw error
                }
            }
        } catch {
            report.skipped.append("“\(name)” was left as it is: \(error.localizedDescription)")
            return false
        }
        report.done += 1
        report.restored += 1
        return true
    }
}

extension MetadataValues {
    /// The same values for exactly `wanted` fields (an absent field is a removal).
    func withFields(_ wanted: Set<MetadataField>) -> MetadataValues {
        var copy = only(wanted)
        copy.fields = wanted
        return copy
    }
}
