import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Undo stopped part way, folders of a change undone in two parts and counts, from the fifteenth audit.
final class Audit15Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit15-\(UUID().uuidString)", isDirectory: true)
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
    func journal() -> OperationJournal { OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true)) }

    /// B15-M1, C15-M2: an Undo stopped part way (Cancel, Quit) records what it did; the rest is undone later.
    func testAnUndoStoppedPartWayIsRecorded() async throws {
        let files = (0 ..< 5).map { file("A/f\($0).jpg") }
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let journal = journal()
        let move = await journal.run(FolderOperations.move(files, to: url("D")))
        let task = Task {
            try? await Task.sleep(for: .milliseconds(50))
            return await journal.undo(move.id)
        }
        task.cancel()
        let stopped = await task.value
        XCTAssertTrue(stopped.stopped)
        let entry = await journal.entry(move.id)
        XCTAssertEqual(entry?.undone, false, "nothing was undone, so the change is still done")
        let rest = await journal.undo(move.id)
        XCTAssertEqual(rest.restored, 5, "\(rest.skipped)")
        XCTAssertTrue(exists("A/f0.jpg"))
    }

    /// B15-m4, B15-m6: a change undone in two parts removes the folder it made, and counts all its files meanwhile.
    func testAChangeUndoneInTwoPartsRemovesItsFolder() async throws {
        let a = file("A/a.jpg")
        let b = file("B/b.jpg")
        try fm.createDirectory(at: url("T"), withIntermediateDirectories: true)
        let journal = journal()
        let move = await journal.run(FolderOperations.sort([a, b], into: url("T"), title: "Sort") { _ in [["2024"]] })
        XCTAssertTrue(exists("T/2024/a.jpg"))
        try fm.moveItem(at: url("A"), to: url("A away"))
        _ = await journal.undo(move.id)
        let part = await journal.entry(move.id)
        XCTAssertEqual(part?.fileCount, 2, "both files, the one undone and the one left")
        try fm.moveItem(at: url("A away"), to: url("A"))
        _ = await journal.undo(move.id)
        XCTAssertTrue(exists("A/a.jpg"))
        XCTAssertTrue(exists("B/b.jpg"))
        XCTAssertFalse(exists("T/2024"), "the folder the change made goes with its last item")
    }

    /// B15-m5: a change that changed nothing says it was undone.
    func testAnEmptyChangeSaysItWasUndone() async throws {
        let gone = file("x.jpg")
        try fm.createDirectory(at: url("D"), withIntermediateDirectories: true)
        let plan = FolderOperations.move([gone], to: url("D"))
        try fm.removeItem(at: gone)
        let journal = journal()
        let entry = await journal.run(plan)
        let report = await journal.undo(entry.id)
        XCTAssertGreaterThan(report.done, 0)
    }
}
