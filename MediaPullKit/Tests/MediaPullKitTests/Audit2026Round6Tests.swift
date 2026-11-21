import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullStore
import UniformTypeIdentifiers
import XCTest

/// Audit 2026-11-21, round 6: metadata edits.
final class Audit2026Round6Tests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Round6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func journal() -> OperationJournal {
        OperationJournal(folder: folder.appendingPathComponent("journal"))
    }

    func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A RAW pair in `A`, with `F` beside it.
    func pair() throws -> (raw: URL, from: URL, to: URL) {
        let from = folder.appendingPathComponent("A"), to = folder.appendingPathComponent("F")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        let raw = from.appendingPathComponent("DSC_1.NEF")
        MetadataEditTests.photo(raw, type: .tiff)
        MetadataEditTests.photo(from.appendingPathComponent("DSC_1.JPG"), type: .jpeg)
        return (raw, from, to)
    }

    func testRedoOfAnOlderXMPChangeLeavesANewerOne() async throws {
        let raw = folder.appendingPathComponent("DSC_2.NEF")
        MetadataEditTests.photo(raw, type: .tiff)
        let xmp = folder.appendingPathComponent("DSC_2.xmp")
        let journal = journal()
        _ = await journal.editMetadata([raw], .keywords(add: ["birds"], remove: []), title: "Keyword")
        let rated = await journal.editMetadata([raw], .rating(3), title: "Rate")
        let older = try XCTUnwrap(rated.entry?.id)
        _ = await journal.undo(older)
        _ = await journal.editMetadata([raw], .rating(5), title: "Rate")
        // The .xmp did not hold a rating before the older change: it holds one now, so Redo leaves it (A6-1).
        let redo = await journal.redo(older)
        XCTAssertEqual(redo.done, 0)
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.rating, 5)
    }

    func testUndoOfAMoveKeepsTheXMPWithItsPhotoAndAnEditedCopyStaysWhole() async throws {
        // Rated after the move, the .xmp changed (A6-2).
        var (raw, from, to) = try pair()
        let journal = journal()
        _ = await journal.editMetadata([raw], .keywords(add: ["birds"], remove: []), title: "Keyword")
        let move = await journal.run(FolderOperations.move([raw], to: to))
        _ = await journal.editMetadata([to.appendingPathComponent("DSC_1.NEF")], .rating(4), title: "Rate")
        _ = await journal.undo(move.id)
        XCTAssertEqual(names(from), ["DSC_1.JPG", "DSC_1.NEF", "DSC_1.xmp"])
        XCTAssertEqual(names(to), [])
        // Moved, then rated: the .xmp is made after the move and goes back with the pair.
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        (raw, from, to) = try pair()
        let second = self.journal()
        let made = await second.run(FolderOperations.move([raw], to: to))
        _ = await second.editMetadata([to.appendingPathComponent("DSC_1.NEF")], .rating(4), title: "Rate")
        _ = await second.undo(made.id)
        XCTAssertEqual(names(from), ["DSC_1.JPG", "DSC_1.NEF", "DSC_1.xmp"])
        // A copy rated since stays whole.
        let copy = await second.run(FolderOperations.copy([from.appendingPathComponent("DSC_1.NEF")], to: to))
        _ = await second.editMetadata([to.appendingPathComponent("DSC_1.NEF")], .keywords(add: ["copy"], remove: []), title: "Keyword")
        _ = await second.undo(copy.id)
        XCTAssertEqual(names(to), ["DSC_1.JPG", "DSC_1.NEF", "DSC_1.xmp"])
    }

    func testANameGivenAfterAnEditSurvivesUndoAndRedoWithADuplicate() async throws {
        // P and Q are duplicates (S1); P rated (S2) and its face named; the rating undone and redone (A6-3).
        let store = try AnalysisStore.make(folder: nil)
        await store.save(AnalysisRecord(sha256: "S1", facts: MediaFacts()))
        await store.addFaces([NewFace(key: "f1", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "S1")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        await store.setPath("/lib/Q.jpg", sha256: "S1", size: 1, modified: Date())
        _ = await store.rekey(from: "S1", to: "S2", path: "/lib/P.jpg")
        await store.setPath("/lib/P.jpg", sha256: "S2", size: 2, modified: Date())
        let alice = UUID()
        _ = await store.applyAssignments(["S2|f1": alice])
        _ = await store.rekey(from: "S2", to: "S1", path: "/lib/P.jpg")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        _ = await store.rekey(from: "S1", to: "S2", path: "/lib/P.jpg")
        let face = await store.faces().first { $0.key == "S2|f1" }
        XCTAssertEqual(face?.personID, alice)
    }

    func testEmptyPacketsAreNothingAndALockedStepIsTriedAgain() async throws {
        // White space, an empty xpacket wrapper and a bare empty RDF root hold nothing (A6-4).
        for text in [" \n", "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n<?xpacket end=\"w\"?>",
                     "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"></rdf:RDF>"]
        {
            XCTAssertNoThrow(try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 3), over: Data(text.utf8)),
                             text)
        }
        // A photo locked during Undo is undone once unlocked (A6-5).
        let one = folder.appendingPathComponent("IMG_1.JPG"), two = folder.appendingPathComponent("IMG_2.JPG")
        MetadataEditTests.photo(one, type: .jpeg)
        MetadataEditTests.photo(two, type: .jpeg)
        let journal = journal()
        let rated = await journal.editMetadata([one, two], .rating(4), title: "Rate")
        let id = try XCTUnwrap(rated.entry?.id)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: two.path)
        _ = await journal.undo(id)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: two.path)
        _ = await journal.undo(id)
        XCTAssertNil(MetadataWriter.values(of: two).rating)
        XCTAssertNil(MetadataWriter.values(of: one).rating)
    }
}
