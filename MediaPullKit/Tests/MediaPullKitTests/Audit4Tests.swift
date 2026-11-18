import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullStore
import XCTest

/// Folder operations, Check Folder and folder sizes, from the fourth audit.
final class Audit4FolderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
        return url
    }

    func folder(_ path: String) -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func journal() -> OperationJournal {
        OperationJournal(folder: root.deletingLastPathComponent().appendingPathComponent("journal-\(UUID().uuidString)"))
    }

    /// Audit 4 (B4-M1): a merge into a folder trashed or renamed after its preview stops; the folder is not made again.
    func testMergeIntoAFolderThatIsGoneChangesNothing() async throws {
        file("B/1.jpg")
        file("A/2.jpg")
        let plan = FolderOperations.merge(root.appendingPathComponent("B"), into: root.appendingPathComponent("A"))
        XCTAssertFalse(plan.moves.isEmpty)
        try FileManager.default.moveItem(at: root.appendingPathComponent("A"), to: root.appendingPathComponent("A renamed"))
        let entry = await journal().run(plan)
        XCTAssertTrue(entry.steps.isEmpty)
        XCTAssertEqual(entry.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path), "not made again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/1.jpg").path), "nothing moved")
    }

    /// Audit 4 (B4-M2): moving, renaming or trashing a library folder, or a folder that holds one, is refused in the
    /// Library and in Organise alike; copies and changes inside a library folder are allowed.
    func testPlansThatChangeALibraryFolderAreRecognised() {
        let parent = folder("Pictures")
        let library = folder("Pictures/Library")
        let inside = folder("Pictures/Library/Trip")
        let other = folder("Elsewhere")
        let roots = [library]
        let cases: [(String, OrganisePlan, Bool)] = [
            ("trash the library folder", FolderOperations.trash([library]), true),
            ("trash the folder holding it", FolderOperations.trash([parent]), true),
            ("trash a folder inside it", FolderOperations.trash([inside]), false),
            ("rename it", FolderOperations.rename(library, to: "Renamed"), true),
            ("rename it, other letter case", FolderOperations.rename(root.appendingPathComponent("pictures/library"), to: "X"), true),
            ("move it", FolderOperations.move([library], to: other), true),
            ("move the folder holding it", FolderOperations.move([parent], to: other), true),
            ("move a folder inside it", FolderOperations.move([inside], to: other), false),
            ("copy it", FolderOperations.copy([library], to: other), false),
            ("merge it away", FolderOperations.merge(library, into: other), true),
            ("merge into it", FolderOperations.merge(other, into: library), false),
        ]
        for (name, plan, expected) in cases {
            XCTAssertEqual(plan.changes(anyOf: roots), expected, name)
        }
    }

    /// Audit 4 (B4-m13): a folder selected with a file inside it is planned once, so trashing both reports no failure.
    func testItemsInsideASelectedFolderAreLeftToTheFolder() async {
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let cases: [([URL], [URL])] = [
            ([a, a.appendingPathComponent("1.jpg")], [a]),
            ([a.appendingPathComponent("x/2.jpg"), a], [a]),
            ([a, b.appendingPathComponent("1.jpg")], [a, b.appendingPathComponent("1.jpg")]),
            ([root.appendingPathComponent("A B/1.jpg"), a], [root.appendingPathComponent("A B/1.jpg"), a]),
            ([a, a], [a]),
        ]
        for (items, expected) in cases {
            XCTAssertEqual(FolderOperations.outermost(items), expected)
        }
        file("A/1.jpg")
        let entry = await journal().run(FolderOperations.trash([root.appendingPathComponent("A"),
                                                                root.appendingPathComponent("A/1.jpg")]))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    /// Audit 4 (B4-m5): a metadata file kept only in iCloud is not read (that would download it); it is reported instead.
    func testCheckFolderDoesNotReadMetadataOnlyInICloud() throws {
        let check = folder("check")
        let photo = file("check/a.jpg")
        try Data(#"{"sha256":"0000"}"#.utf8).write(to: Sidecar.sidecarURL(for: photo))
        let cloudOnly = Sidecar.sidecarURL(for: photo).standardizedFileURL
        let report = FolderCheck.run(check, archive: true, isDataless: { $0.standardizedFileURL == cloudOnly })
        XCTAssertTrue(report.changed.isEmpty, "the metadata file was not read")
        XCTAssertTrue(report.withoutMetadata.isEmpty)
        XCTAssertEqual(report.notDownloaded.map(\.lastPathComponent), ["a.jpg.json"])
        XCTAssertEqual(FolderCheck.run(check, archive: true, isDataless: { _ in false }).changed.map(\.lastPathComponent), ["a.jpg"])
        // An old-style placeholder for the metadata file is not a missing metadata file either.
        let placeholder = file("check/b.jpg")
        try Data().write(to: check.appendingPathComponent(".b.jpg.json.icloud"))
        let old = FolderCheck.run(check, archive: true, isDataless: { _ in false })
        XCTAssertFalse(old.withoutMetadata.contains(placeholder))
        XCTAssertTrue(old.notDownloaded.map(\.lastPathComponent).contains("b.jpg.json"))
    }

    /// Audit 4 (B4-m6): a package such as a photo library is one item: its contents are not counted as the folder's media,
    /// and merging two folders that both hold one keeps both packages whole.
    func testPackagesAreSingleItems() {
        file("sizes/a.jpg", "12")
        file("sizes/Photos.photoslibrary/originals/b.jpg", "123456")
        let stats = FolderStats.measure(root.appendingPathComponent("sizes"))
        XCTAssertEqual(stats.files, 1)
        XCTAssertEqual(stats.bytes, 2)

        file("A/Photos.photoslibrary/originals/1.jpg")
        file("B/Photos.photoslibrary/originals/1.jpg")
        let plan = FolderOperations.merge(root.appendingPathComponent("B"), into: root.appendingPathComponent("A"))
        XCTAssertEqual(plan.moves.map { $0.destination.lastPathComponent }, ["Photos 2.photoslibrary"])
        XCTAssertEqual(plan.foldersToTrash.map(\.lastPathComponent), ["B"])
    }

    /// Audit 4 (B4-m14): the batch rename preview shows the names the rename will really give, collision numbers included,
    /// and follows names swapped through temporary ones.
    func testBatchRenamePreviewMatchesTheRename() {
        let files = ["d.jpg", "c.jpg", "b.jpg", "a.jpg", "e.jpg"].map { file("rename/\($0)") }
        let cases: [(String, [URL], [String?])] = [
            ("Trip", files, ["Trip.jpg", "Trip 2.jpg", "Trip 3.jpg", "Trip 4.jpg"]),
            ("{name}", files, [nil, nil, nil, nil]),
            ("{n}", files, ["1.jpg", "2.jpg", "3.jpg", "4.jpg"]),
        ]
        for (pattern, chosen, expected) in cases {
            let preview = FolderOperations.batchRenamePreview(chosen, pattern: pattern)
            XCTAssertEqual(preview.map(\.old), ["d.jpg", "c.jpg", "b.jpg", "a.jpg"], pattern)
            XCTAssertEqual(preview.map(\.new), expected, pattern)
        }
        let one = file("swap/1.jpg"), two = file("swap/2.jpg")
        let swap = FolderOperations.batchRenamePreview([two, one], pattern: "{n}")
        XCTAssertEqual(swap.map(\.new), ["1.jpg", "2.jpg"])
        let finals = FolderOperations.batchRename([two, one], pattern: "{n}").finalDestinations
        XCTAssertEqual(finals[two.standardizedFileURL.path]?.lastPathComponent, "1.jpg")
        XCTAssertEqual(finals[one.standardizedFileURL.path]?.lastPathComponent, "2.jpg")
    }
}

final class Audit4PeopleTests: XCTestCase {
    /// Audit 4 (B4-m9): a named person whose photos are all gone can be forgotten; a person with photos cannot.
    func testANamedPersonWithNoPhotosLeftCanBeForgotten() async throws {
        let store = try AnalysisStore.make(folder: nil)
        await store.addFaces([NewFace(key: "f", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "kept")
        await store.addFaces([NewFace(key: "f", vectorRow: 1, quality: 1, pixelSize: 100)], sha256: "gone")
        await store.setPath("/lib/kept.jpg", sha256: "kept", size: 1, modified: Date())
        await store.setPath("/lib/gone.jpg", sha256: "gone", size: 1, modified: Date())
        let alice = UUID(), bob = UUID()
        await store.applyAssignments(["kept|f": alice, "gone|f": bob])
        await store.rename(person: alice, to: "Alice")
        await store.rename(person: bob, to: "Bob")
        await store.forget(paths: ["/lib/gone.jpg"])
        _ = await store.pruneOrphans()
        let kept = await store.forget(person: alice)
        XCTAssertFalse(kept, "a person with photos is not forgotten")
        let forgotten = await store.forget(person: bob)
        XCTAssertTrue(forgotten)
        let people = await store.people().map(\.id)
        XCTAssertEqual(people, [alice])
    }
}
