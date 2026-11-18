import Foundation
@testable import MediaPullCore
@testable import MediaPullEngines
@testable import MediaPullLibrary
import XCTest

/// What metadata files keep for the profile views (D-111) and what an account folder's record keeps (D-112).
final class PostDetailsTests: XCTestCase {
    private func sidecar(_ raw: [String: Any], subcategory: String) throws -> [String: Any] {
        let meta = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: raw))
        let context = EngineContext.from(meta: meta, key: "k", subcategory: subcategory, sourceURL: URL(string: "https://example.org/u"))
        let url = URL(string: "https://cdn.example.org/a.jpg")!
        let item = MediaItem(id: "k", kind: .image, variants: [MediaVariant(id: url.absoluteString, url: url, format: .jpeg, origin: .img)],
                             source: .engine(context), discoveryIndex: 0, group: "g", groupTitle: "t")
        let info = FinalFileInfo(format: .jpeg, sha256: "ab", pixelSize: nil, duration: nil, sourceURL: url, lastModified: nil,
                                 originalName: nil, note: nil)
        let target = SaveTarget(folder: URL(fileURLWithPath: "/tmp"), layout: .archive, autoSubfolders: true)
        let data = try ArchivePlanner.sidecar(for: item, info: info, target: target, settings: SaveSettings()).encoded()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInstagramPostsKeepTheirPlacePinAndCover() throws {
        let post = try sidecar(["category": "instagram", "username": "alice", "post_id": "1", "media_id": "2", "num": 1, "count": 1,
                                "description": "Sunset #beach", "location_name": "Santa Monica Pier", "location_id": "212988663",
                                "pinned": true], subcategory: "posts")
        XCTAssertEqual(post["location_name"] as? String, "Santa Monica Pier")
        XCTAssertEqual(post["location_id"] as? String, "212988663")
        XCTAssertEqual(post["pinned"] as? Bool, true)
        XCTAssertEqual(post["description"] as? String, "Sunset #beach")
        XCTAssertNil(post["highlight_cover"])
        // No place, no id; nothing pinned, no key.
        let plain = try sidecar(["category": "instagram", "username": "alice", "post_id": "1", "media_id": "3", "location_id": "9"],
                                subcategory: "posts")
        XCTAssertNil(plain["location_id"])
        XCTAssertNil(plain["pinned"])
        let cover = try sidecar(["category": "instagram", "username": "alice", "post_id": "17", "media_id": "17_cover",
                                 "highlight_title": "Trips", "highlight_cover": true], subcategory: "highlights")
        XCTAssertEqual(cover["highlight_cover"] as? Bool, true)
        XCTAssertEqual(cover["highlight_title"] as? String, "Trips")
    }

    func testOtherSitesKeepThePostsOwnText() throws {
        let tweet = try sidecar(["category": "twitter", "username": "bob", "post_id": "5", "description": "alt text of the picture",
                                 "post_text": "What a day"], subcategory: "user")
        XCTAssertEqual(tweet["description"] as? String, "What a day", "the post's text, not the picture's alt text")
        XCTAssertNil(tweet["location_name"], "only Instagram's place is kept")
        let reddit = try sidecar(["category": "reddit", "username": "carol", "post_id": "t3", "title": "My build",
                                  "post_text": "Parts list below", "community": "battlestations"], subcategory: "submission")
        XCTAssertEqual(reddit["description"] as? String, "Parts list below")
        XCTAssertEqual(reddit["title"] as? String, "My build")
        XCTAssertEqual(reddit["community"] as? String, "battlestations")
        // A title that is the description is not written twice.
        let pin = try sidecar(["category": "pinterest", "username": "dee", "post_id": "p", "title": "Kitchen"], subcategory: "board")
        XCTAssertEqual(pin["description"] as? String, "Kitchen")
        XCTAssertNil(pin["title"])
    }

    func testRecordsKeepTheProfileAndOldRecordsStillRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("alice"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountFolderStore(folder: folder.appendingPathComponent("records"))
        let record = await store.record(account: "alice", folder: folder.appendingPathComponent("alice"))
        XCTAssertNil(record.profile)
        let profile = AccountProfile(fullName: "Alice A", biography: "Photos", postCount: 120, followerCount: 3400, followingCount: 210,
                                     externalURL: "https://alice.example", isVerified: false, category: "Artist")
        await store.setProfile(profile, in: record.id)
        let again = AccountFolderStore(folder: folder.appendingPathComponent("records"))
        let read = await again.record(account: "alice", folder: folder.appendingPathComponent("alice"))
        XCTAssertEqual(read.profile, profile)
        // A record written before D-112 has no profile and still reads.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(read)) as? [String: Any] ?? [:]
        old["profile"] = nil
        let decoded = try JSONDecoder().decode(AccountFolderRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.profile)
        XCTAssertEqual(decoded.account, "alice")
    }
}
