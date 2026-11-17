import Foundation
@testable import MediaPullCore
@testable import MediaPullEngines
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullNet
import XCTest

/// Runs the real bundled engine when the development build cache has it (scripts/fetch-engines.sh).
final class EngineTests: XCTestCase {
    var paths: EnginePaths!

    override func setUpWithError() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let found = EnginePaths.developmentPaths(repository: repository) else {
            throw XCTSkip("Engines are not installed; run scripts/fetch-engines.sh")
        }
        paths = found
    }

    func testFinalEventsAreNeverLost() async throws {
        let client = BridgeClient(paths: paths)
        for _ in 0 ..< 6 {
            var request = BridgeRequest(op: "supports")
            request.url = "https://www.pinterest.com/pin/123456/"
            let events = try await client.collect(request)
            let supported = events.contains { event in
                if case let .supports(site) = event { return site?.category == "pinterest" }
                return false
            }
            XCTAssertTrue(supported, "supports event missing: \(events)")
            XCTAssertTrue(events.contains { if case .done = $0 { return true } else { return false } })
        }
    }

    func testSelfTestPassesAndGuardBlocksWrites() async throws {
        let manager = EngineManager(paths: paths)
        let problems = await manager.selfTest()
        XCTAssertEqual(problems, [])
        let versions = try await manager.versions()
        XCTAssertNotNil(versions.galleryDL)
        XCTAssertNotNil(versions.ytDLP)
    }

    func testCookieFileRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cookie-test-\(UUID().uuidString)/cookies.txt")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let cookies = [
            CookieRecord(name: "sessionid", value: "abc%3Adef", domain: ".instagram.com", path: "/", isSecure: true, isHTTPOnly: true,
                         expires: Date(timeIntervalSince1970: 2_000_000_000)),
            CookieRecord(name: "csrftoken", value: "xyz", domain: ".instagram.com", path: "/", isSecure: true,
                         isHTTPOnly: false, expires: nil),
        ]
        try CookieFile.write(cookies, to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let read = CookieFile.read(file)
        XCTAssertEqual(read.map(\.name), ["sessionid", "csrftoken"])
        XCTAssertEqual(read.first?.isHTTPOnly, true)
        XCTAssertEqual(read.first?.value, "abc%3Adef")
    }

    func testVersionComparisonAndDependencies() {
        XCTAssertEqual(EngineManager.compare("1.32.19", "1.32.2"), .orderedDescending)
        XCTAssertEqual(EngineManager.compare("2026.10.26", "2026.11.1"), .orderedAscending)
        XCTAssertNil(EngineManager.unmetDependency(["requests>=2.11.0", "yt-dlp; extra == \"video\""]))
        XCTAssertNotNil(EngineManager.unmetDependency(["requests>=9.0"]))
        XCTAssertNotNil(EngineManager.unmetDependency(["brand-new-package"]))
    }
}

final class ConversionTests: XCTestCase {
    /// A tiny lossless WebP made from a PNG through the bundled ffmpeg is not possible (no WebP
    /// encoder), so these tests use ImageIO-written files for the formats ImageIO can encode.
    func testPNGStaysUntouchedAndHEICBecomesJPEG() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try XCTUnwrap(Self.gradient(width: 64, height: 48, alpha: false))
        let png = folder.appendingPathComponent("a.png")
        try ImageWriter.write(image, type: "public.png", to: png)
        let converter = MediaConverter(ffmpeg: nil)
        let kept = try await converter.convert(png, policy: ConversionPolicy(), layout: .archive,
                                               workDirectory: folder.appendingPathComponent("w"))
        XCTAssertFalse(kept.converted)
        XCTAssertEqual(kept.format, .png)

