import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullNet
import XCTest

final class SidecarTests: XCTestCase {
    func testInstagramSidecarMatchesContract() throws {
        var sidecar = Sidecar(category: "instagram", subcategory: "posts", username: "example.account", postID: "3008811223344556677")
        sidecar.author = "Example Account"
        sidecar.postShortcode = "CnAbCdEfGh"
        sidecar.num = 2
        sidecar.count = 3
        sidecar.date = Date(timeIntervalSince1970: 1_672_971_730)
        sidecar.description = "Morning walk #autumn"
        sidecar.postURL = "https://www.instagram.com/p/CnAbCdEfGh/"
        let data = try sidecar.encoded()
        let text = String(decoding: data, as: UTF8.self)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["date"] as? String, "2023-01-06 02:22:10")
        XCTAssertEqual(object["post_id"] as? String, "3008811223344556677")
        XCTAssertEqual(object["num"] as? Int, 2)
        XCTAssertEqual(object["count"] as? Int, 3)
        XCTAssertEqual(object["username"] as? String, "example.account")
        XCTAssertTrue(text.contains("https://www.instagram.com/p/CnAbCdEfGh/"), "Slashes must not be escaped")
        let keys = object.keys.sorted()
        let order = text.split(separator: "\n").compactMap { line -> String? in
            guard let start = line.firstIndex(of: "\""), let end = line[line.index(after: start)...].firstIndex(of: "\"") else { return nil }
            return String(line[line.index(after: start) ..< end])
        }
        XCTAssertEqual(order, keys, "Keys must be sorted")
    }

    func testNumAndCountComeTogether() throws {
        var sidecar = Sidecar(category: "example.com", subcategory: "page", username: "example.com", postID: "abc")
        sidecar.num = 1
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sidecar.encoded()) as? [String: Any])
        XCTAssertNil(object["num"])
        XCTAssertNil(object["count"])
    }

    func testDatesIgnoreUserCalendar() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DateFormats.sidecarString(date), "2023-11-14 22:13:20")
    }
}

