import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// Redo after things changed, and what earlier versions remembered, from the eleventh audit.
final class Audit11Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit11-\(UUID().uuidString)", isDirectory: true)
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

    func replaceInPlace(_ path: String) throws {
        let temp = root.appendingPathComponent("edit-\(UUID().uuidString)")
        try Data("edited".utf8).write(to: temp)
        _ = try fm.replaceItemAt(url(path), withItemAt: temp)
    }

    /// B11-M1, C11-M1: Redo of a name swap after one file was replaced never leaves a photo hidden.
    func testRedoOfASwapNeverLeavesAPhotoHidden() async throws {
        file("2.jpg", "two")
        file("2.jpg.json", "{}")
        file("1.jpg", "one")
        file("1.jpg.json", "{}")
        let journal = journal()
        let rename = await journal.run(FolderOperations.batchRename([url("2.jpg"), url("1.jpg")], pattern: "{n}"))
        _ = await journal.undo(rename.id)
        try replaceInPlace("1.jpg")
        _ = await journal.redo(rename.id)
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".journal") }
        XCTAssertFalse(names.contains { $0.hasPrefix(".mediapull-rename-") }, "\(names)")
        XCTAssertEqual(names.filter { $0.hasSuffix(".jpg") }.count, 2, "\(names)")
    }

    /// B11-M2: New Folder and a change inside it, both undone, then both redone: the second finds the folder the first
    /// made again.
    func testRedoOfAChangeInsideAFolderMadeAgain() async {
        let x = file("x.jpg")
        let journal = journal()
        let made = await journal.run(FolderOperations.newFolder(named: "F", in: root))
        let move = await journal.run(FolderOperations.move([x], to: url("F")))
        _ = await journal.undo(move.id)
        _ = await journal.undo(made.id)
        XCTAssertFalse(exists("F"))
        _ = await journal.redo(made.id)
        let report = await journal.redo(move.id)
        XCTAssertEqual(report.done, 1, "\(report.skipped)")
        XCTAssertTrue(exists("F/x.jpg"))

        // The same with a rename of the folder made.
        let named = await journal.run(FolderOperations.rename(url("F"), to: "Trips"))
        _ = await journal.undo(named.id)
        _ = await journal.undo(move.id)
        _ = await journal.undo(made.id)
        _ = await journal.redo(made.id)
        _ = await journal.redo(move.id)
        let renamed = await journal.redo(named.id)
        XCTAssertEqual(renamed.done, 1, "\(renamed.skipped)")
        XCTAssertTrue(exists("Trips/x.jpg"))
    }

    /// B11-m3: a copied folder partly taken back (one file changed) counts what was taken back.
    func testAPartUndoOfACopiedFolderCounts() async throws {
        file("X/a.jpg")
        file("X/b.jpg")
        try fm.createDirectory(at: url("Dest"), withIntermediateDirectories: true)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([url("X")], to: url("Dest")))
        try Data("changed since it was copied".utf8).write(to: url("Dest/X/a.jpg"))
        let report = await journal.undo(copy.id)
        XCTAssertEqual(report.done, 1)
        XCTAssertTrue(exists("Dest/X/a.jpg"))
    }

    /// A11-M2: only what earlier versions remembered is taken over, by when records began, not by a folder's date.
    func testOnlyEarlierMemoryIsTakenOver() async throws {
        let store = try AppStore.make(inMemory: true)
        let folder = url("lib/alice")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        await store.recordArchive(key: "ig:old", account: "alice", path: folder.appendingPathComponent("old.jpg").path, sha256: "")
        let began = Date()
        try await Task.sleep(for: .milliseconds(20))
        await store.recordArchive(key: "ig:new", account: "alice", path: folder.appendingPathComponent("new.jpg").path, sha256: "")
        let taken = await store.takeInstagramKeys(account: "alice", under: folder.path, savedBefore: began)
        XCTAssertEqual(taken, ["ig:old"])
    }
}
