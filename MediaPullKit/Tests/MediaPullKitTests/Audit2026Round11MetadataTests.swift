import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullDevices
@testable import MediaPullLibrary
@testable import MediaPullNet
import UniformTypeIdentifiers
import XCTest

/// Audit 2026-11-21, round 11: shot names through Replace, Redo of copies, saves and cross-folder renames.
final class Audit2026Round11MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        // Tests that trash run only on a disk image (its own `.Trashes`) named by MEDIAPULL_TEST_VOLUME, never the person's
        // Trash; the others run in the temporary folder.
        let root = ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        folder = root.appendingPathComponent("A11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func journal() -> OperationJournal { OperationJournal(folder: folder.appendingPathComponent("journal")) }

    func all(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }.sorted()
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

    func listed(_ url: URL) -> [String] {
        FolderOperations.mediaFiles(in: url, recursive: false).map(\.lastPathComponent).sorted()
    }

    /// An editor Replace of a Live Photo's still (Preview → Edit → Replace, EditorModel.saveFile → AppModel.replaceFile →
    /// OperationJournal.replace). The edit must take the still's own name so the Live Photo stays one unit (R-4206).
    func testA11ReplaceOfALivePhotosStillKeepsItsNameAndUnit() async throws {
        let d = try dirs("F")[0]
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try clip(d.appendingPathComponent("IMG_1.MOV"))
        let edit = folder.appendingPathComponent("edit.heic")
        MetadataEditTests.photo(edit, type: .heic, date: "2021:01:01 00:00:00")
        let entry = try await journal().replace(d.appendingPathComponent("IMG_1.HEIC"), identity: nil, with: edit,
                                                named: d.appendingPathComponent("IMG_1.HEIC"), metadata: nil, title: "Edit")
        XCTAssertTrue(entry.finished)
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.MOV"], "the edit keeps the Live Photo's name")
        XCTAssertEqual(MediaUnits.units(in: all(d)).map(\.kind), [.live])
    }

    /// Undo of that Replace must put the original still back, not leave it in the Trash because its own clip is "another
    /// photo" (OperationJournal.undo .trash → anotherShot(at:current: nil)).
    func testA11UndoOfReplaceOfALivePhotosStillPutsTheOriginalBack() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"] == nil, "trashes: needs a test disk image")
        let d = try dirs("F")[0]
        let original = d.appendingPathComponent("IMG_1.HEIC")
        MetadataEditTests.photo(original, type: .heic)
        let originalBytes = try Data(contentsOf: original)
        try clip(d.appendingPathComponent("IMG_1.MOV"))
        let edit = folder.appendingPathComponent("edit.heic")
        MetadataEditTests.photo(edit, type: .heic, date: "2021:01:01 00:00:00")
        let journal = journal()
        let entry = try await journal.replace(original, identity: nil, with: edit, named: original, metadata: nil, title: "Edit")
        let report = await journal.undo(entry.id)
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.MOV"], "skipped: \(report.skipped)")
        XCTAssertEqual(try? Data(contentsOf: original), originalBytes, "the original is back: \(report.skipped)")
    }

    /// Redo of a copy (D-120 as amended in round 10: Redo never puts a photo beside another shot of its name). IMG_1.JPG
    /// copied X -> Y, undone, a camera's IMG_1.CR3 then imported into Y: Redo must not make a false RAW+JPEG unit.
    func testA11RedoOfACopyNeverPutsAPhotoBesideAnotherShotOfItsName() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([x.appendingPathComponent("IMG_1.JPG")], to: y))
        XCTAssertEqual(all(y), ["IMG_1.JPG"])
        _ = await journal.undo(copy.id)
        XCTAssertEqual(all(y), [])
        try raw(y.appendingPathComponent("IMG_1.CR3"))
        _ = await journal.redo(copy.id)
        XCTAssertTrue(MediaUnits.units(in: all(y)).isEmpty, "no false RAW+JPEG unit in Y: \(all(y))")
        XCTAssertEqual(listed(y).count, all(y).count, "every file in Y listed: \(all(y)), listed \(listed(y))")
    }

    /// A web Save (SavePipeline.place, also every Instagram and gallery save) into a folder holding an iPhone video
    /// IMG_1234.MOV: the saved IMG_1234.jpg must not make the video a hidden Live Photo clip (D-120: "saves").
    func testA11WebSaveNeverMakesAFalseLivePhotoWithAVideoOfItsName() throws {
        let d = try dirs("F")[0]
        try clip(d.appendingPathComponent("IMG_1234.MOV"))
        let pipeline = SavePipeline(gate: NetworkGate(), converter: MediaConverter(ffmpeg: nil), index: FingerprintIndex(storeURL: nil),
                                    workDirectory: folder.appendingPathComponent(".work"), engine: nil)
        let file = folder.appendingPathComponent("download")
        MetadataEditTests.photo(file, type: .jpeg)
        let placed = try pipeline.place(file, in: d, name: "IMG_1234.jpg", conflict: .number)
        XCTAssertNotNil(placed)
        XCTAssertEqual(listed(d).count, 2, "the video stays listed: \(all(d)), listed \(listed(d))")
    }
    /// A batch rename of a selection from two folders (Library search across subfolders). B holds "Trip 2.CR3" outside the
    /// rename; A's "Trip 2.CR3" is in it. `otherShots` leaves out names of the rename in every folder, so B's RAW is not
    /// seen and B's JPEG is named "Trip 2.JPG" beside it: a false RAW+JPEG unit hiding the JPEG.
    func testA11BatchRenameAcrossFoldersSeesAnotherFoldersShotOfARenamedName() async throws {
        let d = try dirs("A", "B")
        let a = d[0], b = d[1]
        try raw(a.appendingPathComponent("Trip 2.CR3"))
        try raw(b.appendingPathComponent("Trip 2.CR3"))
        MetadataEditTests.photo(b.appendingPathComponent("IMG_7.JPG"), type: .jpeg)
        let plan = FolderOperations.batchRename([a.appendingPathComponent("Trip 2.CR3"), b.appendingPathComponent("IMG_7.JPG")],
                                                pattern: "Trip {n}")
        _ = await journal().run(plan)
        XCTAssertTrue(MediaUnits.units(in: all(b)).isEmpty, "no false unit in B: \(all(b))")
        XCTAssertEqual(listed(b).count, 2, "both of B's shots listed: \(all(b))")
    }
}
