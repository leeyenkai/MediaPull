import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// Account folders, saving and the journal, from the fifth audit.
final class Audit5EngineTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
        return url
    }

    func folder(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func journal() -> OperationJournal {
        OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
    }

    /// Audit 5 (B5-M1, B5-M2, B5-m7): every plan works inside its root. A root renamed or moved since the plan was made
    /// (in the Finder, in another pane) stops it: nothing is moved and the root is not made again at its old path.
    func testPlansWhoseRootWentAwayChangeNothing() async throws {
        let source = file("Source/a.jpg")
        let target = folder("Sorted")
        let plans: [(String, OrganisePlan)] = [
            ("move to the target", FolderOperations.move([source], to: target)),
            ("copy to the target", FolderOperations.copy([source], to: target)),
            ("new folder in the target", FolderOperations.newFolder(named: "Trip", in: target)),
            ("sort into the target", FolderOperations.sort([source], into: target, title: "Sort") { _ in [["2024"]] }),
        ]
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("Sorted 2024"))
        for (name, plan) in plans {
            let entry = await journal().run(plan)
            XCTAssertTrue(entry.steps.isEmpty, name)
            XCTAssertEqual(entry.failures, ["“Sorted” is no longer there, so nothing was changed."], name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "\(name): not made again")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "\(name): nothing moved")
        }
        // A plan whose root is still there runs as before.
        let entry = await journal().run(FolderOperations.newFolder(named: "Trip", in: root.appendingPathComponent("Sorted 2024")))
        XCTAssertEqual(entry.steps.count, 1)
    }

    /// Audit 5 (B5-m1, B5-M3): what Undo can still put back includes the files inside a trashed folder.
    func testFilesInsideARestorableFolderAreRestorable() async throws {
        let trip = folder("Trip")
        let photo = file("Trip/a.jpg")
        let store = try AppStore.make(inMemory: true)
        await store.recordArchive(key: "web:1", account: "web", path: photo.path, sha256: "")
        let journal = journal()
        let entry = await journal.run(FolderOperations.trash([trip]))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        let restorable = await journal.restorablePaths()
        XCTAssertTrue(restorable.containsPathOrParent(of: photo.path), "\(restorable) \(photo.path)")
        XCTAssertFalse(restorable.containsPathOrParent(of: root.appendingPathComponent("Trip 2/a.jpg").path), "a prefix is not a parent")
        await store.prune(keepAccounts: [], restorable: restorable)
        _ = await journal.undo(entry.id)
        let found = await store.archivedPaths(for: ["web:1"])
        XCTAssertEqual(found["web:1"], photo.path, "the entry of a file inside a folder Undo brought back survived the prune")
    }

    /// Audit 5 (C5-M4): a folder MediaPull renamed is found by a job that was given its old path; one in the Trash is not.
    func testAJobFindsAFolderMediaPullRenamed() async throws {
        let store = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let alice = folder("lib/alice")
        _ = await store.record(account: "alice", folder: alice)
        let renamed = root.appendingPathComponent("lib/Alice (friend)", isDirectory: true)
        try FileManager.default.moveItem(at: alice, to: renamed)
        await store.moveFolders([(from: alice.path, to: renamed.path)])
        let found = await store.currentFolder(for: alice)
        XCTAssertEqual(found?.standardizedFileURL.path, renamed.standardizedFileURL.path)
        var trashed: NSURL?
        try FileManager.default.trashItem(at: renamed, resultingItemURL: &trashed)
        defer { if let trashed = trashed as URL? { try? FileManager.default.removeItem(at: trashed) } }
        let gone = await store.currentFolder(for: alice)
        XCTAssertNil(gone, "a folder in the Trash is gone for a pull")
    }

    /// Audit 5 (A5-m3): merging two records of one folder keeps the account id either had.
    func testMergedRecordsKeepTheAccountID() async throws {
        let records = root.appendingPathComponent("records", isDirectory: true)
        let alice = folder("lib/alice")
        let store = AccountFolderStore(folder: records)
        let record = await store.record(account: "alice", folder: alice)
        await store.update(record.id, lastUpdate: Date(timeIntervalSinceReferenceDate: 1000), userID: "42")
        let file = records.appendingPathComponent("\(record.id.uuidString).json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["id"] = UUID().uuidString
        json["userID"] = nil
        json["lastUpdate"] = 2000.0
        try JSONSerialization.data(withJSONObject: json)
            .write(to: records.appendingPathComponent("\(json["id"] as? String ?? "x").json"))
        let reloaded = AccountFolderStore(folder: records)
        let all = await reloaded.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.userID, "42")
    }

    /// Audit 5 (B5-m2, A5-m5): an item saved earlier is skipped only where the save itself would find it: anywhere in an
    /// account's folder, but only in the folder itself for a plain folder.
    func testItemsSavedEarlierAreSkippedOnlyWhereTheSaveLooks() {
        var context = EngineContext(key: "ig:1", category: "instagram", subcategory: "reels")
        context.username = "alice"
        let url = URL(string: "https://cdn.example.com/a.mp4")!
        let item = MediaItem(id: "ig:1", kind: .video,
                             variants: [MediaVariant(id: url.absoluteString, url: url, format: .mp4, origin: .img)],
                             source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        let alice = root.appendingPathComponent("lib/alice", isDirectory: true)
        var account = SaveTarget(folder: alice.deletingLastPathComponent(), layout: .archive, autoSubfolders: true,
                                 accountUsername: "alice")
        account.accountFolder = alice
        account.typeSubfolders = true
        let settings = SaveSettings()
        XCTAssertTrue(SavePipeline.wouldFind(alice.appendingPathComponent("reels/a.mp4"), item: item, target: account, settings: settings))
        XCTAssertTrue(SavePipeline.wouldFind(alice.appendingPathComponent("posts/a.mp4"), item: item, target: account, settings: settings))
        let bob = root.appendingPathComponent("lib/bob/a.mp4")
        XCTAssertFalse(SavePipeline.wouldFind(bob, item: item, target: account, settings: settings))
        let trip = root.appendingPathComponent("Trip", isDirectory: true)
        let plain = SaveTarget(folder: trip, layout: .plain, autoSubfolders: false)
        XCTAssertTrue(SavePipeline.wouldFind(trip.appendingPathComponent("a.mp4"), item: item, target: plain, settings: settings))
        XCTAssertFalse(SavePipeline.wouldFind(trip.appendingPathComponent("Day 1/a.mp4"), item: item, target: plain, settings: settings),
                       "a copy in a subfolder is not one the save would find")
    }

    /// Audit 5 (C5-m4): a collection pull from inside Hashtags or Saved posts goes beside that folder.
    func testCollectionFoldersAreFoundFromInside() {
        let lib = folder("lib")
        let cats = folder("lib/Hashtags/cats")
        XCTAssertEqual(AccountFolders.collectionFolder(containing: cats, root: lib)?.lastPathComponent, "Hashtags")
        XCTAssertEqual(AccountFolders.collectionFolder(containing: folder("lib/Saved posts"), root: lib)?.lastPathComponent,
                       "Saved posts")
        XCTAssertNil(AccountFolders.collectionFolder(containing: folder("lib/alice"), root: lib))
    }
}
