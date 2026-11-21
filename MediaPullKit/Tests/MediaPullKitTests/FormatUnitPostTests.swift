import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullDevices
@testable import MediaPullLibrary
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Section 42: formats (R-4201 to R-4205, R-4210), units (R-4206, R-4207) and posts (R-4208, R-4209).
final class FormatTests: XCTestCase {
    func testExtensions() {
        let table: [(String, MediaFormat?)] = [
            ("heic", .heic), ("HIF", .heic), ("heics", .heic), ("avci", .heic), ("CR3", .raw), ("nef", .raw), ("ARW", .raw),
            ("dng", .raw), ("raf", .raw), ("aif", .aiff), ("aiff", .aiff), ("aifc", .aiff), ("mp3", .mp3), ("xmp", nil), ("aae", nil),
        ]
        for (ext, format) in table {
            XCTAssertEqual(MediaFormat.fromExtension(ext), format, ext)
        }
        XCTAssertTrue(MediaFormat.isSequenceExtension("HEICS"))
        XCTAssertFalse(MediaFormat.raw.isConvertible)
        XCTAssertFalse(MediaFormat.mp3.isConvertible)
        XCTAssertTrue(MediaFormat.heic.isConvertible)
        XCTAssertEqual(MediaFormat.raw.kind, .image)
        XCTAssertEqual(MediaFormat.aiff.kind, .audio)
        XCTAssertTrue(MediaFormat.knownExtensions.isSuperset(of: ["cr3", "hif", "aiff", "jpg"]))
    }

    func testRawWinsOverTheTiffSignature() {
        let tiff = Data([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0])
        XCTAssertEqual(Sniffer.sniff(tiff).format, .tiff)
        let table: [(Data, String, MediaFormat?)] = [
            (tiff, "NEF", .raw), (tiff, "dng", .raw), (tiff, "tif", .tiff), (tiff, "jpg", .tiff),
            (Data("FUJIFILMCCD-RAW 0201".utf8), "raf", .raw),
            (Data([0, 0, 0, 0x18] + Array("ftypcrx ".utf8) + [0, 0, 0, 1]), "cr3", .raw),
            (Data("FORM\0\0\0\u{10}AIFFCOMM".utf8), "aiff", .aiff),
            (Data([0, 0, 0, 0x18] + Array("ftypavci".utf8) + [0, 0, 0, 0]), "avci", .heic),
        ]
        for (bytes, ext, format) in table {
            XCTAssertEqual(Sniffer.resolve(Sniffer.sniff(bytes).format, fileExtension: ext), format, ext)
        }
    }

    func testOffsetsInEveryForm() {
        let table: [(String?, String?)] = [
            ("+08:00", "+08:00"), ("+0800", "+08:00"), ("-0530", "-05:30"), ("+08", "+08:00"), ("Z", "+00:00"), (" +01:00 ", "+01:00"),
            ("0800", nil), ("+8", nil), ("", nil), (nil, nil), ("+08:0a", nil),
        ]
        for (text, expected) in table {
            XCTAssertEqual(MediaFactsReader.normalizedOffset(text), expected, text ?? "nil")
        }
        let digitizedOnly: [CFString: Any] = [kCGImagePropertyExifDateTimeDigitized: "2024:06:01 18:30:05",
                                              kCGImagePropertyExifOffsetTimeDigitized: "+0900", kCGImagePropertyExifOffsetTime: "+01:00"]
        XCTAssertEqual(MediaFactsReader.takenDate(digitizedOnly)?.1, "+0900", "the digitized date goes with its own offset")
        let date = MediaFactsReader.exifDate("2024:06:01 18:30:05", offset: "+0900")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2024-06-01T09:30:05Z"))
    }

    func testAudioTagHelpers() {
        XCTAssertEqual(MediaFactsReader.year("2019-04-01"), 2019)
        XCTAssertNil(MediaFactsReader.year("19"))
        XCTAssertEqual(MediaFactsReader.trackNumber("3/12"), 3)
        XCTAssertEqual(MediaFactsReader.codecName(kAudioFormatMPEGLayer3), "MP3")
        XCTAssertEqual(MediaFactsReader.codecName(kAudioFormatAppleLossless), "ALAC")
        var first = AudioTags()
        first.title = "One"
        var second = AudioTags()
        second.title = "Other"
        second.artist = "Band"
        let merged = MediaFactsReader.merged(first, second)
        XCTAssertEqual(merged.title, "One", "what the system read wins")
        XCTAssertEqual(merged.artist, "Band")
    }

