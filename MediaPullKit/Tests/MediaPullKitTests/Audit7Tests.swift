import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// The journal, account folder identity and edited copies, from the seventh audit.
final class Audit7Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit7-\(UUID().uuidString)", isDirectory: true)
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

    func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    /// The journal as the app drives it: every run, undo and redo is followed by the folder moves it made.
    actor Driver {
        let journal: OperationJournal
        init(_ folder: URL) { journal = OperationJournal(folder: folder) }

        func run(_ plan: OrganisePlan) async -> JournalEntry {
            let entry = await journal.run(plan)
            await journal.followFolderMoves(entry.moves, except: entry.id)
            return entry
        }

        @discardableResult
        func undo(_ id: UUID) async -> UndoReport {
            let report = await journal.undo(id)
            await journal.followFolderMoves(report.moves, except: id)
            return report
        }

        @discardableResult
        func redo(_ id: UUID) async -> UndoReport {
            let report = await journal.redo(id)
            await journal.followFolderMoves(report.moves, except: id)
            return report
        }
    }

    func driver() -> Driver {
        Driver(root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
    }

    /// Audit 7 (B7-M1): a folder renamed aside and its name given to another; undoing both puts each back.
    func testUndoingARenameAsideAndTakingItsName() async {
        file("Photos/a.jpg")
        file("New/b.jpg")
        let journal = driver()
        let first = await journal.run(FolderOperations.rename(root.appendingPathComponent("Photos"), to: "Photos old"))
        let second = await journal.run(FolderOperations.rename(root.appendingPathComponent("New"), to: "Photos"))
        await journal.undo(second.id)
        let report = await journal.undo(first.id)
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertTrue(exists("Photos/a.jpg"))
        XCTAssertTrue(exists("New/b.jpg"))
        XCTAssertFalse(exists("Photos old"))
    }

    /// Audit 7 (B7-M1): a folder renamed, a new folder given its name, then all undone: the person's folder keeps its name.
    func testUndoingANewFolderThatTookAnOldName() async {
        file("Holiday/a.jpg")
        let journal = driver()
        let renamed = await journal.run(FolderOperations.rename(root.appendingPathComponent("Holiday"), to: "Holiday 2023"))
        let made = await journal.run(FolderOperations.newFolder(named: "New Folder", in: root))
        let named = await journal.run(FolderOperations.rename(root.appendingPathComponent("New Folder"), to: "Holiday"))
        for id in [named.id, made.id, renamed.id] {
            await journal.undo(id)
        }
        XCTAssertTrue(exists("Holiday/a.jpg"))
        XCTAssertFalse(exists("New Folder"))
        XCTAssertFalse(exists("Holiday 2023"))
    }

    /// Audit 7 (B7-M1): two folders swap names through a temporary one, and all three steps are undone.
    func testUndoingASwapThroughATemporaryName() async {
        file("Dogs/d.jpg")
        file("Cats/c.jpg")
        let journal = driver()
        let one = await journal.run(FolderOperations.rename(root.appendingPathComponent("Dogs"), to: "tmp"))
        let two = await journal.run(FolderOperations.rename(root.appendingPathComponent("Cats"), to: "Dogs"))
        let three = await journal.run(FolderOperations.rename(root.appendingPathComponent("tmp"), to: "Cats"))
        XCTAssertTrue(exists("Cats/d.jpg"))
        for id in [three.id, two.id, one.id] {
            await journal.undo(id)
        }
        XCTAssertTrue(exists("Dogs/d.jpg"))
        XCTAssertTrue(exists("Cats/c.jpg"))
        XCTAssertFalse(exists("tmp"))
    }

    /// Audit 7 (B7-m1): a change that made its own folder is done again by Redo.
    func testRedoOfAChangeThatMadeItsFolder() async {
        let photo = file("in/a.jpg")
        let journal = driver()
        var plan = FolderOperations.copy([photo], to: root.appendingPathComponent("Out", isDirectory: true))
        plan.createsRoot = true
        let entry = await journal.run(plan)
        await journal.undo(entry.id)
        XCTAssertFalse(exists("Out"))
        let report = await journal.redo(entry.id)
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertTrue(exists("Out/a.jpg"))
    }

    /// Audit 7 (B7-M2): a destination folder renamed after the preview is not made again; its items fail.
    func testAPreviewNeverRemakesADestinationThatWentAway() async throws {
        let photo = file("Source/a.jpg")
        folder("R/2024")
        let plan = FolderOperations.sort([photo], into: root.appendingPathComponent("R"), title: "Sort") { _ in [["2024"]] }
        XCTAssertTrue(plan.foldersToCreate.isEmpty, "the folder was there when previewed")
        try fm.moveItem(at: root.appendingPathComponent("R/2024"), to: root.appendingPathComponent("R/Year 2024"))
        let entry = await driver().run(plan)
        XCTAssertFalse(exists("R/2024"))
        XCTAssertTrue(exists("Source/a.jpg"))
        XCTAssertEqual(entry.failures.count, 1)
    }

    /// Audit 7 (B7-m7): an undone change still says how many files it moved.
    func testAnUndoneChangeKeepsItsFileCount() async {
        let journal = driver()
        let entry = await journal.run(FolderOperations.move([file("a.jpg"), file("b.jpg")], to: folder("Dest")))
        XCTAssertEqual(entry.fileCount, 2)
        await journal.undo(entry.id)
        let undone = await journal.journal.entry(entry.id)
        XCTAssertEqual(undone?.fileCount, 2)
    }

    /// Audit 7 (A7-M1): a folder's identity is its volume's UUID and its file number, which reconnecting a disk does not
    /// change; another folder on the same volume at the same path is another folder; one on another volume (copied or
    /// restored) keeps its memory.
    func testFolderIdentitySurvivesReconnectingADisk() async throws {
        let alice = folder("lib/alice")
        let number = try XCTUnwrap(AccountFolderRecord.number(of: alice))
        let volume = try XCTUnwrap(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        XCTAssertTrue(number.hasPrefix(volume + ":"), number)
        let records = root.appendingPathComponent("records", isDirectory: true)
        let store = AccountFolderStore(folder: records)
        let record = await store.record(account: "alice", folder: alice)
        await store.addKeys(["ig:1"], to: record.id)
        func rewrite(_ number: String) throws {
            let file = records.appendingPathComponent("\(record.id.uuidString).json")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            json["folderNumber"] = number
            try JSONSerialization.data(withJSONObject: json).write(to: file)
        }
        // Copied or restored onto another volume: same record.
        try rewrite("OTHER-VOLUME:12345")
        let copied = await AccountFolderStore(folder: records).record(account: "alice", folder: alice)
        XCTAssertEqual(copied.id, record.id)
        XCTAssertEqual(copied.keys, ["ig:1"])
        // Another folder on the same volume at the path: a record of its own.
        try rewrite("\(volume):1")
        let other = await AccountFolderStore(folder: records).record(account: "alice", folder: alice)
        XCTAssertNotEqual(other.id, record.id)
    }

    /// Audit 7 (C7-M2): an edited copy has an id, key and metadata of its own, never the original's.
    func testAnEditedCopyIsAnItemOfItsOwn() {
        var context = EngineContext(key: "ig:1", category: "instagram", subcategory: "posts")
        context.username = "alice"
        context.mediaID = "1"
        context.shortcode = "abc"
        context.postID = "10"
        let url = URL(string: "https://cdn.example.com/a.jpg")!
        let original = MediaItem(id: "ig:1", kind: .image, variants: [MediaVariant(id: url.absoluteString, url: url, format: .jpeg,
                                                                                    origin: .img)],
                                 source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        let edited = URL(fileURLWithPath: "/tmp/edited.jpg")
        let copy = original.madeCopy(MediaVariant(id: edited.absoluteString, url: edited, format: .jpeg, origin: .img))
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertNotEqual(copy.source.engine?.key, "ig:1")
        XCTAssertNil(copy.source.engine?.mediaID)
        XCTAssertNil(copy.source.engine?.shortcode)
        XCTAssertEqual(copy.source.engine?.username, "alice", "it still goes to the account's folder")
        XCTAssertEqual(copy.best?.url, edited)
    }

    /// Audit 7 (B7-m5): People knows how many of a person's photos are in the Trash, waiting for Undo.
    func testHeldPhotosAreCountedApart() async throws {
        let store = try AnalysisStore.make(folder: nil)
        await store.addFaces([NewFace(key: "f", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "trashed")
        await store.setPath("/lib/trashed.jpg", sha256: "trashed", size: 1, modified: Date())
        let alice = UUID()
        await store.applyAssignments(["trashed|f": alice])
        await store.setHeld(["/lib/trashed.jpg"])
        let person = await store.people().first { $0.id == alice }
        XCTAssertEqual(person?.faceCount, 0)
        XCTAssertEqual(person?.heldCount, 1)
    }
}
