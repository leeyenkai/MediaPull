import Foundation
@testable import MediaPullAnalysis
@testable import MediaPullCore
@testable import MediaPullMedia
@testable import MediaPullStore
import XCTest

final class AnalysisSupportTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testGeocoderFindsTheNearestPlaceWithinFiftyKilometres() throws {
        let table = """
        Paris\tÎle-de-France\tFrance\t48.85341\t2.3488\t2138551
        Boulogne-Billancourt\tÎle-de-France\tFrance\t48.83545\t2.24128\t108782
        Singapore\t\tSingapore\t1.28967\t103.85007\t3547809
        Suva\tCentral\tFiji\t-18.14161\t178.44149\t77366
        Tromsø\tTroms\tNorway\t69.6489\t18.95508\t52436
        """
        let url = folder.appendingPathComponent("places.tsv")
        try table.write(to: url, atomically: true, encoding: .utf8)
        let geocoder = try XCTUnwrap(OfflineGeocoder(table: url))
        let cases: [(Double, Double, String?)] = [
            (48.8566, 2.3522, "Paris, Île-de-France, France"),
            (48.86, 2.30, "Paris, Île-de-France, France"),
            (1.35, 103.82, "Singapore, Singapore"),
            (-18.1, 178.45, "Suva, Central, Fiji"),
            (69.5, 19.3, "Tromsø, Troms, Norway"),
            (0, 0, nil),
            (48.85, 4.0, nil),
        ]
        for (lat, lon, expected) in cases {
            XCTAssertEqual(geocoder.place(latitude: lat, longitude: lon)?.display, expected, "\(lat), \(lon)")
        }
    }

    func testISO6709() {
        XCTAssertEqual(MediaFactsReader.parseISO6709("+37.3349-122.0090+030.000/")?.0, 37.3349)
        XCTAssertEqual(MediaFactsReader.parseISO6709("-33.8688+151.2093/")?.1, 151.2093)
        XCTAssertNil(MediaFactsReader.parseISO6709("nowhere"))
    }

    func testVectorStoreKeepsVectorsAcrossReloads() async {
        let a: [Float] = [1, 0, 0, 0], b: [Float] = [0, 1, 0, 0], c: [Float] = [0.6, 0.8, 0, 0]
        let store = VectorStore(folder: folder, name: "test", dimension: 4)
        await store.put("a", a)
        await store.put("b", b)
        await store.put("a", c)
        let reloaded = VectorStore(folder: folder, name: "test", dimension: 4)
        let count = await reloaded.count
        XCTAssertEqual(count, 2)
        let sims = await reloaded.similarities(to: [1, 0, 0, 0], keys: ["a", "b", "missing"])
        XCTAssertEqual(sims["a"] ?? 0, 0.6, accuracy: 0.01)
        XCTAssertEqual(sims["b"] ?? 1, 0, accuracy: 0.01)
        XCTAssertNil(sims["missing"])
    }

    func testFaceGroupingRespectsCorrections() {
        func vector(_ person: Int, _ noise: Int) -> [Float] {
            var v = [Float](repeating: 0, count: 8)
            v[person] = 1
            v[7] = Float(noise) * 0.05
            return FaceGrouping.normalized(v)
        }
        let alice = UUID(), bob = UUID()
        var faces = (0 ..< 4).map { FaceGrouping.Face(
            key: "a\($0)",
            vector: vector(0, $0),
            quality: 0.9,
            personID: nil,
            pinned: false,
            rejected: []
        ) }
        faces += (0 ..< 3).map { FaceGrouping.Face(
            key: "b\($0)",
            vector: vector(1, $0),
            quality: 0.9,
            personID: nil,
            pinned: false,
            rejected: []
        ) }
        faces.append(FaceGrouping.Face(key: "lonely", vector: vector(2, 0), quality: 0.9, personID: nil, pinned: false, rejected: []))
        let first = FaceGrouping.group(faces, threshold: 0.5)
        XCTAssertEqual(Set((0 ..< 4).compactMap { first["a\($0)"] ?? nil }).count, 1, "one person for every face of the first")
        XCTAssertNotEqual(first["a0"] ?? nil, first["b0"] ?? nil)
        XCTAssertNil(first["lonely"] ?? nil, "a single face does not make a person")

        // Existing people keep their faces, new faces join them, and a rejected person is never chosen again.
        faces = faces.map { var f = $0; f.personID = $0.key.hasPrefix("a") ? alice : $0.key.hasPrefix("b") ? bob : nil; return f }
        faces.append(FaceGrouping.Face(key: "a-new", vector: vector(0, 5), quality: 0.5, personID: nil, pinned: false, rejected: []))
        faces.append(FaceGrouping.Face(
            key: "a-rejected",
            vector: vector(0, 1),
            quality: 0.5,
            personID: nil,
            pinned: false,
            rejected: [alice]
        ))
        let second = FaceGrouping.group(faces, threshold: 0.5)
        XCTAssertEqual(second["a-new"] ?? nil, alice)
        XCTAssertNotEqual(second["a-rejected"] ?? nil, alice)
        XCTAssertNil(second["a0"], "unchanged faces are not reported")
    }

    func testNameSuggestion() {
        let alice = (1 ... 6).map { "/lib/Family/Alice Smith/\($0).jpg" }
        XCTAssertEqual(
            NameSuggestion.suggest(
                personPhotos: alice,
                peoplePhotosByFolder: ["/lib/Family/Alice Smith": 7, "/lib/Family": 30, "/lib": 200],
                accountFolders: []
            ),
            "Alice Smith"
        )
        XCTAssertNil(NameSuggestion.suggest(personPhotos: Array(alice.prefix(4)), peoplePhotosByFolder: [:], accountFolders: []),
                     "too few photos")
        XCTAssertNil(NameSuggestion.suggest(personPhotos: alice, peoplePhotosByFolder: ["/lib/Family/Alice Smith": 40], accountFolders: []),
                     "the folder is mostly other people")
        let account = (1 ... 6).map { "/lib/natgeo/posts/\($0).jpg" }
        XCTAssertNil(NameSuggestion.suggest(personPhotos: account, peoplePhotosByFolder: ["/lib/natgeo": 6, "/lib/natgeo/posts": 6],
                                            accountFolders: ["/lib/natgeo"]))
        let cases: [(String, Bool)] = [("Alice", true), ("Jean-Luc Picard", true), ("O'Brien", true), ("2024-05-01", false),
                                       ("posts", false), ("john_doe", false), ("Unsorted", false), ("media", false), ("IMG 2", false)]
        for (name, expected) in cases {
            XCTAssertEqual(NameSuggestion.looksLikeName(name), expected, name)
        }
    }

    func testAnalysisStoreFollowsMovesAndDeletesFaceData() async throws {
        let store = try AnalysisStore.make(folder: nil)
        var facts = MediaFacts()
        facts.pixelWidth = 10
        await store.save(AnalysisRecord(sha256: "abc", facts: facts, faces: [FaceBox(x: 0, y: 0, width: 0.5, height: 0.5, quality: 1,
                                                                                     pixelSize: 100, yaw: nil)]))
        await store.setPath("/lib/a.jpg", sha256: "abc", size: 1, modified: Date())
        await store.movePaths([(from: "/lib/a.jpg", to: "/lib/sorted/a.jpg")])
        let moved = await store.records(for: ["/lib/sorted/a.jpg", "/lib/a.jpg"])
        XCTAssertEqual(moved["/lib/sorted/a.jpg"]?.facts.pixelWidth, 10)
        XCTAssertNil(moved["/lib/a.jpg"])

        await store.addFaces([NewFace(key: "f1", vectorRow: 0, quality: 1, pixelSize: 100), NewFace(key: "f2", vectorRow: 1, quality: 1,
                                                                                                    pixelSize: 100)], sha256: "abc")
        let person = UUID()
        await store.applyAssignments(["abc|f1": person, "abc|f2": person])
        var people = await store.people()
        XCTAssertEqual(people.first?.faceCount, 2)
        XCTAssertEqual(people.first?.displayName, "Person 1")
        await store.reject(faceKeys: ["abc|f2"], from: person)
        people = await store.people()
        XCTAssertEqual(people.first?.faceCount, 1)
        let faces = await store.faces()
        XCTAssertEqual(faces.first { $0.key == "abc|f2" }?.rejected, [person])
        await store.deleteAllFaceData()
        let afterFaces = await store.faces()
        let afterPeople = await store.people()
        XCTAssertTrue(afterFaces.isEmpty)
        XCTAssertTrue(afterPeople.isEmpty)
        let record = await store.record(sha256: "abc")
        XCTAssertNotNil(record, "analysis results other than faces stay")
    }
}

final class SimilarSetTests: XCTestCase {
    func testCloseVectorsFormSets() {
        func v(_ a: Float, _ b: Float, _ c: Float) -> [Float] {
            let n = (a * a + b * b + c * c).squareRoot()
            return [a / n, b / n, c / n]
        }
        let vectors = [v(1, 0, 0), v(0.99, 0.05, 0), v(0, 1, 0), v(0, 0.98, 0.1), v(0, 0, 1)]
        let groups = SimilarSets.groups(vectors, threshold: 0.95)
        XCTAssertNotNil(groups[0])
        XCTAssertEqual(groups[0], groups[1])
        XCTAssertEqual(groups[2], groups[3])
        XCTAssertNotEqual(groups[0], groups[2])
        XCTAssertNil(groups[4])
    }
}
