import Foundation
@testable import MediaPullCore
@testable import MediaPullMedia
import XCTest

/// Image-host rules not covered elsewhere (Appendix D), and which hosts count as trackers.
final class MoreCDNRuleTests: XCTestCase {
    func testRulesTable() throws {
        let cases: [(String, String?)] = [
            ("https://i.pinimg.com/236x/ab/cd/ef/abcdef.jpg", "https://i.pinimg.com/originals/ab/cd/ef/abcdef.jpg"),
            ("https://cdn.shopify.com/s/files/1/0001/products/shirt_400x400.jpg?v=123&width=400",
             "https://cdn.shopify.com/s/files/1/0001/products/shirt.jpg?v=123"),
            ("https://i0.wp.com/example.com/a.jpg?resize=300%2C200&ssl=1", "https://i0.wp.com/example.com/a.jpg?ssl=1"),
        ]
        for (input, expected) in cases {
            let url = try XCTUnwrap(URL(string: input))
            XCTAssertEqual(CDNRules.candidates(for: url).first?.url.absoluteString, expected, input)
        }
        // A signed Cloudinary address is never rewritten.
        let signed = try XCTUnwrap(URL(string: "https://res.cloudinary.com/demo/image/upload/s--abc123--/w_300/cat.jpg"))
        XCTAssertFalse(CDNRules.candidates(for: signed).contains { $0.rule == "cloudinary" })
    }

    func testWordPressRenditionsShareOneAsset() throws {
        let sized = try XCTUnwrap(URL(string: "https://example.com/wp-content/uploads/2024/05/photo-1024x683.jpg"))
        let scaled = try XCTUnwrap(URL(string: "https://example.com/wp-content/uploads/2024/05/photo-scaled.jpg"))
        let original = try XCTUnwrap(URL(string: "https://example.com/wp-content/uploads/2024/05/photo.jpg"))
        XCTAssertNotNil(CDNRules.assetKey(for: sized))
        XCTAssertEqual(CDNRules.assetKey(for: sized), CDNRules.assetKey(for: scaled))
        XCTAssertEqual(CDNRules.assetKey(for: sized), CDNRules.assetKey(for: original))
    }

    func testTrackersMatchWholeDomains() throws {
        XCTAssertTrue(ExtractionIngestor.isTracker(try XCTUnwrap(URL(string: "https://js-agent.newrelic.com/a.gif"))))
        XCTAssertTrue(ExtractionIngestor.isTracker(try XCTUnwrap(URL(string: "https://s.pinimg.com/ct/lite.js"))))
        XCTAssertFalse(ExtractionIngestor.isTracker(try XCTUnwrap(URL(string: "https://newrelic.company.com/photo.jpg"))))
        XCTAssertFalse(ExtractionIngestor.isTracker(try XCTUnwrap(URL(string: "https://i.pinimg.com/originals/a.jpg"))))
    }
}

/// How found pictures merge and how a check of a guessed original is applied (R-910, R-913).
final class IngestorCheckTests: XCTestCase {
    private let page = URL(string: "https://example.com/post/")!

    private func ingest(_ items: String) async -> (ExtractionIngestor, [MediaItem]) {
        let ingestor = ExtractionIngestor(interval: .milliseconds(1))
        let json = #"{"v":1,"page":"https://example.com/post/","items":["# + items + "]}"
        await ingestor.ingest(json: json, frame: FrameInfo(frameURL: page, isMainFrame: true, origin: nil, pageURL: page, pageTitle: nil))
        return (ingestor, await ingestor.snapshot().items)
    }

    func testRenditionsInDifferentElementsMerge() async {
        let (_, items) = await ingest("""
        {"u":"/wp-content/uploads/2024/05/photo-1024x683.jpg","k":"img","w":1024,"h":683},
        {"u":"/wp-content/uploads/2024/05/photo-300x200.jpg","k":"img","w":300,"h":200}
        """)
        XCTAssertEqual(items.count, 1)
    }

