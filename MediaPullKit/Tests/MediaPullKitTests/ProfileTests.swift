import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

/// Profile views (D-113, SPEC section 40): which folders they show and how files become posts.
final class ProfileTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("profiles-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func file(_ path: String, _ meta: [String: Any]?) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        if let meta { try JSONSerialization.data(withJSONObject: meta).write(to: Sidecar.sidecarURL(for: url)) }
        return url
    }

    private func ig(_ sub: String, post: String, num: Int = 1, count: Int = 1, date: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["category": "instagram", "subcategory": sub, "username": "alice", "post_id": post, "media_id": "\(post)\(num)", "num": num,
         "count": count, "date": date].merging(extra) { $1 }
    }

    private func aliceFolder(_ name: String = "alice") throws -> URL {
        try file("\(name)/posts/a2.jpg", ig("posts", post: "p1", num: 2, count: 3, date: "2024-01-01 10:00:00"))
        try file("\(name)/posts/a1.jpg", ig("posts", post: "p1", num: 1, count: 3, date: "2024-01-01 10:00:00",
                                           extra: ["description": "Beach day", "location_name": "Bondi Beach"]))
        try file("\(name)/posts/b.jpg", ig("posts", post: "p2", date: "2024-03-01 10:00:00"))
        try file("\(name)/posts/old.jpg", ig("posts", post: "p0", date: "2023-01-01 10:00:00", extra: ["pinned": true]))
        try file("\(name)/reels/r.mp4", ig("reels", post: "r1", date: "2024-02-01 10:00:00",
                                     extra: ["product_type": "clips", "duration": 12.5]))
        try file("\(name)/tagged/t.jpg", ig("posts", post: "t1", date: "2024-02-02 10:00:00",
                                     extra: ["username": "alice", "owner_username": "bob"]))
        try file("\(name)/reposts/s.jpg", ig("posts", post: "s1", date: "2024-02-03 10:00:00"))
        try file("\(name)/stories/s1.jpg", ig("stories", post: "st1", date: "2024-05-01 09:00:00"))
        try file("\(name)/stories/s2.mp4", ig("stories", post: "st2", date: "2024-05-01 08:00:00"))
        try file("\(name)/stories/s3.jpg", ig("stories", post: "st3", date: "2024-04-01 09:00:00"))
        try file("\(name)/highlights/Trips/c.jpg", ig("highlights", post: "h1", date: "2024-01-05 09:00:00",
                                                    extra: ["highlight_title": "Trips", "media_id": "h1_cover", "highlight_cover": true]))
        try file("\(name)/highlights/Trips/1.jpg", ig("highlights", post: "h1", date: "2024-01-03 09:00:00",
                                     extra: ["highlight_title": "Trips"]))
        try file("\(name)/highlights/Food/1.jpg", ig("highlights", post: "h2", date: "2024-01-04 09:00:00",
                                     extra: ["highlight_title": "Food"]))
        try file("\(name)/profile pictures/new.jpg", ig("avatar", post: "av2", date: "2024-06-01 00:00:00", extra: ["author": "Alice A"]))
        try file("\(name)/profile pictures/old.jpg", ig("avatar", post: "av1", date: "2022-06-01 00:00:00"))
        try file("\(name)/Account details/2024-06-01_followers.csv", nil)
        return root.appendingPathComponent(name)
    }

    func testAnInstagramFolderBecomesItsProfile() throws {
        let folder = try aliceFolder()
        let source = try XCTUnwrap(ProfileDetector.detect(folder))
        XCTAssertEqual(source.kind, .profile)
        XCTAssertEqual(source.sources.map(\.name), ["alice"])
        let built = ProfileBuilder.build(source.sources[0], kind: .profile).content
        guard case let .profile(profile) = built else { return XCTFail("unexpected content") }
        XCTAssertEqual(profile.posts.map(\.id), ["post:p0", "post:p2", "post:p1"], "pinned first, then newest")
        let carousel = try XCTUnwrap(profile.posts.last)
        XCTAssertEqual(carousel.media.map(\.url.lastPathComponent), ["a1.jpg", "a2.jpg"], "by number, never by count")
        XCTAssertEqual(carousel.text, "Beach day")
        XCTAssertEqual(carousel.place, "Bondi Beach")
        XCTAssertTrue(profile.posts[0].pinned)
        XCTAssertEqual(profile.reels.map(\.id), ["reel:r1"])
        XCTAssertEqual(profile.reels.first?.duration, 12.5)
        XCTAssertEqual(profile.tagged.count, 1)
        XCTAssertEqual(profile.reposts.count, 1)
        XCTAssertEqual(profile.highlights.map(\.title), ["Trips", "Food"])
        XCTAssertEqual(profile.highlights[0].cover?.url.lastPathComponent, "c.jpg", "the saved cover")
        XCTAssertEqual(profile.highlights[0].items.map(\.url.lastPathComponent), ["1.jpg"])
        XCTAssertEqual(profile.highlights[1].cover?.url.lastPathComponent, "1.jpg", "else the first item")
        XCTAssertEqual(profile.storyDays.count, 2)
        XCTAssertEqual(profile.storyDays[0].items.map(\.url.lastPathComponent), ["s2.mp4", "s1.jpg"], "a day's stories in order")
        XCTAssertEqual(profile.avatars.map(\.url.lastPathComponent), ["new.jpg", "old.jpg"])
        XCTAssertEqual(profile.fullName, "Alice A")
    }

    func testAFlatFolderIsSortedByItsMetadata() throws {
        try file("flat/a.jpg", ig("posts", post: "p1", date: "2024-01-01 10:00:00"))
        try file("flat/r.mp4", ig("reels", post: "r1", date: "2024-01-02 10:00:00"))
        try file("flat/c.mp4", ig("posts", post: "c1", date: "2024-01-03 10:00:00", extra: ["product_type": "clips"]))
        try file("flat/s.jpg", ig("stories", post: "s1", date: "2024-01-04 10:00:00"))
        let ref = ProfileRef(folder: root.appendingPathComponent("flat"), name: "alice", site: "instagram")
        guard case let .profile(profile) = ProfileBuilder.build(ref, kind: .profile).content else { return XCTFail("unexpected content") }
        XCTAssertEqual(profile.posts.map(\.id), ["post:p1"])
        XCTAssertEqual(Set(profile.reels.map(\.id)), ["reel:r1", "reel:c1"])
        XCTAssertEqual(profile.storyDays.count, 1)
        // Without metadata, the folder says what it is.
        try file("plain/reels/x.mp4", nil)
        try file("plain/posts/y.jpg", nil)
        let plain = ProfileRef(folder: root.appendingPathComponent("plain"), name: "alice", site: "instagram")
        guard case let .profile(bare) = ProfileBuilder.build(plain, kind: .profile).content else { return XCTFail("unexpected content") }
        XCTAssertEqual(bare.reels.count, 1)
        XCTAssertEqual(bare.posts.count, 1)
    }

    func testAFolderOfAccountsAndOtherSites() throws {
        _ = try aliceFolder("accounts/alice")
        try file("accounts/bob/posts/b.jpg", ig("posts", post: "q", date: "2024-01-01 10:00:00", extra: ["username": "bob"]))
        let source = try XCTUnwrap(ProfileDetector.detect(root.appendingPathComponent("accounts")))
        XCTAssertEqual(source.kind, .profile)
        XCTAssertEqual(source.sources.map(\.name), ["alice", "bob"])

        for index in 1 ... 3 {
            try file("X/v\(index).mp4", ["category": "youtube", "subcategory": "video", "username": "X", "post_id": "v\(index)",
                                         "date": "2024-01-0\(index) 10:00:00", "title": "Video \(index)", "description": "About \(index)",
                                         "playlist_title": index < 3 ? "Trips" : nil, "playlist_index": 3 - index, "duration": 60]
                    .compactMapValues { $0 })
        }
        try file("X/v1.jpg", nil)
        let channel = try XCTUnwrap(ProfileDetector.detect(root.appendingPathComponent("X")))
        XCTAssertEqual(channel.kind, .channel)
        let builtChannel = ProfileBuilder.build(channel.sources[0], kind: .channel).content
        guard case let .channel(videos) = builtChannel else { return XCTFail("unexpected content") }
        XCTAssertEqual(videos.videos.map(\.title), ["Video 3", "Video 2", "Video 1"])
        XCTAssertEqual(videos.videos.last?.thumbnail?.lastPathComponent, "v1.jpg")
        XCTAssertEqual(videos.videos.last?.text, "About 1")
        XCTAssertEqual(videos.playlists.map(\.title), ["Trips"])
        XCTAssertEqual(videos.playlists[0].videos.map(\.title), ["Video 2", "Video 1"], "in the playlist's order")
        XCTAssertEqual(videos.totalDuration, 180)

        try file("sub/1.jpg", ["category": "reddit", "subcategory": "subreddit", "username": "u1", "community": "pics", "post_id": "a",
                               "date": "2024-01-01 10:00:00", "description": "Hello", "title": "First"])
        try file("sub/2.jpg", ["category": "reddit", "subcategory": "subreddit", "username": "u2", "community": "pics", "post_id": "b",
                               "date": "2024-01-02 10:00:00"])
        let reddit = try XCTUnwrap(ProfileDetector.detect(root.appendingPathComponent("sub")))
        XCTAssertEqual(reddit.kind, .timeline)
        XCTAssertEqual(reddit.sources.first?.name, "pics", "a subreddit's files name their community")
        let builtFeed = ProfileBuilder.build(reddit.sources[0], kind: .timeline).content
        guard case let .feed(feed) = builtFeed else { return XCTFail("unexpected content") }
        XCTAssertEqual(feed.posts.map(\.id), ["item:b", "item:a"])
        XCTAssertEqual(feed.posts.last?.title, "First")
        XCTAssertEqual(feed.posts.last?.text, "Hello")

        try file("board/1.jpg", ["category": "pinterest", "subcategory": "board", "username": "dee", "post_id": "1"])
        XCTAssertEqual(ProfileDetector.detect(root.appendingPathComponent("board"))?.kind, .board)
    }

    func testMixedAndPlainFoldersAreNotProfiles() throws {
        try file("mixed/a.jpg", ["category": "twitter", "username": "a", "post_id": "1"])
        try file("mixed/b.jpg", ["category": "twitter", "username": "b", "post_id": "2"])
        try file("mixed/c.jpg", ["category": "pinterest", "username": "c", "post_id": "3"])
        XCTAssertNil(ProfileDetector.single(root.appendingPathComponent("mixed")))
        try file("photos/a.jpg", nil)
        XCTAssertNil(ProfileDetector.detect(root.appendingPathComponent("photos")))
        try file("web/a.jpg", ["category": "example.com", "subcategory": "page", "username": "example.com", "post_id": "1"])
        XCTAssertNil(ProfileDetector.detect(root.appendingPathComponent("web")))
    }

    func testAUserWhoPostsInManyCommunitiesIsTheirOwnFeed() throws {
        for (index, community) in ["pics", "cats", "food", "art", "cars"].enumerated() {
            try file("u/\(index).jpg", ["category": "reddit", "subcategory": "user", "username": "dana", "community": community,
                                         "post_id": "p\(index)", "date": "2024-01-0\(index + 1) 10:00:00"])
        }
        let source = try XCTUnwrap(ProfileDetector.detect(root.appendingPathComponent("u")))
        XCTAssertEqual(source.kind, .timeline)
        XCTAssertEqual(source.sources.map(\.name), ["dana"])
        // A site name that is empty never makes a source.
        try file("blank/1.jpg", ["category": "", "subcategory": "user", "username": "x", "post_id": "1"])
        XCTAssertNil(ProfileDetector.single(root.appendingPathComponent("blank")))
    }

    func testFilesWithoutAPostIDAreGroupedByAuthorMomentAndText() throws {
        let meta: [String: Any] = ["category": "twitter", "subcategory": "tweet", "username": "ed", "date": "2024-01-01 10:00:00",
                                   "description": "Two pictures"]
        try file("x/1.jpg", meta.merging(["num": 1]) { $1 })
        try file("x/2.jpg", meta.merging(["num": 2]) { $1 })
        try file("x/3.jpg", meta.merging(["date": "2024-01-02 10:00:00", "description": "Another"]) { $1 })
        let source = try XCTUnwrap(ProfileDetector.detect(root.appendingPathComponent("x")))
        guard case let .feed(feed) = ProfileBuilder.build(source.sources[0], kind: .timeline).content else {
            return XCTFail("unexpected content")
        }
        XCTAssertEqual(feed.posts.map(\.media.count), [1, 2])
    }

    func testAHighlightTitledByItsFolderKeepsItsCase() throws {
        try file("alice/highlights/New York/1.jpg", ig("highlights", post: "h1", date: "2024-01-03 09:00:00"))
        try file("alice/posts/a.jpg", ig("posts", post: "p1", date: "2024-01-01 10:00:00"))
        let ref = ProfileRef(folder: root.appendingPathComponent("alice"), name: "alice", site: "instagram")
        guard case let .profile(profile) = ProfileBuilder.build(ref, kind: .profile).content else { return XCTFail("unexpected content") }
        XCTAssertEqual(profile.highlights.map(\.title), ["New York"])
    }

    func testTheLimitIsSaid() throws {
        let folder = try aliceFolder()
        let ref = ProfileRef(folder: folder, name: "alice", site: "instagram")
        XCTAssertTrue(ProfileBuilder.build(ref, kind: .profile, limit: 3).limited)
        XCTAssertFalse(ProfileBuilder.build(ref, kind: .profile).limited)
    }
}
