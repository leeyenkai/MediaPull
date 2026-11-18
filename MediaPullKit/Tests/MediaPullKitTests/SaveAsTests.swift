import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Save As in the Downloads pane (D-108): what a chosen folder holds is judged from that folder alone, and Download All
/// As… keeps every entry inside the chosen folder.
final class SaveAsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("saveas-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func file(_ path: String, metadata: [String: Any]) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try JSONSerialization.data(withJSONObject: metadata).write(to: Sidecar.sidecarURL(for: url))
    }

    func testKeysComeFromTheFoldersOwnMetadataOnly() throws {
        try file("chosen/a.jpg", metadata: ["category": "testsite", "post_id": "p1", "num": 2])
        try file("chosen/sub/b.jpg", metadata: ["category": "testsite", "media_id": "m9"])
        try file("chosen/c.mp4", metadata: ["category": "youtube", "subcategory": "video", "post_id": "v1"])
        try file("chosen/d.jpg", metadata: ["category": "instagram", "media_id": "1", "post_id": "2", "num": 1])
        try file("other/e.jpg", metadata: ["category": "testsite", "post_id": "p2", "num": 1])
        let held = ExactFolder.held(in: root.appendingPathComponent("chosen"))
        XCTAssertEqual(held.keys, ["testsite:p1", "testsite:p1:2", "testsite:m9", "youtube:v1"])
        XCTAssertEqual(held.videoIDs, ["v1"])
        XCTAssertFalse(held.keys.contains("testsite:p2"), "another folder never counts")
        XCTAssertFalse(held.keys.contains { $0.hasPrefix("instagram") }, "Instagram items are known by the folder index")
        // Numbers in metadata files count as well as strings.
        XCTAssertEqual(ExactFolder.keys(of: ["category": "s", "post_id": 5, "num": 1]).keys, ["s:5", "s:5:1"])
    }

    func testDownloadAllEntriesStayInsideTheChosenFolder() throws {
        try file("parent/my alice/posts/a.jpg", metadata: ["category": "instagram", "username": "alice", "post_id": "1", "num": 1])
        try file("parent/alice/b.jpg", metadata: ["category": "instagram", "username": "bob", "post_id": "2", "num": 1])
        let parent = root.appendingPathComponent("parent")
        XCTAssertEqual(ExactFolder.entryFolder(named: "alice", account: "alice", in: parent).lastPathComponent, "my alice",
                       "the folder that holds the account, whatever it is called")
        XCTAssertEqual(ExactFolder.entryFolder(named: "carol", account: "carol", in: parent).lastPathComponent, "carol")
        XCTAssertEqual(ExactFolder.entryFolder(named: "Some Channel", account: nil, in: parent).lastPathComponent, "Some Channel")
        // A folder of that name holding another account's media is not taken: a numbered one beside it instead.
        try fm.removeItem(at: parent.appendingPathComponent("my alice"))
        XCTAssertEqual(ExactFolder.entryFolder(named: "alice", account: "alice", in: parent).lastPathComponent, "alice 2")
        for name in ["../escape", "/abs", ".."] {
            let folder = ExactFolder.entryFolder(named: name, account: nil, in: parent)
            XCTAssertTrue(ExactFolder.contains(parent, folder.path), "\(name) stays inside: \(folder.path)")
            XCTAssertNotEqual(folder.standardizedFileURL.path, parent.standardizedFileURL.path)
        }
    }

    func testContainsComparesAsTheVolumeDoes() throws {
        let folder = root.appendingPathComponent("Chosen", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(ExactFolder.contains(folder, folder.appendingPathComponent("a.jpg").path))
        XCTAssertFalse(ExactFolder.contains(folder, root.appendingPathComponent("Chosen 2/a.jpg").path))
        let values = try? root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let caseSensitive = values?.volumeSupportsCaseSensitiveNames == true
        XCTAssertEqual(ExactFolder.contains(folder, root.appendingPathComponent("chosen/a.jpg").path), !caseSensitive)
    }
}
