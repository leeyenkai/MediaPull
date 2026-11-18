import Foundation

/// One note in the scratchpad (D-109): plain text, named by its first line.
public struct ScratchNote: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var text: String
    public var created: Date
    public var modified: Date

    public init(id: UUID = UUID(), text: String = "", created: Date = Date(), modified: Date? = nil) {
        self.id = id
        self.text = text
        self.created = created
        self.modified = modified ?? created
    }

    /// The first line that has any text, shortened; "New Note" while it is empty.
    public var title: String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line else { return "New Note" }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// The text after the first line, for a short preview under the title.
    public var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst().first.map { $0.count > 80 ? String($0.prefix(79)) + "…" : $0 } ?? ""
    }
}

/// The scratchpad's notes, newest change first.
public struct NoteCollection: Codable, Sendable, Equatable {
    public private(set) var notes: [ScratchNote] = []

    public init(notes: [ScratchNote] = []) {
        self.notes = notes.sorted { $0.modified > $1.modified }
    }

    public subscript(id: UUID) -> ScratchNote? { notes.first { $0.id == id } }

    /// Adds an empty note at the top and returns it.
    @discardableResult
    public mutating func add(at date: Date = Date()) -> ScratchNote {
        let note = ScratchNote(created: date)
        notes.insert(note, at: 0)
        return note
    }

    /// Sets a note's text; a note that changed moves to the top.
    public mutating func update(_ id: UUID, text: String, at date: Date = Date()) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        var note = notes.remove(at: index)
        note.text = text
        note.modified = date
        notes.insert(note, at: 0)
    }

    public mutating func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
    }

    /// Notes read from disk keep the newest first, whatever order the file had.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(notes: try container.decode([ScratchNote].self, forKey: .notes))
    }
}
