import Foundation
@testable import MediaPullCore
@testable import MediaPullLibrary
import XCTest

private func entry(_ name: String, date: Date, size: Int64 = 100, record: AnalysisRecord? = nil, source: SourceInfo? = nil) -> MediaEntry {
    MediaEntry(url: URL(fileURLWithPath: "/lib/\(name)"), size: size, created: date, modified: date,
               format: MediaFormat.fromExtension((name as NSString).pathExtension), source: source, record: record)
}

private func analysis(width: Int = 4000, height: Int = 3000, faces: [FaceBox] = [], labels: [ContentLabel] = [], text: String? = nil,
                      screenshot: Bool = false, colour: ColourName? = nil, capture: Date? = nil) -> AnalysisRecord
{
    var facts = MediaFacts()
    facts.pixelWidth = width
    facts.pixelHeight = height
    facts.format = .jpeg
    facts.captureDate = capture
    return AnalysisRecord(sha256: UUID().uuidString, facts: facts, labels: labels, text: text, isScreenshot: screenshot, colour: colour,
                          faces: faces)
}

private func face(area: Double) -> FaceBox {
    FaceBox(x: 0.1, y: 0.1, width: area.squareRoot(), height: area.squareRoot(), quality: 0.8, pixelSize: 200, yaw: 0)
}

final class LibraryQueryTests: XCTestCase {
    let day = Date(timeIntervalSince1970: 1_780_000_000)

    func testDateFallsBackFromCaptureToMetadataToFile() {
        let capture = day.addingTimeInterval(-86400)
        let sidecarDate = day.addingTimeInterval(-3600)
        let cases: [(MediaFacts?, SourceInfo?, Date)] = [
            ({ var f = MediaFacts(); f.captureDate = capture; return f }(), SourceInfo(date: sidecarDate), capture),
            (MediaFacts(), SourceInfo(date: sidecarDate), sidecarDate),
            (nil, nil, day),
        ]
        for (facts, source, expected) in cases {
            XCTAssertEqual(MediaDates.effective(facts: facts, source: source, created: day, modified: day.addingTimeInterval(9)), expected)
        }
    }

    func testFiltersCombine() {
        let items = [
            entry("portrait.jpg", date: day, record: analysis(faces: [face(area: 0.2)])),
            entry("group.jpg", date: day, record: analysis(faces: [face(area: 0.02), face(area: 0.02), face(area: 0.03)])),
            entry("tiny-face.jpg", date: day, record: analysis(faces: [face(area: 0.01)])),
            entry(
                "landscape.jpg",
                date: day,
                record: analysis(labels: [ContentLabel(identifier: "beach", confidence: 0.9)], colour: .blue)
            ),
            entry("shot.png", date: day, record: analysis(width: 1170, height: 2532, screenshot: true)),
            entry("unanalysed.jpg", date: day),
        ]
        let cases: [(LibraryFilter, [String])] = [
            ({ var f = LibraryFilter(); f.faces = .portraits; return f }(), ["portrait.jpg"]),
            ({ var f = LibraryFilter(); f.faces = .groups; return f }(), ["group.jpg"]),
            ({ var f = LibraryFilter(); f.faces = .withFaces; return f }(), ["group.jpg", "portrait.jpg", "tiny-face.jpg"]),
            ({ var f = LibraryFilter(); f.faces = .withoutFaces; return f }(), ["landscape.jpg", "shot.png"]),
            ({ var f = LibraryFilter(); f.screenshots = .screenshots; return f }(), ["shot.png"]),
            ({ var f = LibraryFilter(); f.orientations = [.portrait]; return f }(), ["shot.png"]),
            ({ var f = LibraryFilter(); f.tags = ["beach"]; f.colours = [.blue]; return f }(), ["landscape.jpg"]),
            ({ var f = LibraryFilter(); f.tags = ["beach"]; f.colours = [.red]; return f }(), []),
            ({ var f = LibraryFilter(); f.formats = [.png]; return f }(), ["shot.png"]),
        ]
        for (filter, expected) in cases {
            var query = LibraryQuery()
            query.filter = filter
            let names = items.filter { query.matches($0) }.map(\.name).sorted()
            XCTAssertEqual(names, expected, "\(filter)")
        }
    }

