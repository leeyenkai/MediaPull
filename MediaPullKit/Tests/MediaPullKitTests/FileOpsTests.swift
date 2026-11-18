import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// File changes outside the operation journal and editor Replace (D-107).
final class FileOpsTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("fileops-\(UUID().uuidString)", isDirectory: true)
        outside = fm.temporaryDirectory.appendingPathComponent("fileops-edits-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
        try? fm.removeItem(at: outside)
    }

    @discardableResult
    private func file(_ name: String, _ contents: String, in folder: URL? = nil, metadata: [String: Any]? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        if let metadata {
            try JSONSerialization.data(withJSONObject: metadata).write(to: Sidecar.sidecarURL(for: url))
        }
        return url
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    private func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: Sidecar.sidecarURL(for: url))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func names() throws -> [String] {
        try fm.contentsOfDirectory(atPath: root.path).filter { $0 != ".journal" }.sorted()
    }

    private func journal() -> OperationJournal {
        OperationJournal(folder: outside.appendingPathComponent("journal", isDirectory: true))
    }

    private var caseInsensitive: Bool {
        (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) != true
    }

    private func replace(_ original: URL, named name: String, with contents: String, using journal: OperationJournal) async throws
        -> JournalEntry
    {
        let edit = try file("\(UUID().uuidString).jpg", contents, in: outside)
        let metadata = try FileOps.metadata(of: original, applying: .init(values: ["edited": .bool(true)], isCopy: false))
        return try await journal.replace(original, identity: AccountFolderRecord.number(of: original), with: edit,
                                         named: root.appendingPathComponent(name), metadata: metadata, title: "Replace")
    }

    /// A case-only rename on Replace keeps its metadata file: no " 2", and the metadata file is beside the new name.
    func testACaseOnlyRenameOnReplaceKeepsItsMetadataFile() async throws {
        try XCTSkipUnless(caseInsensitive, "needs a case-insensitive volume")
        let original = try file("Photo.jpg", "old", metadata: ["username": "a", "media_id": "1"])
        let entry = try await replace(original, named: "photo.jpg", with: "new", using: journal())
        XCTAssertEqual(try names(), ["photo.jpg", "photo.jpg.json"])
        let placed = root.appendingPathComponent("photo.jpg")
        XCTAssertEqual(text(placed), "new")
        XCTAssertEqual(json(placed)?["edited"] as? Bool, true)
        XCTAssertEqual(json(placed)?["media_id"] as? String, "1", "a Replace is the same item")
        XCTAssertTrue(entry.finished)
        XCTAssertEqual(FileOps.freeName(for: root.appendingPathComponent("PHOTO.jpg"), replacing: placed).lastPathComponent,
                       "PHOTO.jpg", "its own name and metadata file never count as taken")
    }

    /// An orphaned metadata file is never overwritten: the new file takes the next free name.
    func testAnOrphanedMetadataFileIsNeverOverwritten() async throws {
        let orphan = Sidecar.sidecarURL(for: root.appendingPathComponent("x.jpg"))
        try Data(#"{"username":"kept"}"#.utf8).write(to: orphan)
        let new = try file("new.jpg", "picture", in: outside)
        let placed = try await FileOps.place(new, as: root.appendingPathComponent("x.jpg"),
                                             with: .data(Data(#"{"username":"new"}"#.utf8)))
        XCTAssertEqual(placed.url.lastPathComponent, "x 2.jpg")
        XCTAssertNil(placed.metadataProblem)
        XCTAssertEqual(text(orphan), #"{"username":"kept"}"#)
        XCTAssertEqual(json(placed.url)?["username"] as? String, "new")
        XCTAssertFalse(fm.fileExists(atPath: new.path))
        // An exclusive write refuses a name that is taken.
        XCTAssertThrowsError(try FileOps.writeNew(Data("x".utf8), to: orphan))
        XCTAssertEqual(text(orphan), #"{"username":"kept"}"#)
    }

    /// Another file at the path is refused: nothing is trashed, the edit goes back, and no undo record is left.
    func testAnotherFileAtThePathIsRefused() async throws {
        let original = try file("a.jpg", "opened", metadata: ["username": "a"])
        let identity = AccountFolderRecord.number(of: original)
        try fm.removeItem(at: original)
        try file("a.jpg", "another")
        let edit = try file("edit.jpg", "edit", in: outside)
        let journal = journal()
        do {
            _ = try await journal.replace(original, identity: identity, with: edit, named: original, metadata: nil, title: "Replace")
            XCTFail("a different file must not be replaced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("is another file now"))
        }
        XCTAssertEqual(text(original), "another")
        XCTAssertEqual(text(edit), "edit", "the edit is back where it was, so Save can be tried again")
        XCTAssertEqual(try names(), ["a.jpg", "a.jpg.json"])
        let entries = await journal.entries()
        XCTAssertTrue(entries.isEmpty)
        // Trashing checks the same way.
        do {
            try await FileOps.trash(original, identity: identity)
            XCTFail("a different file must not be trashed")
        } catch {}
        XCTAssertEqual(text(original), "another")
    }

    /// A failure part way, after the original went to the Trash, puts the original and its metadata file back.
    func testAFailurePartWayRestoresTheOriginal() async throws {
        let original = try file("b.jpg", "original", metadata: ["username": "b", "num": 1])
        let journal = journal()
        await journal.failReplace(afterTrash: true)
        let edit = try file("edit.jpg", "edit", in: outside)
        do {
            _ = try await journal.replace(original, identity: AccountFolderRecord.number(of: original), with: edit, named: original,
                                          metadata: Data("{}".utf8), title: "Replace")
            XCTFail("the test hook makes it fail")
        } catch {}
        XCTAssertEqual(try names(), ["b.jpg", "b.jpg.json"])
        XCTAssertEqual(text(original), "original")
        XCTAssertEqual(json(original)?["username"] as? String, "b")
        XCTAssertEqual(text(edit), "edit")
        let entries = await journal.entries()
        XCTAssertTrue(entries.isEmpty)
        let stranded = await journal.stranded()
        XCTAssertTrue(stranded.isEmpty)
    }

    /// Copies drop the keys that identify the item, and keep everything else.
    func testCopiesDropTheIdentityKeys() async throws {
        let original = try file("c.jpg", "picture", metadata: [
            "username": "c", "media_id": "9", "post_id": "8", "num": 2, "count": 3, "shortcode": "S", "post_shortcode": "P",
        ])
        let copy = try await FileOps.copy(original, as: root.appendingPathComponent("c copy.jpg"))
        XCTAssertEqual(copy.url.lastPathComponent, "c copy.jpg")
        XCTAssertEqual(text(copy.url), "picture")
        let metadata = try XCTUnwrap(json(copy.url))
        XCTAssertEqual(metadata["username"] as? String, "c")
        for key in FileOps.identityKeys {
            XCTAssertNil(metadata[key], key)
        }
        XCTAssertEqual(json(original)?["media_id"] as? String, "9", "the original is untouched")
    }

    /// ⌘Z of a Replace puts back the original exactly and sends the edit to the Trash; Redo does it again, and nothing is
    /// left under a hidden name.
    func testUndoAndRedoOfAReplace() async throws {
        let original = try file("d.jpg", "original", metadata: ["username": "d"])
        let journal = journal()
        let entry = try await replace(original, named: "d.jpg", with: "edited", using: journal)
        XCTAssertEqual(text(original), "edited")
        func hidden() throws -> [String] { try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".mediapull-") } }

        let undone = await journal.undo(entry.id)
        XCTAssertEqual(undone.restored, 1)
        XCTAssertEqual(text(original), "original")
        XCTAssertNil(json(original)?["edited"])
        XCTAssertEqual(try hidden(), [])
        XCTAssertEqual(try names(), ["d.jpg", "d.jpg.json"])

        let redone = await journal.redo(entry.id)
        XCTAssertEqual(redone.restored, 1)
        XCTAssertEqual(text(original), "edited")
        XCTAssertEqual(json(original)?["edited"] as? Bool, true)
        XCTAssertEqual(try hidden(), [])

        _ = await journal.undo(entry.id)
        XCTAssertEqual(text(original), "original")
        XCTAssertEqual(try hidden(), [])
        let stranded = await journal.stranded()
        XCTAssertTrue(stranded.isEmpty)
    }

    /// A Replace stopped before the original went (a crash) is found at launch and its hidden edit goes to the Trash.
    func testAStoppedReplaceIsTakenBack() async throws {
        let original = try file("e.jpg", "original")
        let hidden = try file(".mediapull-edit-x.jpg", "edit")
        let journal = journal()
        var entry = JournalEntry(id: UUID(), title: "Replace", root: root.path, date: Date(), steps: [], failures: [],
                                 undone: false, finished: false)
        entry.edits = [hidden.path]
        await journal.save(entry)
        let stranded = await journal.stranded()
        XCTAssertEqual(stranded, [entry.id])
        _ = await journal.undo(entry.id)
        XCTAssertFalse(fm.fileExists(atPath: hidden.path))
        XCTAssertEqual(text(original), "original")
        let after = await journal.stranded()
        XCTAssertTrue(after.isEmpty)
    }
}