final class NamingTests: XCTestCase {
    func testArchiveNamesNeverMatchForbiddenPattern() {
        for seconds in stride(from: 1_300_000_000, to: 1_800_000_000, by: 7_777_777) {
            var context = NameContext(date: Date(timeIntervalSince1970: TimeInterval(seconds)), index: 3)
            context.code = "Cabc_12-x"
            context.num = 1
            context.originalName = "photo"
            for template in [NameTemplate.archiveEngine, .archiveWeb, .archiveAvatar] {
                let name = template.render(context)
                XCTAssertFalse(FileNaming.isForbiddenArchiveName(name), name)
                XCTAssertNotNil(name.range(of: #"^\d{4}-\d{2}-\d{2}_"#, options: .regularExpression), name)
            }
        }
        XCTAssertTrue(FileNaming.isForbiddenArchiveName("2023-01-06_18-42-10_UTC.jpg"))
        XCTAssertFalse(NameTemplate("{yyyy}-{MM}-{dd}_{HH}-{mm}-{ss}_UTC").archiveProblems().isEmpty)
        XCTAssertTrue(NameTemplate.archiveEngine.archiveProblems().isEmpty)
    }

    func testReservedFoldersAndLengths() {
        XCTAssertEqual(FileNaming.safeTopFolder("media"), "_media")
        XCTAssertEqual(FileNaming.safeTopFolder("Your_Instagram_Activity"), "_Your_Instagram_Activity")
        XCTAssertEqual(FileNaming.safeTopFolder("nasa"), "nasa")
        let long = String(repeating: "é", count: 400)
        let name = FileNaming.fileName(stem: long, ext: "jpg")
        XCTAssertLessThanOrEqual(name.utf8.count + 5, 255)
        XCTAssertEqual(FileNaming.sanitize("../a/b:c"), "_a_b_c")
    }
}

final class CDNRuleTests: XCTestCase {
    func testNYTimesRendition() throws {
        let url = try XCTUnwrap(URL(string: "https://static01.nyt.com/images/2026/11/13/world/13int-abc/13int-abc-articleLarge.jpg?quality=75&auto=webp"))
        let candidates = CDNRules.candidates(for: url).map(\.url.absoluteString)
        XCTAssertEqual(candidates.first, "https://static01.nyt.com/images/2026/11/13/world/13int-abc/13int-abc-superJumbo.jpg")
        XCTAssertTrue(candidates.contains("https://static01.nyt.com/images/2026/11/13/world/13int-abc/13int-abc-articleLarge.jpg"))
        let other = try XCTUnwrap(URL(string: "https://static01.nyt.com/images/2026/11/13/world/13int-abc/13int-abc-threeByTwoMediumAt2X.jpg"))
        XCTAssertEqual(CDNRules.assetKey(for: url), CDNRules.assetKey(for: other))
        let versioned = try XCTUnwrap(URL(string: "https://static01.nyt.com/images/2018/a/author-x/author-x-thumbLarge-v3.png?quality=75&auto=avif"))
        XCTAssertEqual(CDNRules.candidates(for: versioned).first?.url.absoluteString,
                       "https://static01.nyt.com/images/2018/a/author-x/author-x-superJumbo-v3.png")
    }

    func testTwitterWordPressAndSigned() throws {
        let twitter = try XCTUnwrap(URL(string: "https://pbs.twimg.com/media/ABC123?format=jpg&name=small"))
        XCTAssertEqual(CDNRules.candidates(for: twitter).first?.url.absoluteString, "https://pbs.twimg.com/media/ABC123?format=jpg&name=orig")
        let wordpress = try XCTUnwrap(URL(string: "https://example.com/wp-content/uploads/2024/05/photo-1024x683.jpg"))
        XCTAssertEqual(CDNRules.candidates(for: wordpress).first?.url.absoluteString, "https://example.com/wp-content/uploads/2024/05/photo.jpg")
        let signed = try XCTUnwrap(URL(string: "https://scontent.cdninstagram.com/v/t51/abc.jpg?stp=dst-jpg&oh=1&oe=2"))
        XCTAssertTrue(CDNRules.candidates(for: signed).isEmpty)
        let wiki = try XCTUnwrap(URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/File.jpg/220px-File.jpg"))
        XCTAssertEqual(CDNRules.candidates(for: wiki).first?.url.absoluteString, "https://upload.wikimedia.org/wikipedia/commons/a/ab/File.jpg")
        let thumbScript = URL(string: "https://shop.example.com/ss26/squarethumb.php?src=products/A_WP/a_600_01.png")!
        XCTAssertEqual(CDNRules.candidates(for: thumbScript).first?.url.absoluteString, "https://shop.example.com/ss26/products/A_WP/a_600_01.png")
        let nextImage = URL(string: "https://site.example/_next/image?url=%2Fuploads%2Fhero.jpg&w=640&q=75")!
        XCTAssertEqual(CDNRules.proxiedTarget(of: nextImage)?.absoluteString, "https://site.example/uploads/hero.jpg")
        XCTAssertNil(CDNRules.proxiedTarget(of: URL(string: "https://site.example/page.php?src=home")!))
    }
}

final class SnifferTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(Sniffer.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])).format, .jpeg)
        XCTAssertEqual(Sniffer.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])).format, .png)
        var webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8L".utf8) + Data([0, 0, 0, 0])
        XCTAssertEqual(Sniffer.sniff(webp).webp?.lossless, true)
        webp = Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBPVP8 ".utf8) + Data([0, 0, 0, 0])
        XCTAssertEqual(Sniffer.sniff(webp).webp?.lossless, false)
        let mp4 = Data([0, 0, 0, 0x18]) + Data("ftypisom".utf8) + Data([0, 0, 0, 0]) + Data("isomiso2".utf8)
        XCTAssertEqual(Sniffer.sniff(mp4).format, .mp4)
        let avif = Data([0, 0, 0, 0x1C]) + Data("ftypavif".utf8) + Data([0, 0, 0, 0]) + Data("avifmif1miaf".utf8)
        XCTAssertEqual(Sniffer.sniff(avif).format, .avif)
        XCTAssertTrue(Sniffer.sniff(Data("<!DOCTYPE html><html>".utf8)).isMarkup)
        XCTAssertEqual(Sniffer.sniff(Data("#EXTM3U\n".utf8)).format, .hls)
    }
}

final class PolicyTests: XCTestCase {
    func testOnlyReadsAreAllowed() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a.jpg"))
        XCTAssertEqual(RequestPolicy.evaluate(method: "GET", url: url, headers: ["Accept": "*/*"], hasBody: false), .allowed)
        XCTAssertEqual(RequestPolicy.evaluate(method: "HEAD", url: url, headers: [:], hasBody: false), .allowed)
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            XCTAssertNotEqual(RequestPolicy.evaluate(method: method, url: url, headers: [:], hasBody: false), .allowed)
        }
        XCTAssertNotEqual(RequestPolicy.evaluate(method: "GET", url: url, headers: [:], hasBody: true), .allowed)
        XCTAssertNotEqual(RequestPolicy.evaluate(method: "GET", url: url, headers: ["Authorization": "x"], hasBody: false), .allowed)
        let file = try XCTUnwrap(URL(string: "file:///etc/passwd"))
        XCTAssertNotEqual(RequestPolicy.evaluate(method: "GET", url: file, headers: [:], hasBody: false), .allowed)
        let built = try RequestPolicy.urlRequest(for: .get(url, purpose: .save)).get()
        XCTAssertEqual(built.httpMethod, "GET")
        XCTAssertNil(built.httpBody)
        XCTAssertFalse(built.httpShouldHandleCookies)
    }
}

