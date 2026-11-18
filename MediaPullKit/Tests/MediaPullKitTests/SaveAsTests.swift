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
        // Metadata as the app writes it: a number only with a count.
        try file("chosen/a.jpg", metadata: ["category": "testsite", "post_id": "p1", "num": 2, "count": 3])
        try file("chosen/sub/b.jpg", metadata: ["category": "testsite", "media_id": "m9"])
        try file("chosen/c.mp4", metadata: ["category": "youtube", "subcategory": "video", "post_id": "v1"])
        try file("chosen/c.m4a", metadata: ["category": "youtube", "subcategory": "audio", "post_id": "v2"])
        try file("chosen/d.jpg", metadata: ["category": "instagram", "media_id": "1", "post_id": "2", "num": 1])
        try file("other/e.jpg", metadata: ["category": "testsite", "post_id": "p2", "num": 1])
        let held = ExactFolder.held(in: root.appendingPathComponent("chosen"))
        XCTAssertEqual(held.keys, ["testsite:p1:2", "testsite:m9"], "a file without a number is never taken as held")
        XCTAssertEqual(held.videoIDs, ["v1"])
        XCTAssertEqual(held.audioIDs, ["v2"], "a held MP4 does not stand for audio of the same video (B25-m3)")
        XCTAssertFalse(held.keys.contains("testsite:p2"), "another folder never counts")
        XCTAssertFalse(held.keys.contains { $0.hasPrefix("instagram") }, "Instagram items are known by the folder index")
        // Numbers in metadata files count as well as strings; a file numbered 0 is keyed by its post alone, as the engine keys
        // it (D-75, B24-M1), so a folder holding a post's later pages never counts as holding its first.
        XCTAssertEqual(ExactFolder.keys(of: ["category": "s", "post_id": 5, "num": 1]).keys, ["s:5:1"])
        XCTAssertEqual(ExactFolder.keys(of: ["category": "s", "post_id": "w", "num": 0, "count": 3]).keys, ["s:w"])
        XCTAssertEqual(ExactFolder.keys(of: ["category": "s", "post_id": "w", "num": 2, "count": 3]).keys, ["s:w:2"])
        // A site that numbers files without a count: the metadata file has no number, so it cannot stand for the post's file
        // numbered 0 (pixivFANBOX covers, B25-M1).
        XCTAssertEqual(ExactFolder.keys(of: ["category": "fanbox", "post_id": "9001"]).keys, [])
    }

    /// Download All As… finds each entry's folder by its name alone (D-108 rule 4, after B26-M1 and B26-M2): an account, a
    /// hashtag and a post never take one another's folders, and a rerun reuses them.
    func testDownloadAllEntriesStayInsideTheChosenFolder() throws {
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        try file("parent/ABC/a.jpg", metadata: ["category": "instagram", "username": "alice", "post_id": "1", "num": 1, "count": 1])
        try file("parent/#sunset/b.jpg", metadata: ["category": "instagram", "username": "alice", "post_id": "2", "num": 1, "count": 1])
        XCTAssertEqual(ExactFolder.entryFolder(named: "alice", in: parent).lastPathComponent, "alice",
                       "never a post's or a tag's folder that alice's media fills")
        XCTAssertEqual(ExactFolder.entryFolder(named: "ABC", in: parent).lastPathComponent, "ABC", "a rerun reuses the post's folder")
        XCTAssertEqual(ExactFolder.entryFolder(named: "#sunset", in: parent).lastPathComponent, "#sunset")
        // A file of that name: a numbered folder beside it, never a failure (B24-m7).
        try Data("x".utf8).write(to: parent.appendingPathComponent("dave"))
        XCTAssertEqual(ExactFolder.entryFolder(named: "dave", in: parent).lastPathComponent, "dave 2")
        for name in ["../escape", "/abs", ".."] {
            let folder = ExactFolder.entryFolder(named: name, in: parent)
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

    /// A copy already anywhere in the chosen folder is found, its subfolders included, so Save As never keeps a second copy
    /// (B24-m1).
    func testSaveAsLooksForCopiesInTheWholeChosenFolder() {
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        var flat = SaveTarget(folder: chosen, layout: .archive, autoSubfolders: false)
        XCTAssertFalse(SavePipeline.duplicateScope(of: chosen, target: flat).recursive, "Automatic, as before")
        flat.searchesWholeFolder = true
        XCTAssertEqual(SavePipeline.duplicateScope(of: chosen, target: flat).folder, chosen)
        XCTAssertTrue(SavePipeline.duplicateScope(of: chosen, target: flat).recursive)
        var perSource = SaveTarget(folder: chosen, layout: .plain, autoSubfolders: true, collectionPath: ["carol (site)"])
        perSource.searchesWholeFolder = true
        let entry = chosen.appendingPathComponent("carol (site)", isDirectory: true)
        XCTAssertEqual(SavePipeline.duplicateScope(of: entry, target: perSource).folder.lastPathComponent, "carol (site)")
        XCTAssertTrue(SavePipeline.duplicateScope(of: entry, target: perSource).recursive)
    }
}
