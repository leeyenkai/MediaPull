import Foundation
@testable import MediaPullCore
@testable import MediaPullEngines
import XCTest

/// Regression tests for the 1.8 audit: untrusted input must never crash the app or vanish silently.
final class SafeNumberTests: XCTestCase {
    func testBytesNeverTrap() {
        let cases: [(Double?, Int64?)] = [
            (nil, nil), (.nan, nil), (.infinity, nil), (-.infinity, nil),
            (-5, 0), (0, 0), (1234.9, 1234), (1e20, SafeNumber.maxBytes), (Double(Int64.max), SafeNumber.maxBytes),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(SafeNumber.bytes(input), expected, "\(String(describing: input))")
        }
    }

    func testFiniteAndIntClamp() {
        XCTAssertNil(SafeNumber.finite(.nan))
        XCTAssertEqual(SafeNumber.finite(5e9, in: 0 ... 1000), 1000)
        XCTAssertEqual(SafeNumber.int(1e30), Int(Int32.max))
        XCTAssertEqual(SafeNumber.int(-3.7), -3)
        XCTAssertNil(SafeNumber.int(.infinity))
    }

    func testBridgeEventsWithHostileNumbersDecode() throws {
        let progress = BridgeEvent.decode(#"{"type":"progress","received":1e20,"total":99999999999999999999,"speed":1e400}"#)
        // 1e400 is not valid JSON for Swift's decoder: the line is unreadable, which the client now reports.
        XCTAssertNil(progress)
        let event = try XCTUnwrap(BridgeEvent.decode(#"{"type":"progress","received":1e20,"total":99999999999999999999}"#))
        guard case let .progress(received, total, _) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(received, SafeNumber.maxBytes)
        XCTAssertEqual(total, SafeNumber.maxBytes)
        let file = try XCTUnwrap(BridgeEvent.decode(#"{"type":"file","path":"/tmp/x.jpg","bytes":-1e300}"#))
        guard case let .file(info) = file else { return XCTFail("\(file)") }
        XCTAssertEqual(info.bytes, 0)
    }

    func testVideoSizeEstimateNeverTraps() {
        let format = VideoFormatInfo(id: "1", ext: "mp4", height: 720, width: 1280, fps: 30, vcodec: "avc1", acodec: "mp4a",
                                     abr: nil, tbr: 1e300, size: nil, drm: false)
        XCTAssertEqual(VideoDownloadFormat.bestMP4.estimatedBytes(in: [format], height: nil, duration: 1e300), nil)
    }
}

/// R-1305: an engine update is tested from its own folder before `active.json` names it.
final class EngineActivationTests: XCTestCase {
    func testCandidateEnginePathsComeFirstWithoutTouchingActiveFile() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("engines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let paths = EnginePaths(python: URL(fileURLWithPath: "/usr/bin/false"), bridgeDirectory: URL(fileURLWithPath: "/bridge"),
                                baselineSitePackages: URL(fileURLWithPath: "/baseline"), helpers: URL(fileURLWithPath: "/helpers"),
                                support: support)
        paths.prepareFolders()
        let candidate = support.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let active = ["gallery_dl": ActiveEngine(version: "9.9", path: candidate.path, previousVersion: nil, previousPath: nil)]
        XCTAssertEqual(paths.pythonPaths(active: active), ["/bridge", candidate.path, "/baseline"])
        XCTAssertEqual(paths.pythonPaths(), ["/bridge", "/baseline"], "nothing is active until the test passes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.activeFile.path))
    }
}
