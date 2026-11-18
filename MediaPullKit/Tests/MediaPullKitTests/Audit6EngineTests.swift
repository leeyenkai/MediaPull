import Foundation
@testable import MediaPullCore
@testable import MediaPullEngines
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// The journal, account folders and the account id, from the sixth audit.
final class Audit6EngineTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit6-\(UUID().uuidString)", isDirectory: true)
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

    func folder(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func journal() -> OperationJournal {
        OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
    }

    /// Audit 6 (B6-M1): Undo never makes a folder again. A folder renamed by a later change is followed by the earlier
    /// change's undo record; one renamed elsewhere (the Finder) leaves the item where it is, to be tried again.
    func testUndoFollowsRenamedFoldersAndNeverRemakesThem() async throws {
        let photo = file("Trip/x.jpg")
        file("Trip/keep.jpg")
        let journal = journal()
        let trashed = await journal.run(FolderOperations.trash([photo]))
        XCTAssertTrue(trashed.failures.isEmpty)
        let trip = root.appendingPathComponent("Trip", isDirectory: true)
        let renamed = await journal.run(FolderOperations.rename(trip, to: "Trip 2024"))
        await journal.followFolderMoves(renamed.moves, except: renamed.id)
        let report = await journal.undo(trashed.id)
        XCTAssertEqual(report.restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Trip 2024/x.jpg").path), "back where its folder is now")
        XCTAssertFalse(fm.fileExists(atPath: trip.path), "the old folder is not made again")

        // Renamed outside MediaPull: nothing is made, the file stays in the Trash and Undo can be tried again.
        let second = await journal.run(FolderOperations.trash([root.appendingPathComponent("Trip 2024/keep.jpg")]))
        try fm.moveItem(at: root.appendingPathComponent("Trip 2024"), to: root.appendingPathComponent("Elsewhere"))
        let left = await journal.undo(second.id)
        XCTAssertEqual(left.restored, 0)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Trip 2024").path))
        let entry = await journal.entry(second.id)
        XCTAssertEqual(entry?.undone, false, "kept so Undo can be tried again")
    }

    /// Audit 6 (B6-M1): Redo stops when the folder the change worked in is gone.
    func testRedoNeverRemakesAFolderThatWentAway() async throws {
        let album = folder("Album")
        let journal = journal()
        let made = await journal.run(FolderOperations.newFolder(named: "2024", in: album))
        _ = await journal.undo(made.id)
        try fm.moveItem(at: album, to: root.appendingPathComponent("Album renamed"))
        let report = await journal.redo(made.id)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: album.path))
    }

    /// Audit 6 (B6-m1): a plan into a folder nobody has made yet makes that folder only, never the folders above it.
    func testAPlanNeverMakesTheFoldersAboveItsRoot() async {
        let photo = file("in/a.jpg")
        let gone = root.appendingPathComponent("Refs/2024", isDirectory: true)
        let entry = await journal().run(FolderOperations.move([photo], to: gone))
        XCTAssertTrue(entry.steps.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Refs").path))
        let fresh = await journal().run(FolderOperations.move([photo], to: root.appendingPathComponent("out", isDirectory: true)))
        XCTAssertFalse(fresh.steps.isEmpty, "a new folder in a folder that is there is fine")
    }

    /// Audit 6 (C6-m2, C6-M2): a new folder at the path of a trashed one gets a record of its own; a folder the store
    /// followed after a Finder rename is still found by a job that was given its old path.
    func testRecordsOfTrashedAndRenamedFolders() async throws {
        let store = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let alice = folder("lib/alice")
        let old = await store.record(account: "alice", folder: alice)
        await store.update(old.id, userID: "111")
        var trashed: NSURL?
        try fm.trashItem(at: alice, resultingItemURL: &trashed)
        defer { if let trashed = trashed as URL? { try? fm.removeItem(at: trashed) } }
        let again = folder("lib/alice")
        let fresh = await store.record(account: "alice", folder: again)
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertNil(fresh.userID)

        let renamed = root.appendingPathComponent("lib/Alice (friend)", isDirectory: true)
        try fm.moveItem(at: again, to: renamed)
        _ = await store.all() // the store follows the rename through the bookmark
        let found = await store.currentFolder(for: again)
        XCTAssertEqual(found?.standardizedFileURL.path, renamed.standardizedFileURL.path)
    }

    /// Audit 6 (A6-M1, C6-M1): the id a name was first seen with is never replaced by a later scan or pull.
    func testTheStoredAccountIDIsNeverReplaced() async throws {
        let store = try AppStore.make(inMemory: true)
        await store.updateAccount("alice", userID: "111")
        await store.updateAccount("alice", userID: "222")
        let account = await store.account("alice")
        XCTAssertEqual(account?.userID, "111")
    }

    /// Audit 6 (A6-M2): an item's owner id is read from its metadata, as text only (the bridge's form).
    func testTheOwnerIDIsReadFromMetadata() {
        let text = EngineContext.from(meta: ["category": .string("instagram"), "owner_id": .string("42")], key: "ig:1",
                                      subcategory: "posts", sourceURL: nil)
        XCTAssertEqual(text.ownerID, "42")
    }

    /// Audit 6 (A6-m5): an account named like the Hashtags folder never takes it as its folder.
    func testHashtagsIsNeverAnAccountsFolder() {
        let lib = folder("lib")
        folder("lib/Hashtags/cats")
        XCTAssertNil(AccountFolders.resolveTarget(account: "hashtags", saveFolder: lib, root: lib).existing)
    }

    /// Audit 6 (B6-m7): faces of photos in the Trash that Undo can bring back are kept but not counted.
    func testHeldPhotosAreNotCountedInPeople() async throws {
        let store = try AnalysisStore.make(folder: nil)
        for sha in ["here", "trashed"] {
            await store.addFaces([NewFace(key: "f", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: sha)
            await store.setPath("/lib/\(sha).jpg", sha256: sha, size: 1, modified: Date())
        }
        let alice = UUID()
        await store.applyAssignments(["here|f": alice, "trashed|f": alice])
        await store.setHeld(["/lib/trashed.jpg"])
        let held = await store.people().first { $0.id == alice }?.faceCount
        XCTAssertEqual(held, 1)
        let examples = await store.faceExamples(of: alice)
        XCTAssertEqual(examples.map(\.path), ["/lib/here.jpg"])
        await store.setHeld([])
        let back = await store.people().first { $0.id == alice }?.faceCount
        XCTAssertEqual(back, 2)
    }
}