    func testSmallerGuessedOriginalIsRejected() async throws {
        let (ingestor, items) = await ingest(#"{"u":"/wp-content/uploads/2024/05/photo-1024x683.jpg","k":"img","w":1024,"h":683}"#)
        let item = try XCTUnwrap(items.first)
        let derived = try XCTUnwrap(item.variants.first { $0.isDerived })
        await ingestor.apply(probe: ProbeResult(format: .jpeg, pixelSize: PixelSize(width: 800, height: 533)), itemID: item.id,
                             variantID: derived.id)
        let snapshot = await ingestor.snapshot()
        let after = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(after.variants.first { $0.id == derived.id }?.check, .failed(1))
        XCTAssertFalse(after.best?.isDerived ?? true, "the found picture stays the one saved")
    }

    func testPageInsteadOfPictureFailsTheVariant() async throws {
        let (ingestor, items) = await ingest(#"{"u":"/img/a.jpg","k":"img","w":400,"h":300}"#)
        let item = try XCTUnwrap(items.first)
        let variant = try XCTUnwrap(item.variants.first)
        await ingestor.apply(probe: ProbeResult(isMarkup: true), itemID: item.id, variantID: variant.id)
        let snapshot = await ingestor.snapshot()
        let after = try XCTUnwrap(snapshot.items.first)
        XCTAssertEqual(after.variants.first?.check, .failed(0))
    }

    func testInlineSVGIsADrawing() async {
        // Data addresses under 4 KB are placeholders and skipped; a real drawing is longer.
        let svg = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E%3C!--" + String(repeating: "x", count: 4200)
            + "--%3E%3C/svg%3E"
        let (_, items) = await ingest(#"{"u":""# + svg + #"","k":"data","w":200,"h":200}"#)
        XCTAssertEqual(items.first?.kind, .vector)
    }

    /// R-905: the page address a batch reports is believed only within the frame's own origin.
    func testBatchPageMustMatchTheFrameOrigin() async {
        let ingestor = ExtractionIngestor(interval: .milliseconds(1))
        let item = #"{"u":"https://cdn.example.com/a.jpg","k":"img","w":400,"h":300}"#
        let spoofed = #"{"v":1,"page":"https://bank.example.net/","items":["# + item + "]}"
        await ingestor.ingest(json: spoofed, frame: FrameInfo(frameURL: page, isMainFrame: true, origin: nil, pageURL: page, pageTitle: nil))
        let items = await ingestor.snapshot().items
        XCTAssertEqual(items.first?.source.pageURL, page)
    }

    /// 1.8 audit: an inline image is identified by a short hash, and a page cannot list more than the inline budget.
    func testInlineImagesUseShortIDsAndABudget() async {
        let ingestor = ExtractionIngestor(interval: .milliseconds(1), inlineBudget: 64 << 10)
        let size = 6 << 10
        var entries: [String] = []
        for index in 0 ..< 12 {
            let body = String(repeating: String(UnicodeScalar(UInt8(65 + index))), count: size)
            entries.append(#"{"u":"data:image/png;base64,"# + body + #"","k":"data","w":2000,"h":2000}"#)
        }
        let json = #"{"v":1,"page":"https://example.com/post/","items":["# + entries.joined(separator: ",") + "]}"
        await ingestor.ingest(json: json, frame: FrameInfo(frameURL: page, isMainFrame: true, origin: nil, pageURL: page, pageTitle: nil))
        let items = await ingestor.snapshot().items
        XCTAssertEqual(items.count, (64 << 10) / size, "inline images beyond the budget are not listed")
        XCTAssertTrue(items.allSatisfy { $0.id.count < 64 && $0.variants.allSatisfy { $0.id.count < 64 } })
    }
}

/// File types from their first bytes, including short and unusual files.
final class SnifferCoverageTests: XCTestCase {
    private func ftyp(_ brand: String) -> Data {
        Data([0, 0, 0, 0x18]) + Data("ftyp".utf8) + Data(brand.utf8) + Data(count: 12)
    }

    func testContainerBrands() {
        XCTAssertEqual(Sniffer.sniff(ftyp("qt  ")).format, .mov)
        XCTAssertEqual(Sniffer.sniff(ftyp("M4A ")).format, .m4a)
        XCTAssertEqual(Sniffer.sniff(ftyp("heic")).format, .heic)
    }

    func testAnimatedPNGAndWebPWithAlpha() {
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let length = UInt32(body.count)
            return [UInt8(length >> 24), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
                + Array(type.utf8) + body + [0, 0, 0, 0]
        }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let ihdr = chunk("IHDR", [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])
        let apng = Sniffer.sniff(Data(signature + ihdr + chunk("acTL", [0, 0, 0, 2, 0, 0, 0, 0])))
        XCTAssertEqual(apng.format, .png)
        XCTAssertTrue(apng.isAnimatedPNG)
        XCTAssertFalse(Sniffer.sniff(Data(signature + ihdr + chunk("IDAT", [0]))).isAnimatedPNG)

        // VP8X with the alpha flag, then a lossy VP8 chunk.
        var webp = Array("RIFF".utf8) + [0x40, 0, 0, 0] + Array("WEBP".utf8)
        webp += Array("VP8X".utf8) + [10, 0, 0, 0] + [0x10, 0, 0, 0] + [0, 0, 0, 0, 0, 0]
        webp += Array("VP8 ".utf8) + [10, 0, 0, 0] + Array(repeating: 0, count: 10)
        let info = Sniffer.sniff(Data(webp))
        XCTAssertEqual(info.format, .webp)
        XCTAssertEqual(info.webp?.alpha, true)
        XCTAssertEqual(info.webp?.lossless, false)
    }

    /// Every prefix of real headers is read without a crash (files are often cut short).
    func testTruncatedHeadersNeverCrash() {
        let headers: [[UInt8]] = [
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52],
            [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46],
            Array("RIFF".utf8) + [0x40, 0, 0, 0] + Array("WEBPVP8X".utf8) + [10, 0, 0, 0, 0x10],
            [0, 0, 0, 0x18] + Array("ftypheic".utf8),
            Array("GIF89a".utf8),
        ]
        for header in headers {
            for length in 0 ... header.count {
                _ = Sniffer.sniff(Data(header.prefix(length)))
            }
        }
    }
}

/// Video lengths from the movie header: version 1 boxes, and an unknown length is no length.
final class MovieHeaderTests: XCTestCase {
    private func mvhd(version: UInt8, timescale: UInt32, duration: UInt64) -> [UInt8] {
        func be32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (24 - 8 * $0)) } }
        func be64(_ value: UInt64) -> [UInt8] { (0 ..< 8).map { UInt8(truncatingIfNeeded: value >> (56 - 8 * $0)) } }
        if version == 1 {
            return [1, 0, 0, 0] + be64(0) + be64(0) + be32(timescale) + be64(duration) + Array(repeating: 0, count: 80)
        }
        return [0, 0, 0, 0] + be32(0) + be32(0) + be32(timescale) + be32(UInt32(truncatingIfNeeded: duration))
            + Array(repeating: 0, count: 80)
    }

