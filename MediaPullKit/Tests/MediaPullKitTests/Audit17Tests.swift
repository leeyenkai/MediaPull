import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// What a video job says at its end, from the seventeenth audit.
final class Audit17Tests: XCTestCase {
    /// A17-M1: only failures a Retry neither saved nor failed again are "not tried"; none on a first run.
    func testOnlyFailuresNotReachedAreSaidNotTried() {
        XCTAssertTrue(VideoRunNotes.notReached(earlier: [], saved: ["a", "b", "c"], failedNow: []).isEmpty)
        let earlier = [(id: "b", message: "rate limited"), (id: "video:site:c", message: "could not be saved"), (id: "d", message: "x")]
        let notReached = VideoRunNotes.notReached(earlier: earlier, saved: ["a", "b"], failedNow: [(id: "video:site:d", message: "x")])
        XCTAssertEqual(notReached.map(\.id), ["video:site:c"])
    }

    /// A17-m1: each language asked for is checked; "all" only asks that some came.
    func testMissingSubtitlesByLanguage() {
        let attached: [Set<String>] = [["subtitles.en", "thumbnail"], ["subtitles.en", "subtitles.fr"], []]
        XCTAssertEqual(VideoRunNotes.missingSubtitles(asked: ["en", "fr"], attached: attached), ["en": 1, "fr": 2])
        XCTAssertEqual(VideoRunNotes.missingSubtitles(asked: ["all"], attached: attached), ["any": 1])
        XCTAssertEqual(VideoRunNotes.missingSubtitles(asked: ["en.*"], attached: attached), ["any": 1])
    }

    /// C17-M2: an Undo or Redo of a name swap stopped after its first item goes on until no file is under a temporary name.
    func testAStoppedSwapNeverLeavesFilesHidden() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit17-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let files = (1 ... 4).map { number -> URL in
            let url = root.appendingPathComponent("\(number).jpg")
            try? Data("\(number)".utf8).write(to: url)
            return url
        }
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true))
        let rename = await journal.run(FolderOperations.batchRename(files.reversed(), pattern: "{n}"))
        func hidden() throws -> [String] {
            try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".mediapull-rename-") }
        }
        await journal.stop(after: 1)
        _ = await journal.undo(rename.id)
        XCTAssertEqual(try hidden(), [])
        let names = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".jpg") }.sorted()
        XCTAssertEqual(names, ["1.jpg", "2.jpg", "3.jpg", "4.jpg"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("1.jpg"), encoding: .utf8), "1")
        _ = await journal.redo(rename.id)
        XCTAssertEqual(try hidden(), [])
        let stranded = await journal.stranded()
        XCTAssertTrue(stranded.isEmpty)
    }
}
