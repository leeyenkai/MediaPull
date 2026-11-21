import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullStore
import UniformTypeIdentifiers
import XCTest

/// Audit 2026-11-21, round 4.
final class Audit2026Round4Tests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Round4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func journal() -> OperationJournal {
        OperationJournal(folder: folder.appendingPathComponent("journal"))
    }

    func testUndoKeepsAnXMPAnotherAppAddedToAndTrashesOnlyAnEmptyOne() async throws {
        let png = folder.appendingPathComponent("shot.png")
        MetadataEditTests.photo(png, type: .png)
        let xmp = folder.appendingPathComponent("shot.xmp")
        let journal = journal()
        let rated = await journal.editMetadata([png], .rating(3), title: "Rate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmp.path))
        // A developer adds its settings to the .xmp MediaPull made (A4-1).
        let data = try Data(contentsOf: xmp)
        let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData).flatMap { CGImageMetadataCreateMutableCopy($0) })
        CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.adobe.com/camera-raw-settings/1.0/" as CFString, "crs" as CFString, nil)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(metadata, nil, "crs:Exposure2012" as CFString, "+0.50" as CFString))
        try XCTUnwrap(CGImageMetadataCreateXMPData(metadata, nil) as Data?).write(to: xmp)
        let undo = await journal.undo(try XCTUnwrap(rated.entry?.id))
        XCTAssertEqual(undo.done, 1, "\(undo.skipped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: xmp.path), "another app's settings are kept")
        XCTAssertNil(MetadataWriter.values(ofXMPAt: xmp)?.rating)
        XCTAssertTrue(String(decoding: try Data(contentsOf: xmp), as: UTF8.self).contains("Exposure2012"))

        // An .xmp emptied by Undo goes, whichever edit made it, and Redo makes it again (A4-8).
        let raw = folder.appendingPathComponent("IMG_1.png")
        MetadataEditTests.photo(raw, type: .png)
        let made = folder.appendingPathComponent("IMG_1.xmp")
        let first = await journal.editMetadata([raw], .rating(2), title: "Rate")
        let second = await journal.editMetadata([raw], .keywords(add: ["sea"], remove: []), title: "Keyword")
        _ = await journal.undo(try XCTUnwrap(first.entry?.id))
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: made)?.keywords, ["sea"])
        let emptied = await journal.undo(try XCTUnwrap(second.entry?.id))
        XCTAssertEqual(emptied.done, 1, "\(emptied.skipped)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path), "an emptied .xmp is not left beside the photo")
        let redo = await journal.redo(try XCTUnwrap(second.entry?.id))
        XCTAssertEqual(redo.done, 1, "\(redo.skipped)")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: made)?.keywords, ["sea"])
    }

    func testCorrectionsWinOverStaleFacesOfTheSameContent() async throws {
        // Redo writes bytes the store still holds from before (A4-2): the person named since is kept.
        let store = try AnalysisStore.make(folder: nil)
        await store.save(AnalysisRecord(sha256: "A", facts: MediaFacts()))
        await store.save(AnalysisRecord(sha256: "B", facts: MediaFacts()))
        await store.addFaces([NewFace(key: "f1", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "A")
        await store.addFaces([NewFace(key: "f1", vectorRow: 1, quality: 1, pixelSize: 100)], sha256: "B")
        let old = UUID(), named = UUID()
        _ = await store.applyAssignments(["B|f1": old])
        _ = await store.applyAssignments(["A|f1": named])
        _ = await store.rekey(from: "A", to: "B")
        let face = await store.faces().first { $0.key == "B|f1" }
        XCTAssertEqual(face?.personID, named)
    }

    func testADateShiftInAnXMPKeepsItsFormAndTheOtherCopy() throws {
        // A developer's .xmp with both copies of the date and a fraction of a second (A4-5).
        let packet = #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">"#
            + #"<rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/" "#
            + #"xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/" exif:DateTimeOriginal="2020-01-02T03:04:05.25+01:00" "#
            + #"photoshop:DateCreated="2020-01-02T03:04:05.25+01:00"/></rdf:RDF></x:xmpmeta>"#
        let before = MetadataWriter.values(ofXMP: Data(packet.utf8))
        let shifted = try XCTUnwrap(MetadataEdit.shiftDate(seconds: 60).apply(to: before))
        let data = try MetadataWriter.xmpData(setting: shifted, over: Data(packet.utf8))
        let metadata = try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData))
        XCTAssertEqual(MetadataWriter.string(in: metadata, path: "exif:DateTimeOriginal"), "2020-01-02T03:05:05.25+01:00")
        XCTAssertEqual(MetadataWriter.string(in: metadata, path: "photoshop:DateCreated"), "2020-01-02T03:05:05.25+01:00")
    }

    func testAnEditNeverOverwritesTheCorrectionsOfACopyWithTheSameContent() async throws {
        // P and Q are duplicates; Q was rated and its face named, then P is rated the same: same bytes (A5-2).
        let store = try AnalysisStore.make(folder: nil)
        await store.save(AnalysisRecord(sha256: "P0", facts: MediaFacts()))
        await store.save(AnalysisRecord(sha256: "R", facts: MediaFacts()))
        await store.addFaces([NewFace(key: "f1", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "P0")
        await store.addFaces([NewFace(key: "f1", vectorRow: 1, quality: 1, pixelSize: 100)], sha256: "R")
        await store.setPath("/lib/P.jpg", sha256: "P0", size: 1, modified: Date())
        await store.setPath("/lib/Q.jpg", sha256: "R", size: 1, modified: Date())
        let alice = UUID()
        _ = await store.applyAssignments(["R|f1": alice])
        _ = await store.rekey(from: "P0", to: "R")
        let face = await store.faces().first { $0.key == "R|f1" }
        XCTAssertEqual(face?.personID, alice, "the copy keeps its own correction")
    }

    func testAnXMPImageIOCannotReadIsNeverWrittenOverFromEmpty() throws {
        // An old Camera Raw root element (A5-1).
        let old = #"<x:xapmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">"#
            + #"<rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" crs:Exposure="+0.50"/>"#
            + #"</rdf:RDF></x:xapmeta>"#
        XCTAssertThrowsError(try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 3), over: Data(old.utf8)))
        XCTAssertNoThrow(try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 3), over: nil))
    }
}