    func testSearchMatchesTextTagsAndSimilarity() {
        let items = [
            entry("IMG_1.jpg", date: day, record: analysis(labels: [ContentLabel(identifier: "dog", confidence: 0.8)])),
            entry("receipt.png", date: day, record: analysis(text: "Café Total 12.50")),
            entry("post.jpg", date: day, source: SourceInfo(username: "natgeo", description: "Sunset over the dunes")),
            entry("beach.jpg", date: day, record: analysis()),
        ]
        var query = LibraryQuery()
        let cases: [(String, [String: Float], [String])] = [
            ("dog", [:], ["IMG_1.jpg"]),
            ("cafe", [:], ["receipt.png"]),
            ("NATGEO sunset", [:], ["post.jpg"]),
            ("seaside", ["/lib/beach.jpg": 0.31, "/lib/IMG_1.jpg": 0.12], ["beach.jpg"]),
            ("dog", ["/lib/beach.jpg": 0.5], ["IMG_1.jpg", "beach.jpg"]),
        ]
        for (text, scores, expected) in cases {
            query.search = text
            let result = query.apply(items, context: .init(similarity: scores, similarityFloor: 0.2)).flatMap(\.items).map(\.name)
            XCTAssertEqual(result, expected, text)
        }
    }

    func testEventsSplitAtTheGap() {
        let times: [TimeInterval] = [0, 3600, 7200, 7200 + 4 * 3600, 7200 + 5 * 3600, 7200 + 30 * 3600]
        let items = times.enumerated().map { entry("\($0.offset).jpg", date: day.addingTimeInterval($0.element)) }
        var query = LibraryQuery()
        query.sort = .events
        query.ascending = true
        XCTAssertEqual(query.apply(items).map { $0.items.map(\.name) }, [["0.jpg", "1.jpg", "2.jpg"], ["3.jpg", "4.jpg"], ["5.jpg"]])
    }

    func testSortsBySizeAndSource() {
        let items = [
            entry("a.jpg", date: day, size: 10, source: SourceInfo(username: "zed")),
            entry("b.jpg", date: day, size: 30, source: SourceInfo(username: "amy")),
            entry("c.jpg", date: day, size: 20),
        ]
        var query = LibraryQuery()
        query.sort = .fileSize
        XCTAssertEqual(query.apply(items)[0].items.map(\.name), ["b.jpg", "c.jpg", "a.jpg"])
        query.sort = .source
        query.ascending = true
        XCTAssertEqual(query.apply(items)[0].items.map(\.name), ["b.jpg", "a.jpg", "c.jpg"])
    }

    func testScreenshotRule() {
        func facts(_ w: Int, _ h: Int, _ format: MediaFormat, camera: Bool = false, marker: Bool = false) -> MediaFacts {
            var f = MediaFacts()
            f.pixelWidth = w
            f.pixelHeight = h
            f.format = format
            f.hasCameraEXIF = camera
            f.screenCaptureMarker = marker
            return f
        }
        let cases: [(MediaFacts, String, Bool)] = [
            (facts(1170, 2532, .png), "IMG_0001.png", true),
            (facts(2532, 1170, .png), "a.png", true),
            (facts(3024, 1964, .png), "a.png", true),
            (facts(1170, 2532, .png, camera: true), "a.png", false),
            (facts(1170, 2532, .jpeg), "a.jpg", false),
            (facts(4032, 3024, .heic, camera: true), "IMG_2.heic", false),
            (facts(813, 611, .png, marker: true), "window.png", true),
            (facts(813, 611, .png), "Screenshot 2026-11-15 at 10.00.00.png", true),
            (facts(813, 611, .png), "chart.png", false),
        ]
        for (f, name, expected) in cases {
            XCTAssertEqual(ScreenshotRule.isScreenshot(facts: f, fileName: name), expected, name)
        }
    }

    func testDominantColour() {
        func grid(_ r: UInt8, _ g: UInt8, _ b: UInt8, accent: (UInt8, UInt8, UInt8)? = nil, cells: Int = 0) -> [UInt8] {
            (0 ..< 64).flatMap { i -> [UInt8] in i < cells && accent != nil ? [accent!.0, accent!.1, accent!.2] : [r, g, b] }
        }
        let cases: [([UInt8], ColourName)] = [
            (grid(220, 30, 30), .red),
            (grid(30, 80, 220), .blue),
            (grid(40, 170, 60), .green),
            (grid(250, 250, 250), .white),
            (grid(10, 10, 10), .black),
            (grid(120, 120, 120), .grey),
            (grid(120, 70, 30), .brown),
            (grid(240, 240, 240, accent: (230, 120, 20), cells: 24), .orange),
        ]
        for (g, expected) in cases {
            XCTAssertEqual(ColourName.dominant(grid: g), expected)
        }
    }
}

