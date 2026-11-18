import Foundation
@testable import MediaPullCore
import XCTest

/// The scratchpad's notes (D-109).
final class NotesTests: XCTestCase {
    func testNotesKeepNewestFirstAndNameThemselves() throws {
        var notes = NoteCollection()
        let first = notes.add(at: Date(timeIntervalSince1970: 100))
        let second = notes.add(at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(notes.notes.map(\.id), [second.id, first.id])
        XCTAssertEqual(notes[first.id]?.title, "New Note")
        notes.update(first.id, text: "\n  Shopping list  \nmilk\neggs", at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(notes.notes.map(\.id), [first.id, second.id], "a changed note moves to the top")
        XCTAssertEqual(notes[first.id]?.title, "Shopping list")
        XCTAssertEqual(notes[first.id]?.preview, "milk")
        notes.update(second.id, text: String(repeating: "a", count: 100), at: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(notes[second.id]?.title.count, 60)
        // Setting the same text again changes nothing, not even the order.
        notes.update(first.id, text: notes[first.id]?.text ?? "", at: Date(timeIntervalSince1970: 500))
        XCTAssertEqual(notes.notes.first?.id, second.id)
        notes.delete(second.id)
        XCTAssertEqual(notes.notes.map(\.id), [first.id])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(NoteCollection.self, from: encoder.encode(notes)), notes)
        // A file in another order reads newest first.
        let old = #"{"id":"\#(UUID())","text":"old","created":"2020-01-01T00:00:00Z","modified":"2020-01-01T00:00:00Z"}"#
        let new = #"{"id":"\#(UUID())","text":"new","created":"2021-01-01T00:00:00Z","modified":"2021-01-01T00:00:00Z"}"#
        let shuffled = Data(#"{"notes":[\#(old),\#(new)]}"#.utf8)
        XCTAssertEqual(try decoder.decode(NoteCollection.self, from: shuffled).notes.map(\.text), ["new", "old"])
    }
}
