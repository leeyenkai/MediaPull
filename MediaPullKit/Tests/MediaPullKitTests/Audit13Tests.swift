import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// Undo and Redo that do nothing, and copied folders' contents, from the thirteenth audit.
final class Audit13Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit13-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, _ text: String? = nil) -> URL {
        let url = root.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((text ?? path).utf8).write(to: url)
        return url
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }
    func journal() -> OperationJournal {
        OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
    }

    /// B13-m1: after a sort is undone and redone, Redo of a rename in its folder never renames another photo that took the
    /// name.
    func testAFolderMadeAgainNeverStandsForItsContents() async throws {
        let photo = file("S/a.jpg", "first")
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let journal = journal()
        let sort = await journal.run(FolderOperations.sort([photo], into: url("T"), title: "Sort") { _ in [["2024"]] })
        _ = await journal.undo(sort.id)
        _ = await journal.redo(sort.id)
        XCTAssertTrue(exists("T/2024/a.jpg"))
        let rename = await journal.run(FolderOperations.rename(url("T/2024/a.jpg"), to: "beach.jpg"))
        _ = await journal.undo(rename.id)
        try fm.removeItem(at: url("T/2024/a.jpg"))
        file("T/2024/a.jpg", "another photo")
        let report = await journal.redo(rename.id)
        XCTAssertEqual(report.done, 0)
        XCTAssertTrue(exists("T/2024/a.jpg"))
        XCTAssertFalse(exists("T/2024/beach.jpg"))
    }

    /// B13-m2: a Redo whose files were all refused makes no empty folders and stays undone; once the file is back it
    /// sorts it.
    func testARedoOfFoldersOnlyMakesNothing() async throws {
        let photo = file("S/a.jpg")
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let journal = journal()
        let sort = await journal.run(FolderOperations.sort([photo], into: url("T"), title: "Sort") { _ in [["2024"]] })
        _ = await journal.undo(sort.id)
        try fm.moveItem(at: url("S/a.jpg"), to: url("S/b.jpg"))
        let report = await journal.redo(sort.id)
        XCTAssertEqual(report.done, 0, "\(report.skipped)")
        XCTAssertFalse(exists("T/2024"))
        let entry = await journal.entry(sort.id)
        XCTAssertEqual(entry?.undone, true)
        try fm.moveItem(at: url("S/b.jpg"), to: url("S/a.jpg"))
        let again = await journal.redo(sort.id)
        XCTAssertGreaterThan(again.done, 0, "\(again.skipped)")
        XCTAssertTrue(exists("T/2024/a.jpg"))
    }

    /// B13-m4: an Undo that does nothing leaves the change done, so it can be undone once the way is clear.
    func testAnUndoThatDoesNothingLeavesTheChangeDone() async throws {
        file("x.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([url("x.jpg")], to: url("D")))
        file("x.jpg", "in the way")
        let report = await journal.undo(move.id)
        XCTAssertEqual(report.done, 0)
        let entry = await journal.entry(move.id)
        XCTAssertEqual(entry?.undone, false)
        XCTAssertEqual(entry?.fileCount, 1)
        try fm.removeItem(at: url("x.jpg"))
        let again = await journal.undo(move.id)
        XCTAssertEqual(again.done, 1, "\(again.skipped)")
        XCTAssertFalse(exists("D/x.jpg"))
    }
}
