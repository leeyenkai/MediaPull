import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullDevices
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullNet
import UniformTypeIdentifiers
import XCTest

/// Audit 2026-11-21, round 13 (auditor A): metadata edits and file operations.
final class Audit2026Round13MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        folder = root.appendingPathComponent("A13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func exFAT() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MEDIAPULL_EXFAT"] else { throw XCTSkip("needs an exFAT disk image") }
        return URL(fileURLWithPath: path)
    }

    var onTestVolume: Bool { ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"] != nil }
    func journal() -> OperationJournal { OperationJournal(folder: folder.appendingPathComponent("journal")) }

    func all(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" && !$0.hasPrefix("._") }
            .sorted()
    }

    func dirs(_ list: String...) throws -> [URL] {
        try list.map { name in
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func raw(_ url: URL) throws { try Data(repeating: 3, count: 500).write(to: url) }
    func clip(_ url: URL) throws { try Data(repeating: 7, count: 300).write(to: url) }
    func xmp(_ url: URL, rating: Int) throws {
        try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: rating), over: nil).write(to: url)
    }

    // MARK: Two photos and a clip of one name

    /// A Live Photo with a JPEG of the same name beside it (IMG_1.HEIC, IMG_1.JPG, IMG_1.MOV, as an export or a
    /// conversion elsewhere leaves them). `MediaUnits.units` makes the three one unit (HEIC lead, JPG and MOV members),
    /// so `run` moves all three; but `OperationJournal.units` groups steps by `isCompanionName`, where since A12-m3 a
    /// photo leads clips only: the steps become [HEIC] and [JPG, MOV]. Undo takes [JPG, MOV] back first, then finds
    /// "another photo" of the HEIC's name at home and leaves the HEIC in the destination: the unit is split.
    func testA13UndoOfAMoveOfTwoPhotosAndAClipBringsAllBack() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        // Since A13-1 the HEIC leads its clip and the JPEG is an item of its own (two tiles); both are moved.
        XCTAssertEqual(MediaUnits.units(in: all(x)).map(\.members), [["IMG_1.MOV"]], "the still leads its clip only")
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.HEIC"),
                                                             x.appendingPathComponent("IMG_1.JPG")], to: y))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        // Placing keeps shots of one name apart, so the second photo is numbered in Y; Undo puts both back as they were.
        XCTAssertEqual(all(y), ["IMG_1 2.JPG", "IMG_1.HEIC", "IMG_1.MOV"], "moved whole")
        XCTAssertEqual(entry.fileCount, 2, "two items moved, as the grid showed two tiles")
        let undo = await journal.undo(entry.id)
        XCTAssertEqual(all(x), ["IMG_1.HEIC", "IMG_1.JPG", "IMG_1.MOV"], "all back: X \(all(x)), Y \(all(y)), \(undo.skipped)")
    }

    /// The same unit sent to the Trash and put back: the HEIC stays in the Trash.
    func testA13UndoOfATrashOfTwoPhotosAndAClipBringsAllBack() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let x = try dirs("X")[0]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.trash([x.appendingPathComponent("IMG_1.HEIC"),
                                                              x.appendingPathComponent("IMG_1.JPG")]))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(all(x), [])
        let undo = await journal.undo(entry.id)
        XCTAssertEqual(all(x), ["IMG_1.HEIC", "IMG_1.JPG", "IMG_1.MOV"], "all back from the Trash: \(undo.skipped)")
    }

    // MARK: A lone photo's .xmp in a merge

    /// `FolderOperations.children` drops only the companions of units, so a lone photo's `.xmp` (a rating MediaPull
    /// wrote for a PNG, or a RAW's sidecar from another app beside a lone RAW) is planned as an item of its own in Merge
    /// and Remove Folder. Planned first (directory order), it takes the photo's stem in the target, the photo is numbered,
    /// and `run` then moves the photo without its `.xmp`: the rating no longer belongs to it.
    func testA13MergeKeepsALonePhotosXMPWithIt() async throws {
        let d = try dirs("A", "B")
        let a = d[0], b = d[1]
        for n in 0 ..< 24 {
            MetadataEditTests.photo(a.appendingPathComponent("P\(n).png"), type: .png)
            try xmp(a.appendingPathComponent("P\(n).xmp"), rating: 3)
        }
        let plan = FolderOperations.merge(a, into: b)
        let alone = plan.moves.filter { $0.source.pathExtension == "xmp" }.map(\.source.lastPathComponent)
        let entry = await journal().run(plan)
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        let names = all(b)
        let photos = names.filter { $0.hasSuffix(".png") }
        let orphaned = photos.filter { !names.contains(($0 as NSString).deletingPathExtension + ".xmp") }
        XCTAssertEqual(photos.count, 24)
        XCTAssertTrue(orphaned.isEmpty, "every photo keeps its .xmp: \(orphaned.count) lost it; planned alone: \(alone.count); \(names)")
    }

    /// Remove Folder (moves a subfolder's children up) has the same path.
    func testA13RemoveSubfolderKeepsALonePhotosXMPWithIt() async throws {
        let sub = try dirs("P/Sub")[0]
        let parent = sub.deletingLastPathComponent()
        for n in 0 ..< 24 {
            try raw(sub.appendingPathComponent("R\(n).CR3"))
            try xmp(sub.appendingPathComponent("R\(n).xmp"), rating: 2)
        }
        let entry = await journal().run(FolderOperations.removeSubfolders([sub]))
        let names = all(parent)
        let raws = names.filter { $0.hasSuffix(".CR3") }
        let orphaned = raws.filter { !names.contains(($0 as NSString).deletingPathExtension + ".xmp") }
        XCTAssertEqual(raws.count, 24, "\(names) \(entry.failures)")
        XCTAssertTrue(orphaned.isEmpty, "every RAW keeps its .xmp: \(orphaned.count) lost it; \(names)")
    }

    // MARK: Probes of the in-place writer

    /// A JPEG or HEIC with an orientation, a Display P3 profile, exposure details, a lens and another app's XMP label:
    /// after a rating is written in place, everything but the rating reads the same.
    func richPhoto(_ url: URL, type: UTType) {
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0 ..< 64 {
            context.setFillColor(red: CGFloat(x) / 64, green: 0.3, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05",
                                     kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifFNumber: 2.8,
                                     kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifLensModel: "Lens 35mm",
                                     kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifUserComment: "hello"]
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: exif, kCGImagePropertyOrientation: 6,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cam", kCGImagePropertyTIFFModel: "One",
                                                                       kCGImagePropertyTIFFOrientation: 6, kCGImagePropertyTIFFArtist: "Me",
                                                                       kCGImagePropertyTIFFCopyright: "(c) Me"],
                                      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.5, kCGImagePropertyGPSLatitudeRef: "N",
                                                                      kCGImagePropertyGPSLongitude: 2.5,
                                                                      kCGImagePropertyGPSLongitudeRef: "E",
                                                                      kCGImagePropertyGPSAltitude: 120.0],
                                      kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "A caption",
                                                                       kCGImagePropertyIPTCCity: "Town"]]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    func properties(_ url: URL) -> [String: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
    }

    func flat(_ dict: [String: Any], prefix: String = "") -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in dict {
            if let sub = value as? [String: Any] {
                out.merge(flat(sub, prefix: prefix + key + "."), uniquingKeysWith: { a, _ in a })
            } else {
                out[prefix + key] = "\(value)"
            }
        }
        return out
    }

    private func probeKeepsEverythingButTheRating(_ type: UTType, ext: String) async throws {
        let d = try dirs("F")[0]
        let photo = d.appendingPathComponent("IMG_1.\(ext)")
        richPhoto(photo, type: type)
        let before = flat(properties(photo))
        let space = { (url: URL) in CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0,
                                                                    nil)?.colorSpace?.name as String? }
        let spaceBefore = space(photo)
        let result = await journal().editMetadata([photo], .rating(4), title: "Rate")
        XCTAssertEqual(result.changed, 1, "\(result.skipped)")
        XCTAssertTrue(result.xmpWritten.isEmpty, "written in place")
        let after = flat(properties(photo))
        let ignored = ["{IPTC}.StarRating", "FileSize"]
        let lost = before.keys.filter { !ignored.contains($0) && after[$0] != before[$0] }.sorted()
        XCTAssertTrue(lost.isEmpty, "changed or lost: \(lost.map { "\($0): \(before[$0]!) -> \(after[$0] ?? "nil")" })")
        XCTAssertEqual(space(photo), spaceBefore, "colour profile kept")
    }

    func testA13ProbeJPEGRatingKeepsEverythingElse() async throws {
        try await probeKeepsEverythingButTheRating(.jpeg, ext: "JPG")
    }

    func testA13ProbeHEICRatingKeepsEverythingElse() async throws {
        try await probeKeepsEverythingButTheRating(.heic, ext: "HEIC")
    }

    // MARK: Locked members on Undo and Redo

    /// A12-4 refuses a unit with a locked file in `run` only. Undo of a move puts the lead back first
    /// (`undo(unit[0])`), then the clip's step fails on the lock: the Live Photo is split across two folders.
    func testA13UndoOfAMoveNeverSplitsAUnitWithALockedMember() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.HEIC")], to: y))
        XCTAssertEqual(all(y), ["IMG_1.HEIC", "IMG_1.MOV"])
        let mov = y.appendingPathComponent("IMG_1.MOV")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: mov.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: mov.path) }
        let undo = await journal.undo(entry.id)
        XCTAssertEqual(MediaUnits.units(in: all(x)).count + MediaUnits.units(in: all(y)).count, 1,
                       "the Live Photo stays whole: X \(all(x)), Y \(all(y)), \(undo.skipped)")
    }

    /// The same on Redo: the clip locked in X after Undo, Redo moves the still to Y and leaves the clip.
    func testA13RedoOfAMoveNeverSplitsAUnitWithALockedMember() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.HEIC")], to: y))
        _ = await journal.undo(entry.id)
        XCTAssertEqual(all(x), ["IMG_1.HEIC", "IMG_1.MOV"])
        let mov = x.appendingPathComponent("IMG_1.MOV")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: mov.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: mov.path) }
        let redo = await journal.redo(entry.id)
        XCTAssertEqual(MediaUnits.units(in: all(x)).count + MediaUnits.units(in: all(y)).count, 1,
                       "the Live Photo stays whole: X \(all(x)), Y \(all(y)), \(redo.skipped)")
    }

    // MARK: Redo of a Replace whose original went elsewhere

    /// Replace of a lone IMG_1.JPG (stem kept), Undo, the original then moved to another folder by MediaPull, and an
    /// unrelated IMG_1.MOV moved into its old folder (its stem is free there now). Redo of the Replace: `redo(.trash)`
    /// finds no original and counts it done, and the edit's move skips the shot rule because the Replace kept its stem
    /// (`replaceKeptStem`), so the edit lands beside the unrelated video: a false Live Photo that hides the video.
    func testA13RedoOfAReplaceWhoseOriginalMovedAwayNeverJoinsAnotherShot() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let d = try dirs("F", "G", "Videos")
        let f = d[0], g = d[1], videos = d[2]
        let original = f.appendingPathComponent("IMG_1.JPG")
        MetadataEditTests.photo(original, type: .jpeg)
        let edit = folder.appendingPathComponent("edit.jpg")
        MetadataEditTests.photo(edit, type: .jpeg, date: "2021:01:01 00:00:00")
        let journal = journal()
        let replace = try await journal.replace(original, identity: nil, with: edit, named: original, metadata: nil, title: "Edit")
        _ = await journal.undo(replace.id)
        XCTAssertEqual(all(f), ["IMG_1.JPG"])
        let away = await journal.run(FolderOperations.move([original], to: g))
        XCTAssertTrue(away.failures.isEmpty)
        try clip(videos.appendingPathComponent("IMG_1.MOV"))
        let inVideo = await journal.run(FolderOperations.move([videos.appendingPathComponent("IMG_1.MOV")], to: f))
        XCTAssertTrue(inVideo.failures.isEmpty)
        XCTAssertEqual(all(f), ["IMG_1.MOV"])
        let redo = await journal.redo(replace.id)
        XCTAssertTrue(MediaUnits.units(in: all(f)).isEmpty, "no false Live Photo: F \(all(f)), G \(all(g)), \(redo.skipped)")
    }
}
