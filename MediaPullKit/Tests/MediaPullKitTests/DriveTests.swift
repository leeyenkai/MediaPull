import Foundation
@testable import MediaPullDevices
@testable import MediaPullLibrary
import XCTest

/// Section 43: drives told apart by UUID, and the record of where imports were placed.
final class DriveTests: XCTestCase {
    func testDrivePathsArePrunedOnlyWhenTheSameDriveIsBack() {
        let path = "/Volumes/Untitled/DCIM/IMG_0001.JPG"
        XCTAssertEqual(Volumes.mountPoint(of: path), "/Volumes/Untitled")
        XCTAssertNil(Volumes.mountPoint(of: "/Users/me/Pictures/a.jpg"))
        let table: [([String: Set<String>], String?, Bool, String)] = [
            (["/Volumes/Untitled": ["A"]], "A", true, "the same card is back without the file: gone"),
            (["/Volumes/Untitled": ["A"]], "B", false, "another card of the same name: kept"),
            (["/Volumes/Untitled": ["A", "B"]], "A", false, "two cards seen there: kept, as the file may be on the other"),
            ([:], "A", false, "a card never seen: kept"),
            (["/Volumes/Untitled": ["A"]], nil, false, "no card there: kept"),
        ]
        for (seen, mounted, gone, what) in table {
            XCTAssertEqual(Volumes.isGone(path, seen: seen) { _ in mounted }, gone, what)
        }
        XCTAssertTrue(Volumes.isGone("/Users/nobody-\(UUID().uuidString)/a.jpg", seen: [:]) { _ in nil }, "off the drives: gone")
    }

    func testTheTableRemembersEveryDriveSeenAtAMountPoint() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("volumes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let table = VolumeTable(url: file)
        let mount = URL(fileURLWithPath: "/Volumes/Untitled")
        table.note([DriveInfo(url: mount, name: "Untitled", uuid: "A", isReadOnly: false, isCameraCard: true)])
        table.note([DriveInfo(url: mount, name: "Untitled", uuid: "B", isReadOnly: false, isCameraCard: true)])
        XCTAssertEqual(VolumeTable(url: file).snapshot, ["/Volumes/Untitled": ["A", "B"]], "kept between launches")
    }

    func testImportsRecordWhereTheyWerePlacedAndFollowMoves() async throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("placed-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("sorted"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let device = DeviceIdentity(name: "Card", serial: "volume:X", vendorID: 0, productID: 0)
        let copy = folder.appendingPathComponent("IMG_1.JPG")
        try Data("picture".utf8).write(to: copy)
        let index = ImportedIndex(folder: folder.appendingPathComponent("records"), device: device)
        await index.record("n:img_1.jpg|7|-", placedAt: copy)
        await index.save()
        let moved = folder.appendingPathComponent("sorted/Beach.JPG")
        try fm.moveItem(at: copy, to: moved)
        let again = ImportedIndex(folder: folder.appendingPathComponent("records"), device: device)
        let found = await again.verifiedCopy(of: "n:img_1.jpg|7|-")
        XCTAssertEqual(found?.standardizedFileURL.resolvingSymlinksInPath().path, moved.standardizedFileURL.resolvingSymlinksInPath().path,
                       "the copy is followed through a move and a rename")
        try Data("changed".utf8).write(to: moved)
        let changed = await again.verifiedCopy(of: "n:img_1.jpg|7|-")
        XCTAssertNil(changed, "a copy that changed is no longer proof the original is safe to delete")
        let unknown = await again.verifiedCopy(of: "n:other|1|-")
        XCTAssertNil(unknown)
    }
}
