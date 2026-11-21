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

/// Audit 2026-11-21, round 12: Replace and a unit, locked members, imports, exFAT saves, two photos of one name.
final class Audit2026Round12MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        let root = ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        folder = root.appendingPathComponent("A12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// An exFAT disk image named by MEDIAPULL_EXFAT; tests on one are skipped without it.
    func exFAT() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MEDIAPULL_EXFAT"] else { throw XCTSkip("needs an exFAT disk image") }
        return URL(fileURLWithPath: path)
    }

    var onTestVolume: Bool { ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"] != nil }
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

    /// Redo of an editor Replace of a Live Photo's still: `redo(.move)` from the hidden edit name runs `anotherShot`, which
    /// counts the still's own clip as another shot, so the edit is given "IMG_1 2.HEIC" and the Live Photo is split
    /// (the Redo side of A11-1).
    func testA12RedoOfReplaceOfALivePhotosStillKeepsItsName() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let d = try dirs("F")[0]
        let original = d.appendingPathComponent("IMG_1.HEIC")
        MetadataEditTests.photo(original, type: .heic)
        try clip(d.appendingPathComponent("IMG_1.MOV"))
        let edit = folder.appendingPathComponent("edit.heic")
        MetadataEditTests.photo(edit, type: .heic, date: "2021:01:01 00:00:00")
        let journal = journal()
        let entry = try await journal.replace(original, identity: nil, with: edit, named: original, metadata: Data("{}".utf8),
                                              title: "Edit")
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.HEIC.json", "IMG_1.MOV"])
        let undo = await journal.undo(entry.id)
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.MOV"], "undo: \(undo.skipped)")
        let redo = await journal.redo(entry.id)
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.HEIC.json", "IMG_1.MOV"], "redo keeps the Live Photo's name: \(redo.skipped)")
        XCTAssertEqual(MediaUnits.units(in: all(d)).map(\.kind), [.live])
    }

    /// An editor Replace with a new name (Preview → Edit, crop and type a new name, Replace: EditorModel.saveFile passes
    /// `wanted` with the new stem). A rename alone in the same editor carries the clip (FolderOperations.rename); with an
    /// edit the still takes the new name and its clip and `.aae` stay under the old one: the Live Photo is split (R-4206).
    func testA12ReplaceWithANewNameOfALivePhotosStillIsRefused() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let d = try dirs("F")[0]
        let original = d.appendingPathComponent("IMG_1.HEIC")
        MetadataEditTests.photo(original, type: .heic)
        try clip(d.appendingPathComponent("IMG_1.MOV"))
        let edit = folder.appendingPathComponent("edit.heic")
        MetadataEditTests.photo(edit, type: .heic, date: "2021:01:01 00:00:00")
        do {
            _ = try await journal().replace(original, identity: nil, with: edit, named: d.appendingPathComponent("Beach.heic"),
                                            metadata: nil, title: "Edit")
            XCTFail("a Live Photo's still is never replaced under another name")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("keeps its name"), error.localizedDescription)
        }
        XCTAssertEqual(all(d), ["IMG_1.HEIC", "IMG_1.MOV"], "nothing changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edit.path), "the edit is left where it was")
    }

    func entries(_ source: FolderDeviceSource) async throws -> [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var pending = [DeviceFolder(storage: "0")]
        while let next = pending.popLast() {
            for entry in try await source.children(of: next) {
                if entry.isFolder { pending.append(DeviceFolder(storage: "0", ref: entry.ref)) } else { entries.append(entry) }
            }
        }
        return entries
    }

    /// Import New of a Live Photo whose still fails to copy (a read error, a size that changed, here the size): the clip is
    /// still placed with `joining: true` (DeviceImport.importOne, `item.clipOf != nil`) under its own device name, so it
    /// joins whatever other shot of that name the folder already holds: an iPhone's earlier IMG_0001.JPG becomes a false
    /// Live Photo and the clip is hidden as its member (D-120).
    func testA12ClipWhosePhotoFailedNeverJoinsAnotherShotOfItsName() async throws {
        let card = try dirs("card/DCIM/100APPLE")[0]
        let destination = try dirs("Library")[0]
        MetadataEditTests.photo(card.appendingPathComponent("IMG_0001.HEIC"), type: .heic)
        try clip(card.appendingPathComponent("IMG_0001.MOV"))
        MetadataEditTests.photo(destination.appendingPathComponent("IMG_0001.JPG"), type: .jpeg, date: "2015:01:01 00:00:00")
        let identity = DeviceIdentity(name: "Phone", serial: "volume:Y", vendorID: 0, productID: 0)
        let source = FolderDeviceSource(root: folder.appendingPathComponent("card"), identity: identity)
        let plan = ImportPlan.make(try await entries(source), imported: [], existing: [], includeClips: true)
        XCTAssertEqual(plan.items.count, 2)
        // The still's size changes after it was listed: its copy fails with a size mismatch.
        let handle = try FileHandle(forWritingTo: card.appendingPathComponent("IMG_0001.HEIC"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 0]))
        try handle.close()
        let index = ImportedIndex(folder: folder.appendingPathComponent("records"), device: identity)
        let outcome = await DeviceImporter.run(plan.items, from: source, into: destination, index: index) { _, _, _ in }
        XCTAssertEqual(outcome.failed.count, 1, "the still failed")
        XCTAssertTrue(MediaUnits.units(in: all(destination)).isEmpty, "no false Live Photo: \(all(destination))")
        XCTAssertEqual(listed(destination).count, 2, "the old JPEG and the clip both listed: \(all(destination))")
    }

    /// Undo of a Replace skips the shot rule altogether (`entry.edits == nil` in undo(.trash), A11-2), and
    /// `replaceUndoRefusal` only checks the original's exact name. A Replace that renamed the photo (IMG_1.JPG edited and
    /// saved as "Beach"), then an Organise move of an unrelated IMG_1.MOV into the folder (allowed: no IMG_1 shot is there),
    /// then Undo of the Replace: the original comes back beside the video, a false Live Photo hiding the video.
    func testA12UndoOfARenamingReplaceNeverMakesAFalseLivePhoto() async throws {
        try XCTSkipIf(!onTestVolume, "trashes: needs a test disk image")
        let d = try dirs("F", "Videos")
        let f = d[0], videos = d[1]
        let original = f.appendingPathComponent("IMG_1.JPG")
        MetadataEditTests.photo(original, type: .jpeg)
        let edit = folder.appendingPathComponent("edit.jpg")
        MetadataEditTests.photo(edit, type: .jpeg, date: "2021:01:01 00:00:00")
        let journal = journal()
        let replace = try await journal.replace(original, identity: nil, with: edit, named: f.appendingPathComponent("Beach.jpg"),
                                                metadata: nil, title: "Edit")
        try clip(videos.appendingPathComponent("IMG_1.MOV"))
        let move = await journal.run(FolderOperations.move([videos.appendingPathComponent("IMG_1.MOV")], to: f))
        XCTAssertTrue(move.failures.isEmpty)
        XCTAssertEqual(all(f), ["Beach.jpg", "IMG_1.MOV"])
        let undo = await journal.undo(replace.id)
        XCTAssertTrue(MediaUnits.units(in: all(f)).isEmpty, "no false Live Photo: \(all(f)), \(undo.skipped)")
    }

    /// Probe (not a finding unless it fails): an in-place rating on an exFAT card, Undo and Redo, with nothing left hidden.
    func testA12ProbeInPlaceEditOnExFAT() async throws {
        let ex = try exFAT()
        let d = ex.appendingPathComponent("A12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let photo = d.appendingPathComponent("IMG_1.JPG")
        MetadataEditTests.photo(photo, type: .jpeg)
        MetadataEditTests.photo(d.appendingPathComponent("IMG_2.HEIC"), type: .heic)
        try clip(d.appendingPathComponent("IMG_2.MOV"))
        let journal = journal()
        let result = await journal.editMetadata([photo, d.appendingPathComponent("IMG_2.HEIC")], .rating(4), title: "Rate")
        XCTAssertEqual(result.changed, 2, "\(result.skipped)")
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 4)
        XCTAssertEqual(all(d).filter { !$0.hasPrefix("._") }, ["IMG_1.JPG", "IMG_2.HEIC", "IMG_2.MOV"])
        let entry = try XCTUnwrap(result.entry)
        let undo = await journal.undo(entry.id)
        XCTAssertNil(MetadataWriter.values(of: photo).rating, "\(undo.skipped)")
        let redo = await journal.redo(entry.id)
        XCTAssertEqual(MetadataWriter.values(of: photo).rating, 4, "\(redo.skipped)")
        XCTAssertEqual(all(d).filter { !$0.hasPrefix("._") }, ["IMG_1.JPG", "IMG_2.HEIC", "IMG_2.MOV"])
    }

    /// Organise Move of a Live Photo whose clip is locked in the Finder (OperationJournal.run): the still moves first, the
    /// clip's move fails, and nothing puts the still back, so the unit is split across two folders (R-4206: every move acts
    /// on the whole unit).
    func testA12MoveOfAUnitWithALockedMemberNeverSplitsIt() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        let mov = x.appendingPathComponent("IMG_1.MOV")
        try clip(mov)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: mov.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: mov.path) }
        let entry = await journal().run(FolderOperations.move([x.appendingPathComponent("IMG_1.HEIC")], to: y))
        XCTAssertFalse(entry.failures.isEmpty, "the locked clip is reported")
        XCTAssertEqual(MediaUnits.units(in: all(x)).count + MediaUnits.units(in: all(y)).count, 1,
                       "the Live Photo stays whole in one folder: X \(all(x)), Y \(all(y)), \(entry.failures)")
    }

    /// Probe: a web save (SavePipeline.place) into a folder on an exFAT drive, where an exclusive rename is not supported.
    func testA12ProbeWebSaveOntoExFAT() throws {
        let ex = try exFAT()
        let d = ex.appendingPathComponent("A12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let pipeline = SavePipeline(gate: NetworkGate(), converter: MediaConverter(ffmpeg: nil), index: FingerprintIndex(storeURL: nil),
                                    workDirectory: folder.appendingPathComponent(".work"), engine: nil)
        let file = folder.appendingPathComponent("download")
        MetadataEditTests.photo(file, type: .jpeg)
        let placed = try pipeline.place(file, in: d, name: "photo.jpg", conflict: .number)
        XCTAssertEqual(placed?.lastPathComponent, "photo.jpg")
        let again = folder.appendingPathComponent("download2")
        MetadataEditTests.photo(again, type: .jpeg)
        let second = try pipeline.place(again, in: d, name: "photo.jpg", conflict: .number)
        XCTAssertEqual(second?.lastPathComponent, "photo 2.jpg")
    }

    /// `OperationJournal.units` groups steps by `MediaUnits.isCompanionName`, which takes IMG_1.JPG for a member of
    /// IMG_1.HEIC although two photos are never a unit (MediaUnits.units). A batch rename of the two separate photos is
    /// then one item: History counts 1 file, and when the HEIC cannot be undone (renamed in the Finder since) the JPEG's
    /// rename is silently not undone and the change is marked undone, so it can never be taken back.
    func testA12TwoPhotosOfOneNameAreTwoItemsInTheJournal() async throws {
        let d = try dirs("F")[0]
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.HEIC"), type: .heic)
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        XCTAssertTrue(MediaUnits.units(in: all(d)).isEmpty, "two photos, two shots")
        let journal = journal()
        let plan = FolderOperations.batchRename([d.appendingPathComponent("IMG_1.HEIC"), d.appendingPathComponent("IMG_1.JPG")],
                                                pattern: "Trip {n}")
        let entry = await journal.run(plan)
        XCTAssertEqual(all(d), ["Trip 1.HEIC", "Trip 2.JPG"])
        XCTAssertEqual(entry.fileCount, 2, "two files renamed")
        try FileManager.default.moveItem(at: d.appendingPathComponent("Trip 1.HEIC"), to: d.appendingPathComponent("Finder.HEIC"))
        let undo = await journal.undo(entry.id)
        XCTAssertTrue(all(d).contains("IMG_1.JPG") || undo.skipped.contains { $0.contains("Trip 2") },
                      "the JPEG is put back or reported: \(all(d)), \(undo.skipped)")
    }
}
