import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Check Folder from the fifth audit.
final class Audit5FolderCheckTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var caseSensitive: Bool {
        (try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    @discardableResult
    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Audit 5 (C5-m7): a media file renamed in the Finder by letter case only still has its metadata file on a
    /// case-insensitive volume, where reads find it: that file is not orphaned, so Trash Orphaned Metadata leaves it.
    func testCaseOnlyRenameKeepsMetadata() throws {
        try XCTSkipIf(caseSensitive, "the test folder is on a case-sensitive volume")
        try file("check/beach.jpg.json", #"{"sha256":""}"#)
        try file("check/Beach.jpg")
        let report = FolderCheck.run(root.appendingPathComponent("check"), archive: true, isDataless: { _ in false })
        XCTAssertTrue(report.orphanedMetadata.isEmpty, "\(report.orphanedMetadata)")
        XCTAssertTrue(report.withoutMetadata.isEmpty)
        XCTAssertEqual(report.checked, 1)
    }

    /// Unicode form aside too: a name written decomposed matches its metadata file written precomposed.
    func testUnicodeFormsMatch() throws {
        try file("check/cafe\u{301}.jpg.json".precomposedStringWithCanonicalMapping, #"{"sha256":""}"#)
        try file("check/cafe\u{301}.jpg".decomposedStringWithCanonicalMapping)
        let report = FolderCheck.run(root.appendingPathComponent("check"), archive: true, isDataless: { _ in false })
        XCTAssertTrue(report.orphanedMetadata.isEmpty, "\(report.orphanedMetadata)")
    }

    /// Metadata files whose media file is really gone are still reported.
    func testRealOrphansStillReported() throws {
        try file("check/kept.jpg.json", #"{"sha256":""}"#)
        try file("check/kept.jpg")
        try file("check/gone.jpg.json", #"{"sha256":""}"#)
        let report = FolderCheck.run(root.appendingPathComponent("check"), archive: true, isDataless: { _ in false })
        XCTAssertEqual(report.orphanedMetadata.map(\.lastPathComponent), ["gone.jpg.json"])
    }

    /// The key follows the volume: letter case counts only where the volume tells names apart by it.
    func testPathKeyFollowsVolume() {
        let key = FolderCheck.pathKey(for: root)
        XCTAssertEqual(key("/a/cafe\u{301}"), key("/a/caf\u{e9}"))
        XCTAssertEqual(key("/a/Beach.jpg") == key("/a/beach.jpg"), !caseSensitive)
    }
}
