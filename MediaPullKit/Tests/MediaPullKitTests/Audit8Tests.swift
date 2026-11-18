import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Undo and Redo find things by what they are, not by path, from the eighth audit (B8-M1, B8-M2, B8-m1).
final class Audit8Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit8-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(path.utf8).write(to: url)
        return url
    }

    func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }
    func exists(_ path: String) -> Bool { fm.fileExists(atPath: url(path).path) }

    func journal() -> OperationJournal {
        OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
    }

    /// Flatten trashes a subfolder; a new folder takes its name and is renamed; undoing Flatten puts the file back into
    /// its own subfolder, not into the new one, in any order.
    func testUndoFlattenAfterItsSubfolderNameIsReused() async {
        for order in ["history", "strict"] {
            try? fm.removeItem(at: url("F"))
            file("F/sub/x.jpg")
            let journal = journal()
            let flatten = await journal.run(FolderOperations.flatten(url("F")))
            XCTAssertTrue(exists("F/x.jpg"), order)
            let made = await journal.run(FolderOperations.newFolder(named: "sub", in: url("F")))
            let renamed = await journal.run(FolderOperations.rename(url("F/sub"), to: "other"))
            if order == "strict" {
                _ = await journal.undo(renamed.id)
                _ = await journal.undo(made.id)
            }
            let report = await journal.undo(flatten.id)
            XCTAssertTrue(report.skipped.isEmpty, "\(order): \(report.skipped)")
            XCTAssertTrue(exists("F/sub/x.jpg"), order)
            XCTAssertFalse(exists("F/other/x.jpg"), order)
        }
    }

    /// Redo after the change's folder was replaced by another of the same name, or renamed while it held another file.
    func testRedoFindsItsOwnFolders() async throws {
        let journal = journal()
        // Replaced: Redo makes its own folder again and leaves the other one alone.
        let x = file("in/x.jpg")
        try fm.createDirectory(at: url("Out"), withIntermediateDirectories: true)
        let sort = await journal.run(FolderOperations.sort([x], into: url("Out"), title: "Sort") { _ in [["Cats"]] })
        _ = await journal.undo(sort.id)
        XCTAssertFalse(exists("Out/Cats"))
        _ = await journal.run(FolderOperations.newFolder(named: "Cats", in: url("Out")))
        _ = await journal.run(FolderOperations.rename(url("Out/Cats"), to: "Dogs"))
        _ = await journal.redo(sort.id)
        XCTAssertTrue(exists("Out/Cats/x.jpg"))
        XCTAssertFalse(exists("Out/Dogs/x.jpg"))

        // Kept and renamed: Redo leaves the file and makes nothing at the old path (D-93).
        let y = file("in/y.jpg")
        file("Year/2024/keep.jpg")
        let second = await journal.run(FolderOperations.sort([y], into: url("Year"), title: "Sort") { _ in [["2024"]] })
        _ = await journal.undo(second.id)
        try fm.moveItem(at: url("Year/2024"), to: url("Year/Year 2024"))
        let redone = await journal.redo(second.id)
        XCTAssertEqual(redone.done, 0)
        XCTAssertTrue(exists("in/y.jpg"))
        XCTAssertFalse(exists("Year/2024"))
    }

    /// A previewed sort never makes a folder above its planned ones again (B8-M2): renamed after the preview, it fails.
    func testASortNeverRemakesTheParentOfAPlannedFolder() async throws {
        let photo = file("Source/a.jpg")
        file("R/2024/old.jpg")
        let plan = FolderOperations.sort([photo], into: url("R"), title: "Sort") { _ in [["2024", "2024-05"]] }
        XCTAssertEqual(plan.foldersToCreate.map(\.lastPathComponent), ["2024-05"])
        try fm.moveItem(at: url("R/2024"), to: url("R/Year 2024"))
        let entry = await journal().run(plan)
        XCTAssertFalse(exists("R/2024"))
        XCTAssertTrue(exists("Source/a.jpg"))
        XCTAssertFalse(entry.failures.isEmpty)
    }

    /// D-93: a trash undone after its folder was renamed in the Finder leaves the file in the Trash and says so; a new
    /// folder given the old name is not taken for it (audit 9, B9-M5: the check is by disk identity, which reconnecting a
    /// disk does not change).
    func testUndoLeavesWhatMovedAndNeverTakesAnotherFolder() async throws {
        let photo = file("Trip/x.jpg")
        let journal = journal()
        let trashed = await journal.run(FolderOperations.trash([photo]))
        try fm.moveItem(at: url("Trip"), to: url("Trip 2024"))
        let report = await journal.undo(trashed.id)
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(report.skipped.count, 1)
        try fm.createDirectory(at: url("Trip"), withIntermediateDirectories: false)
        let second = await journal.undo(trashed.id)
        XCTAssertEqual(second.restored, 0, "another folder named Trip is not the one it came from")
        XCTAssertFalse(exists("Trip/x.jpg"))
    }

    /// B9-M2: an item trashed later under the same name is never put back in place of the one the change trashed.
    func testUndoNeverTakesAnotherItemFromTheTrash() async throws {
        let journal = journal()
        let first = await journal.run(FolderOperations.trash([file("A/x.jpg")]))
        let entry = await journal.entry(first.id)
        guard case let .trash(_, inTrash)? = entry?.steps.first else { return XCTFail("no trash step") }
        try fm.removeItem(atPath: inTrash)
        // Whatever ends up at that Trash path later is another file.
        try Data("other".utf8).write(to: URL(fileURLWithPath: inTrash))
        defer { try? fm.removeItem(atPath: inTrash) }
        let report = await journal.undo(first.id)
        XCTAssertEqual(report.restored, 0)
        XCTAssertFalse(exists("A/x.jpg"))
    }

    /// B9-M3, B9-M4: a copy whose folder was renamed is not counted as undone; Redo never trashes a folder it emptied once
    /// that now holds files.
    func testCopiesAndEmptiedFoldersAreChecked() async throws {
        let journal = journal()
        let photo = file("in/a.jpg")
        try fm.createDirectory(at: url("People"), withIntermediateDirectories: true)
        let sort = await journal.run(FolderOperations.sort([photo], into: url("People"), title: "Sort") { _ in [["Alice"], ["Bob"]] })
        XCTAssertTrue(exists("People/Bob/a.jpg"))
        try fm.moveItem(at: url("People/Bob"), to: url("People/Robert"))
        let report = await journal.undo(sort.id)
        XCTAssertFalse(report.skipped.isEmpty, "the copy in Robert is reported, not counted as undone")
        let after = await journal.entry(sort.id)
        XCTAssertNotEqual(after?.undone, true)

        file("F/sub/x.jpg")
        let flatten = await journal.run(FolderOperations.flatten(url("F")))
        _ = await journal.undo(flatten.id)
        file("F/sub/new.jpg")
        _ = await journal.redo(flatten.id)
        XCTAssertTrue(exists("F/sub/new.jpg"), "a folder holding files now is kept")
    }

    /// A8-m3, C8-m3: a record whose folder went to the Trash is not listed for, nor followed into, a new folder made at its
    /// path, whatever build wrote its number.
    func testARecordIsNeverTakenOverByANewFolderAtItsPath() async throws {
        for format in ["current", "round 6"] {
            let records = url("records-\(format)")
            let alice = url("lib-\(format)/alice")
            try fm.createDirectory(at: alice, withIntermediateDirectories: true)
            let store = AccountFolderStore(folder: records)
            let record = await store.record(account: "alice", folder: alice)
            if format == "round 6" {
                // The device-number form an earlier build wrote.
                let file = records.appendingPathComponent("\(record.id.uuidString).json")
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                let number = try XCTUnwrap(json["folderNumber"] as? String)
                json["folderNumber"] = "16777220:" + (number.split(separator: ":").last.map(String.init) ?? "")
                try JSONSerialization.data(withJSONObject: json).write(to: file)
            }
            let reloaded = AccountFolderStore(folder: records)
            var trashed: NSURL?
            try fm.trashItem(at: alice, resultingItemURL: &trashed)
            defer { if let trashed = trashed as URL? { try? fm.removeItem(at: trashed) } }
            try fm.createDirectory(at: alice, withIntermediateDirectories: true)
            let listed = await reloaded.all()
            XCTAssertTrue(listed.isEmpty, "\(format): the new folder is not listed as alice's")
            // A path-based look-up finds the folder at the path; the trashed folder's record does not claim it (A9-M1).
            let followed = await reloaded.currentFolder(for: alice)
            XCTAssertEqual(followed?.standardizedFileURL.path, alice.standardizedFileURL.path, format)
            let byID = await reloaded.currentFolder(of: record.id)
            XCTAssertNil(byID, format)
        }
    }
}