        let heic = folder.appendingPathComponent("b.heic")
        guard (try? ImageWriter.write(image, type: "public.heic", to: heic)) != nil else { throw XCTSkip("HEIC encoding unavailable") }
        let converted = try await converter.convert(heic, policy: ConversionPolicy(), layout: .archive,
                                                    workDirectory: folder.appendingPathComponent("w"))
        XCTAssertTrue(converted.converted)
        XCTAssertEqual(converted.format, .jpeg)
        XCTAssertEqual(converted.pixelSize, PixelSize(width: 64, height: 48))
        XCTAssertEqual(Sniffer.sniff(try Data(contentsOf: converted.url)).format, .jpeg)
    }

    func testSVGIsSkippedInArchiveButKeptInPlain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = folder.appendingPathComponent("icon.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"></svg>".utf8).write(to: svg)
        let converter = MediaConverter(ffmpeg: nil)
        do {
            _ = try await converter.convert(svg, policy: ConversionPolicy(), layout: .archive, workDirectory: folder)
            XCTFail("SVG should be skipped in the Archive layout")
        } catch let issue as ConversionIssue {
            XCTAssertTrue(issue.isSkip)
        }
        let plain = try await converter.convert(svg, policy: ConversionPolicy(), layout: .plain, workDirectory: folder)
        XCTAssertEqual(plain.format, .svg)
    }

    static func gradient(width: Int, height: Int, alpha: Bool) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                        : CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        for x in 0 ..< width {
            context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return context.makeImage()
    }
}

import ImageIO

enum ImageWriter {
    static func write(_ image: CGImage, type: String, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

final class SavePipelineTests: XCTestCase {
    func testArchiveSaveWritesSidecarDedupesAndNeverOverwrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try XCTUnwrap(ConversionTests.gradient(width: 80, height: 60, alpha: false))
        let source = root.appendingPathComponent("source.jpg")
        try ImageWriter.write(image, type: "public.jpeg", to: source)

        var context = EngineContext(key: "ig:3008811223344556677", category: "instagram", subcategory: "posts")
        context.username = "example.account"
        context.postShortcode = "CnAbCdEfGh"
        context.postID = "3008811223344556677"
        context.num = 2
        context.count = 3
        context.date = Date(timeIntervalSince1970: 1_672_971_730)
        context.description = "Caption #tag"
        let input = EngineItemInput(context: context, kind: .image, engineURL: "https://example.invalid/a.jpg", thumbURL: nil, width: 80,
                                    height: 60, isDash: false, fallbackURL: nil)
        let item = input.makeItem(discoveryIndex: 0)
        let pipeline = SavePipeline(gate: NetworkGate(), converter: MediaConverter(ffmpeg: nil), index: FingerprintIndex(storeURL: nil),
                                    workDirectory: root.appendingPathComponent(".work"), engine: nil)
        let target = SaveTarget(folder: root, layout: .archive, autoSubfolders: true, accountUsername: "example.account")
        let copy = root.appendingPathComponent("staged.jpg")
        try FileManager.default.copyItem(at: source, to: copy)
        let (outcome, _) = await pipeline.saveStaged(copy, item: item, target: target, settings: SaveSettings(), index: 1)
        let saved = try XCTUnwrap(outcome.url)
        XCTAssertEqual(saved.lastPathComponent, "2023-01-06_022210_CnAbCdEfGh_02.jpg")
        XCTAssertEqual(saved.deletingLastPathComponent().pathComponents.suffix(2), ["example.account", "posts"])
        let sidecar = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Sidecar.sidecarURL(for: saved))) as? [String: Any])
        XCTAssertEqual(sidecar["post_shortcode"] as? String, "CnAbCdEfGh")
        XCTAssertEqual(sidecar["count"] as? Int, 3)
        XCTAssertEqual(sidecar["date"] as? String, "2023-01-06 02:22:10")
        XCTAssertEqual(sidecar["subcategory"] as? String, "posts")
        XCTAssertNil(sidecar["location_id"])

        let again = root.appendingPathComponent("staged2.jpg")
        try FileManager.default.copyItem(at: source, to: again)
        let (second, _) = await pipeline.saveStaged(again, item: item, target: target, settings: SaveSettings(), index: 1)
        guard case .duplicate = second else { return XCTFail("Expected a duplicate, got \(second)") }

        let different = try XCTUnwrap(ConversionTests.gradient(width: 81, height: 60, alpha: false))
        let other = root.appendingPathComponent("other.jpg")
        try ImageWriter.write(different, type: "public.jpeg", to: other)
        let (third, _) = await pipeline.saveStaged(other, item: item, target: target, settings: SaveSettings(), index: 1)
        XCTAssertEqual(third.url?.lastPathComponent, "2023-01-06_022210_CnAbCdEfGh_02 2.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "The first file must never be overwritten")
    }
}

