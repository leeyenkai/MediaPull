import Foundation
@testable import MediaPullLibrary
import XCTest

/// Findings from the sixth audit.
final class Audit6Tests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audit6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    private let precomposed = "caf\u{E9}.jpg"
    private let decomposed = "cafe\u{301}.jpg"

    /// B6-m10: one name written precomposed in one subfolder and decomposed in another is one name on the volume, so
    /// flattening gives the two files different names.
    func testFlattenKeepsUnicodeFormsApart() throws {
        _ = try file("a/" + precomposed)
        _ = try file("b/" + decomposed)
        let plan = FolderOperations.flatten(root)
        XCTAssertEqual(plan.moves.count, 2)
        let keys = Set(plan.moves.map { OrganisePlan.key($0.destination) })
        XCTAssertEqual(keys.count, 2, "\(plan.moves.map(\.destination.lastPathComponent))")
        XCTAssertEqual(plan.renamed, 1)
    }

    /// The same for a move into one folder.
    func testMoveKeepsUnicodeFormsApart() throws {
        let first = try file("a/" + precomposed), second = try file("b/" + decomposed)
        let plan = FolderOperations.move([first, second], to: root.appendingPathComponent("into", isDirectory: true))
        XCTAssertEqual(Set(plan.moves.map { OrganisePlan.key($0.destination) }).count, 2)
    }

    /// A batch rename that gives two files the same name in different Unicode forms numbers the second.
    func testBatchRenameKeepsUnicodeFormsApart() throws {
        let first = try file("r/one.jpg"), second = try file("r/two.jpg")
        let plan = FolderOperations.batchRename([first, second], pattern: "caf\u{E9}")
        XCTAssertEqual(Set(plan.finalDestinations.values.map { OrganisePlan.key($0) }).count, 2)
    }
}