final class FolderOperationTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("organise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "x", sidecar: Bool = false) -> URL {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.data(using: .utf8)!.write(to: url)
        if sidecar {
            try? "{\"username\":\"a\"}".data(using: .utf8)!.write(to: Sidecar.sidecarURL(for: url))
        }
        return url
    }

    func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    func tree() -> [String] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        var out: [String] = []
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(relative(url))
            }
        }
        return out.sorted()
    }

    func testFlattenNumbersCollisionsAndKeepsDatePrefix() {
        file("2026-01-01_120000_a.jpg", "top")
        file("sub/2026-01-01_120000_a.jpg", "one", sidecar: true)
        file("sub/deeper/2026-01-01_120000_a.jpg", "two")
        file("sub/b.png")
        let plan = FolderOperations.flatten(root)
        XCTAssertEqual(plan.renamed, 2)
        XCTAssertEqual(Set(plan.moves.map(\.destination.lastPathComponent)),
                       ["2026-01-01_120000_a 2.jpg", "2026-01-01_120000_a 3.jpg", "b.png"])
        XCTAssertEqual(plan.foldersToTrash.map(\.lastPathComponent), ["sub"])
    }

    func testRunMovesSidecarsAndUndoRestoresTheTree() async {
        file("sub/a.jpg", "one", sidecar: true)
        file("sub/b.jpg", "two")
        file("c.jpg", "three")
        let before = tree()
        let journal = OperationJournal(folder: root.appendingPathComponent("../journal-\(UUID().uuidString)").standardizedFileURL)
        let entry = await journal.run(FolderOperations.flatten(root))
        XCTAssertEqual(tree(), ["a.jpg", "a.jpg.json", "b.jpg", "c.jpg"])
        XCTAssertTrue(entry.failures.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("sub").path),
            "the emptied folder went to the Trash"
        )
        let report = await journal.undo(entry.id)
        XCTAssertEqual(report.restored, 3, "two files and the folder from the Trash")
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertEqual(tree(), before)
    }

    func testUndoLeavesChangedFilesInPlace() async throws {
        file("sub/a.jpg", "one")
        file("sub/b.jpg", "two")
        let journal = OperationJournal(folder: root.appendingPathComponent("../journal-\(UUID().uuidString)").standardizedFileURL)
        let entry = await journal.run(FolderOperations.move(
            [root.appendingPathComponent("sub/a.jpg"), root.appendingPathComponent("sub/b.jpg")],
            to: root
        ))
        try try XCTUnwrap("changed contents".data(using: .utf8)?.write(to: root.appendingPathComponent("a.jpg")))
        let report = await journal.undo(entry.id)
        XCTAssertEqual(report.restored, 1)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertEqual(tree(), ["a.jpg", "sub/b.jpg"])
    }

    func testMergeCombinesSameNamedFolders() {
        file("A/x/1.jpg")
        file("B/x/1.jpg")
        file("B/2.jpg")
        let plan = FolderOperations.merge(root.appendingPathComponent("B"), into: root.appendingPathComponent("A"))
        XCTAssertEqual(Set(plan.moves.map { relative($0.destination) }), ["A/x/1 2.jpg", "A/2.jpg"])
        XCTAssertEqual(Set(plan.foldersToTrash.map(\.lastPathComponent)), ["x", "B"])
    }

    func testSortClonesGroupPhotosAndUsesUnsorted() async {
        let a = file("in/a.jpg", "a", sidecar: true)
        let b = file("in/b.jpg", "b")
        let c = file("in/c.jpg", "c")
        let people: [URL: [String]] = [a: ["Alice", "Media"], b: ["Bob"]]
        let plan = FolderOperations.sort([a, b, c], into: root, title: "Sort by Person") { url in
            SortRules.personFolders(names: people[url] ?? [], placement: .everyPerson)
        }
        XCTAssertEqual(plan.unsorted, 1)
        XCTAssertEqual(plan.cloneCount, 1)
        let journal = OperationJournal(folder: root.appendingPathComponent("../journal-\(UUID().uuidString)").standardizedFileURL)
        let entry = await journal.run(plan)
        XCTAssertEqual(tree(), ["Alice/a.jpg", "Alice/a.jpg.json", "Bob/b.jpg", "Unsorted/c.jpg", "_Media/a.jpg", "_Media/a.jpg.json"])
        _ = await journal.undo(entry.id)
        XCTAssertEqual(tree(), ["in/a.jpg", "in/a.jpg.json", "in/b.jpg", "in/c.jpg"])
    }

    func testGroupPhotoPlacement() {
        let cases: [(GroupPhotoPlacement, [String], [[String]])] = [
            (.everyPerson, ["A", "B"], [["A"], ["B"]]),
            (.sharedFolder, ["A", "B"], [[FolderNames.groupPhotos]]),
            (.firstPerson, ["A", "B"], [["A"]]),
            (.sharedFolder, ["A"], [["A"]]),
            (.everyPerson, [], []),
        ]
        for (placement, names, expected) in cases {
            XCTAssertEqual(SortRules.personFolders(names: names, placement: placement), expected)
        }
    }

    func testReservedNamesGetAnUnderscore() {
        XCTAssertEqual(FolderNames.safe("media"), "_media")
        XCTAssertEqual(FolderNames.safe("Your_Instagram_Activity"), "_Your_Instagram_Activity")
        XCTAssertEqual(FolderNames.safe("Alice"), "Alice")
    }
}
