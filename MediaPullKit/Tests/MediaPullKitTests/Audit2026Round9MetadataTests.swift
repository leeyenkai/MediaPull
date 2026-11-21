import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullAnalysis
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullStore
import UniformTypeIdentifiers
import XCTest

final class Audit2026Round9MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("A9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func journal() -> OperationJournal { OperationJournal(folder: folder.appendingPathComponent("journal")) }

    func all(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
    }

    func dirs(_ list: String...) throws -> [URL] {
        try list.map { name in
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func raw(_ url: URL) throws { try Data(repeating: 3, count: 500).write(to: url) }

    /// Renumbering two RAW+JPEG pairs whose names swap (2 -> 1, 1 -> 2) goes through temporary names. Every member must
    /// end under its unit's new name; none may be left hidden.
    func testA9SwapRenameOfRAWPairsLeavesNoJPEGHidden() async throws {
        let d = try dirs("F")[0]
        for n in ["1", "2"] {
            try raw(d.appendingPathComponent("\(n).CR3"))
            MetadataEditTests.photo(d.appendingPathComponent("\(n).JPG"), type: .jpeg)
        }
        let journal = journal()
        let plan = FolderOperations.batchRename([d.appendingPathComponent("2.CR3"), d.appendingPathComponent("1.CR3")], pattern: "{n}")
        XCTAssertTrue(plan.moves.contains { $0.destination.lastPathComponent.hasPrefix(".mediapull-rename-") })
        let renamed = await journal.run(plan)
        XCTAssertEqual(all(d), ["1.CR3", "1.JPG", "2.CR3", "2.JPG"], "forward: \(renamed.failures)")
        _ = await journal.undo(renamed.id)
        XCTAssertEqual(all(d), ["1.CR3", "1.JPG", "2.CR3", "2.JPG"], "undo")
    }

    /// The same with Live Photos (HEIC/JPEG + MOV).
    func testA9SwapRenameOfLivePhotosLeavesNoClipHidden() async throws {
        let d = try dirs("F")[0]
        for n in ["1", "2"] {
            MetadataEditTests.photo(d.appendingPathComponent("\(n).JPG"), type: .jpeg)
            try Data(repeating: 7, count: 300).write(to: d.appendingPathComponent("\(n).MOV"))
        }
        let journal = journal()
        let plan = FolderOperations.batchRename([d.appendingPathComponent("2.JPG"), d.appendingPathComponent("1.JPG")], pattern: "{n}")
        let renamed = await journal.run(plan)
        XCTAssertEqual(all(d), ["1.JPG", "1.MOV", "2.JPG", "2.MOV"], "forward: \(renamed.failures)")
    }

    /// A rated PNG (its rating in P.xmp) is edited and replaced in the editor (D-107), then ⌘Z: the original comes back
    /// and its .xmp must stay beside it under its own name, never under the edit's hidden name.
    func testA9UndoOfAReplaceLeavesThePhotosXMPBesideIt() async throws {
        let d = try dirs("F")[0]
        let original = d.appendingPathComponent("P.png")
        MetadataEditTests.photo(original, type: .png)
        let journal = journal()
        _ = await journal.editMetadata([original], .rating(4), title: "Rate")
        XCTAssertEqual(all(d), ["P.png", "P.xmp"])
        let edit = folder.appendingPathComponent("edit.png")
        MetadataEditTests.photo(edit, type: .png, date: "2021:01:01 00:00:00")
        let entry = try await journal.replace(original, identity: AccountFolderRecord.number(of: original), with: edit, named: original,
                                              metadata: nil, title: "Replace")
        XCTAssertEqual(all(d), ["P.png", "P.xmp"])
        let report = await journal.undo(entry.id)
        XCTAssertEqual(all(d), ["P.png", "P.xmp"], "after Undo of the Replace: \(report.skipped)")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("P.xmp"))?.rating, 4)
    }

    /// Two rated PNGs moved X -> Y; Undo stopped after one; Redo; Undo; Redo: every photo keeps its .xmp throughout.
    func testA9PartialUndoRedoKeepsEditFilesWithTheirPhotos() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        for n in ["A", "B", "C"] { MetadataEditTests.photo(x.appendingPathComponent("\(n).png"), type: .png) }
        let journal = journal()
        _ = await journal.editMetadata(["A", "B", "C"].map { x.appendingPathComponent("\($0).png") }, .rating(3), title: "Rate")
        let move = await journal.run(FolderOperations.move(["A", "B", "C"].map { x.appendingPathComponent("\($0).png") }, to: y))
        XCTAssertEqual(all(y), ["A.png", "A.xmp", "B.png", "B.xmp", "C.png", "C.xmp"])
        await journal.stop(after: 1)
        _ = await journal.undo(move.id)
        await journal.stop(after: nil)
        XCTAssertEqual(all(x), ["C.png", "C.xmp"])
        _ = await journal.redo(move.id)
        XCTAssertEqual(all(y), ["A.png", "A.xmp", "B.png", "B.xmp", "C.png", "C.xmp"], "redo")
        await journal.stop(after: 2)
        _ = await journal.undo(move.id)
        await journal.stop(after: nil)
        _ = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["A.png", "A.xmp", "B.png", "B.xmp", "C.png", "C.xmp"], "undo all: y=\(all(y))")
        _ = await journal.redo(move.id)
        XCTAssertEqual(all(y), ["A.png", "A.xmp", "B.png", "B.xmp", "C.png", "C.xmp"], "redo all: x=\(all(x))")
        _ = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["A.png", "A.xmp", "B.png", "B.xmp", "C.png", "C.xmp"], "undo again: y=\(all(y))")
    }

    /// A folder holding a RAW pair and a rated PNG is moved; inside it the pair is renamed; Undo of the rename then of the
    /// folder move; Redo of both.
    func testA9NestedFolderMoveWithUnitsInside() async throws {
        let d = try dirs("X/Trip", "Y")
        let trip = d[0], y = d[1]
        try raw(trip.appendingPathComponent("IMG_1.CR3"))
        MetadataEditTests.photo(trip.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let journal = journal()
        _ = await journal.editMetadata([trip.appendingPathComponent("IMG_1.CR3")], .rating(2), title: "Rate")
        XCTAssertEqual(all(trip), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
        let move = await journal.run(FolderOperations.move([trip], to: y))
        let moved = y.appendingPathComponent("Trip")
        let rename = await journal.run(FolderOperations.rename(moved.appendingPathComponent("IMG_1.CR3"), to: "Day"))
        XCTAssertEqual(all(moved), ["Day.CR3", "Day.JPG", "Day.xmp"])
        _ = await journal.undo(rename.id)
        _ = await journal.undo(move.id)
        XCTAssertEqual(all(trip), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
        _ = await journal.redo(move.id)
        _ = await journal.redo(rename.id)
        XCTAssertEqual(all(moved), ["Day.CR3", "Day.JPG", "Day.xmp"])
    }

    /// A rated PNG (P.png, P.xmp) moved into a folder that holds another photo called P (P.jpg): the move must not put the
    /// .xmp beside a second photo of that name (R-4502), and Undo must bring the rating back with its photo.
    func testA9MoveBesideAnotherPhotoOfTheNameKeepsTheRatingWithItsPhoto() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("P.png"), type: .png)
        MetadataEditTests.photo(y.appendingPathComponent("P.jpg"), type: .jpeg)
        let journal = journal()
        _ = await journal.editMetadata([x.appendingPathComponent("P.png")], .rating(5), title: "Rate")
        let move = await journal.run(FolderOperations.move([x.appendingPathComponent("P.png")], to: y))
        let forward = all(y)
        _ = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["P.png", "P.xmp"], "forward put \(forward) in Y; after Undo Y has \(all(y))")
        XCTAssertEqual(all(y), ["P.jpg"])
    }

    /// The same with a RAW pair moved into a folder holding a camera clip of the same name (IMG_1.MOV).
    func testA9RAWPairMovedBesideAClipOfTheNameComesBackWhole() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        try raw(x.appendingPathComponent("IMG_1.CR3"))
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try Data(repeating: 7, count: 300).write(to: y.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        _ = await journal.editMetadata([x.appendingPathComponent("IMG_1.CR3")], .rating(5), title: "Rate")
        XCTAssertEqual(all(x), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"])
        let move = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.CR3")], to: y))
        let forward = all(y)
        _ = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "forward put \(forward) in Y; after Undo Y has \(all(y))")
    }

    /// A camera's IMG_1.CR3 and a phone's IMG_1.JPG, taken the same day, sorted by date into one folder: they are two
    /// shots and must stay two items, never become one RAW+JPEG unit that hides the phone's photo and goes to the Trash
    /// with the camera's.
    func testA9SortingTwoShotsOfOneNameIntoOneFolderKeepsThemApart() async throws {
        let d = try dirs("Card", "Phone", "Sorted")
        try raw(d[0].appendingPathComponent("IMG_1.CR3"))
        MetadataEditTests.photo(d[1].appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let journal = journal()
        let files = [d[0].appendingPathComponent("IMG_1.CR3"), d[1].appendingPathComponent("IMG_1.JPG")]
        let sort = await journal.run(FolderOperations.sort(files, into: d[2], title: "Sort by Date") { _ in [["2020-01-02"]] })
        let day = d[2].appendingPathComponent("2020-01-02")
        XCTAssertEqual(FolderOperations.mediaFiles(in: day, recursive: false).count, 2,
                       "one of the two photos is hidden as a member: \(all(day)), \(sort.failures)")
        let trash = await journal.run(FolderOperations.trash([day.appendingPathComponent("IMG_1.CR3")]))
        XCTAssertTrue(all(day).contains { $0.hasPrefix("IMG_1") && $0.hasSuffix(".JPG") },
                      "the phone's photo went to the Trash with the camera's RAW: \(all(day)) \(trash.steps.count)")
    }

    /// On a FAT card (no name swap, two-second dates): rate a JPEG in place, move it with a rated PNG, Undo the move,
    /// Undo the rating, Redo both.
    func testA9FATCardEditsMovesUndoRedo() async throws {
        guard let mount = ProcessInfo.processInfo.environment["A9_FAT"] else { throw XCTSkip("no FAT image") }
        let root = URL(fileURLWithPath: mount).appendingPathComponent("T-\(UUID().uuidString.prefix(6))")
        let x = root.appendingPathComponent("DCIM"), y = root.appendingPathComponent("Keep")
        try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: y, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        MetadataEditTests.photo(x.appendingPathComponent("A.JPG"), type: .jpeg)
        MetadataEditTests.photo(x.appendingPathComponent("B.png"), type: .png)
        let journal = journal()
        let rate = await journal.editMetadata([x.appendingPathComponent("A.JPG"), x.appendingPathComponent("B.png")], .rating(4),
                                              title: "Rate")
        XCTAssertEqual(rate.changed, 2, "\(rate.skipped)")
        XCTAssertEqual(all(x), ["A.JPG", "B.png", "B.xmp"])
        XCTAssertEqual(MetadataWriter.values(of: x.appendingPathComponent("A.JPG")).rating, 4)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let move = await journal.run(FolderOperations.move([x.appendingPathComponent("A.JPG"), x.appendingPathComponent("B.png")], to: y))
        XCTAssertEqual(all(y), ["A.JPG", "B.png", "B.xmp"])
        let u1 = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["A.JPG", "B.png", "B.xmp"], "\(u1.skipped)")
        let u2 = await journal.undo(rate.entry!.id)
        XCTAssertNil(MetadataWriter.values(of: x.appendingPathComponent("A.JPG")).rating, "\(u2.skipped)")
        XCTAssertEqual(all(x), ["A.JPG", "B.png"], "\(u2.skipped)")
        let r1 = await journal.redo(rate.entry!.id)
        XCTAssertEqual(MetadataWriter.values(of: x.appendingPathComponent("A.JPG")).rating, 4, "\(r1.skipped)")
        XCTAssertEqual(all(x), ["A.JPG", "B.png", "B.xmp"], "\(r1.skipped)")
        let r2 = await journal.redo(move.id)
        XCTAssertEqual(all(y), ["A.JPG", "B.png", "B.xmp"], "\(r2.skipped)")
        // A swap rename on the card.
        let swap = await journal.run(FolderOperations.batchRename([y.appendingPathComponent("B.png"), y.appendingPathComponent("A.JPG")],
                                                                  pattern: "{n}"))
        let u3 = await journal.undo(swap.id)
        XCTAssertEqual(all(y), ["A.JPG", "B.png", "B.xmp"], "\(u3.skipped)")
    }

    /// Flatten a card's two camera folders, each with a rated RAW pair called IMG_1; Undo; Redo.
    func testA9FlattenOfRatedPairsUndoRedo() async throws {
        let d = try dirs("DCIM/100CANON", "DCIM/101CANON")
        for f in d {
            try raw(f.appendingPathComponent("IMG_1.CR3"))
            MetadataEditTests.photo(f.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        }
        let journal = journal()
        _ = await journal.editMetadata([d[0].appendingPathComponent("IMG_1.CR3")], .rating(1), title: "Rate")
        _ = await journal.editMetadata([d[1].appendingPathComponent("IMG_1.CR3")], .rating(2), title: "Rate")
        let top = folder.appendingPathComponent("DCIM")
        let flat = await journal.run(FolderOperations.flatten(top))
        XCTAssertEqual(all(top), ["IMG_1 2.CR3", "IMG_1 2.JPG", "IMG_1 2.xmp", "IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "\(flat.failures)")
        let u = await journal.undo(flat.id)
        XCTAssertEqual(all(d[0]), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "\(u.skipped)")
        XCTAssertEqual(all(d[1]), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "\(u.skipped)")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d[1].appendingPathComponent("IMG_1.xmp"))?.rating, 2)
        let r = await journal.redo(flat.id)
        XCTAssertEqual(all(top), ["IMG_1 2.CR3", "IMG_1 2.JPG", "IMG_1 2.xmp", "IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "\(r.skipped)")
    }

    /// A JPEG and a PNG moved X -> Y, both rated there by MediaPull (the JPEG in place, the PNG in a .xmp), then Undo of
    /// the move: both go back, as the PNG does (R-4505: only a change by something else keeps a file where it is).
    func testA9UndoOfAMoveAfterAnInPlaceRatingTakesThePhotoBack() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("A.jpg"), type: .jpeg)
        MetadataEditTests.photo(x.appendingPathComponent("B.png"), type: .png)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([x.appendingPathComponent("A.jpg"), x.appendingPathComponent("B.png")], to: y))
        try await Task.sleep(nanoseconds: 1_100_000_000)
        _ = await journal.editMetadata([y.appendingPathComponent("A.jpg"), y.appendingPathComponent("B.png")], .rating(3), title: "Rate")
        XCTAssertEqual(all(y), ["A.jpg", "B.png", "B.xmp"])
        let report = await journal.undo(move.id)
        XCTAssertEqual(all(x), ["A.jpg", "B.png", "B.xmp"], "\(report.skipped)")
    }
}