final class AddressTests: XCTestCase {
    func testClassification() {
        XCTAssertEqual(AddressInput.parse("@nasa"), .handle("nasa"))
        if case let .instagramPost(code, url) = AddressInput.parse("https://www.instagram.com/reel/DLxYzAbCdEf/?igsh=abc") {
            XCTAssertEqual(code, "DLxYzAbCdEf")
            XCTAssertEqual(url.absoluteString, "https://www.instagram.com/reel/DLxYzAbCdEf/")
        } else {
            XCTFail("Expected a post")
        }
        if case let .instagramProfile(name, _) = AddressInput.parse("instagram.com/nasa") {
            XCTAssertEqual(name, "nasa")
        } else {
            XCTFail("Expected a profile")
        }
        if case .web = AddressInput.parse("nytimes.com/international") {} else { XCTFail("Expected web") }
        XCTAssertEqual(AddressInput.parse("hello world"), .invalid)
        XCTAssertEqual(InstagramIDs.shortcode(fromID: InstagramIDs.id(fromShortcode: "CnAbCdEfGh") ?? ""), "CnAbCdEfGh")
    }

    func testRegistrableDomain() {
        XCTAssertEqual(PublicSuffix.shared.registrableDomain("static01.nyt.com"), "nyt.com")
        XCTAssertEqual(PublicSuffix.shared.registrableDomain("www.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(PublicSuffix.shared.registrableDomain("scontent-lax3-1.cdninstagram.com"), "cdninstagram.com")
    }
}

final class IngestorTests: XCTestCase {
    func testSrcsetCandidatesMergeAndRank() async throws {
        let ingestor = ExtractionIngestor(interval: .milliseconds(1))
        let page = try XCTUnwrap(URL(string: "https://example.com/gallery/"))
        let json = """
        {"v":1,"seq":1,"page":"https://example.com/gallery/","title":"Gallery","items":[
          {"u":"/img/a-400.jpg","k":"img","w":400,"h":300,"g":1},
          {"u":"/img/a-800.jpg","k":"srcset","d":"800w","g":1},
          {"u":"/img/a-1600.jpg","k":"srcset","d":"1600w","g":1},
          {"u":"https://cdn.example.com/b.mp4","k":"video","g":2},
          {"u":"https://cdn.example.com/b-poster.jpg","k":"poster"}
        ]}
        """
        await ingestor.ingest(json: json, frame: FrameInfo(frameURL: page, isMainFrame: true, origin: nil, pageURL: page, pageTitle: nil))
        let snapshot = await ingestor.snapshot()
        XCTAssertEqual(snapshot.items.count, 3)
        let image = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(image.variants.count, 3)
        XCTAssertEqual(image.best?.url.absoluteString, "https://example.com/img/a-1600.jpg")
        XCTAssertEqual(image.groupTitle, "Gallery")
        XCTAssertEqual(snapshot.items[1].kind, .video)
    }

    func testFilterHidesTinyAndMatchesSize() {
        let url = URL(string: "https://example.com/x.jpg")!
        let page = URL(string: "https://example.com/")!
        var variant = MediaVariant(id: url.absoluteString, url: url, format: .jpeg, origin: .img)
        variant.pixelSize = PixelSize(width: 40, height: 40)
        let tiny = MediaItem(id: "a", kind: .image, variants: [variant], source: .web(WebContext(pageURL: page)), discoveryIndex: 0,
                             group: "g", groupTitle: "t")
        let context = FilterContext(currentPage: page) { _ in .notSaved }
        XCTAssertFalse(MediaFilter().matches(tiny, context: context))
        var filter = MediaFilter()
        filter.hideTiny = false
        filter.hideIcons = false
        XCTAssertTrue(filter.matches(tiny, context: context))
        filter.minWidth = 100
        XCTAssertFalse(filter.matches(tiny, context: context))
    }
}

final class PaneArrangementTests: XCTestCase {
    func testMovesAndStacks() throws {
        var layout = PaneArrangement.standard
        XCTAssertEqual(layout.key, "source+downloads|extracted+preview|library")
        layout.move(.preview, .right)
        XCTAssertEqual(layout.key, "source+downloads|extracted|preview|library")
        layout.move(.library, .left)
        XCTAssertEqual(layout.key, "source+downloads|extracted|library|preview")
        XCTAssertFalse(layout.canMove(.preview, .right))
        layout.stack(.preview, onto: .left)
        XCTAssertEqual(layout.key, "source+downloads|extracted|library+preview")
        layout.moveInStack(.preview, .up)
        XCTAssertEqual(layout.key, "source+downloads|extracted|preview+library")
        layout.move(.downloads, .right)
        XCTAssertEqual(layout.key, "source|downloads|extracted|preview+library")
    }

    func testDecodingRepairsMissingAndDuplicatePanes() throws {
        let data = Data(#"[["source","source"],["extracted"],["bogus"],["organiseWork"]]"#.utf8)
        let layout = try JSONDecoder().decode(PaneArrangement.self, from: data)
        XCTAssertEqual(layout.key, "source+downloads|extracted+preview|library", "organise panes never join the collect panes")
        let round = try JSONDecoder().decode(PaneArrangement.self, from: JSONEncoder().encode(PaneArrangement.previewColumn))
        XCTAssertEqual(round, .previewColumn)
    }

    func testOrganiseArrangementsHoldOnlyOrganisePanes() throws {
        XCTAssertEqual(PaneArrangement.organiseStandard.key, "organiseSource|organiseWork|organiseTarget")
        XCTAssertEqual(PaneArrangement.organiseStandard.group, .organise)
        let data = Data(#"[["organiseTarget"],["library"]]"#.utf8)
        let layout = try JSONDecoder().decode(PaneArrangement.self, from: data)
        XCTAssertEqual(layout.key, "organiseTarget|organiseSource|organiseWork")
    }
}

final class BrowsingDataTests: XCTestCase {
    func testBookmarksAndFolders() throws {
        var bookmarks = BookmarkCollection()
        XCTAssertEqual(bookmarks.folders.map(\.name), ["Favourites"])
        let page = try XCTUnwrap(URL(string: "https://example.com/gallery/#top"))
        let first = bookmarks.add(title: "  Gallery ", url: page)
        XCTAssertEqual(first.title, "Gallery")
        XCTAssertEqual(bookmarks.add(title: "Again", url: try XCTUnwrap(URL(string: "https://example.com/gallery"))).id, first.id)
        let folder = bookmarks.addFolder(named: "Shoots")
        XCTAssertNotEqual(bookmarks.addFolder(named: "shoots"), folder)
        XCTAssertEqual(bookmarks.folders.last?.name, "shoots 2")
        bookmarks.move(first.id, to: folder)
        XCTAssertEqual(bookmarks.bookmark(for: page)?.folder.id, folder)
        bookmarks.renameFolder(folder, to: "Summer shoots")
        XCTAssertEqual(bookmarks.folders[1].name, "Summer shoots")
        bookmarks.renameFolder(folder, to: "   ")
        XCTAssertEqual(bookmarks.folders[1].name, "Summer shoots")
        bookmarks.removeFolder(folder)
        XCTAssertNil(bookmarks.bookmark(for: page))
        let round = try JSONDecoder().decode(BookmarkCollection.self, from: JSONEncoder().encode(bookmarks))
        XCTAssertEqual(round, bookmarks)
    }

    func testHistoryRecordsOncePerAddressAndClears() throws {
        var history = BrowsingHistory()
        let now = Date()
        let a = try XCTUnwrap(URL(string: "https://a.example/"))
        let b = try XCTUnwrap(URL(string: "https://b.example/page"))
        history.record(a, title: "A", at: now.addingTimeInterval(-7200))
        history.record(b, title: "B", at: now.addingTimeInterval(-60))
        history.record(a, title: "", at: now)
        history.record(try XCTUnwrap(URL(string: "about:blank")), title: "")
        XCTAssertEqual(history.entries.map(\.title), ["A", "B"])
        XCTAssertEqual(history.entries.first?.visits, 2)
        XCTAssertEqual(history.matching("b.exa").count, 1)
        history.clear(since: now.addingTimeInterval(-3600))
        XCTAssertTrue(history.entries.isEmpty)
        history.record(b, title: "B")
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }
}

final class VideoDownloadTests: XCTestCase {
    /// Shaped like a real listing: H.264 up to 1080p, VP9 and AV1 up to 2160p, AAC and Opus audio.
    private let formats: [VideoFormatInfo] = [
        VideoFormatInfo(id: "299", ext: "mp4", height: 1080, fps: 60, vcodec: "avc1.64002A", acodec: "none", tbr: 4500, size: 250_000_000),
        VideoFormatInfo(id: "298", ext: "mp4", height: 720, fps: 60, vcodec: "avc1.4D4020", acodec: "none", tbr: 2500, size: 120_000_000),
        VideoFormatInfo(id: "315", ext: "webm", height: 2160, fps: 60, vcodec: "vp9", acodec: "none", tbr: 20000, size: 1_500_000_000),
        VideoFormatInfo(id: "401", ext: "mp4", height: 2160, fps: 60, vcodec: "av01.0.13M.0", acodec: "none", tbr: 18000),
        VideoFormatInfo(id: "303", ext: "webm", height: 1080, fps: 60, vcodec: "vp9", acodec: "none", tbr: 4000, size: 220_000_000),
        VideoFormatInfo(id: "140", ext: "m4a", vcodec: "none", acodec: "mp4a.40.2", abr: 129, size: 10_000_000),
        VideoFormatInfo(id: "251", ext: "webm", vcodec: "none", acodec: "opus", abr: 129, size: 9_000_000),
        VideoFormatInfo(id: "drm", ext: "mp4", height: 4320, vcodec: "avc1", acodec: "none", drm: true),
    ]

    func testResolutionsPerFormat() {
        XCTAssertEqual(VideoDownloadFormat.bestMP4.heights(in: formats), [2160, 1080, 720])
        XCTAssertEqual(VideoDownloadFormat.h264MP4.heights(in: formats), [1080, 720], "protected formats are never offered")
        XCTAssertEqual(VideoDownloadFormat.webm.heights(in: formats), [2160, 1080])
        XCTAssertEqual(VideoDownloadFormat.audioM4A.heights(in: formats), [])
    }

    func testSelectorsSizesAndConversion() {
        XCTAssertEqual(VideoDownloadFormat.h264MP4.selector(height: 720).format, "bv*[vcodec^=avc1][height<=720]+ba[acodec^=mp4a]/b[vcodec^=avc1][height<=720]")
        XCTAssertEqual(VideoDownloadFormat.bestMP4.selector(height: nil).format, "bv*+ba/b")
        XCTAssertEqual(VideoDownloadFormat.webm.selector(height: 1080).merge, "webm")
        XCTAssertNil(VideoDownloadFormat.audioM4A.selector(height: nil).merge)
        XCTAssertEqual(VideoDownloadFormat.h264MP4.estimatedBytes(in: formats, height: 1080), 260_000_000)
        XCTAssertEqual(VideoDownloadFormat.webm.estimatedBytes(in: formats, height: nil), 1_509_000_000)
        XCTAssertEqual(VideoDownloadFormat.audioM4A.estimatedBytes(in: formats, height: nil), 10_000_000)
        let withoutVP9 = formats.filter { $0.id != "315" }
        XCTAssertNil(VideoDownloadFormat.originalMP4.estimatedBytes(in: withoutVP9, height: nil), "the AV1 stream reports no size")
        XCTAssertEqual(VideoDownloadFormat.originalMP4.estimatedBytes(in: withoutVP9, height: nil, duration: 100), 225_000_000 + 10_000_000,
                       "18,000 kbit/s for 100 s, plus the audio")
        XCTAssertTrue(VideoDownloadFormat.bestMP4.needsConversion(in: formats, height: 2160), "4K exists only as VP9 or AV1")
        XCTAssertFalse(VideoDownloadFormat.bestMP4.needsConversion(in: formats, height: 1080), "1080p exists as H.264")
        XCTAssertFalse(VideoDownloadFormat.originalMP4.needsConversion(in: formats, height: 2160))
        XCTAssertFalse(VideoDownloadFormat.bestMP4.keepsDownloadedFile)
        XCTAssertTrue(VideoDownloadFormat.webm.keepsDownloadedFile)
    }

    func testVideoPagesAndDates() throws {
        for page in ["https://www.youtube.com/watch?v=aqz-KE-bpKQ", "https://youtu.be/aqz-KE-bpKQ", "https://www.youtube.com/shorts/abc",
                     "https://vimeo.com/76979871", "https://www.dailymotion.com/video/x8abc"] {
            XCTAssertTrue(VideoPage.isLikely(URL(string: page)), page)
        }
        for page in ["https://www.youtube.com/", "https://www.youtube.com/@Blender", "https://vimeo.com/channels/staffpicks", "https://example.com/watch"] {
            XCTAssertFalse(VideoPage.isLikely(URL(string: page)), page)
        }
        let date = try XCTUnwrap(VideoInfo.date(uploadDate: "20141110", timestamp: nil))
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2014-11-10T00:00:00Z")
    }
}
