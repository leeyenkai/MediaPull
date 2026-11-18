import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// Redo, counts and earlier versions' memory, from the twelfth audit.
final class Audit12Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit12-\(UUID().uuidString)", isDirectory: true)
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

    /// B12-M1: a rename inside a folder that Redo copied again is redone too.
    func testRedoOfAChangeInsideAFolderCopiedAgain() async throws {
        file("X/a.jpg")
        try fm.createDirectory(at: url("Dest"), withIntermediateDirectories: true)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([url("X")], to: url("Dest")))
        let rename = await journal.run(FolderOperations.rename(url("Dest/X/a.jpg"), to: "b.jpg"))
        XCTAssertTrue(exists("Dest/X/b.jpg"))
        _ = await journal.undo(rename.id)
        _ = await journal.undo(copy.id)
        XCTAssertFalse(exists("Dest/X"))
        let copied = await journal.redo(copy.id)
        XCTAssertGreaterThan(copied.done, 0, "\(copied.skipped)")
        let renamed = await journal.redo(rename.id)
        XCTAssertEqual(renamed.done, 1, "\(renamed.skipped)")
        XCTAssertTrue(exists("Dest/X/b.jpg"))
    }

    /// B12-m1: Redo never makes a change's folders inside another folder that took the old name.
    func testRedoNeverBuildsInsideAnotherFolderOfTheName() async throws {
        let photo = file("S/a.jpg")
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let journal = journal()
        let sort = await journal.run(FolderOperations.sort([photo], into: url("T"), title: "Sort") { _ in [["2024"]] })
        XCTAssertTrue(exists("T/2024/a.jpg"))
        _ = await journal.undo(sort.id)
        XCTAssertTrue(exists("S/a.jpg"))
        try fm.moveItem(at: url("T"), to: url("T aside"))
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let report = await journal.redo(sort.id)
        XCTAssertEqual(report.done, 0, "\(report.skipped)")
        XCTAssertFalse(exists("T/2024"))
        XCTAssertTrue(exists("S/a.jpg"))
    }

    /// B12-m2: a name swap goes through temporary names but counts each file once, before and after Undo.
    func testASwapCountsEachFileOnce() async {
        file("1.jpg", "one")
        file("2.jpg", "two")
        let journal = journal()
        let rename = await journal.run(FolderOperations.batchRename([url("2.jpg"), url("1.jpg")], pattern: "{n}"))
        XCTAssertEqual(rename.fileCount, 2)
        let report = await journal.undo(rename.id)
        XCTAssertEqual(report.restored, 2, "\(report.skipped)")
        let undone = await journal.entry(rename.id)
        XCTAssertEqual(undone?.fileCount, 2)
    }

    /// B12-m3, B12-m4: a Redo that finds its file moved names it plainly, does nothing and keeps the change undone, so it
    /// can be redone once the file is back.
    func testARedoThatDoesNothingStaysUndone() async throws {
        file("x.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([url("x.jpg")], to: url("D")))
        _ = await journal.undo(move.id)
        try fm.moveItem(at: url("x.jpg"), to: url("y.jpg"))
        let report = await journal.redo(move.id)
        XCTAssertEqual(report.done, 0)
        XCTAssertEqual(report.skipped, ["x.jpg is no longer where it was, so it was left"])
        let entry = await journal.entry(move.id)
        XCTAssertEqual(entry?.undone, true)
        XCTAssertFalse(entry?.undoneSteps?.isEmpty ?? true)

        try fm.moveItem(at: url("y.jpg"), to: url("x.jpg"))
        let again = await journal.redo(move.id)
        XCTAssertEqual(again.done, 1, "\(again.skipped)")
        XCTAssertTrue(exists("D/x.jpg"))
    }

    /// B12-m5: a file in the Trash is restorable only while the item there is the one the change trashed.
    func testRestorableOnlyWhileTheTrashedItemIsThere() async throws {
        let journal = journal()
        var entry = JournalEntry(id: UUID(), title: "Trash", root: root.path, date: Date(), steps: [], failures: [], undone: false,
                                 finished: true)
        let trashed = file("Trash/x.jpg", "first")
        entry.steps = [.trash(original: url("x.jpg").path, trashed: trashed.path)]
        await journal.noteForTest(trashed.path, in: &entry)
        await journal.saveForTest(entry)
        var restorable = await journal.restorablePaths()
        XCTAssertEqual(restorable, [url("x.jpg").path])

        // Emptied from the Trash, and another x.jpg trashed later to the same place.
        try fm.removeItem(at: trashed)
        file("Trash/x.jpg", "second")
        restorable = await journal.restorablePaths()
        XCTAssertTrue(restorable.isEmpty)
    }

    /// C12-M2, A13-M3: a 1.7 folder renamed in the Finder before its first Update takes over what was remembered at its
    /// old path, through its record; what was remembered of another folder of the account that is gone is never taken.
    func testEarlierMemoryOfAFolderRenamedInTheFinder() async throws {
        let store = try AppStore.make(inMemory: true)
        let old = url("lib/alice")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        await store.recordArchive(key: "ig:gone", account: "alice", path: old.appendingPathComponent("gone.jpg").path, sha256: "")
        await store.recordArchive(key: "ig:copy", account: "alice", path: url("lib/alice 2/copy.jpg").path, sha256: "")
        let began = Date().addingTimeInterval(1)
        let records = AccountFolderStore(folder: url("records"))
        _ = await records.record(account: "alice", folder: old)
        try fm.moveItem(at: old, to: url("lib/Alice S"))
        let all = await records.all()
        let record = try XCTUnwrap(all.first { $0.account == "alice" })
        XCTAssertEqual(AccountFolderStore.key(record.path), AccountFolderStore.key(url("lib/Alice S").path))
        let taken = await store.takeInstagramKeys(account: "alice", under: record.allPaths, savedBefore: began)
        XCTAssertEqual(taken, ["ig:gone"])
    }

    /// C12-m4: earlier versions' memory waits to be taken over; memory saved since records began goes with its file.
    func testPruneKeepsOnlyEarlierMemoryWaiting() async throws {
        let store = try AppStore.make(inMemory: true)
        let folder = url("lib/bob")
        await store.recordArchive(key: "ig:old", account: "bob", path: folder.appendingPathComponent("old.jpg").path, sha256: "")
        let began = Date()
        try await Task.sleep(for: .milliseconds(20))
        await store.recordArchive(key: "ig:new", account: "bob", path: folder.appendingPathComponent("new.jpg").path, sha256: "")
        await store.prune(keepAccounts: ["bob"], earlierMemoryBefore: began)
        let left = await store.takeInstagramKeys(account: "bob", under: folder.path)
        XCTAssertEqual(left, ["ig:old"])
    }
}

extension OperationJournal {
    func noteForTest(_ path: String, in entry: inout JournalEntry) { note(path, in: &entry) }
    func saveForTest(_ entry: JournalEntry) { save(entry) }
}