    func testFactsCarryTheirOwnVersion() throws {
        let record = AnalysisRecord(sha256: "x", facts: MediaFacts())
        XCTAssertEqual(record.factsVersion, AnalysisRecord.currentFactsVersion)
        // A record stored before facts had a version reads as nil, so its facts are read again without models.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any] ?? [:]
        json["factsVersion"] = nil
        let old = try JSONDecoder().decode(AnalysisRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.factsVersion)
    }

    func testAudioSortsByArtistAlbumAndTrack() {
        func song(_ name: String, artist: String?, album: String?, track: Int?) -> MediaEntry {
            var facts = MediaFacts()
            facts.format = .mp3
            var tags = AudioTags()
            tags.artist = artist
            tags.album = album
            tags.track = track
            facts.audio = tags
            return MediaEntry(url: URL(fileURLWithPath: "/m/\(name)"), size: 1, created: nil, modified: .distantPast, format: .mp3,
                              record: AnalysisRecord(sha256: name, facts: facts))
        }
        let songs = [song("c.mp3", artist: "B", album: "X", track: 2), song("a.mp3", artist: "A", album: "Y", track: 1),
                     song("b.mp3", artist: "B", album: "X", track: 1), song("z.mp3", artist: nil, album: nil, track: nil)]
        var query = LibraryQuery()
        query.sort = .artist
        query.ascending = true
        XCTAssertEqual(query.sorted(songs, context: .init()).map(\.name), ["a.mp3", "b.mp3", "c.mp3", "z.mp3"])
        XCTAssertEqual(SortRules.byArtist(songs[0]), [["B", "X"]])
        XCTAssertEqual(SortRules.byAlbum(songs[0]), [["X"]])
        XCTAssertEqual(SortRules.byArtist(songs[3]), [], "untagged audio stays where it is")
    }

    /// A rotation alone keeps a HEIC's image data and its format (R-4203).
    func testRotatingAHeicIsLossless() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.heic"), output = folder.appendingPathComponent("turned.heic")
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Test"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var turn = ImageEditing.Reorientation()
        turn.rotate(clockwise: true)
        try ImageEditing.writeReoriented(source, by: turn, to: output)
        func pixels(_ url: URL) -> Data? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return image.dataProvider?.data as Data?
        }
        XCTAssertEqual(pixels(source), pixels(output), "the image data is the same; only the orientation tag changed")
        let props = CGImageSourceCreateWithURL(output as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
            as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(CGImageSourceCreateWithURL(output as CFURL, nil).flatMap(CGImageSourceGetType) as String?, UTType.heic.identifier)
    }
}

