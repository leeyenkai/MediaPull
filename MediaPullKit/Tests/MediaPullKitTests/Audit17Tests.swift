import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import MediaPullEngines
import XCTest

/// What a video job says at its end, from the seventeenth audit.
final class Audit17Tests: XCTestCase {
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

/// Prune and stranded changes, from the nineteenth audit.
final class Audit19Tests: XCTestCase {
    /// C19-m1: a change that still holds items under temporary names is never pruned, whatever its age.
    func testPruneKeepsAStrandedChange() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit19-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".mediapull-rename-x-1.jpg")
        try Data("photo".utf8).write(to: hidden)
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true))
        let entry = JournalEntry(id: UUID(), title: "Rename", root: root.path, date: Date().addingTimeInterval(-400 * 86400),
                                 steps: [.move(from: root.appendingPathComponent("1.jpg").path, to: hidden.path, size: 5,
                                               modified: Date())],
                                 failures: [], undone: false, finished: false)
        await journal.saveForTest(entry)
        await journal.prune(olderThan: 7)
        let stranded = await journal.stranded()
        XCTAssertEqual(stranded, [entry.id])
        try fm.removeItem(at: hidden)
        await journal.prune(olderThan: 7)
        let gone = await journal.entry(entry.id)
        XCTAssertNil(gone)
    }
}

extension Audit19Tests {
    /// B19-m1: a copy whose name was taken after the plan was made fails, never copying into the other folder, and Undo
    /// leaves that folder alone.
    func testACopyNeverGoesIntoAFolderThatTookItsName() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit19-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let trip = root.appendingPathComponent("Source/Trip", isDirectory: true)
        try fm.createDirectory(at: trip, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: trip.appendingPathComponent("a.jpg"))
        let target = root.appendingPathComponent("Target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let plan = FolderOperations.copy([trip], to: target)
        try fm.createDirectory(at: target.appendingPathComponent("Trip"), withIntermediateDirectories: true)
        try Data("own".utf8).write(to: target.appendingPathComponent("Trip/own.jpg"))
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal", isDirectory: true))
        let entry = await journal.run(plan)
        XCTAssertEqual(entry.failures.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Trip/Trip").path))
        _ = await journal.undo(entry.id)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Trip/own.jpg").path))
    }
}

/// The request keys of what a pull knows, from the twentieth audit.
final class Audit20Tests: XCTestCase {
    /// C20-m2: the app sends what a job saved and what the owners' folders remember under the keys the bridge reads.
    func testKnownListsGoUnderTheBridgesKeys() throws {
        var request = BridgeRequest(op: "pull")
        request.knownIDs = "/k"
        request.retryIDs = "/r"
        request.ownersKnownIDs = "/o"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["known_ids"] as? String, "/k")
        XCTAssertEqual(json["retry_ids"] as? String, "/r")
        XCTAssertEqual(json["owners_known_ids"] as? String, "/o")
    }
}
