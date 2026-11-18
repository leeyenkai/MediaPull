import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Undo after a stopped change, from the sixteenth audit.
final class Audit16Tests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("audit16-\(UUID().uuidString)", isDirectory: true)
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

    /// B16-M2: the take-back of a stopped rename runs in a task of its own, so the stop that ended the rename never stops
    /// the take-back.
    func testATakeBackRunsInsideAStoppedTask() async throws {
        let files = (1 ... 4).map { file("\($0).jpg") }
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true))
        let rename = await journal.run(FolderOperations.batchRename(files.reversed(), pattern: "{n}"))
        let stopped = Task {
            try? await Task.sleep(for: .milliseconds(50))
            return await Task { await journal.undo(rename.id) }.value
        }
        stopped.cancel()
        let report = await stopped.value
        XCTAssertFalse(report.stopped)
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }.sorted()
        XCTAssertEqual(names, ["1.jpg", "2.jpg", "3.jpg", "4.jpg"])
        for number in 1 ... 4 {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("\(number).jpg"), encoding: .utf8), "\(number).jpg")
        }
    }

    /// C16-m5: an Undo and a Redo stopped part way record what they did; the rest is done later.
    func testUndoAndRedoStoppedPartWay() async throws {
        let files = (0 ..< 5).map { file("A/f\($0).jpg") }
        try fm.createDirectory(at: root.appendingPathComponent("D"), withIntermediateDirectories: true)
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true))
        let move = await journal.run(FolderOperations.move(files, to: root.appendingPathComponent("D")))
        await journal.stop(after: 2)
        let undone = await journal.undo(move.id)
        XCTAssertTrue(undone.stopped)
        XCTAssertEqual(undone.restored, 2)
        var entry = await journal.entry(move.id)
        XCTAssertEqual(entry?.undone, false)
        XCTAssertEqual(entry?.fileCount, 5)
        await journal.stop(after: nil)
        let rest = await journal.undo(move.id)
        XCTAssertEqual(rest.restored, 3, "\(rest.skipped)")
        entry = await journal.entry(move.id)
        XCTAssertEqual(entry?.undone, true)

        await journal.stop(after: 2)
        let redone = await journal.redo(move.id)
        XCTAssertTrue(redone.stopped)
        XCTAssertEqual(redone.restored, 2)
        await journal.stop(after: nil)
        let more = await journal.redo(move.id)
        XCTAssertEqual(more.restored, 3, "\(more.skipped)")
        let inD = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("D").path).filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(inD.count, 5)
    }
}
