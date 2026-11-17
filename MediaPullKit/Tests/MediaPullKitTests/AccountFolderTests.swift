import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import MediaPullNet
@testable import MediaPullStore
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
        XCTAssertNil(AccountFolders.detect(only, stopAt: only), "a library holding one account is not that account's folder")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "alice", saveFolder: only, root: only).existing?.lastPathComponent, "alice")
    }

    /// Audit round 1 (C1, C5, C6, C15): folders without media, accounts one level further down, a Plain folder named after
    /// the account, and an account folder whose files were all sorted into one subfolder.
    func testAccountFoldersAmongOtherFolders() throws {
        for index in 0 ..< 3 {
            file("lib/alice/posts/\(index).jpg", account: "alice")
            file("lib/Friends/carol/posts/\(index).jpg", account: "carol")
            file("lib/Friends/dave/posts/\(index).jpg", account: "dave")
            file("lib/erin/2024/\(index).jpg", account: "erin")
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lib/Favourites"), withIntermediateDirectories: true)
        file("lib/frank/frank_photo.jpg")
        let lib = root.appendingPathComponent("lib")
        XCTAssertNil(AccountFolders.detect(lib, stopAt: lib), "an empty folder beside one account does not make the root its folder")
        XCTAssertNil(AccountFolders.detect(lib.appendingPathComponent("Favourites"), stopAt: lib))
        let bob = AccountFolders.resolveTarget(account: "bob", saveFolder: lib, root: lib)
        XCTAssertNil(bob.existing)
        XCTAssertEqual(bob.parent.path, lib.standardizedFileURL.path, "a new account goes inside the library")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "carol", saveFolder: lib, root: lib).existing?.lastPathComponent, "carol",
                       "found two levels down, in a folder of several accounts")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "frank", saveFolder: lib, root: lib).existing?.lastPathComponent, "frank",
                       "a folder named after the account with no metadata is reused")
        XCTAssertEqual(AccountFolders.detect(lib.appendingPathComponent("erin/2024"), stopAt: lib)?.folder.lastPathComponent, "erin",
                       "files sorted into one subfolder: the account folder is still the one above")
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
        // Saved without metadata on purpose (audit round 1, C23): a video's thumbnail and an audio file.
        file("check/clip.mp4", account: "alice")
        file("check/clip.jpg")
        file("check/song.m4a")
        XCTAssertEqual(FolderCheck.run(folder, archive: true).withoutMetadata.map(\.lastPathComponent), ["c.jpg"])
    }

    func testFolderStatsCountMediaInSubfoldersOnly() throws {
        file("sizes/a.jpg", account: "alice")
        file("sizes/deep/b.mp4")
        try Data(count: 1000).write(to: root.appendingPathComponent("sizes/deep/c.png"))
        file("sizes/notes.txt")
        let stats = FolderStats.measure(root.appendingPathComponent("sizes"))
        XCTAssertEqual(stats.files, 3, "metadata and other files are not counted")
        XCTAssertEqual(stats.bytes, 1002)
    }

    /// R-1715: a file with any of the chosen Finder tags passes; the filter counts once.
    func testFinderTagFilter() {
        func entry(_ name: String, _ tags: [String]) -> MediaEntry {
            var entry = MediaEntry(url: URL(fileURLWithPath: "/x/\(name).jpg"), size: 1, created: nil, modified: Date(), format: .jpeg)
            entry.finderTags = tags
            return entry
        }
        var query = LibraryQuery()
        query.filter.finderTags = ["Red", "Work"]
        let shown = [entry("a", ["Red"]), entry("b", []), entry("c", ["Blue", "Work"])].filter { query.matches($0) }.map(\.name)
        XCTAssertEqual(shown, ["a.jpg", "c.jpg"])
        XCTAssertEqual(query.filter.count, 1)
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

    /// Audit round 2 (C2-M1, C2-M2, C2-m1, C2-m6, C2-m7, B2-M3).
    func testRoundTwoAccountFolderCases() throws {
        let lib = root.appendingPathComponent("lib")
        for index in 0 ..< 3 {
            file("lib/Friends/alice/posts/\(index).jpg", account: "alice")
            file("lib/Alice old/2024/2024-05/\(index).jpg", account: "dave")
            file("lib/erin/highlights/Stories/\(index).jpg", account: "erin")
            file("lib/erin/posts/\(index).jpg", account: "erin")
        }
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Alice old/posts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Wallpapers"), withIntermediateDirectories: true)
        file("lib/Frank/x.jpg")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "alice", saveFolder: lib, root: lib).existing?.lastPathComponent, "alice",
                       "found inside a folder that holds only that account")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "dave", saveFolder: lib, root: lib).existing?.lastPathComponent, "Alice old",
                       "an account folder whose files were sorted into dated folders, with its empty posts/")
        XCTAssertEqual(AccountFolders.detect(lib.appendingPathComponent("erin/highlights/Stories"), stopAt: lib)?.folder.lastPathComponent,
                       "erin", "a highlight titled like a type folder does not make highlights/ the account folder")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "frank", saveFolder: lib, root: lib).existing?.lastPathComponent, "Frank",
                       "the folder's real spelling")
        XCTAssertEqual(AccountFolders.sortsByType(lib.appendingPathComponent("Frank")), false, "a flat Plain folder stays flat")
        let solo = root.appendingPathComponent("solo")
        file("solo/posts/1.jpg", account: "gina")
        file("solo/posts/2.jpg", account: "gina")
        let hank = AccountFolders.resolveTarget(account: "hank", saveFolder: solo, root: solo)
        XCTAssertEqual(hank.parent.path, solo.standardizedFileURL.path,
                       "an account folder that is the library folder takes other accounts inside, never outside the library")
    }

    /// Audit round 3 (C3-M3, C3-m1, C3-m2, C3-m4, B3-M3).
    func testRoundThreeAccountFolderCases() {
        let lib = root.appendingPathComponent("lib")
        for index in 0 ..< 4 {
            file("lib/Hashtags/alicetravels/\(index).jpg", account: "alice")
            file("lib/Saved posts/\(index).jpg", account: "bob")
            file("lib/Alice Smith/posts/\(index).jpg", account: "alice")
            file("lib/Alice Smith/www.example.com/w\(index).jpg")
            file("lib/carol/highlights/carol/\(index).jpg", account: "carol")
            file("lib/carol/posts/\(index).jpg", account: "carol")
        }
        XCTAssertNil(AccountFolders.detect(lib.appendingPathComponent("Hashtags/alicetravels"), stopAt: lib), "a hashtag folder")
        XCTAssertNotEqual(AccountFolders.resolveTarget(account: "bob", saveFolder: lib, root: lib).existing?.lastPathComponent,
                          "Saved posts")
        XCTAssertEqual(AccountFolders.resolveTarget(account: "alice", saveFolder: lib, root: lib).existing?.lastPathComponent,
                       "Alice Smith", "a renamed account folder that also holds web saves")
        XCTAssertEqual(AccountFolders.detect(lib.appendingPathComponent("carol/highlights/carol"), stopAt: lib)?.folder.lastPathComponent,
                       "carol", "a highlight titled like the account is not its folder")
        XCTAssertEqual(AccountFolders.detect(lib.appendingPathComponent("carol/highlights/carol"), stopAt: lib)?.folder.path,
                       lib.appendingPathComponent("carol").standardizedFileURL.path)
        let solo = root.appendingPathComponent("solo")
        for index in 0 ..< 3 {
            file("solo/posts/\(index).jpg", account: "dave")
            file("solo/erin/posts/\(index).jpg", account: "erin")
        }
        XCTAssertEqual(AccountFolders.resolveTarget(account: "dave", saveFolder: solo, root: solo).existing?.path,
                       solo.standardizedFileURL.path, "a library folder that is an account's, with another account inside it")
        XCTAssertEqual(AccountFolders.newFolder(named: "solo", in: root).lastPathComponent, "solo 2")
        XCTAssertTrue(FileFlags.isInTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/501/Library")))
        XCTAssertTrue(FileFlags.isInTrash(URL(fileURLWithPath: "/Users/someone/.Trash/Library")))
        XCTAssertFalse(FileFlags.isInTrash(URL(fileURLWithPath: "/Users/someone/Pictures/Trash talk")))
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

    /// R-1011: saved items are found again in one lookup, and a record whose file is gone does not count.
    func testArchivedPathsAreLookedUpInBatchesAndIgnoreMissingFiles() async throws {
        let store = try AppStore.make(inMemory: true)
        let kept = file("saved/a.jpg")
        for index in 0 ..< 1500 {
            await store.recordArchive(key: "web:\(index)", account: "example.com", path: kept.path, sha256: "")
        }
        await store.recordArchive(key: "web:gone", account: "example.com", path: root.appendingPathComponent("gone.jpg").path, sha256: "")
        let found = await store.archivedPaths(for: (0 ..< 1500).map { "web:\($0)" } + ["web:gone", "web:never"])
        XCTAssertEqual(found.count, 1500)
        XCTAssertNil(found["web:gone"])
        XCTAssertNil(found["web:never"])
    }

    /// Audit round 1 (C4, C27): a folder renamed while MediaPull runs keeps its record; a deleted folder's record goes.
    func testRecordsFollowRenamesAndForgetDeletedFolders() async throws {
        let records = root.appendingPathComponent("records")
        let store = AccountFolderStore(folder: records)
        let folder = root.appendingPathComponent("alice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = await store.record(account: "alice", folder: folder)
        await store.addKeys(["ig:9"], to: record.id)
        let renamed = root.appendingPathComponent("Alice (friend)")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let again = await store.record(account: "alice", folder: renamed)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(again.keys, ["ig:9"], "items deleted on purpose stay known after a rename in the Finder")
        try FileManager.default.removeItem(at: renamed)
        let reloaded = AccountFolderStore(folder: records)
        let left = await reloaded.all()
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty, "the record file is removed")
    }

    /// Audit round 1 (A3): a gallery file's metadata never records the working folder it was downloaded to.
    func testEngineSidecarsNeverRecordALocalPath() {
        var context = EngineContext(key: "deviantart:42", category: "deviantart", subcategory: "gallery")
        context.username = "artist"
        let staged = URL(fileURLWithPath: "/Users/someone/Library/Application Support/MediaPull/Staging/x/a.jpg")
        let variant = MediaVariant(id: staged.absoluteString, url: staged, format: .jpeg, origin: .img)
        let item = MediaItem(id: "k", kind: .image, variants: [variant],
                             source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        let info = FinalFileInfo(format: .jpeg, sha256: "ab", pixelSize: nil, duration: nil, sourceURL: staged, lastModified: nil,
                                 originalName: nil, note: nil)
        let target = SaveTarget(folder: root, layout: .archive, autoSubfolders: true)
        let first = ArchivePlanner.sidecar(for: item, info: info, target: target, settings: SaveSettings())
        XCTAssertNil(first.sourceURL)
        XCTAssertEqual(first.postID, ShortHash.of("deviantart:42"), "the same item keeps the same id on every run")
    }

    /// SPEC 6.3 (audit 2, B2-M2): records of files that are gone, and old accounts nothing refers to, are pruned.
    func testArchiveAndAccountsArePruned() async throws {
        let store = try AppStore.make(inMemory: true)
        let kept = file("pruned/a.jpg")
        await store.recordArchive(key: "ig:1", account: "alice", path: kept.path, sha256: "")
        await store.recordArchive(key: "web:2", account: "bob", path: root.appendingPathComponent("gone.jpg").path, sha256: "")
        await store.updateAccount("bob", lastResult: "x")
        await store.updateAccount("alice", lastResult: "x")
        await store.updateAccount("carol", lastResult: "x")
        await store.prune(keepAccounts: ["carol"], now: Date().addingTimeInterval(400 * 24 * 3600))
        let found = await store.archivedPaths(for: ["ig:1", "web:2"])
        XCTAssertEqual(Array(found.keys), ["ig:1"])
        let bob = await store.account("bob")
        let alice = await store.account("alice")
        let carol = await store.account("carol")
        XCTAssertNil(bob, "an old account with no saved file left is forgotten")
        XCTAssertNotNil(alice, "an account with a saved file stays")
        XCTAssertNotNil(carol, "an account with a remembered folder stays")
    }

    /// Audit round 2 (B2-M4, C2-m8, C2-M5): a change of letter case keeps the record; a folder in the Trash keeps it; a
    /// folder moved while running is found again before an update.
    func testRecordsSurviveCaseChangesTheTrashAndMoves() async throws {
        let records = root.appendingPathComponent("records")
        let store = AccountFolderStore(folder: records)
        let folder = root.appendingPathComponent("alice")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = await store.record(account: "alice", folder: folder)
        await store.addKeys(["ig:1"], to: record.id)
        let upper = root.appendingPathComponent("Alice")
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("tmp-move"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("tmp-move"), to: upper)
        let again = await store.record(account: "alice", folder: upper)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(again.keys, ["ig:1"])
        let moved = root.appendingPathComponent("Alice 2024")
        try FileManager.default.moveItem(at: upper, to: moved)
        let found = await store.currentFolder(for: upper)
        XCTAssertEqual(found?.lastPathComponent, "Alice 2024", "an update of the old path finds the folder where it is now")
        let trash = root.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: moved, to: trash.appendingPathComponent("Alice 2024"))
        let reloaded = AccountFolderStore(folder: records)
        let kept = await reloaded.record(account: "alice", folder: moved)
        XCTAssertEqual(kept.id, record.id, "a folder in the Trash keeps its record, in case it is put back")
    }

    /// Audit round 3 (C3-M1): what 1.7 remembered of a folder (files saved there, deleted since or not) is kept until the
    /// folder's record takes it over, so a first Update after upgrading never brings deleted files back.
    func testRecordsTakeOverWhatEarlierVersionsRemembered() async throws {
        let store = try AppStore.make(inMemory: true)
        let kept = file("old/alice/posts/a.jpg")
        await store.recordArchive(key: "ig:1", account: "alice", path: kept.path, sha256: "")
        await store.recordArchive(key: "ig:2", account: "alice", path: root.appendingPathComponent("old/alice/posts/deleted.jpg").path,
                                  sha256: "")
        await store.recordArchive(key: "ig:3", account: "alice", path: root.appendingPathComponent("elsewhere/x.jpg").path, sha256: "")
        await store.prune(keepAccounts: [])
        let taken = await store.takeInstagramKeys(account: "Alice", under: root.appendingPathComponent("old/alice").path)
        XCTAssertEqual(taken, ["ig:1", "ig:2"], "the deleted file is remembered too, and the prune kept it")
        let again = await store.takeInstagramKeys(account: "alice", under: root.appendingPathComponent("old/alice").path)
        XCTAssertEqual(again, ["ig:1"], "a handed-over entry of a deleted file is gone; the saved file's stays")
    }

    func testStoreRemembersKeysAndCursorPerFolder() async {
        let store = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let folder = root.appendingPathComponent("alice")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = await store.record(account: "Alice", folder: folder)
        await store.addKeys(["ig:1", "ig:2"], to: record.id)
        await store.setPlace(ResumePlace(cursor: "abc", untilEnd: false), in: record.id)
        let reloaded = AccountFolderStore(folder: root.appendingPathComponent("records"))
        let again = await reloaded.record(account: "alice", folder: folder)
        XCTAssertEqual(again.id, record.id)
        XCTAssertEqual(again.keys, ["ig:1", "ig:2"])
        XCTAssertEqual(again.places?.first?.cursor, "abc")
    }
}