final class UnitTests: XCTestCase {
    var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("units-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func file(_ path: String, _ text: String = "x") {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func tree() -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var out: [String] = []
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
            }
        }
        return out.sorted()
    }

    func testUnitsByName() {
        let names = ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp", "IMG_1.CR3.json", "IMG_2.HEIC", "IMG_2.MOV", "IMG_2.AAE", "IMG_3.jpg",
                     "IMG_E2.HEIC", "IMG_4.DNG", "IMG_4.HEIC", "IMG_4.MOV", "IMG_5.jpg", "IMG_5.heic", "notes.txt"]
        let units = MediaUnits.units(in: names)
        XCTAssertEqual(units, [
            MediaUnits.Unit(lead: "IMG_1.CR3", members: ["IMG_1.JPG"], kind: .rawPair),
            MediaUnits.Unit(lead: "IMG_2.HEIC", members: ["IMG_2.MOV"], kind: .live),
            MediaUnits.Unit(lead: "IMG_4.DNG", members: ["IMG_4.HEIC", "IMG_4.MOV"], kind: .live),
        ], "IMG_E edits, single files and two photos without a clip are not units")
        XCTAssertEqual(MediaUnits.companions(ofLead: "IMG_1.CR3", in: names), ["IMG_1.CR3.json", "IMG_1.JPG", "IMG_1.xmp"])
        XCTAssertEqual(MediaUnits.companions(ofLead: "IMG_2.HEIC", in: names), ["IMG_2.MOV", "IMG_2.AAE"])
        XCTAssertEqual(MediaUnits.companions(ofLead: "IMG_1.JPG", in: names), [], "a member alone does not take the shot's edit files")
        XCTAssertEqual(MediaUnits.memberNames(in: names), ["IMG_1.JPG", "IMG_2.MOV", "IMG_4.HEIC", "IMG_4.MOV"])
        let table: [(String, String, Bool)] = [
            ("IMG_1.JPG", "IMG_1.CR3", true), ("IMG_1.JPG.json", "IMG_1.CR3", true), ("IMG_1.CR3.json", "IMG_1.CR3", true),
            ("img_1.xmp", "IMG_1.CR3", true), ("IMG_1.MOV", "IMG_1.HEIC", true), ("IMG_1.PNG", "IMG_1.CR3", false),
            ("IMG_10.JPG", "IMG_1.CR3", false), ("IMG_1.edited.jpg", "IMG_1.CR3", false), ("IMG_1.JPG", "IMG_1.mp4", false),
        ]
        for (name, lead, expected) in table {
            XCTAssertEqual(MediaUnits.isCompanionName(name, ofLead: lead), expected, "\(name) of \(lead)")
        }
        XCTAssertEqual(MediaUnits.renamed("IMG_1.JPG.json", lead: "IMG_1.CR3", newLead: "IMG_1 2.CR3"), "IMG_1 2.JPG.json")
    }

    /// A pair moves as one, takes one shared number when its name is taken, and Undo puts every file back (R-4206).
    func testAPairMovesAsOneAndUndoPutsItBack() async {
        file("card/IMG_1.CR3", "raw")
        file("card/IMG_1.JPG", "jpeg")
        file("card/IMG_1.xmp", "edits")
        file("card/IMG_1.JPG.json", "{}")
        file("card/IMG_2.HEIC", "photo")
        file("card/IMG_2.MOV", "clip")
        file("sorted/IMG_1.JPG", "an older photo")
        let before = tree()
        let sources = [root.appendingPathComponent("card/IMG_1.CR3"), root.appendingPathComponent("card/IMG_2.HEIC")]
        let plan = FolderOperations.move(sources, to: root.appendingPathComponent("sorted"))
        XCTAssertEqual(plan.moves.map(\.destination.lastPathComponent), ["IMG_1 2.CR3", "IMG_2.HEIC"],
                       "the RAW takes a number because its JPEG's name is taken")
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
        let entry = await journal.run(plan)
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(tree().filter { $0.hasPrefix("sorted/") }, [
            "sorted/IMG_1 2.CR3", "sorted/IMG_1 2.JPG", "sorted/IMG_1 2.JPG.json", "sorted/IMG_1 2.xmp", "sorted/IMG_1.JPG",
            "sorted/IMG_2.HEIC", "sorted/IMG_2.MOV",
        ])
        XCTAssertEqual(entry.fileCount, 2, "two shots")
        let report = await journal.undo(entry.id)
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertEqual(report.restored, 2)
        XCTAssertEqual(tree().filter { !$0.hasPrefix(".journal") }, before.filter { !$0.hasPrefix(".journal") })
    }

    func testTrashAndFlattenKeepUnitsWhole() async {
        file("a/IMG_1.HEIC", "photo")
        file("a/IMG_1.MOV", "clip")
        file("a/IMG_1.AAE", "edit")
        let flatten = FolderOperations.flatten(root)
        XCTAssertEqual(flatten.moves.map(\.source.lastPathComponent), ["IMG_1.HEIC"], "members are never planned on their own")
        let journal = OperationJournal(folder: root.appendingPathComponent(".journal-\(UUID().uuidString)", isDirectory: true))
        _ = await journal.run(flatten)
        XCTAssertEqual(tree().filter { !$0.hasPrefix(".journal") }, ["IMG_1.AAE", "IMG_1.HEIC", "IMG_1.MOV"])
        let trash = await journal.run(FolderOperations.trash([root.appendingPathComponent("IMG_1.HEIC")]))
        XCTAssertTrue(trash.failures.isEmpty)
        XCTAssertEqual(tree().filter { !$0.hasPrefix(".journal") }, [], "the clip and edit file went with the photo")
        let report = await journal.undo(trash.id)
        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(tree().filter { !$0.hasPrefix(".journal") }, ["IMG_1.AAE", "IMG_1.HEIC", "IMG_1.MOV"])
    }

    func testDropsAndListingsCarryMembersWithTheirLead() {
        let urls = ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp", "IMG_9.jpg", "IMG_9.jpg.json"].map { root.appendingPathComponent($0) }
        XCTAssertEqual(Sidecar.withoutCompanions(urls).map(\.lastPathComponent), ["IMG_1.CR3", "IMG_9.jpg"])
        file("IMG_1.CR3")
        file("IMG_1.JPG")
        file("IMG_9.jpg")
        XCTAssertEqual(FolderOperations.mediaFiles(in: root, recursive: false).map(\.lastPathComponent), ["IMG_1.CR3", "IMG_9.jpg"])
        XCTAssertEqual(DuplicateFinder.mediaFiles(under: root).map(\.url.lastPathComponent).sorted(), ["IMG_1.CR3", "IMG_9.jpg"])
    }

    func testImportsPairARawWithItsJpeg() {
        func entry(_ name: String) -> DeviceEntry {
            DeviceEntry(id: "0/\(name)", ref: name, storage: "0", name: name, isFolder: false, size: 10,
                        pairKey: "DCIM/" + (name as NSString).deletingPathExtension.lowercased())
        }
        let raw = entry("DSC_1.NEF"), jpeg = entry("DSC_1.JPG"), clip = entry("IMG_2.MOV"), photo = entry("IMG_2.HEIC")
        let plan = ImportPlan.make([jpeg, raw, clip, photo], imported: [], existing: [], includeClips: false)
        XCTAssertEqual(plan.items.map(\.entry.name), ["DSC_1.NEF", "DSC_1.JPG", "IMG_2.HEIC"])
        XCTAssertEqual(plan.items[1].clipOf, raw.id, "the JPEG takes the RAW's name; it is never optional")
        XCTAssertEqual(plan.clipsLeftOut, 1)
    }
}

