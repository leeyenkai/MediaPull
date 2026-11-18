import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Undo and Redo after things changed, from the tenth audit.
final class Audit10Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit10-\(UUID().uuidString)", isDirectory: true)
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

    /// Replaced in place, as the editor's save does: a new file at the same name.
    func replaceInPlace(_ path: String) throws {
        let target = url(path)
        let temp = root.appendingPathComponent("edit-\(UUID().uuidString)")
        try Data("edited".utf8).write(to: temp)
        _ = try fm.replaceItemAt(target, withItemAt: temp)
    }

    /// B10-M1: undoing a rename that swapped names, after one file was edited, never leaves a photo hidden under a
    /// temporary name: it comes back under a free name beside its own, with its metadata file.
    func testUndoOfASwapNeverLeavesAPhotoHidden() async throws {
        file("2.jpg", "two")
        file("2.jpg.json", "{}")
        file("1.jpg", "one")
        file("1.jpg.json", "{}")
        let journal = journal()
        let rename = await journal.run(FolderOperations.batchRename([url("2.jpg"), url("1.jpg")], pattern: "{n}"))
        XCTAssertTrue(rename.failures.isEmpty, "\(rename.failures)")
        try replaceInPlace("1.jpg")
        _ = await journal.undo(rename.id)
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".journal") }
        XCTAssertFalse(names.contains { $0.hasPrefix(".mediapull-rename-") }, "\(names)")
        XCTAssertEqual(names.filter { $0.hasSuffix(".jpg") }.count, 2, "\(names)")
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 2, "\(names)")
    }

    /// B10-m1, B10-m6: a made folder renamed before Undo is not made again by Redo; Redo of a folder already there counts
    /// as nothing done.
    func testRedoMakesOnlyFoldersItStillOwns() async throws {
        let y = file("in/y.jpg")
        try fm.createDirectory(at: url("Year"), withIntermediateDirectories: true)
        let journal = journal()
        let sort = await journal.run(FolderOperations.sort([y], into: url("Year"), title: "Sort") { _ in [["2024"]] })
        try fm.moveItem(at: url("Year/2024"), to: url("Year/Year 2024"))
        _ = await journal.undo(sort.id)
        _ = await journal.redo(sort.id)
        XCTAssertFalse(exists("Year/2024"), "no empty folder at the old path")

        let made = await journal.run(FolderOperations.newFolder(named: "A", in: root))
        _ = await journal.undo(made.id)
        try fm.createDirectory(at: url("A"), withIntermediateDirectories: false)
        let report = await journal.redo(made.id)
        XCTAssertEqual(report.done, 0)
    }

    /// B10-m5: Redo never copies into another folder that took the copy's folder name since Undo.
    func testRedoOfACopyChecksItsFolder() async throws {
        let x = file("in/x.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([x], to: url("D")))
        _ = await journal.undo(copy.id)
        try fm.moveItem(at: url("D"), to: url("D old"))
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let report = await journal.redo(copy.id)
        XCTAssertEqual(report.done, 0)
        XCTAssertFalse(exists("D/x.jpg"))
    }
}
