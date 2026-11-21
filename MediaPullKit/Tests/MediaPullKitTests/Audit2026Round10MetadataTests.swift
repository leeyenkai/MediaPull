import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullDevices
@testable import MediaPullLibrary
import UniformTypeIdentifiers
import XCTest

final class Audit2026Round10MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("A10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
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

    /// The listing a person sees: leads only (R-4206). Every photo must still be listed.
    func listed(_ url: URL) -> [String] {
        FolderOperations.mediaFiles(in: url, recursive: false).map(\.lastPathComponent).sorted()
    }

    /// A10-1: one rename giving two different shots one name ("Trip"): a camera's RAW and a phone's JPEG. They must not end
    /// as Trip.CR3 and Trip.JPG, one false RAW+JPEG unit with the JPEG hidden (D-120 as amended by A9-3).
    func testA10BatchRenameNeverGivesTwoShotsOfOneRenameOneName() async throws {
        let d = try dirs("F")[0]
        try raw(d.appendingPathComponent("IMG_5.CR3"))
        MetadataEditTests.photo(d.appendingPathComponent("IMG_9.JPG"), type: .jpeg)
        let plan = FolderOperations.batchRename([d.appendingPathComponent("IMG_5.CR3"), d.appendingPathComponent("IMG_9.JPG")],
                                                pattern: "Trip")
        let stems = plan.finalDestinations.values.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        XCTAssertEqual(Set(stems).count, 2, "two shots, two names: \(plan.moves.map(\.destination.lastPathComponent))")
        _ = await journal().run(plan)
        XCTAssertEqual(listed(d).count, 2, "both shots listed: \(all(d))")
    }

    /// A10-1b: the same for a still and a video: Trip.JPG and Trip.MOV become a false Live Photo with the video hidden.
    func testA10BatchRenameNeverMakesAFalseLivePhoto() async throws {
        let d = try dirs("F")[0]
        MetadataEditTests.photo(d.appendingPathComponent("A.JPG"), type: .jpeg)
        try Data(repeating: 7, count: 300).write(to: d.appendingPathComponent("B.MOV"))
        let plan = FolderOperations.batchRename([d.appendingPathComponent("A.JPG"), d.appendingPathComponent("B.MOV")], pattern: "Trip")
        _ = await journal().run(plan)
        XCTAssertEqual(listed(d).count, 2, "the video is listed: \(all(d))")
    }

    /// A10-2: a renumbering whose new name is another renamed file's old stem (2.JPG -> 1.JPG while 1.CR3 -> 2.CR3). The
    /// plan moves 2.JPG beside 1.CR3 first, making a unit, and 1.CR3's move then carries the JPEG along to 2.JPG.
    func testA10RenumberingThroughAnotherShotsStemKeepsShotsApart() async throws {
        let d = try dirs("F")[0]
        try raw(d.appendingPathComponent("1.CR3"))
        MetadataEditTests.photo(d.appendingPathComponent("2.JPG"), type: .jpeg)
        let plan = FolderOperations.batchRename([d.appendingPathComponent("2.JPG"), d.appendingPathComponent("1.CR3")], pattern: "{n}")
        XCTAssertEqual(Set(plan.finalDestinations.values.map(\.lastPathComponent)), ["1.JPG", "2.CR3"])
        let entry = await journal().run(plan)
        XCTAssertEqual(all(d), ["1.JPG", "2.CR3"], "as planned: \(entry.failures)")
    }

    /// A10-3: an iPhone's IMG_0001.HEIC is in the import folder; a camera card's IMG_0001.CR3 is imported into it (both
    /// default to the library folder, R-4104). The import must not make the two one RAW+HEIC unit hiding the phone's photo.
    func testA10ImportFromACameraNeverPairsWithAPhonesPhotoOfTheSameName() async throws {
        let card = try dirs("card/DCIM/100CANON")[0]
        let destination = try dirs("Library")[0]
        try raw(card.appendingPathComponent("IMG_0001.CR3"))
        MetadataEditTests.photo(destination.appendingPathComponent("IMG_0001.HEIC"), type: .heic)
        let identity = DeviceIdentity(name: "Card", serial: "volume:X", vendorID: 0, productID: 0)
        let source = FolderDeviceSource(root: folder.appendingPathComponent("card"), identity: identity)
        var entries: [DeviceEntry] = []
        var pending = [DeviceFolder(storage: "0")]
        while let next = pending.popLast() {
            for entry in try await source.children(of: next) {
                if entry.isFolder { pending.append(DeviceFolder(storage: "0", ref: entry.ref)) } else { entries.append(entry) }
            }
        }
        let index = ImportedIndex(folder: folder.appendingPathComponent("records"), device: identity)
        let plan = ImportPlan.make(entries, imported: [], existing: [], includeClips: false)
        let outcome = await DeviceImporter.run(plan.items, from: source, into: destination, index: index) { _, _, _ in }
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertEqual(listed(destination).count, 2, "the phone's HEIC stays listed: \(all(destination))")
    }

    /// A10-4: IMG_1.JPG moved X -> Y, undone; a camera's IMG_1.CR3 then arrives in Y; Redo must not put the JPEG beside it.
    func testA10RedoOfAMoveNeverPutsAFileBesideAnotherShotOfItsName() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([x.appendingPathComponent("IMG_1.JPG")], to: y))
        _ = await journal.undo(move.id)
        try raw(y.appendingPathComponent("IMG_1.CR3"))
        _ = await journal.redo(move.id)
        XCTAssertEqual(listed(x).count + listed(y).count, 2, "x: \(all(x)) y: \(all(y))")
    }

    /// A10-4b: the same for Undo: IMG_1.JPG sorted out of Inbox, then the camera card imported into Inbox, then ⌘Z.
    func testA10UndoOfAMoveNeverPutsAFileBesideAnotherShotOfItsName() async throws {
        let d = try dirs("Inbox", "Sorted")
        let inbox = d[0], sorted = d[1]
        MetadataEditTests.photo(inbox.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        let journal = journal()
        let move = await journal.run(FolderOperations.move([inbox.appendingPathComponent("IMG_1.JPG")], to: sorted))
        try raw(inbox.appendingPathComponent("IMG_1.CR3"))
        _ = await journal.undo(move.id)
        XCTAssertEqual(listed(inbox).count + listed(sorted).count, 2, "inbox: \(all(inbox)) sorted: \(all(sorted))")
    }

    /// A case-only change of a RAW pair's extension (IMG_1.CR3 -> IMG_1.cr3): the JPEG and .xmp keep their names.
    func testA10CaseOnlyExtensionRenameOfAPairKeepsItWhole() async throws {
        let d = try dirs("F")[0]
        try raw(d.appendingPathComponent("IMG_1.CR3"))
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try Data("<x/>".utf8).write(to: d.appendingPathComponent("IMG_1.xmp"))
        let journal = journal()
        let entry = await journal.run(FolderOperations.rename(d.appendingPathComponent("IMG_1.CR3"), to: "IMG_1.cr3"))
        XCTAssertEqual(all(d), ["IMG_1.JPG", "IMG_1.cr3", "IMG_1.xmp"], "\(entry.failures)")
        XCTAssertTrue(entry.failures.isEmpty, "\(entry.failures)")
        let undo = await journal.undo(entry.id)
        XCTAssertEqual(all(d), ["IMG_1.CR3", "IMG_1.JPG", "IMG_1.xmp"], "\(undo.skipped)")
    }

    /// Renaming a pair's lead to a new stem where the folder also holds an unrelated shot of that stem in other case.
    func testA10RenameOfALeadToAnotherShotsStemInOtherCaseIsNumbered() async throws {
        let d = try dirs("F")[0]
        try raw(d.appendingPathComponent("IMG_1.CR3"))
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        MetadataEditTests.photo(d.appendingPathComponent("beach.heic"), type: .heic)
        let entry = await journal().run(FolderOperations.rename(d.appendingPathComponent("IMG_1.CR3"), to: "Beach"))
        XCTAssertEqual(all(d), ["Beach 2.CR3", "Beach 2.JPG", "beach.heic"], "\(entry.failures)")
    }

    /// A10-3b: the Converter "next to originals" places a Live Photo's HEIC converted to JPEG beside it (AppModel.convertFiles
    /// -> LibraryModel.placeConverted -> FileOps.place). The JPEG must be listed, not hidden as the unit's member, and
    /// trashing the HEIC afterwards must not take the JPEG along.
    func testA10AConvertedStillPlacedBesideItsLivePhotoIsItsOwnShot() async throws {
        let d = try dirs("F")[0]
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        try Data(repeating: 7, count: 300).write(to: d.appendingPathComponent("IMG_1.MOV"))
        let converted = folder.appendingPathComponent("out.jpg")
        MetadataEditTests.photo(converted, type: .jpeg)
        let placed = try await FileOps.place(converted, as: d.appendingPathComponent("IMG_1.jpg"), with: .none)
        XCTAssertTrue(listed(d).contains(placed.url.lastPathComponent), "the JPEG is listed: \(all(d)), listed \(listed(d))")
        // Move to Trash of the HEIC (run's companions) would take the JPEG along.
        let companions = UnitFiles.companions(of: d.appendingPathComponent("IMG_1.HEIC")).map(\.lastPathComponent)
        XCTAssertFalse(companions.contains(placed.url.lastPathComponent), "trashing the HEIC takes: \(companions)")
    }
}
