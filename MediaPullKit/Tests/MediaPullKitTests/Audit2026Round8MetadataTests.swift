import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullAnalysis
@testable import MediaPullCore
@testable import MediaPullLibrary
@testable import MediaPullMedia
@testable import MediaPullStore
import UniformTypeIdentifiers
import XCTest

/// Auditor A, round 8: each test asserts the correct behaviour.
final class Audit2026Round8MetadataTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("A8-\(UUID().uuidString)")
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

    /// Two rated PNGs swap names (a batch rename through temporary names). Undo must give each its .xmp back under its
    /// own name, never leave a .xmp under a hidden temporary name.
    func testUndoOfASwapRenameLeavesNoXMPHidden() async throws {
        let d = try dirs("F")[0]
        let a = d.appendingPathComponent("A.png"), b = d.appendingPathComponent("B.png")
        MetadataEditTests.photo(a, type: .png)
        MetadataEditTests.photo(b, type: .png)
        let journal = journal()
        _ = await journal.editMetadata([a], .rating(1), title: "Rate")
        _ = await journal.editMetadata([b], .rating(5), title: "Rate")
        let swap = await journal.run(swapPlan(a, b))
        XCTAssertEqual(all(d), ["A.png", "A.xmp", "B.png", "B.xmp"])
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("B.xmp"))?.rating, 1, "forward swap")
        _ = await journal.undo(swap.id)
        XCTAssertEqual(all(d), ["A.png", "A.xmp", "B.png", "B.xmp"], "a .xmp was left under a temporary name")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("A.xmp"))?.rating, 1)
    }

    /// A real renumbering (Rename with "{n}" over files called 2 and 1, in that order): every file goes through a
    /// temporary name, and Undo must leave no rated photo's .xmp hidden.
    func testUndoOfARenumberingLeavesNoXMPHidden() async throws {
        let d = try dirs("F")[0]
        let two = d.appendingPathComponent("2.png"), one = d.appendingPathComponent("1.png")
        MetadataEditTests.photo(two, type: .png)
        MetadataEditTests.photo(one, type: .png)
        let journal = journal()
        _ = await journal.editMetadata([two], .rating(2), title: "Rate")
        _ = await journal.editMetadata([one], .rating(1), title: "Rate")
        let plan = FolderOperations.batchRename([two, one], pattern: "{n}")
        XCTAssertTrue(plan.moves.contains { $0.destination.lastPathComponent.hasPrefix(".mediapull-rename-") })
        let renamed = await journal.run(plan)
        XCTAssertEqual(all(d), ["1.png", "1.xmp", "2.png", "2.xmp"])
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("1.xmp"))?.rating, 2)
        _ = await journal.undo(renamed.id)
        XCTAssertEqual(all(d), ["1.png", "1.xmp", "2.png", "2.xmp"], "a .xmp was left under a temporary name")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("1.xmp"))?.rating, 1)
    }

    /// Redo of the same swap must also take both .xmp files to their photos' new names.
    func testRedoOfASwapRenameLeavesNoXMPHidden() async throws {
        let d = try dirs("F")[0]
        let a = d.appendingPathComponent("A.png"), b = d.appendingPathComponent("B.png")
        MetadataEditTests.photo(a, type: .png)
        MetadataEditTests.photo(b, type: .png)
        let journal = journal()
        _ = await journal.editMetadata([a], .rating(1), title: "Rate")
        _ = await journal.editMetadata([b], .rating(5), title: "Rate")
        let swap = await journal.run(swapPlan(a, b))
        _ = await journal.undo(swap.id)
        // Whatever Undo did, put the files right by hand so only Redo is judged.
        for name in all(d) where name.hasPrefix(".mediapull-rename-") {
            try? FileManager.default.removeItem(at: d.appendingPathComponent(name))
        }
        if !FileManager.default.fileExists(atPath: d.appendingPathComponent("A.xmp").path) {
            _ = await journal.editMetadata([a], .rating(1), title: "Rate")
            _ = await journal.editMetadata([b], .rating(5), title: "Rate")
        }
        XCTAssertEqual(all(d), ["A.png", "A.xmp", "B.png", "B.xmp"])
        _ = await journal.redo(swap.id)
        XCTAssertEqual(all(d), ["A.png", "A.xmp", "B.png", "B.xmp"], "a .xmp was left under a temporary name")
        XCTAssertEqual(MetadataWriter.values(ofXMPAt: d.appendingPathComponent("B.xmp"))?.rating, 1)
    }

    /// A plan that swaps two names, as `batchRename` builds it when names are swapped.
    func swapPlan(_ a: URL, _ b: URL) -> OrganisePlan {
        var plan = OrganisePlan(title: "Rename 2 Files", root: a.deletingLastPathComponent())
        let t0 = a.deletingLastPathComponent().appendingPathComponent(".mediapull-rename-test-0.png")
        let t1 = a.deletingLastPathComponent().appendingPathComponent(".mediapull-rename-test-1.png")
        plan.moves = [PlannedMove(source: a, destination: t0), PlannedMove(source: b, destination: t1),
                      PlannedMove(source: t0, destination: b), PlannedMove(source: t1, destination: a)]
        return plan
    }

    /// A copied folder holding a Live Photo (JPEG + MOV): the JPEG is rated in place afterwards. Undo of the copy must keep
    /// the Live Photo whole (R-4206, D-120), never trash its clip and keep the still.
    func testUndoOfAFolderCopyKeepsARatedLivePhotoWhole() async throws {
        let d = try dirs("Src/Trip", "Dst")
        let trip = d[0], dst = d[1]
        MetadataEditTests.photo(trip.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try Data(repeating: 7, count: 300).write(to: trip.appendingPathComponent("IMG_1.MOV"))
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([trip], to: dst))
        let copied = dst.appendingPathComponent("Trip")
        XCTAssertEqual(all(copied), ["IMG_1.JPG", "IMG_1.MOV"])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let rated = await journal.editMetadata([copied.appendingPathComponent("IMG_1.JPG")], .rating(4), title: "Rate")
        XCTAssertEqual(rated.changed, 1)
        _ = await journal.undo(copy.id)
        let left = all(copied)
        XCTAssertTrue(left == ["IMG_1.JPG", "IMG_1.MOV"] || left.isEmpty, "the Live Photo was split: \(left)")
    }

    /// A copied folder holding a PNG rated afterwards (its rating in a new .xmp): Undo must not trash the photo and leave
    /// its .xmp alone (the folder case of A7-4).
    func testUndoOfAFolderCopyKeepsARatedPNGWithItsXMP() async throws {
        let d = try dirs("Src/Trip", "Dst")
        let trip = d[0], dst = d[1]
        MetadataEditTests.photo(trip.appendingPathComponent("P.png"), type: .png)
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([trip], to: dst))
        let copied = dst.appendingPathComponent("Trip")
        _ = await journal.editMetadata([copied.appendingPathComponent("P.png")], .rating(5), title: "Rate")
        XCTAssertEqual(all(copied), ["P.png", "P.xmp"])
        _ = await journal.undo(copy.id)
        let left = all(copied)
        XCTAssertTrue(left == ["P.png", "P.xmp"] || left.isEmpty, "the photo went to the Trash without its .xmp: \(left)")
    }

    /// A copy made beside another photo's .xmp (Y holds P.jpg and P.xmp; P.png is copied in). Nothing was written since,
    /// so Undo of the copy must take it back.
    func testUndoOfACopyBesideAnotherPhotosXMPTakesTheCopyBack() async throws {
        let d = try dirs("X", "Y")
        let x = d[0], y = d[1]
        MetadataEditTests.photo(x.appendingPathComponent("P.png"), type: .png)
        MetadataEditTests.photo(y.appendingPathComponent("P.jpg"), type: .jpeg)
        try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 2), over: nil)
            .write(to: y.appendingPathComponent("P.xmp"))
        let journal = journal()
        let copy = await journal.run(FolderOperations.copy([x.appendingPathComponent("P.png")], to: y))
        XCTAssertTrue(all(y).contains("P.png"))
        _ = await journal.undo(copy.id)
        XCTAssertEqual(all(y), ["P.jpg", "P.xmp"], "the untouched copy was kept")
    }

    /// Case-only rename of a Live Photo (IMG_1.HEIC with its clip and .xmp to img_1.heic) and Undo: the .xmp's name
    /// must get its case back with its photo.
    func testUndoOfACaseOnlyRenameOfALivePhotoPutsTheXMPNameBack() async throws {
        let d = try dirs("F")[0]
        MetadataEditTests.photo(d.appendingPathComponent("IMG_1.JPG"), type: .jpeg)
        try Data(repeating: 7, count: 300).write(to: d.appendingPathComponent("IMG_1.MOV"))
        try MetadataWriter.xmpData(setting: MetadataValues(fields: [.rating], rating: 2), over: nil)
            .write(to: d.appendingPathComponent("IMG_1.xmp"))
        let journal = journal()
        let rename = await journal.run(FolderOperations.rename(d.appendingPathComponent("IMG_1.JPG"), to: "img_1.JPG"))
        XCTAssertEqual(all(d), ["img_1.JPG", "img_1.MOV", "img_1.xmp"])
        _ = await journal.undo(rename.id)
        XCTAssertEqual(all(d), ["IMG_1.JPG", "IMG_1.MOV", "IMG_1.xmp"])
    }

    /// "Not This Person" on an edited photo, then a full regroup, then Undo of the edit while the old content is still
    /// held (a copy, or not yet pruned): the person's correction must survive (R-3904); an automatic regroup is not a
    /// correction that may override it (D-126).
    func testARegroupNeverOverridesAPersonsCorrectionOnRekey() async throws {
        let store = try AnalysisStore.make(folder: nil)
        let v: [Float] = [1, 0, 0]
        var vectors: [String: [Float]] = [:]
        for sha in ["S1", "O1", "O2"] {
            await store.save(AnalysisRecord(sha256: sha, facts: MediaFacts()))
            await store.addFaces([NewFace(key: "f", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: sha)
            vectors["\(sha)|f"] = v
        }
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        await store.setPath("/backup/P.jpg", sha256: "S1", size: 1, modified: Date())
        await store.setPath("/lib/O1.jpg", sha256: "O1", size: 1, modified: Date())
        await store.setPath("/lib/O2.jpg", sha256: "O2", size: 1, modified: Date())
        let bob = UUID()
        _ = await store.applyAssignments(["S1|f": bob, "O1|f": bob, "O2|f": bob])
        // P is rated: S1 -> S2 (the backup still holds S1).
        _ = await store.rekey(from: "S1", to: "S2")
        vectors["S2|f"] = v
        await store.setPath("/lib/P.jpg", sha256: "S2", size: 2, modified: Date())
        try await Task.sleep(nanoseconds: 20_000_000)
        // The person says P's face is not this person.
        await store.reject(faceKeys: ["S2|f"], from: bob)
        try await Task.sleep(nanoseconds: 20_000_000)
        // Regroup (as AnalysisService.performRegroup does).
        let faces = await store.faces()
        let input = faces.map {
            FaceGrouping.Face(key: $0.key, vector: vectors[$0.key]!, quality: $0.quality, personID: $0.personID, pinned: $0.pinned,
                              rejected: Set($0.rejected))
        }
        let changes = FaceGrouping.group(input, threshold: 0.5, minimumGroup: 2, regroup: true, named: [])
        _ = await store.applyAssignments(changes, ifUnchangedSince: faces)
        let regrouped = await store.faces().first { $0.key == "O1|f" }?.personID
        // Undo of the rating on P: S2 -> S1, which the backup holds.
        _ = await store.rekey(from: "S2", to: "S1")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        let face = await store.faces().first { $0.key == "S1|f" }
        XCTAssertNotEqual(face?.personID, regrouped, "P's face went back to the person it was said not to be")
        XCTAssertTrue(face?.rejected.contains(bob) ?? false, "the person's \"Not This Person\" was lost")
    }

    /// A store from before `changed` was kept (every face nil): a correction made then on edited content must not lose to
    /// the stale faces of the content Undo writes back.
    func testACorrectionFromAnOlderStoreSurvivesRekeyOntoHeldContent() async throws {
        let store = try AnalysisStore.make(folder: nil)
        await store.save(AnalysisRecord(sha256: "S1", facts: MediaFacts()))
        await store.addFaces([NewFace(key: "f", vectorRow: 0, quality: 1, pixelSize: 100)], sha256: "S1")
        await store.setPath("/lib/P.jpg", sha256: "S1", size: 1, modified: Date())
        await store.setPath("/backup/P.jpg", sha256: "S1", size: 1, modified: Date())
        _ = await store.rekey(from: "S1", to: "S2")
        await store.setPath("/lib/P.jpg", sha256: "S2", size: 2, modified: Date())
        let bob = UUID()
        _ = await store.split(faceKeys: ["S2|f"], from: bob)
        // As an older store has it: no date of change anywhere.
        await store.clearChangedForTest()
        _ = await store.rekey(from: "S2", to: "S1")
        let face = await store.faces().first { $0.key == "S1|f" }
        XCTAssertTrue(face?.pinned ?? false, "the split made before the upgrade was lost")
        XCTAssertTrue(face?.rejected.contains(bob) ?? false)
    }
}

import SwiftData

extension AnalysisStore {
    func clearChangedForTest() {
        for face in (try? modelContext.fetch(FetchDescriptor<FaceModel>())) ?? [] {
            face.changed = nil
        }
        try? modelContext.save()
    }
}