    func testLengths() {
        let long = mvhd(version: 1, timescale: 1000, duration: 7_200_000)
        XCTAssertEqual(MP4Probe.parseMVHD(long, 0 ..< long.count), 7200)
        let short = mvhd(version: 0, timescale: 600, duration: 1200)
        XCTAssertEqual(MP4Probe.parseMVHD(short, 0 ..< short.count), 2)
        // A fragmented MP4 keeps its length in the fragments: zero or all ones in the header means unknown.
        let fragmented = mvhd(version: 0, timescale: 600, duration: 0)
        XCTAssertNil(MP4Probe.parseMVHD(fragmented, 0 ..< fragmented.count))
        let unknown = mvhd(version: 1, timescale: 1000, duration: .max)
        XCTAssertNil(MP4Probe.parseMVHD(unknown, 0 ..< unknown.count))
    }
}

/// The length filter is about videos and audio, and equal values keep the order things were found in.
final class FilterSortTests: XCTestCase {
    private let page = URL(string: "https://example.com/")!

    private func item(_ id: String, kind: MediaKind, index: Int, pixels: Int = 100, duration: Double? = nil) -> MediaItem {
        let url = URL(string: "https://example.com/\(id)")!
        var variant = MediaVariant(id: url.absoluteString, url: url, format: kind == .video ? .mp4 : .gif, origin: .img)
        variant.pixelSize = PixelSize(width: pixels, height: pixels)
        variant.duration = duration
        return MediaItem(id: id, kind: kind, variants: [variant], source: .web(WebContext(pageURL: page)), discoveryIndex: index,
                         group: "g", groupTitle: "t")
    }

    func testLengthFilterKinds() {
        var filter = MediaFilter()
        filter.hideTiny = false
        filter.hideIcons = false
        filter.minDuration = 5
        let context = FilterContext(currentPage: page) { _ in .notSaved }
        XCTAssertTrue(filter.matches(item("v", kind: .video, index: 0), context: context), "a video of unknown length stays")
        XCTAssertFalse(filter.matches(item("g", kind: .animatedImage, index: 1), context: context))
        XCTAssertFalse(filter.matches(item("s", kind: .vector, index: 2), context: context))
        XCTAssertTrue(filter.matches(item("long", kind: .video, index: 3, duration: 9), context: context))
    }

    func testEqualValuesKeepDiscoveryOrder() {
        let items = [item("a", kind: .image, index: 0), item("b", kind: .image, index: 1), item("c", kind: .image, index: 2, pixels: 500)]
        var filter = MediaFilter()
        filter.sort = .resolution
        filter.ascending = true
        XCTAssertEqual(filter.sorted(items).map(\.id), ["a", "b", "c"])
        filter.ascending = false
        XCTAssertEqual(filter.sorted(items).map(\.id), ["c", "a", "b"])
    }
}

/// R-914, R-1009: the Preview says why a version was chosen.
final class VariantReasonTests: XCTestCase {
    private func variant(_ id: String, _ width: Int?, _ format: MediaFormat, origin: VariantOrigin = .srcset) -> MediaVariant {
        var variant = MediaVariant(id: id, url: URL(string: "https://example.com/\(id)")!, format: format, origin: origin)
        if let width { variant.pixelSize = PixelSize(width: width, height: width) }
        return variant
    }

    func testReasons() {
        XCTAssertEqual(VariantRanker.reason([variant("a", 800, .jpeg)]), "The only version that can be saved.")
        XCTAssertEqual(VariantRanker.reason([variant("a", 800, .jpeg), variant("b", 1600, .jpeg)]), "The most pixels.")
        XCTAssertEqual(VariantRanker.reason([variant("a", 800, .webp), variant("b", 800, .jpeg)]),
                       "Already in a normal format at the same size, so nothing is converted.")
        XCTAssertTrue(VariantRanker.reason([variant("a", 800, .jpeg), variant("b", nil, .jpeg, origin: .cdnRewrite)])?
            .hasPrefix("Probably the full-size original") ?? false)
    }
}