/// Talks to PyPI; run with MEDIAPULL_NETWORK_TESTS=1.
final class EngineUpdateNetworkTests: XCTestCase {
    func testUpdateCheckReadsPyPI() async throws {
        guard ProcessInfo.processInfo.environment["MEDIAPULL_NETWORK_TESTS"] == "1" else { throw XCTSkip("Network tests are off") }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let paths = EnginePaths.developmentPaths(repository: repository) else { throw XCTSkip("Engines are not installed") }
        let manager = EngineManager(paths: paths, gate: NetworkGate())
        let updates = try await manager.checkForUpdates()
        for update in updates {
            XCTAssertEqual(EngineManager.compare(update.available, update.current), .orderedDescending)
            XCTAssertEqual(update.sha256.count, 64)
            XCTAssertTrue(update.wheelURL.absoluteString.hasSuffix("py3-none-any.whl"))
        }
        print("Engine updates available: \(updates.map { "\($0.name) \($0.current) -> \($0.available)" })")
    }
}

final class PDFExtractionTests: XCTestCase {
    func testEmbeddedImagesComeOutAtOriginalSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try XCTUnwrap(ConversionTests.gradient(width: 200, height: 150, alpha: false))
        let jpegURL = folder.appendingPathComponent("photo.jpg")
        try ImageWriter.write(photo, type: "public.jpeg", to: jpegURL)
        let jpegProvider = try XCTUnwrap(CGDataProvider(url: jpegURL as CFURL))
        let jpeg = try XCTUnwrap(CGImage(jpegDataProviderSource: jpegProvider, decode: nil, shouldInterpolate: true,
                                         intent: .defaultIntent))
        let transparent = try XCTUnwrap(ConversionTests.gradient(width: 120, height: 80, alpha: true))

        let pdf = folder.appendingPathComponent("doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(jpeg, in: CGRect(x: 50, y: 500, width: 100, height: 75))
        context.draw(transparent, in: CGRect(x: 50, y: 300, width: 60, height: 40))
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.draw(jpeg, in: CGRect(x: 50, y: 500, width: 100, height: 75))
        context.endPDFPage()
        context.closePDF()

        let images = try PDFImageExtractor.extract(pdf: pdf, to: folder.appendingPathComponent("out"), baseName: "doc")
        XCTAssertEqual(images.count, 2, "\(images)")
        let photoResult = try XCTUnwrap(images.first { $0.format == .jpeg })
        XCTAssertEqual(photoResult.width, 200)
        XCTAssertEqual(photoResult.height, 150)
        XCTAssertEqual(Sniffer.sniff(try Data(contentsOf: photoResult.file)).format, .jpeg)
        let pngResult = try XCTUnwrap(images.first { $0.format == .png })
        XCTAssertEqual(pngResult.width, 120)
        XCTAssertEqual(pngResult.height, 80)
        XCTAssertTrue(photoResult.file.lastPathComponent.hasPrefix("doc p001"))
    }
}

