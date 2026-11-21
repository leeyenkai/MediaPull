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

/// Audit 2026-11-22, round 14 (auditor A): metadata edits and file operations.
final class Audit2026Round14MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        folder = root.appendingPathComponent("A14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
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

    func clip(_ url: URL) throws { try Data(repeating: 7, count: 300).write(to: url) }
    func aae(_ url: URL) throws { try Data("<plist>adjustments</plist>".utf8).write(to: url) }

    /// The lead of the unit `name` belongs to in `folder`, if any.
    func leadOf(_ name: String, in folder: URL) -> String? {
        MediaUnits.units(in: all(folder)).first { $0.members.contains(name) }?.lead
    }

    // MARK: A14-1 a unit's clip is put back beside another photo that sorts first

    /// A JPEG Live Photo (IMG_1.JPG + IMG_1.MOV) is moved from X to Y; another camera's IMG_1.HEIC then lands in X.
    /// Undo checks the shot rule for the JPEG alone (`anotherShot`: a JPEG beside a HEIC is two items) and puts it
    /// back; the MOV follows as a companion with no check. In X the MOV now joins IMG_1.HEIC (it sorts first), so the
    /// other camera's still becomes a Live Photo with this clip, and the JPEG has lost its clip.
    func testA14UndoNeverPutsAClipBesideAnotherPhotoThatWouldLeadIt() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.JPG")], to: y))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(all(y), ["IMG_1.JPG", "IMG_1.MOV"])
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic, date: "2023:05:06 07:08:09")
        let undo = await journal.undo(entry.id)
        let lead = leadOf("IMG_1.MOV", in: x) ?? leadOf("IMG_1.MOV", in: y)
        XCTAssertEqual(lead, "IMG_1.JPG", "the clip stays with its own still: X \(all(x)), Y \(all(y)), \(undo.skipped)")
    }

    /// Redo of the same move into a folder where another IMG_1.HEIC arrived after the Undo.
    func testA14RedoNeverPutsAClipBesideAnotherPhotoThatWouldLeadIt() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.JPG")], to: y))
        _ = await journal.undo(entry.id)
        XCTAssertEqual(all(x), ["IMG_1.JPG", "IMG_1.MOV"])
        MetadataEditTests.photo(y.appendingPathComponent("IMG_1.HEIC"), type: .heic, date: "2023:05:06 07:08:09")
        let redo = await journal.redo(entry.id)
        let lead = leadOf("IMG_1.MOV", in: x) ?? leadOf("IMG_1.MOV", in: y)
        XCTAssertEqual(lead, "IMG_1.JPG", "the clip stays with its own still: X \(all(x)), Y \(all(y)), \(redo.skipped)")
    }

    /// Put back from the Trash: the same, on a test disk image.
    func testA14UndoOfATrashNeverPutsAClipBesideAnotherPhotoThatWouldLeadIt() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let x = try dirs("X")[0]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.trash([x.appendingPathComponent("IMG_1.JPG")]))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(all(x), [])
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic, date: "2023:05:06 07:08:09")
        let undo = await journal.undo(entry.id)
        XCTAssertNotEqual(leadOf("IMG_1.MOV", in: x), "IMG_1.HEIC",
                          "the clip never becomes the other still's: X \(all(x)), \(undo.skipped)")
    }

    // MARK: A14-2 a lone photo takes another shot's edit files

    /// IMG_1.HEIC + IMG_1.MOV + IMG_1.AAE (a Live Photo with its adjustments) and IMG_1.JPG (a converted copy) in one
    /// folder. Since A13-1 the JPEG is an item of its own, and `MediaUnits.companions(ofLead:)` gives every lead the edit
    /// files of its stem, so moving the JPEG alone takes the Live Photo's `.aae` with it.
    func testA14MovingALonePhotoLeavesAnotherShotsEditFiles() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        try aae(x.appendingPathComponent("IMG_1.AAE"))
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let entry = await journal().run(FolderOperations.move([x.appendingPathComponent("IMG_1.JPG")], to: y))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(all(x), ["IMG_1.AAE", "IMG_1.HEIC", "IMG_1.MOV"], "the Live Photo keeps its adjustments: Y \(all(y))")
    }

    /// Trash Extra Copies of the JPEG (it duplicates the still): the Live Photo's `.aae` goes to the Trash with it.
    func testA14TrashingALonePhotoLeavesAnotherShotsEditFiles() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let x = try dirs("X")[0]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        try aae(x.appendingPathComponent("IMG_1.AAE"))
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let entry = await journal().run(FolderOperations.trash([x.appendingPathComponent("IMG_1.JPG")]))
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        XCTAssertEqual(all(x), ["IMG_1.AAE", "IMG_1.HEIC", "IMG_1.MOV"], "only the JPEG went to the Trash")
    }

    // MARK: A14-3 Undo puts an edit file beside another photo of its name

    /// A PNG rated three stars (P.png + P.xmp, written by MediaPull) is moved from X to Y; a camera's P.JPG then lands in
    /// X. Before round 13 Undo left the PNG where it was (another shot of its name); since A13-1 `anotherShot` asks only
    /// whether the PNG would join a unit, which a PNG never does, so the PNG goes back and `carryEditFiles` brings the
    /// `.xmp`. Both photos now read it: the JPEG shows the PNG's rating, and moving the JPEG later takes the PNG's `.xmp`.
    func testA14UndoNeverPutsAnEditFileBesideAnotherPhotoOfItsName() async throws {
        let d = try dirs("X", "Y", "Z")
        let x = d[0], y = d[1], z = d[2]
        MetadataEditTests.photo(x.appendingPathComponent("P.png"), type: .png)
        try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 3), over: nil)
            .write(to: x.appendingPathComponent("P.xmp"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("P.png")], to: y))
        XCTAssertEqual(all(y), ["P.png", "P.xmp"])
        MetadataEditTests.photo(x.appendingPathComponent("P.JPG"), type: .jpeg)
        let undo = await journal.undo(entry.id)
        let jpeg = x.appendingPathComponent("P.JPG")
        let place = OperationJournal.place(of: jpeg, names: all(x))
        XCTAssertNil(place.xmp, "the camera's JPEG reads no other photo's .xmp: X \(all(x)), Y \(all(y)), \(undo.skipped)")
        XCTAssertNotEqual(OperationJournal.currentValues(of: jpeg, place: place).rating, 3, "the JPEG never shows the PNG's rating")
        // And the next ordinary move of the JPEG takes the PNG's rating with it.
        _ = await journal.run(FolderOperations.move([jpeg], to: z))
        let png = [x, y].first { all($0).contains("P.png") }!
        XCTAssertTrue(all(png).contains("P.xmp"), "the PNG keeps its .xmp: X \(all(x)), Y \(all(y)), Z \(all(z))")
    }

    // MARK: A14-4 dropped files: a lone photo's edit file planned on its own

    /// A13-2 fixed `FolderOperations.children`, but `Sidecar.withoutCompanions` (every drop into the Library and
    /// Organise) still drops only the companions of units. An edited still (IMG_1.HEIC with its IMG_1.AAE, no clip)
    /// dragged from the Finder lists the `.AAE` first (it sorts first); planned on its own it takes the name, the
    /// photo is numbered, and the move separates them.
    func testA14DroppedLonePhotoKeepsItsEditFile() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try aae(x.appendingPathComponent("IMG_1.AAE"))
        let dropped = Sidecar.withoutCompanions([x.appendingPathComponent("IMG_1.AAE"), x.appendingPathComponent("IMG_1.HEIC")])
        XCTAssertEqual(dropped.map(\.lastPathComponent), ["IMG_1.HEIC"], "the edit file goes with its photo, never on its own")
        let entry = await journal().run(FolderOperations.move(dropped, to: y))
        let names = all(y)
        let photo = names.first { $0.hasSuffix(".HEIC") }.map { ($0 as NSString).deletingPathExtension } ?? "?"
        XCTAssertTrue(names.contains(photo + ".AAE"), "the photo keeps its adjustments: \(names) \(entry.failures)")
    }

    // MARK: A14-m1 a lone locked file is dropped from the change on Undo

    /// A13-3 keeps a unit with a locked file for a later Undo. A lone file locked since the move is reported and then
    /// dropped from the change (`canRetry` is false for it), so once it is unlocked ⌘Z can no longer put it back.
    func testA14UndoKeepsALoneLockedFileForLater() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("A.png"), type: .png)
        let journal = journal()
        let entry = await journal.run(FolderOperations.move([x.appendingPathComponent("A.png")], to: y))
        let moved = y.appendingPathComponent("A.png")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: moved.path)
        let first = await journal.undo(entry.id)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: moved.path)
        XCTAssertEqual(all(y), ["A.png"], "left while locked: \(first.skipped)")
        let second = await journal.undo(entry.id)
        let left = await journal.entry(entry.id)?.steps.count ?? -1
        XCTAssertEqual(all(x), ["A.png"], "once unlocked, Undo puts it back: \(second.skipped); \(left) steps left")
    }

    /// Redo of a copy: the same, the clip's copy is made beside another camera's IMG_1.HEIC without a check.
    func testA14RedoOfACopyNeverPutsAClipBesideAnotherPhotoThatWouldLeadIt() async throws {
        try XCTSkipIf(!onTestVolume, "Undo of a copy trashes: needs a test disk image")
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try clip(x.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.copy([x.appendingPathComponent("IMG_1.JPG")], to: y))
        XCTAssertEqual(all(y), ["IMG_1.JPG", "IMG_1.MOV"])
        _ = await journal.undo(entry.id)
        XCTAssertEqual(all(y), [])
        MetadataEditTests.photo(y.appendingPathComponent("IMG_1.HEIC"), type: .heic, date: "2023:05:06 07:08:09")
        let redo = await journal.redo(entry.id)
        XCTAssertNotEqual(leadOf("IMG_1.MOV", in: y), "IMG_1.HEIC",
                          "the copied clip never becomes the other still's: Y \(all(y)), \(redo.skipped)")
    }
}
