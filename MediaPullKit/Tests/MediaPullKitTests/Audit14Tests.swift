import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Redo after a relaunch, partial Undo and changes that changed nothing, from the fourteenth audit.
final class Audit14Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit14-\(UUID().uuidString)", isDirectory: true)
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
    var journalFolder: URL { root.appendingPathComponent(".journal", isDirectory: true) }

    /// B14-M1: a change inside a folder an earlier Redo copied again is redone after a relaunch too.
    func testRedoAfterARelaunchFindsWhatRedoMadeAgain() async throws {
        file("F/a.jpg")
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let first = OperationJournal(folder: journalFolder)
        let copy = await first.run(FolderOperations.copy([url("F")], to: url("T")))
        let rename = await first.run(FolderOperations.rename(url("T/F/a.jpg"), to: "b.jpg"))
        _ = await first.undo(rename.id)
        _ = await first.undo(copy.id)
        _ = await first.redo(copy.id)
        let relaunched = OperationJournal(folder: journalFolder)
        let report = await relaunched.redo(rename.id)
        XCTAssertEqual(report.done, 1, "\(report.skipped)")
        XCTAssertTrue(exists("T/F/b.jpg"))
    }

    /// B14-m1: a second Undo of the rest of a change adds to what Redo does again.
    func testASecondPartialUndoJoinsWhatRedoDoes() async throws {
        let x = file("A/x.jpg")
        let y = file("B/y.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let journal = OperationJournal(folder: journalFolder)
        let move = await journal.run(FolderOperations.move([x, y], to: url("D")))
        try fm.moveItem(at: url("A"), to: url("A away"))
        _ = await journal.undo(move.id)
        XCTAssertTrue(exists("B/y.jpg"))
        try fm.moveItem(at: url("A away"), to: url("A"))
        _ = await journal.undo(move.id)
        XCTAssertTrue(exists("A/x.jpg"))
        let report = await journal.redo(move.id)
        XCTAssertEqual(report.restored, 2, "\(report.skipped)")
        XCTAssertTrue(exists("D/x.jpg"))
        XCTAssertTrue(exists("D/y.jpg"))
    }

    /// B14-m2: a change that changed nothing is undone at once, never left with an Undo that cannot work.
    func testAChangeThatChangedNothingIsSimplyUndone() async throws {
        let gone = file("x.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let plan = FolderOperations.move([gone], to: url("D"))
        try fm.removeItem(at: gone)
        let journal = OperationJournal(folder: journalFolder)
        let entry = await journal.run(plan)
        XCTAssertTrue(entry.steps.isEmpty)
        _ = await journal.undo(entry.id)
        let undone = await journal.entry(entry.id)
        XCTAssertEqual(undone?.undone, true)
    }
}
