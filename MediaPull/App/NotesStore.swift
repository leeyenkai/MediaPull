import Foundation
import MediaPullCore
import Observation

/// The scratchpad's notes (D-109, R-706): one small JSON file in Application Support, never in a library folder and never
/// sent anywhere. Self-tests keep them in memory.
@Observable
final class NotesStore {
    private(set) var notes = NoteCollection()
    /// Why the notes could not be saved or read the last time, shown in the popover.
    var problem: String?
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var edited = false
    @ObservationIgnored private var unsaved = false
    /// Counts changes, so a save that finishes late never marks newer typing as saved (R1-m7).
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The file is there but could not be read (permissions, a disk error): nothing is written over it.
    @ObservationIgnored private var blocked = false

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MediaPull/Notes", isDirectory: true)
    }

    /// `folder` nil keeps the notes in memory only.
    init(folder: URL?) {
        self.folder = folder
        guard let folder else {
            loaded = true
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Self.read(in: folder) }.value
            problem = result.problem
            blocked = result.blocked
            // Notes written before loading finished are kept on top of what was on disk.
            if let stored = result.notes {
                notes = edited ? NoteCollection(notes: notes.notes + stored.notes.filter { notes[$0.id] == nil }) : stored
            }
            loaded = true
            if edited { scheduleSave() }
        }
    }

    /// Whether the stored notes have been read (self-tests wait for it).
    var hasLoaded: Bool { loaded }

    @discardableResult
    func add() -> ScratchNote {
        let note = notes.add()
        changed()
        return note
    }

    func update(_ id: UUID, text: String) {
        guard notes[id]?.text != text else { return }
        notes.update(id, text: text)
        changed()
    }

    func delete(_ id: UUID) {
        notes.delete(id)
        changed()
    }

    private func changed() {
        edited = true
        generation += 1
        scheduleSave()
    }

    /// Notes left empty go when another note is chosen or the popover closes, so New Note never piles up blank notes.
    func dropEmpty(except keep: UUID?) {
        let empty = notes.notes.filter { $0.id != keep && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !empty.isEmpty else { return }
        for note in empty {
            notes.delete(note.id)
        }
        changed()
    }

    // MARK: Saving

    private func scheduleSave() {
        guard let folder, loaded, !blocked else { return }
        unsaved = true
        saveTask?.cancel()
        let notes = notes, saving = generation
        saveTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let problem = Self.write(notes, to: folder)
            await MainActor.run {
                self?.problem = problem
                // Only when nothing changed meanwhile: newer typing is still to be saved, at the next save or at quit.
                if problem == nil, self?.generation == saving { self?.unsaved = false }
            }
        }
    }

    /// Writes what is not saved yet at once; called when the app quits, inside the one-second delay.
    func flush() {
        guard let folder, loaded, unsaved, !blocked else { return }
        saveTask?.cancel()
        problem = Self.write(notes, to: folder)
        unsaved = problem != nil
    }

    nonisolated static func write(_ notes: NoteCollection, to folder: URL) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try encoder.encode(notes).write(to: folder.appendingPathComponent("notes.json"), options: .atomic)
            return nil
        } catch {
            return "Notes could not be saved: \(error.localizedDescription)"
        }
    }

    /// A file that exists but cannot be read is set aside (notes.damaged-<date>.json), never written over; copies set aside
    /// more than 30 days ago go (SPEC 6.3).
    nonisolated static func read(in folder: URL) -> (notes: NoteCollection?, problem: String?, blocked: Bool) {
        let fm = FileManager.default
        let file = folder.appendingPathComponent("notes.json")
        // lint:allow main-io a few names, once at launch, from a detached task
        for old in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where old.hasPrefix("notes.damaged-") {
            let stamp = Double(old.dropFirst("notes.damaged-".count).prefix { $0.isNumber }) ?? 0
            if Date().timeIntervalSince1970 - stamp > 30 * 86400 {
                // lint:allow silent-write a copy that stays is removed at a later launch
                try? fm.removeItem(at: folder.appendingPathComponent(old))
            }
        }
        guard fm.fileExists(atPath: file.path) else { return (nil, nil, false) }
        guard let data = try? Data(contentsOf: file) else { // lint:allow main-io one small JSON file, once at launch
            return (nil, "Notes could not be read, so changes are not saved until MediaPull is opened again.", true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let notes = try? decoder.decode(NoteCollection.self, from: data) { return (notes, nil, false) }
        let aside = folder.appendingPathComponent("notes.damaged-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try fm.moveItem(at: file, to: aside) // lint:allow app-data setting MediaPull's own damaged notes file aside
            return (nil, "The notes file could not be read, so it was set aside as \(aside.lastPathComponent).", false)
        } catch {
            return (nil, "The notes file could not be read: \(error.localizedDescription)", true)
        }
    }
}