final class EditingAndFilterTests: XCTestCase {
    /// A 4×2 image whose top-left pixel is red and everything else is blue.
    func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
        return try XCTUnwrap(context.makeImage())
    }

    /// Red channel of the pixel at (x, y) counted from the top left.
    func red(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        return pixels[(y * image.width + x) * 4]
    }

    func testRotateFlipAndCrop() throws {
        let image = try makeImage()
        XCTAssertEqual(red(image, 0, 0), 255)
        let clockwise = try XCTUnwrap(ImageEditing.rotated(image, quarterTurns: 1))
        XCTAssertEqual(clockwise.width, 2)
        XCTAssertEqual(clockwise.height, 4)
        XCTAssertEqual(red(clockwise, 1, 0), 255, "Top left moves to top right after a clockwise turn")
        let counter = try XCTUnwrap(ImageEditing.rotated(image, quarterTurns: -1))
        XCTAssertEqual(red(counter, 0, 3), 255, "Top left moves to bottom left after a counter-clockwise turn")
        let flipped = try XCTUnwrap(ImageEditing.flippedHorizontally(image))
        XCTAssertEqual(red(flipped, 3, 0), 255)
        let cropped = try XCTUnwrap(ImageEditing.cropped(image, to: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        XCTAssertEqual(cropped.width, 2)
        XCTAssertEqual(cropped.height, 1)
        XCTAssertEqual(red(cropped, 0, 0), 255)
    }

    func testResolutionSliderUsesLongestSide() {
        let page = URL(string: "https://example.com/")!
        func item(_ width: Int, _ height: Int) -> MediaItem {
            let url = URL(string: "https://example.com/\(width)x\(height).jpg")!
            var variant = MediaVariant(id: url.absoluteString, url: url, format: .jpeg, origin: .img)
            variant.pixelSize = PixelSize(width: width, height: height)
            return MediaItem(id: url.absoluteString, kind: .image, variants: [variant], source: .web(WebContext(pageURL: page)),
                             discoveryIndex: 0, group: "g", groupTitle: "t")
        }
        var filter = MediaFilter()
        filter.minLongSide = 1000
        let context = FilterContext(currentPage: page) { _ in .notSaved }
        XCTAssertTrue(filter.matches(item(1080, 1350), context: context))
        XCTAssertTrue(filter.matches(item(1200, 300), context: context))
        XCTAssertFalse(filter.matches(item(800, 800), context: context))
        XCTAssertEqual(filter.activeCount, 1)
    }
}

final class HostileInputTests: XCTestCase {
    private func box(_ size: UInt32, _ name: String, _ payload: [UInt8] = []) -> [UInt8] {
        withUnsafeBytes(of: size.bigEndian, Array.init) + Array(name.utf8) + payload
    }

    func testMalformedMP4BoxesDoNotCrash() {
        let tiny = box(4, "moov")
        XCTAssertNil(MP4Probe.info(from: Data(tiny + [0, 0, 0, 0])))
        let huge = box(1, "moov") + withUnsafeBytes(of: UInt64.max.bigEndian, Array.init) + box(9, "tkhd")
        _ = MP4Probe.info(from: Data(huge))
        let shortLarge = box(1, "moov") + withUnsafeBytes(of: UInt64(9).bigEndian, Array.init)
        _ = MP4Probe.info(from: Data(shortLarge))
        let tkhdAtEnd = box(16, "moov", box(8, "trak")) + box(8, "tkhd")
        _ = MP4Probe.info(from: Data(tkhdAtEnd))
    }

    func testHugeDeclaredSizesDoNotOverflow() {
        var variant = MediaVariant(id: "a", url: URL(string: "https://example.com/a.jpg")!, format: .jpeg, origin: .srcset)
        variant.declaredWidth = 4_000_000_000
        XCTAssertNotNil(VariantRanker.best([variant]))
        XCTAssertEqual(PixelSize(width: Int.max, height: 2).width, 1_000_000)
        XCTAssertNil(JSONValue.number(1e20).int)
    }
}

final class InstagramContentTests: XCTestCase {
    private func folder(_ subcategory: String, owner: String = "someone.else", target: SaveTarget) -> String {
        var context = EngineContext(key: "ig:1", category: "instagram", subcategory: subcategory)
        context.username = owner
        context.highlightTitle = "Trips"
        let item = EngineItemInput(context: context, kind: .image, engineURL: "https://example.invalid/a.jpg", thumbURL: nil, width: 10,
                                   height: 10, isDash: false, fallbackURL: nil).makeItem(discoveryIndex: 0)
        let url = ArchivePlanner.folder(for: item, target: target, settings: SaveSettings())
        return String(url.path.dropFirst(target.folder.path.count))
    }

    func testFlatFoldersWhenSortingByTypeIsOff() {
        var settings = SaveSettings()
        settings.typeSubfolders = false
        var context = EngineContext(key: "ig:1", category: "instagram", subcategory: "reels")
        context.username = "acct"
        let item = EngineItemInput(context: context, kind: .video, engineURL: "https://example.invalid/a.mp4", thumbURL: nil, width: 10,
                                   height: 10, isDash: false, fallbackURL: nil).makeItem(discoveryIndex: 0)
        let target = SaveTarget(folder: URL(fileURLWithPath: "/library"), layout: .archive, autoSubfolders: true, accountUsername: "acct")
        XCTAssertEqual(ArchivePlanner.folder(for: item, target: target, settings: settings).path, "/library/acct")
    }

    func testDateWindows() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z"))
        let day = { (text: String) in try XCTUnwrap(ISO8601DateFormatter().date(from: text + "T09:30:00Z")) }
        XCTAssertNil(InstagramDateWindow.allTime.bounds(now: now, from: now, to: now, calendar: calendar).from)
        XCTAssertEqual(InstagramDateWindow.pastMonth.bounds(now: now, from: now, to: now, calendar: calendar).from,
                       ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z"))
        XCTAssertEqual(InstagramDateWindow.pastYear.bounds(now: now, from: now, to: now, calendar: calendar).from,
                       ISO8601DateFormatter().date(from: "2025-11-14T12:00:00Z"))
        let custom = InstagramDateWindow.custom.bounds(now: now, from: try day("2026-03-05"), to: try day("2026-03-01"), calendar: calendar)
        XCTAssertEqual(custom.from, ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z"), "a reversed range is put in order")
        XCTAssertEqual(custom.to, ISO8601DateFormatter().date(from: "2026-03-05T23:59:59Z"), "whole days are included")
    }

    func testDefaultsAndGroups() {
        XCTAssertEqual(InstagramContent.defaults, [.posts, .reels, .stories, .highlights, .avatar])
        XCTAssertTrue(InstagramContent.defaults.allSatisfy(\.isProfileMedia))
        XCTAssertEqual(InstagramContent.highlightCovers.engineName, "highlights-covers")
        XCTAssertEqual(InstagramContent.profileInfo.group, .details)
        XCTAssertEqual(InstagramContent.storiesTray.group, .yours)
    }

    func testFoldersForEachKindOfContent() {
        let root = URL(fileURLWithPath: "/library")
        let account = SaveTarget(folder: root, layout: .archive, autoSubfolders: true, accountUsername: "acct")
        XCTAssertEqual(folder("posts", target: account), "/acct/posts")
        XCTAssertEqual(folder("reels", target: account), "/acct/reels")
        XCTAssertEqual(folder("avatar", target: account), "/acct/profile pictures")
        XCTAssertEqual(folder("tagged", target: account), "/acct/tagged")
        XCTAssertEqual(folder("reposts", target: account), "/acct/reposts")
        XCTAssertEqual(folder("tagged", owner: "acct", target: account), "/acct/posts",
                       "a post of the account's own, saved from a scan of tagged posts, is one of its posts (audit 3, C3-m15)")
        XCTAssertEqual(folder("stories", target: account), "/acct/stories")
        XCTAssertEqual(folder("highlights-covers", target: account), "/acct/highlights/Trips")
        XCTAssertEqual(folder("saved", target: account), "/Saved posts")
        XCTAssertEqual(folder("stories-tray", target: account), "/someone.else/stories", "followed accounts keep their own folders")
        let tag = SaveTarget(folder: root, layout: .archive, autoSubfolders: true, collectionPath: [SaveTarget.tagsFolder, "sunsets"])
        XCTAssertEqual(folder("tag", target: tag), "/Hashtags/sunsets")

        var tray = EngineContext(key: "k", category: "instagram", subcategory: "stories-tray")
        tray.username = "x"
        XCTAssertEqual(tray.instagramSection, "stories")

        // As the bridge reports them (audit round 1, A1): a child extractor's "stories", marked as from the tray.
        let reported = EngineContext.from(meta: ["category": .string("instagram"), "username": .string("bob"),
                                                 "collection": .string("stories-tray")],
                                          key: "ig:5", subcategory: "stories", sourceURL: nil)
        XCTAssertEqual(reported.subcategory, "stories-tray")
        let saved = EngineContext.from(meta: ["category": .string("instagram"), "username": .string("carol"),
                                              "collection": .string("saved")],
                                       key: "ig:6", subcategory: "posts", sourceURL: nil)
        XCTAssertEqual(saved.subcategory, "saved")
        let url = URL(string: "https://cdn.example.com/a.jpg")!
        let variant = MediaVariant(id: url.absoluteString, url: url, format: .jpeg, origin: .img)
        let item = MediaItem(id: "ig:5", kind: .image, variants: [variant],
                             source: .engine(reported), discoveryIndex: 0, group: "g", groupTitle: "t")
        let info = FinalFileInfo(format: .jpeg, sha256: "ab", pixelSize: nil, duration: nil, sourceURL: url, lastModified: nil,
                                 originalName: nil, note: nil)
        XCTAssertEqual(ArchivePlanner.sidecar(for: item, info: info, target: account, settings: SaveSettings()).username, "bob")
    }
}

final class PlacementTests: XCTestCase {
    /// Saves run in parallel; items that want the same name must each keep their own file.
    func testParallelPlacementNeverOverwrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("place-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pipeline = SavePipeline(gate: NetworkGate(), converter: MediaConverter(ffmpeg: nil), index: FingerprintIndex(storeURL: nil),
                                    workDirectory: root.appendingPathComponent(".work"), engine: nil)
        let count = 40
        var sources: [URL] = []
        for index in 0 ..< count {
            let file = root.appendingPathComponent("source-\(index)")
            try Data("file \(index)".utf8).write(to: file)
            sources.append(file)
        }
        let placed = try await withThrowingTaskGroup(of: URL?.self) { group in
            for file in sources {
                group.addTask { try pipeline.place(file, in: root, name: "image.jpg", conflict: .number) }
            }
            return try await group.reduce(into: [URL]()) { if let url = $1 { $0.append(url) } }
        }
        XCTAssertEqual(Set(placed.map(\.lastPathComponent)).count, count)
        let contents = try Set(placed.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents.count, count)
    }
}

final class TrackHeaderTests: XCTestCase {
    private func tkhd(width: UInt32, height: UInt32, quarterTurn: Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 84)
        func put(_ value: UInt32, at offset: Int) {
            for index in 0 ..< 4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - 8 * UInt32(index))) }
        }
        // Display matrix (16.16 fixed point) at 40, width and height at 76 in a version 0 box.
        put(quarterTurn ? 0 : 0x0001_0000, at: 40)
        put(quarterTurn ? 0x0001_0000 : 0, at: 44)
        put(quarterTurn ? 0xFFFF_0000 : 0, at: 52)
        put(quarterTurn ? 0 : 0x0001_0000, at: 56)
        put(width << 16, at: 76)
        put(height << 16, at: 80)
        return bytes
    }

    func testPortraitPhoneVideoIsReportedUpright() {
        let rotated = tkhd(width: 1920, height: 1080, quarterTurn: true)
        XCTAssertEqual(MP4Probe.parseTKHD(rotated, 0 ..< rotated.count), PixelSize(width: 1080, height: 1920))
        let plain = tkhd(width: 1920, height: 1080, quarterTurn: false)
        XCTAssertEqual(MP4Probe.parseTKHD(plain, 0 ..< plain.count), PixelSize(width: 1920, height: 1080))
    }
}

final class ColourProfileTests: XCTestCase {
    private func jpeg(_ space: CGColorSpace?) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space ?? CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        // No profile in the file, as JPEG data inside a PDF usually has none.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationEmbedThumbnail: false] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func profileName(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyProfileName] as? String
    }

    /// A wide-colour picture copied out of a PDF keeps its profile, and the image data is not touched (R-1602).
    func testPDFProfileIsAddedWithoutReencoding() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData() as Data?)
        let plain = try jpeg(CGColorSpaceCreateDeviceRGB())
        let tagged = PDFImageExtractor.embedICC(p3, in: plain)
        XCTAssertEqual(profileName(tagged), "Display P3")
        XCTAssertTrue(tagged.count > plain.count)
        // From the start-of-scan marker on, the compressed picture is byte for byte the same.
        func scan(_ data: Data) -> Data? {
            let bytes = [UInt8](data)
            return (0 ..< bytes.count - 1).first { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xDA }.map { Data(bytes[$0...]) }
        }
        XCTAssertEqual(scan(tagged), scan(plain))
        XCTAssertEqual(PDFImageExtractor.embedICC(p3, in: tagged), tagged, "a profile is added once")
    }
}
