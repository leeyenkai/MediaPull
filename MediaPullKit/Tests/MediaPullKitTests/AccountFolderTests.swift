import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import MediaPullNet
import XCTest

/// Update an account folder (D-78 to D-81): what a folder already holds, and where an update writes.
final class AccountFolderTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, account: String? = nil, extra: [String: Any] = [:]) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
        if let account {
            var json: [String: Any] = ["category": "instagram", "subcategory": "posts", "username": account, "post_id": "1"]
            json.merge(extra) { $1 }
            try? JSONSerialization.data(withJSONObject: json).write(to: Sidecar.sidecarURL(for: url))
        }
        return url
    }

    func testIdentitiesFromNamesAndMetadata() throws {
        let code = try XCTUnwrap(InstagramIDs.shortcode(fromID: "3008811223344556677"))
        XCTAssertEqual(InstagramIdentity.identities(fileName: "2023-01-06_022210_\(code)_01.jpg"), ["ig:3008811223344556677"])
        XCTAssertEqual(InstagramIdentity.identities(fileName: "2023-01-06_022210_\(code)_02 2.mp4"), ["ig:3008811223344556677"],
                       "a collision number is the same item")
        XCTAssertTrue(InstagramIdentity.identities(fileName: "2026-11-13_210455_3512345678901234567_01.jpg")
            .contains("ig:3512345678901234567"), "a numeric code is the media id")
        XCTAssertTrue(InstagramIdentity.identities(fileName: "2024-05-02_181500_avatar.jpg").isEmpty)
        XCTAssertTrue(InstagramIdentity.identities(fileName: "my_user.name_\(code)_03.jpg").contains("ig:3008811223344556677"),
                      "Plain names, with underscores in the username")
        let renamed = InstagramIdentity.identities(fileName: "Holiday.jpg", metadata: [
            "category": "instagram", "subcategory": "posts", "post_id": "300", "num": 2, "media_id": "301",
        ])
        XCTAssertEqual(renamed, ["ig:301", "igp:300:2"])
        let story = InstagramIdentity.identities(fileName: "Story.jpg", metadata: [
            "category": "instagram", "subcategory": "stories", "post_id": "9", "num": 1,
        ])
        XCTAssertTrue(story.isEmpty, "a story's place in its tray is not an identity")
    }

    func testDetectionFindsTheAccountFolderWhateverItsName() {
        for index in 0 ..< 5 {
            file("lib/Alice old/posts/2023-01-0\(index + 1)_000000_A\(index)_01.jpg", account: "alice")
        }
        file("lib/Alice old/stories/s.jpg", account: "alice")
        for index in 0 ..< 3 {
            file("lib/bob/posts/b\(index).jpg", account: "bob")
        }
        let lib = root.appendingPathComponent("lib")
        let match = AccountFolders.detect(lib.appendingPathComponent("Alice old/posts"), stopAt: lib)
        XCTAssertEqual(match?.account, "alice")
        XCTAssertEqual(match?.folder.lastPathComponent, "Alice old")
        XCTAssertNil(AccountFolders.detect(lib, stopAt: lib), "a folder of several accounts is no account's")
    }

    func testALibraryWithOneAccountAndOtherFoldersIsNotTheAccountsFolder() throws {
        for index in 0 ..< 4 {
            file("lib/alice/posts/\(index).jpg", account: "alice")
        }
        file("lib/example.com/page.jpg")
        let sidecar = Sidecar.sidecarURL(for: root.appendingPathComponent("lib/example.com/page.jpg"))
        try JSONSerialization.data(withJSONObject: ["category": "example.com", "username": "example.com"]).write(to: sidecar)
        file("lib/Pictures/a.png")
        file("lib/Pictures/b.png")
        let lib = root.appendingPathComponent("lib")
        XCTAssertEqual(AccountFolders.detect(lib.appendingPathComponent("alice/posts"), stopAt: nil)?.folder.lastPathComponent, "alice")
        XCTAssertNil(AccountFolders.detect(lib, stopAt: lib))
        let only = root.appendingPathComponent("only")
        for index in 0 ..< 3 {
            file("only/alice/posts/\(index).jpg", account: "alice")
        }
        XCTAssertEqual(AccountFolders.detect(only, stopAt: only)?.folder.lastPathComponent, "alice",
                       "a library holding only the account's folder points at that folder")
    }

    func testCheckFolderFindsOrphansMissingMetadataAndChangedFiles() throws {
        let folder = root.appendingPathComponent("check")
        let kept = file("check/a.jpg", account: "alice", extra: ["sha256": try FileHasher.sha256(of: file("check/a.jpg"))])
        file("check/b.jpg", account: "alice", extra: ["sha256": "0000"])
        file("check/c.jpg")
        let gone = file("check/d.jpg", account: "alice")
        try FileManager.default.removeItem(at: gone)
        try Data().write(to: folder.appendingPathComponent(".e.jpg.icloud"))
        let report = FolderCheck.run(folder, archive: true)
        XCTAssertEqual(report.checked, 3)
        XCTAssertEqual(report.changed.map(\.lastPathComponent), ["b.jpg"])
        XCTAssertEqual(report.withoutMetadata.map(\.lastPathComponent), ["c.jpg"])
        XCTAssertEqual(report.orphanedMetadata.map(\.lastPathComponent), ["d.jpg.json"])
        XCTAssertEqual(report.notDownloaded.map(\.lastPathComponent), ["e.jpg"])
        XCTAssertFalse(report.changed.contains(kept))
        XCTAssertTrue(FolderCheck.run(folder, archive: false).withoutMetadata.isEmpty, "Plain folders have no metadata files")
    }

    func testTheCopyKeptHasTheMostPixelsThenMetadataThenAge() {
        let old = Date(timeIntervalSince1970: 0), new = Date()
        func candidate(_ name: String, _ pixels: Int, _ metadata: Bool, _ created: Date) -> ExtraCopies.Candidate {
            ExtraCopies.Candidate(url: URL(fileURLWithPath: "/x/\(name)"), pixels: pixels, hasMetadata: metadata, created: created,
                                  bytes: 1)
        }
        let rows: [([ExtraCopies.Candidate], String)] = [
            ([candidate("small", 10, true, old), candidate("big", 20, false, new)], "big"),
            ([candidate("bare", 20, false, old), candidate("described", 20, true, new)], "described"),
            ([candidate("newer", 20, true, new), candidate("older", 20, true, old)], "older"),
            ([candidate("long name", 20, true, old), candidate("short", 20, true, old)], "short"),
        ]
        for (candidates, expected) in rows {
            XCTAssertEqual(ExtraCopies.keeper(candidates)?.url.lastPathComponent, expected)
        }
    }

    func testIndexReadsNamesAndRenamedFilesAcrossSubfolders() throws {
        let code = try XCTUnwrap(InstagramIDs.shortcode(fromID: "3008811223344556677"))
        file("alice/posts/2023-01-06_022210_\(code)_01.jpg", account: "alice")
        file("alice/Sorted/Beach/renamed.jpg", account: "alice", extra: ["post_id": "500", "num": 1, "media_id": "501"])
        let index = AccountFolders.index(root.appendingPathComponent("alice"))
        XCTAssertEqual(index.files, 2)
        XCTAssertEqual(index.identities, ["ig:3008811223344556677", "ig:501", "igp:500:1"])
    }

    func testTargetIsTheExistingFolderAndNeverNested() {
        file("lib/Alice old/posts/a.jpg", account: "alice")
        file("lib/Alice old/posts/b.jpg", account: "alice")
        let lib = root.appendingPathComponent("lib")
        let fromLibrary = AccountFolders.resolveTarget(account: "Alice", saveFolder: lib, root: lib)
        XCTAssertEqual(fromLibrary.existing?.lastPathComponent, "Alice old")
        let fromInside = AccountFolders.resolveTarget(account: "alice", saveFolder: lib.appendingPathComponent("Alice old/posts"),
                                                      root: lib)
        XCTAssertEqual(fromInside.existing?.lastPathComponent, "Alice old", "never alice old/alice")
        let other = AccountFolders.resolveTarget(account: "bob", saveFolder: lib.appendingPathComponent("Alice old"), root: lib)
        XCTAssertNil(other.existing)
        XCTAssertEqual(other.parent.lastPathComponent, "lib", "another account goes beside it, not inside it")
        XCTAssertEqual(AccountFolders.sortsByType(lib.appendingPathComponent("Alice old")), true)
    }

    func testUpdateSavesIntoTheExistingFolderWithTheAccountsName() {
        let folder = root.appendingPathComponent("Alice old", isDirectory: true)
        var context = EngineContext(key: "ig:1", category: "instagram", subcategory: "posts")
        context.username = "alice"
        context.mediaID = "1"
        context.postID = "10"
        let url = URL(string: "https://cdn.example.com/a.jpg")!
        let item = MediaItem(id: "ig:1", kind: .image,
                             variants: [MediaVariant(id: url.absoluteString, url: url, format: .jpeg, origin: .img)],
                             source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        var target = SaveTarget(folder: root, layout: .archive, autoSubfolders: true, accountUsername: "alice")
        target.accountFolder = folder
        target.typeSubfolders = true
        XCTAssertEqual(ArchivePlanner.folder(for: item, target: target, settings: SaveSettings()).path,
                       folder.appendingPathComponent("posts").path)
        let info = FinalFileInfo(format: .jpeg, sha256: "ab", pixelSize: nil, duration: nil, sourceURL: url, lastModified: nil,
                                 originalName: nil, note: nil)
        let sidecar = ArchivePlanner.sidecar(for: item, info: info, target: target, settings: SaveSettings())
        XCTAssertEqual(sidecar.username, "alice", "the metadata names the account, never the folder")
        XCTAssertEqual(sidecar.mediaID, "1")
        XCTAssertEqual(SavePipeline.accountFolder(folder.appendingPathComponent("posts"), target: target), folder)
    }

    func testEstimateCountsPagesAtTheAverageDelay() {
        for (posts, pacing, requests, seconds) in [(0, PacingPreset.gentle, 1, 11.5), (12, .gentle, 2, 23.0), (13, .gentle, 3, 34.5),
                                                   (1000, .standard, 85, 765.0)] {
            let estimate = pacing.estimate(posts: posts)
            XCTAssertEqual(estimate.requests, requests, "\(posts) posts")
            XCTAssertEqual(estimate.seconds, seconds, accuracy: 0.001)
        }
    }

    func testStoreRemembersKeysAndCursorPerFolder() async {
        let store = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let folder = root.appendingPathComponent("alice")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = await store.record(account: "Alice", folder: folder)
        await store.addKeys(["ig:1", "ig:2"], to: record.id)
        await store.update(record.id, cursor: .some("abc"))
        let reloaded = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let again = await reloaded.record(account: "alice", folder: folder)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(again.keys, ["ig:1", "ig:2"])
        XCTAssertEqual(again.cursor, "abc")
    }
}