final class PostTests: XCTestCase {
    func entry(_ name: String, post: String?, num: Int, count: Int = 3) -> MediaEntry {
        MediaEntry(url: URL(fileURLWithPath: "/acct/\(name)"), size: 1, created: nil, modified: .distantPast, format: .jpeg,
                   source: SourceInfo(category: "instagram", username: "someone", postID: post, num: num, count: count))
    }

    func testPostsStayTogether() {
        let a1 = entry("a1.jpg", post: "A", num: 1), a2 = entry("a2.jpg", post: "A", num: 2), a3 = entry("a3.jpg", post: "A", num: 3)
        let single = entry("s.jpg", post: "S", num: 1, count: 1)
        let assignment: [String: [[String]]] = [a1.path: [["Beach"]], a2.path: [["Dogs"]], a3.path: [["Dogs"]], single.path: [["Food"]]]
        let first = PostGroups.keepTogether([a1, a2, a3, single], assignment: assignment, byMajority: false)
        XCTAssertEqual(first.posts, 1)
        XCTAssertEqual(first.assignment[a3.path], [["Beach"]], "the first picture's folder")
        XCTAssertEqual(first.assignment[single.path], [["Food"]], "a post of one is its own")
        let majority = PostGroups.keepTogether([a1, a2, a3], assignment: assignment, byMajority: true)
        XCTAssertEqual(majority.assignment[a1.path], [["Dogs"]], "most of the post goes to Dogs")
        let tie = PostGroups.keepTogether([a1, a2], assignment: assignment, byMajority: true)
        XCTAssertEqual(tie.assignment[a2.path], [["Beach"]], "a tie goes to the first picture")
        XCTAssertEqual(a2.source?.postPlace, "2 of 3")
        XCTAssertNil(single.source?.postPlace)
    }

    func testSourceSortOrdersPostsByDateThenPlace() {
        func dated(_ name: String, post: String, num: Int, day: Double) -> MediaEntry {
            MediaEntry(url: URL(fileURLWithPath: "/acct/\(name)"), size: 1, created: nil, modified: .distantPast, format: .jpeg,
                       source: SourceInfo(username: "someone", postID: post, date: Date(timeIntervalSince1970: day * 86400), num: num,
                                          count: 2))
        }
        let items = [dated("old2", post: "zz", num: 2, day: 1), dated("new1", post: "aa", num: 1, day: 9),
                     dated("old1", post: "zz", num: 1, day: 1), dated("new2", post: "aa", num: 2, day: 9)]
        var query = LibraryQuery()
        query.sort = .source
        query.ascending = true
        XCTAssertEqual(query.sorted(items, context: .init()).map(\.name), ["new1", "new2", "old1", "old2"])
    }

    func testExtraCopiesSpareAPostsOwnPictures() {
        let keep = ExtraCopies.Candidate(url: URL(fileURLWithPath: "/a/1.jpg"), pixels: 100, hasMetadata: true, created: .distantPast,
                                         bytes: 10, post: "someone\u{0}P")
        let samePost = ExtraCopies.Candidate(url: URL(fileURLWithPath: "/a/2.jpg"), pixels: 90, hasMetadata: true, created: .distantPast,
                                             bytes: 10, post: "someone\u{0}P")
        XCTAssertEqual(ExtraCopies.keeper([keep, samePost])?.url, keep.url)
        // The rule in `plan`: a candidate in the same post as the keeper is never trashed.
        let spared = [samePost].filter { $0.post == nil || $0.post != keep.post }
        XCTAssertTrue(spared.isEmpty)
    }

    func testArchiveRenamesKeepTheirDatePrefix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("2024-06-01_183005_ABC_01.jpg")
        try Data("x".utf8).write(to: file)
        try Data("{}".utf8).write(to: Sidecar.sidecarURL(for: file))
        let plan = FolderOperations.rename(file, to: "Beach day")
        XCTAssertEqual(plan.moves.first?.destination.lastPathComponent, "2024-06-01_183005_Beach day.jpg")
        XCTAssertEqual(FolderOperations.archiveDatePrefix("photo.jpg"), nil)
    }
}
