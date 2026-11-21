import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullStore
import UniformTypeIdentifiers
import XCTest

/// Auditor A, round 7: each test asserts the correct behaviour.
final class Audit2026Round7MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("A7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func journal() -> OperationJournal { OperationJournal(folder: folder.appendingPathComponent("journal")) }

    func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    func dirs(_ list: String...) throws -> [URL] {
        try list.map { name in
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    /// T1: Undo of a JPEG's move into a folder whose RAW of the same name has its own .xmp must leave that .xmp with the RAW.
    func testUndoOfAMoveNeverTakesAnotherPhotosXMP() async throws {
        let d = try dirs("A", "B")
        let (a, b) = (d[0], d[1])
        let raw = b.appendingPathComponent("IMG_0001.NEF")
        MetadataEditTests.photo(raw, type: .tiff)
        let jpeg = a.appendingPathComponent("IMG_0001.JPG")
        MetadataEditTests.photo(jpeg, type: .jpeg)
        let journal = journal()
        _ = await journal.editMetadata([raw], .rating(2), title: "Rate")
        XCTAssertEqual(names(b), ["IMG_0001.NEF", "IMG_0001.xmp"])
        let move = await journal.run(FolderOperations.move([jpeg], to: b))
        XCTAssertEqual(names(b), ["IMG_0001.JPG", "IMG_0001.NEF", "IMG_0001.xmp"])
        _ = await journal.undo(move.id)
        XCTAssertEqual(names(a), ["IMG_0001.JPG"], "the RAW's .xmp went with the JPEG")
        XCTAssertEqual(names(b), ["IMG_0001.NEF", "IMG_0001.xmp"])
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: b.appendingPathComponent("IMG_0001.xmp"))?.rating, 2)
    }

    /// T2: Redo of a move after Undo carried a .xmp made since must take the .xmp with its photo again.
    func testRedoOfAMoveTakesTheCarriedXMPAlong() async throws {
        let d = try dirs("A", "B")
        let (a, b) = (d[0], d[1])
        let png = a.appendingPathComponent("P.png")
        MetadataEditTests.photo(png, type: .png)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([png], to: b))
        _ = await journal.editMetadata([b.appendingPathComponent("P.png")], .rating(4), title: "Rate")
        _ = await journal.undo(move.id)
        XCTAssertEqual(names(a), ["P.png", "P.xmp"])
        _ = await journal.redo(move.id)
        XCTAssertEqual(names(b), ["P.png", "P.xmp"], "Redo left the .xmp behind")
        XCTAssertEqual(names(a), [])
    }

    /// T3: a copy rated since (its rating in a new .xmp) is edited: Undo of the copy keeps it (R-3806), never trashing the
    /// photo and leaving its .xmp alone.
    func testUndoOfACopyRatedSinceKeepsIt() async throws {
        let d = try dirs("A", "B")
        let (a, b) = (d[0], d[1])
        let raw = a.appendingPathComponent("DSC_9.NEF")
        MetadataEditTests.photo(raw, type: .tiff)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([raw], to: b))
        _ = await journal.editMetadata([b.appendingPathComponent("DSC_9.NEF")], .rating(5), title: "Rate")
        XCTAssertEqual(names(b), ["DSC_9.NEF", "DSC_9.xmp"])
        _ = await journal.undo(copy.id)
        XCTAssertEqual(names(b), ["DSC_9.NEF", "DSC_9.xmp"], "the copy went to the Trash and its .xmp was left alone")
    }

    /// T4: an Undo step refused because the photo of a .xmp is locked is tried again once it is unlocked (A6-5).
    func testAnXMPStepRefusedForALockedPhotoIsTriedAgain() async throws {
        let one = folder.appendingPathComponent("P1.png"), two = folder.appendingPathComponent("P2.png")
        MetadataEditTests.photo(one, type: .png)
        MetadataEditTests.photo(two, type: .png)
        let journal = journal()
        let rated = await journal.editMetadata([one, two], .keywords(add: ["k"], remove: []), title: "Keyword")
        let id = try XCTUnwrap(rated.entry?.id)
        // Another app's tag in each .xmp, so Undo writes rather than trashes them.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: two.path)
        let first = await journal.undo(id)
        XCTAssertEqual(first.done, 1)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: two.path)
        _ = await journal.undo(id)
        let xmp = folder.appendingPathComponent("P2.xmp")
        XCTAssertNil(MetadataWriter.values(ofXMPAt: xmp)?.keywords, "the locked photo's step was dropped for good")
    }

    /// T5: another app saves the RAW's .xmp safely (a new file under the same name) after a move: Undo keeps the pair whole.
    func testUndoOfAMoveTakesAnXMPAnotherAppSavedAgain() async throws {
        let d = try dirs("A", "B")
        let (a, b) = (d[0], d[1])
        let raw = a.appendingPathComponent("DSC_1.NEF")
        MetadataEditTests.photo(raw, type: .tiff)
        MetadataEditTests.photo(a.appendingPathComponent("DSC_1.JPG"), type: .jpeg)
        let journal = journal()
        _ = await journal.editMetadata([raw], .rating(3), title: "Rate")
        let move = await journal.run(FolderOperations.move([raw], to: b))
        XCTAssertEqual(names(b), ["DSC_1.JPG", "DSC_1.NEF", "DSC_1.xmp"])
        // A safe save: written beside it, then renamed over it, as most apps save.
        let xmp = b.appendingPathComponent("DSC_1.xmp")
        let data = try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 5), over: Data(contentsOf: xmp))
        try data.write(to: xmp, options: .atomic)
        _ = await journal.undo(move.id)
        XCTAssertEqual(names(a), ["DSC_1.JPG", "DSC_1.NEF", "DSC_1.xmp"], "the .xmp was left in the other folder")
    }

    /// T6: a name given after an edit survives Undo when a copy holds the edited content (from A6-3's rule).
    func testANameGivenAfterAnEditSurvivesUndoWhenACopyHoldsTheEditedContent() async throws {
        let store = try AnalysisStore.make(folder: nil)
        await store.save(AnalysisRecord(sha256: "S1", facts: MediaFacts()))
        await store.addFaces([NewFace(key: "f1", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "S1")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        // Rated: S1 -> S2.
        _ = await store.rekey(from: "S1", to: "S2")
        await store.setPath("/lib/P.jpg", sha256: "S2", size: 2, modified: Date())
        // Copied elsewhere (Organise copy, a backup drive): Q holds S2.
        await store.setPath("/backup/P.jpg", sha256: "S2", size: 2, modified: Date())
        // Named by the person (a correction, never regrouping).
        let alice = await store.split(faceKeys: ["S2|f1"], from: UUID())
        // Undo of the rating on P: S2 -> S1, before a scan pruned S1.
        _ = await store.rekey(from: "S2", to: "S1")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        let face = await store.faces().first { $0.key == "S1|f1" }
        XCTAssertEqual(face?.personID, alice, "P lost the name given after the edit")
    }
}
