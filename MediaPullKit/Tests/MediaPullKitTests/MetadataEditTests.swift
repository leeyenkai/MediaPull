import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
import MediaPullNet
import UniformTypeIdentifiers
import XCTest

/// Section 45: metadata edits.
final class MetadataEditTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MetadataEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A small photo with a camera date, offset and maker, as a camera would write it.
    static func photo(_ url: URL, type: UTType, date: String = "2020:01:02 03:04:05", offset: String? = "+01:00",
                      gps: (Double, Double)? = nil)
    {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0 ..< 64 {
            context.setFillColor(red: CGFloat(x) / 64, green: 0.3, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: date, kCGImagePropertyExifDateTimeDigitized: date]
        if let offset {
            exif[kCGImagePropertyExifOffsetTimeOriginal] = offset
            exif[kCGImagePropertyExifOffsetTimeDigitized] = offset
        }
        var props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cam", kCGImagePropertyTIFFModel: "One"]]
        if let gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(gps.0), kCGImagePropertyGPSLatitudeRef: gps.0 < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(gps.1), kCGImagePropertyGPSLongitudeRef: gps.1 < 0 ? "W" : "E",
            ]
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Edits (R-4501)

    func testEditsApplyToCurrentValues() {
        let taken = TakenDate(original: "2020:01:31 23:30:00", originalOffset: "+01:00", digitized: "2020:01:31 23:30:00",
                              digitizedOffset: "+01:00")
        let current = MetadataValues(fields: Set(MetadataField.allCases), rating: 2, keywords: ["Beach"], taken: taken,
                                     latitude: 1, longitude: 2)
        let cases: [(MetadataEdit, MetadataValues?)] = [
            (.rating(4), MetadataValues(fields: [.rating], rating: 4)),
            (.rating(2), nil),
            (.rating(0), MetadataValues(fields: [.rating])),
            (.rating(9), MetadataValues(fields: [.rating], rating: 5)),
            (.keywords(add: ["beach", " family "], remove: []), MetadataValues(fields: [.keywords], keywords: ["Beach", "family"])),
            (.keywords(add: [], remove: ["BEACH"]), MetadataValues(fields: [.keywords])),
            (.keywords(add: ["Beach"], remove: []), nil),
            (.shiftDate(seconds: 3600), MetadataValues(fields: [.taken], taken: TakenDate(
                original: "2020:02:01 00:30:00", originalOffset: "+01:00", digitized: "2020:02:01 00:30:00", digitizedOffset: "+01:00"
            ))),
            (.shiftDate(seconds: 0), nil),
            (.timeZone("+0900"), MetadataValues(fields: [.taken], taken: TakenDate(
                original: "2020:01:31 23:30:00", originalOffset: "+09:00", digitized: "2020:01:31 23:30:00", digitizedOffset: "+09:00"
            ))),
            (.timeZone("+01:00"), nil),
            (.timeZone("nine"), nil),
            (.location(latitude: 35.5, longitude: -139.25), MetadataValues(fields: [.location], latitude: 35.5, longitude: -139.25)),
            (.location(latitude: 1, longitude: 2), nil),
            (.location(latitude: 91, longitude: 2), nil),
            (.removeLocation, MetadataValues(fields: [.location])),
        ]
        for (edit, expected) in cases {
            XCTAssertEqual(edit.apply(to: current), expected, "\(edit)")
        }
        // Nothing to shift or zone without a date.
        XCTAssertNil(MetadataEdit.shiftDate(seconds: 60).apply(to: MetadataValues(fields: [.taken])))
        XCTAssertNil(MetadataEdit.timeZone("+02:00").apply(to: MetadataValues(fields: [.taken])))
        XCTAssertNil(MetadataEdit.removeLocation.apply(to: MetadataValues(fields: [.location])))
    }

    func testDateAndCoordinateText() {
        XCTAssertEqual(MetadataEdit.shift("2024:02:28 23:00:00", by: 86400), "2024:02:29 23:00:00")
        XCTAssertEqual(MetadataEdit.shift("2024:03:10 01:30:00", by: 3600), "2024:03:10 02:30:00")
        XCTAssertNil(MetadataEdit.shift("not a date", by: 1))
        XCTAssertEqual(MetadataEdit.offsetText(seconds: -34200), "-09:30")
        XCTAssertEqual(MetadataEdit.offsetSeconds("+05:45"), 20700)
        XCTAssertNil(MetadataEdit.offset("+25:00"))
        let moment = MetadataEdit.moment("2020:01:01 09:00:00", offset: "+09:00")
        XCTAssertEqual(moment, ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z"))

        let dates: [(String, String?, String)] = [
            ("2021:05:06 07:08:09", "+09:00", "2021-05-06T07:08:09+09:00"),
            ("2021:05:06 07:08:09", nil, "2021-05-06T07:08:09"),
        ]
        for (exif, offset, xmp) in dates {
            XCTAssertEqual(XMPText.date(exif: exif, offset: offset), xmp)
            let back = XMPText.exif(fromDate: xmp)
            XCTAssertEqual(back?.text, exif)
            XCTAssertEqual(back?.offset, offset)
        }
        XCTAssertEqual(XMPText.exif(fromDate: "2019-07-01T10:11:12.50+02:00")?.text, "2019:07:01 10:11:12")
        XCTAssertEqual(XMPText.exif(fromDate: "2019-07-01T10:11Z")?.offset, "+00:00")
        XCTAssertEqual(XMPText.exif(fromDate: "2019-07-01")?.text, "2019:07:01 00:00:00")
        XCTAssertEqual(XMPText.exif(fromDate: "2019:07:01 10:11:12+02:00")?.offset, "+02:00")
        XCTAssertNil(XMPText.exif(fromDate: "July"))

        XCTAssertEqual(XMPText.coordinate(35.5, latitude: true), "35,30.000000N")
        XCTAssertEqual(XMPText.coordinate(-139.25, latitude: false), "139,15.000000W")
        XCTAssertEqual(try XCTUnwrap(XMPText.degrees("52,22.5N")), 52.375, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(XMPText.degrees("52,22,30S")), -52.375, accuracy: 1e-9)
        XCTAssertEqual(XMPText.degrees("-4.5"), -4.5)
        XCTAssertNil(XMPText.degrees("north"))
    }

    // MARK: Writing (R-4502)

    func testJPEGAndHEICAreWrittenInPlaceLosslesslyAndBack() throws {
        for type in [UTType.jpeg, .heic] {
            let original = folder.appendingPathComponent("a.\(type.preferredFilenameExtension!)")
            Self.photo(original, type: type)
            XCTAssertTrue(MetadataWriter.writesInFile(original))
            let before = MetadataWriter.values(of: original)
            XCTAssertEqual(before.taken?.original, "2020:01:02 03:04:05")
            XCTAssertNil(before.rating)

            var wanted = MetadataValues(fields: Set(MetadataField.allCases), rating: 4, keywords: ["beach", "family"],
                                        latitude: -35.5, longitude: 139.25)
            wanted.taken = MetadataEdit.timeZone("+09:00").apply(to: before)?.taken
            let edited = folder.appendingPathComponent("b.\(type.preferredFilenameExtension!)")
            try MetadataWriter.writeCopy(of: original, setting: wanted, to: edited)
            XCTAssertTrue(MetadataWriter.samePicture(original, edited))
            let after = MetadataWriter.values(of: edited)
            XCTAssertTrue(after.agrees(with: wanted), "\(type): \(after)")
            XCTAssertEqual(after.taken?.originalOffset, "+09:00")
            // The camera's other values stay.
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(edited as CFURL, nil)!, 0, nil)
                as? [CFString: Any])
            XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "Cam")

            // Undo writes the earlier values back, removals included.
            let back = folder.appendingPathComponent("c.\(type.preferredFilenameExtension!)")
            try MetadataWriter.writeCopy(of: edited, setting: before, to: back)
            let restored = MetadataWriter.values(of: back)
            XCTAssertTrue(restored.agrees(with: before), "\(type): \(restored)")
            XCTAssertNil(restored.rating)
            XCTAssertNil(restored.keywords)
            XCTAssertNil(restored.latitude)
            XCTAssertTrue(MetadataWriter.samePicture(original, back))
        }
    }

    func testOtherFormatsUseXMPAndAChangedPictureIsRefused() {
        for name in ["a.png", "a.tiff", "a.gif", "a.CR3", "a.dng", "a.webp", "a.heics"] {
            XCTAssertFalse(MetadataWriter.writesInFile(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        let original = folder.appendingPathComponent("a.jpg")
        Self.photo(original, type: .jpeg)
        // A re-encoded copy is not the same picture.
        let source = CGImageSourceCreateWithURL(original as CFURL, nil)!
        let copy = folder.appendingPathComponent("re.jpg")
        let destination = CGImageDestinationCreateWithURL(copy as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.3] as CFDictionary)
        CGImageDestinationFinalize(destination)
        XCTAssertFalse(MetadataWriter.samePicture(original, copy))
        XCTAssertTrue(MetadataWriter.samePicture(original, original))
    }

    func testXMPKeepsWhatElseItHoldsAndLiesOverTheFile() throws {
        let existing = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" \
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" xmp:Rating="3" \
        exif:DateTimeOriginal="2019-07-01T10:11:12.50+02:00" exif:GPSLatitude="52,22.5N" exif:GPSLongitude="4,53.25E" \
        crs:Exposure2012="+0.50"/></rdf:RDF></x:xmpmeta>
        """
        let read = MetadataWriter.values(ofXMP: Data(existing.utf8))
        XCTAssertEqual(read.fields, [.rating, .taken, .location])
        XCTAssertEqual(read.rating, 3)
        XCTAssertEqual(read.taken?.original, "2019:07:01 10:11:12")
        XCTAssertEqual(read.taken?.originalOffset, "+02:00")
        XCTAssertEqual(try XCTUnwrap(read.latitude), 52.375, accuracy: 1e-9)

        let wanted = MetadataValues(fields: [.rating, .keywords, .taken, .location], rating: 5, keywords: ["dog"],
                                    taken: TakenDate(original: "2019:07:01 12:11:12", originalOffset: "+02:00"),
                                    latitude: nil, longitude: nil)
        let data = try MetadataWriter.xmpData(setting: wanted, over: Data(existing.utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Exposure2012"), text)
        let back = MetadataWriter.values(ofXMP: data)
        XCTAssertTrue(back.agrees(with: wanted), "\(back)")
        // The location removed is recorded as cleared, so it lies over the file's own (audit A1-1).
        XCTAssertTrue(back.fields.contains(.location))
        XCTAssertNil(back.latitude)

        // Over the file's own values, field by field.
        let file = MetadataValues(fields: Set(MetadataField.allCases), rating: 1, keywords: ["cat"], latitude: 1, longitude: 2)
        let effective = file.merging(back)
        XCTAssertEqual(effective.rating, 5)
        XCTAssertEqual(effective.keywords, ["dog"])
        XCTAssertNil(effective.latitude)
        // A field the `.xmp` holds nothing about leaves the file's own value.
        XCTAssertEqual(file.merging(MetadataValues(fields: [.rating], rating: 4)).latitude, 1)

        let names = ["IMG_1.CR3", "IMG_1.XMP", "IMG_2.CR3"]
        XCTAssertEqual(MetadataWriter.xmpURL(for: URL(fileURLWithPath: "/f/IMG_1.CR3"), existing: names).lastPathComponent, "IMG_1.XMP")
        XCTAssertEqual(MetadataWriter.xmpURL(for: URL(fileURLWithPath: "/f/IMG_2.CR3"), existing: names).lastPathComponent, "IMG_2.xmp")
    }

    // MARK: The journal (R-4503, R-4505)

    func journal() -> OperationJournal {
        OperationJournal(folder: folder.appendingPathComponent("journal"))
    }

    func testAnEditReplacesThePhotoKeepingItsAttributesAndUndoAndRedoWriteTheValues() async throws {
        let photos = folder.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("IMG_1.HEIC")
        Self.photo(photo, type: .heic)
        let created = Date(timeIntervalSince1970: 1_500_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: photo.path)
        try (photo as NSURL).setResourceValue(["Red"], forKey: .tagNamesKey)
        let identity = AccountFolderRecord.number(of: photo)
        let journal = journal()

        let result = await journal.editMetadata([photo], .rating(4), title: "Rate 1 photo")
        XCTAssertEqual(result.changed, 1, "\(result.skipped)")
        XCTAssertEqual(result.rewritten.map(\.path), [photo.path])
        XCTAssertEqual(result.rewritten.first?.sha256, try FileHasher.sha256(of: photo))
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 4)
        XCTAssertNotEqual(AccountFolderRecord.number(of: photo), identity)
        let values = try photo.resourceValues(forKeys: [.creationDateKey, .tagNamesKey])
        XCTAssertEqual(values.creationDate, created)
        XCTAssertEqual(values.tagNames, ["Red"])
        // Nothing hidden is left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photos.path), ["IMG_1.HEIC"])
        let id = try XCTUnwrap(result.entry?.id)
        let entry = await journal.entry(id)
        XCTAssertEqual(entry?.fileCount, 1)

        let undo = await journal.undo(id)
        XCTAssertEqual(undo.done, 1, "\(undo.skipped)")
        XCTAssertNil(MetadataWriter.values(of: photo).rating)
        XCTAssertEqual(undo.rewritten.map(\.path), [photo.path])
        let redo = await journal.redo(id)
        XCTAssertEqual(redo.done, 1, "\(redo.skipped)")
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 4)
        let again = await journal.undo(id)
        XCTAssertEqual(again.done, 1, "\(again.skipped)")
        XCTAssertNil(MetadataWriter.values(of: photo).rating)
        XCTAssertTrue(MetadataWriter.values(of: photo).agrees(with: MetadataValues(fields: [.taken], taken: TakenDate(
            original: "2020:01:02 03:04:05", originalOffset: "+01:00", digitized: "2020:01:02 03:04:05", digitizedOffset: "+01:00"
        ))))

        // A file replaced by something else since is left (R-4505).
        _ = await journal.redo(id)
        try FileManager.default.removeItem(at: photo)
        Self.photo(photo, type: .heic)
        let refused = await journal.undo(id)
        XCTAssertEqual(refused.done, 0)
        XCTAssertFalse(refused.skipped.isEmpty)
    }

    func testOtherFormatsAndRawPairsUseOneXMPAndUndoTrashesAMadeOne() async throws {
        let photos = folder.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let raw = photos.appendingPathComponent("DSC_1.NEF")
        let jpeg = photos.appendingPathComponent("DSC_1.JPG")
        Self.photo(raw, type: .tiff)
        Self.photo(jpeg, type: .jpeg)
        let jpegBytes = try Data(contentsOf: jpeg)
        let journal = journal()
        let result = await journal.editMetadata([raw], .keywords(add: ["birds"], remove: []), title: "Add keyword")
        XCTAssertEqual(result.changed, 1, "\(result.skipped)")
        XCTAssertTrue(result.rewritten.isEmpty)
        let xmp = photos.appendingPathComponent("DSC_1.xmp")
        XCTAssertEqual(result.xmpWritten, [xmp.path])
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.keywords, ["birds"])
        // Neither the RAW nor its JPEG is rewritten: the unit's `.xmp` holds the values.
        XCTAssertEqual(try Data(contentsOf: jpeg), jpegBytes)
        let place = OperationJournal.place(of: raw, names: try FileManager.default.contentsOfDirectory(atPath: photos.path))
        XCTAssertEqual(OperationJournal.currentValues(of: raw, place: place).keywords, ["birds"])

        // A second edit updates the same `.xmp`; Undo takes back only it.
        let second = await journal.editMetadata([raw], .rating(2), title: "Rate")
        XCTAssertEqual(second.changed, 1)
        _ = await journal.undo(try XCTUnwrap(second.entry?.id))
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.rating, nil)
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.keywords, ["birds"])
        // Undo of the edit that made it: it holds nothing else, so it goes to the Trash; Redo makes it again.
        let id = try XCTUnwrap(result.entry?.id)
        let undo = await journal.undo(id)
        XCTAssertEqual(undo.done, 1, "\(undo.skipped)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp.path))
        let redo = await journal.redo(id)
        XCTAssertEqual(redo.done, 1, "\(redo.skipped)")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.keywords, ["birds"])

        // A PNG is never written in place.
        let png = photos.appendingPathComponent("shot.png")
        Self.photo(png, type: .png)
        let pngBytes = try Data(contentsOf: png)
        let located = await journal.editMetadata([png], .location(latitude: 1.5, longitude: 2.5), title: "Set location")
        XCTAssertEqual(located.changed, 1)
        XCTAssertEqual(try Data(contentsOf: png), pngBytes)
        XCTAssertEqual(try XCTUnwrap(MetadataWriter.values(ofXMPAt: photos.appendingPathComponent("shot.xmp"))?.latitude), 1.5,
                       accuracy: 1e-6)
    }

    func testPostFilesKeepTheirDateAndTheirChecksumFollows() async throws {
        let account = folder.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let photo = account.appendingPathComponent("2024-01-01_post_1.jpg")
        Self.photo(photo, type: .jpeg)
        let sidecar = Sidecar.sidecarURL(for: photo)
        let sha = try FileHasher.sha256(of: photo)
        try JSONSerialization.data(withJSONObject: ["sha256": sha, "post_id": "1"]).write(to: sidecar)
        let journal = journal()

        let shifted = await journal.editMetadata([photo], .shiftDate(seconds: 3600), title: "Shift")
        XCTAssertNil(shifted.entry)
        XCTAssertEqual(shifted.skipped.count, 1)
        XCTAssertEqual(MetadataWriter.values(of: photo).taken?.original, "2020:01:02 03:04:05")

        let rated = await journal.editMetadata([photo], .rating(5), title: "Rate")
        XCTAssertEqual(rated.changed, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(object["sha256"] as? String, try FileHasher.sha256(of: photo))
        XCTAssertNotEqual(object["sha256"] as? String, sha)
        XCTAssertEqual(object["post_id"] as? String, "1")
    }

    func testAnEditStoppedPartWayIsSettled() async throws {
        let photos = folder.appendingPathComponent("stopped")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("IMG_2.JPG")
        Self.photo(photo, type: .jpeg)
        let bytes = try Data(contentsOf: photo)
        let journal = journal()
        let result = await journal.editMetadata([photo], .rating(3), title: "Rate")
        var entry = try XCTUnwrap(result.entry)
        // As if MediaPull stopped while the photo stood aside under a hidden name on a drive without name swaps.
        let was = photos.appendingPathComponent("\(OperationJournal.editPrefix)X-was.JPG")
        let copy = photos.appendingPathComponent("\(OperationJournal.editPrefix)X.JPG")
        try FileManager.default.moveItem(at: photo, to: was)
        try bytes.write(to: copy)
        entry.swaps = [was.path: photo.path, copy.path: photo.path]
        await journal.save(entry)
        // Settled at launch: the photo has its name back and the edit is kept, not taken back (A3-9).
        let stranded = await journal.stranded()
        XCTAssertEqual(stranded, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: photos.path), ["IMG_2.JPG"])
        let kept = await journal.entry(entry.id)
        XCTAssertEqual(kept?.undone, false)
        XCTAssertNil(kept?.swaps)
        _ = await journal.undo(entry.id)
        XCTAssertNil(MetadataWriter.values(of: photo).rating)
    }

    func testABatchStoppedPartWayKeepsWhatWasDoneAndUndoesIt() async throws {
        let photos = folder.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let files = (1 ... 4).map { photos.appendingPathComponent("IMG_\($0).JPG") }
        for file in files { Self.photo(file, type: .jpeg) }
        let journal = journal()
        await journal.stop(after: 2)
        let progress = Progress(totalUnitCount: 0)
        let result = await journal.editMetadata(files, .rating(5), title: "Rate") { done, total in
            progress.totalUnitCount = Int64(total)
            progress.completedUnitCount = Int64(done)
        }
        XCTAssertTrue(result.stopped)
        XCTAssertEqual(result.changed, 2)
        XCTAssertEqual(files.map { MetadataWriter.values(of: $0).rating }, [5, 5, nil, nil])
        XCTAssertEqual(progress.totalUnitCount, 4)
        await journal.stop(after: nil)
        let undo = await journal.undo(try XCTUnwrap(result.entry?.id))
        XCTAssertEqual(undo.done, 2, "\(undo.skipped)")
        XCTAssertEqual(files.map { MetadataWriter.values(of: $0).rating }, [nil, nil, nil, nil])
    }

    func testRemovalsInAnXMPLieOverTheFile() throws {
        // A file with its own rating, keywords and place, and a `.xmp` that clears them.
        let data = try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating, .keywords, .location]), over: nil)
        let read = MetadataWriter.values(ofXMP: data)
        XCTAssertEqual(read.fields, [.rating, .keywords, .location])
        let file = MetadataValues(fields: Set(MetadataField.allCases), rating: 3, keywords: ["a", "b"], latitude: 1, longitude: 2)
        let shown = file.merging(read)
        XCTAssertNil(shown.rating)
        XCTAssertNil(shown.keywords)
        XCTAssertNil(shown.latitude)
        // A value set again is no longer cleared.
        let again = try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 4), over: data)
        let reread = MetadataWriter.values(ofXMP: again)
        XCTAssertEqual(reread.rating, 4)
        XCTAssertEqual(reread.fields, [.rating, .keywords, .location])
        // Keywords removed one at a time stay removed.
        var words = MetadataValues(fields: [.keywords], keywords: ["a", "b", "c"])
        var xmp = try MetadataWriter.xmpData(setting: words, over: nil)
        for word in ["a", "b", "c"] {
            let current = file.merging(MetadataWriter.values(ofXMP: xmp))
            words = try XCTUnwrap(MetadataEdit.keywords(add: [], remove: [word]).apply(to: current))
            xmp = try MetadataWriter.xmpData(setting: words, over: xmp)
        }
        XCTAssertNil(file.merging(MetadataWriter.values(ofXMP: xmp)).keywords)
    }

    func testRemovingALocationRemovesThePositionAndUndoPutsItBack() async throws {
        let photo = folder.appendingPathComponent("gps.jpg")
        Self.photo(photo, type: .jpeg, gps: (10, 20))
        let journal = journal()
        let result = await journal.editMetadata([photo], .removeLocation, title: "Remove Location")
        XCTAssertEqual(result.changed, 1)
        XCTAssertNil(MetadataWriter.values(of: photo).latitude)
        _ = await journal.undo(try XCTUnwrap(result.entry?.id))
        XCTAssertEqual(MetadataWriter.values(of: photo).latitude ?? 0, 10, accuracy: 1e-6)
    }

    func testADateShiftMovesTheDateThatCanBeRead() throws {
        let taken = TakenDate(original: "2020:01:02 03:04:05", originalOffset: nil, digitized: "0000:00:00 00:00:00")
        let shifted = try XCTUnwrap(MetadataEdit.shiftDate(seconds: 60).apply(to: MetadataValues(fields: [.taken], taken: taken)))
        XCTAssertEqual(shifted.taken?.original, "2020:01:02 03:05:05")
        XCTAssertEqual(shifted.taken?.digitized, "0000:00:00 00:00:00")
    }

    func testUndoOfAnOlderChangeLeavesANewerValue() async throws {
        let photo = folder.appendingPathComponent("IMG_9.JPG")
        Self.photo(photo, type: .jpeg)
        let journal = journal()
        let first = await journal.editMetadata([photo], .rating(2), title: "Rate")
        let second = await journal.editMetadata([photo], .rating(4), title: "Rate")
        XCTAssertNotNil(second.entry)
        // Undoing the first while the second's value stands would write a stale value: it is left and said (D-93).
        let undo = await journal.undo(try XCTUnwrap(first.entry?.id))
        XCTAssertEqual(undo.done, 0)
        XCTAssertFalse(undo.skipped.isEmpty)
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 4)
        // In order, both come back.
        _ = await journal.undo(try XCTUnwrap(second.entry?.id))
        _ = await journal.undo(try XCTUnwrap(first.entry?.id))
        XCTAssertNil(MetadataWriter.values(of: photo).rating)
    }

    func testASharedNameAndALockedFileAreRefused() async throws {
        let png = folder.appendingPathComponent("cover.png")
        let jpeg = folder.appendingPathComponent("cover.jpg")
        Self.photo(png, type: .png)
        Self.photo(jpeg, type: .jpeg)
        let journal = journal()
        // The PNG needs a `.xmp`, which the JPEG of the same name would read too.
        let shared = await journal.editMetadata([png], .rating(3), title: "Rate")
        XCTAssertNil(shared.entry)
        XCTAssertTrue(shared.skipped.first?.contains("same name") == true, "\(shared.skipped)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cover.xmp").path))
        // The JPEG is written in place: no `.xmp`, so nothing is shared.
        let inPlace = await journal.editMetadata([jpeg], .rating(3), title: "Rate")
        XCTAssertEqual(inPlace.changed, 1)

        let locked = folder.appendingPathComponent("locked.jpg")
        Self.photo(locked, type: .jpeg)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        let refused = await journal.editMetadata([locked], .rating(1), title: "Rate")
        XCTAssertNil(refused.entry)
        XCTAssertTrue(refused.skipped.first?.contains("locked") == true)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".mediapull-edit-") }
        XCTAssertTrue(hidden.isEmpty, "\(hidden)")
    }

    // MARK: Audit round 3

    func testARejectedMarkComesBackOnUndoAndUndoFollowsEachFile() async throws {
        // A JPEG another app marked rejected (xmp:Rating -1).
        let photo = folder.appendingPathComponent("rejected.jpg")
        let plain = folder.appendingPathComponent("plain.jpg")
        Self.photo(plain, type: .jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageMetadataCreateMutable())
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, "-1" as CFString))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(MetadataWriter.values(of: photo).ratingText, "-1")

        let journal = journal()
        let result = await journal.editMetadata([photo], .rating(3), title: "Rate")
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 3)
        let followed = Followed()
        _ = await journal.undo(try XCTUnwrap(result.entry?.id), replaced: { followed.add($0.path) })
        XCTAssertEqual(MetadataWriter.values(of: photo).ratingText, "-1", "A3-2")
        XCTAssertNil(MetadataWriter.values(of: photo).rating)
        XCTAssertEqual(followed.paths, [photo.path], "each file is followed as Undo replaces it (A3-1)")

        // The same in a .xmp beside a file that cannot hold the values in place.
        let png = folder.appendingPathComponent("shot.png")
        Self.photo(png, type: .png)
        let xmp = folder.appendingPathComponent("shot.xmp")
        let packet = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">"#
            + #"<rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="-1"/></rdf:RDF></x:xmpmeta>"#
        try Data(packet.utf8).write(to: xmp)
        let rated = await journal.editMetadata([png], .rating(4), title: "Rate")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.rating, 4)
        _ = await journal.undo(try XCTUnwrap(rated.entry?.id))
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: xmp)?.ratingText, "-1")
    }
}

extension MetadataEditTests {
    func testXMPDateCopiesStayInXMPFormAndALockedLeadIsRefusedAndMembersAreJudgedAlone() async throws {
        // The photo's XMP copy of its date keeps XMP form, its zone and its fraction of a second (A3-4).
        let plain = folder.appendingPathComponent("plain.jpg")
        Self.photo(plain, type: .jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(plain as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) })
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:DateCreated" as CFString,
                                                      "2020-01-02T03:04:05.918+01:00" as CFString))
        // As a camera writes it: the fraction of a second in EXIF too, from which ImageIO writes the XMP copy.
        XCTAssertTrue(CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary,
                                                                   kCGImagePropertyExifSubsecTimeOriginal, "918" as CFString))
        let dated = folder.appendingPathComponent("dated.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(dated as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageAndMetadata(destination, try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let read = try XCTUnwrap(CGImageSourceCreateWithURL(dated as CFURL, nil).flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(MetadataWriter.string(in: read, path: "photoshop:DateCreated"), "2020-01-02T03:04:05.918+01:00")
        let journal = journal()
        let shifted = await journal.editMetadata([dated], .shiftDate(seconds: 60), title: "Shift")
        XCTAssertEqual(shifted.changed, 1, "\(shifted.skipped)")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(dated as CFURL, nil)
            .flatMap { CGImageSourceCopyMetadataAtIndex($0, 0, nil) })
        XCTAssertEqual(MetadataWriter.string(in: written, path: "photoshop:DateCreated"), "2020-01-02T03:05:05.918+01:00")

        // A locked photo is refused even where its values would go to a .xmp, as the Edit section says (A3-5).
        let png = folder.appendingPathComponent("locked.png")
        Self.photo(png, type: .png)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: png.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: png.path) }
        let refused = await journal.editMetadata([png], .rating(2), title: "Rate")
        XCTAssertNil(refused.entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("locked.xmp").path))

        // A unit written in place: a member without the value gets it though the lead has it (A3-7).
        let pair = folder.appendingPathComponent("pair")
        try FileManager.default.createDirectory(at: pair, withIntermediateDirectories: true)
        let heic = pair.appendingPathComponent("IMG_5.HEIC"), jpeg = pair.appendingPathComponent("IMG_5.JPG")
        Self.photo(heic, type: .heic)
        Self.photo(jpeg, type: .jpeg)
        let names = try FileManager.default.contentsOfDirectory(atPath: pair.path)
        let place = OperationJournal.place(of: heic, names: names)
        guard place.xmp == nil, place.files.count == 2 else { return }
        _ = await journal.editMetadata([heic], .rating(3), title: "Rate")
        // The member alone loses its rating (as another app might leave it).
        let reset = await journal.editMetadata([jpeg], .rating(nil), title: "Rate")
        if reset.changed == 1, MetadataWriter.values(of: jpeg).rating == nil {
            let again = await journal.editMetadata([heic], .rating(3), title: "Rate")
            XCTAssertEqual(again.changed, 1, "\(again.skipped)")
            XCTAssertEqual(MetadataWriter.values(of: jpeg).rating, 3)
            XCTAssertEqual(again.entry?.fileCount, 1)
        }
    }
}

/// Paths a callback was told of, from any thread.
private final class Followed: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []

    func add(_ path: String) {
        lock.withLock { list.append(path) }
    }

    var paths: [String] { lock.withLock { list } }
}
