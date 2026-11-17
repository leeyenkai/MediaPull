import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullBrowser
@testable import MediaPullCore
@testable import MediaPullEngines
@testable import MediaPullLibrary
@testable import MediaPullMedia
import XCTest

/// Requirements found without a test in the 1.8 conformance pass (docs/CONFORMANCE.md).
final class ConformanceTests: XCTestCase {
    private var tools: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MediaPullBuild/engines/ffmpeg")
    }

    private func ffmpeg() throws -> FFmpeg {
        let ffmpeg = FFmpeg(ffmpeg: tools.appendingPathComponent("ffmpeg"), ffprobe: tools.appendingPathComponent("ffprobe"))
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        return ffmpeg
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func image(_ width: Int, _ height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// R-507: the bundled ffmpeg can reach nothing but local files and pipes.
    func testFFmpegHasNoNetworkProtocols() async throws {
        let ffmpeg = try ffmpeg()
        let output = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-protocols"])
        let words = Set((output.stdout + output.stderr).split(whereSeparator: \.isWhitespace).map(String.init))
        // "Supported file protocols: Input: file pipe Output: file pipe": nothing but file and pipe.
        XCTAssertEqual(words.subtracting(["Supported", "protocols:", "Input:", "Output:"]), ["file", "pipe"])
    }

    /// R-509: the upload-blocking rules compile, so WebKit enforces them.
    func testUploadBlockingRulesCompile() async throws {
        let rules = try await WebViewSetup.uploadBlockingRules()
        XCTAssertNotNil(rules)
    }

    /// R-1304, R-1307: updates live in Application Support, the previous version is kept, and both undo paths work.
    func testEngineUpdatesStayOutOfTheBundleAndCanBeUndone() async throws {
        let support = try folder()
        let paths = EnginePaths(python: URL(fileURLWithPath: "/usr/bin/false"), bridgeDirectory: URL(fileURLWithPath: "/bridge"),
                                baselineSitePackages: URL(fileURLWithPath: "/baseline"), helpers: URL(fileURLWithPath: "/helpers"),
                                support: support)
        paths.prepareFolders()
        XCTAssertTrue(paths.updates.path.hasPrefix(support.path), "updates are written under Application Support")
        let manager = EngineManager(paths: paths)
        let active = ["gallery_dl": ActiveEngine(version: "2", path: support.appendingPathComponent("v2").path, previousVersion: "1",
                                                 previousPath: support.appendingPathComponent("v1").path)]
        try JSONEncoder().encode(active).write(to: paths.activeFile)
        let installed = await manager.hasUpdatesInstalled()
        XCTAssertTrue(installed)
        try await manager.usePreviousVersions()
        let back = try JSONDecoder().decode([String: ActiveEngine].self, from: Data(contentsOf: paths.activeFile))
        XCTAssertEqual(back["gallery_dl"]?.version, "1")
        try await manager.resetToBuiltIn()
        let afterReset = await manager.hasUpdatesInstalled()
        XCTAssertFalse(afterReset)
    }

    /// R-1508: dates in metadata files never follow the person's calendar, language or time zone.
    func testMetadataDatesUseAFixedCalendar() {
        let formatter = DateFormats.utc("yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        XCTAssertEqual(formatter.timeZone.secondsFromGMT(), 0)
        XCTAssertEqual(DateFormats.sidecarString(Date(timeIntervalSince1970: 0)), "1970-01-01 00:00:00")
    }

    /// R-1602: a converted picture keeps its colour profile.
    func testDisplayP3SurvivesConversion() throws {
        let folder = try folder()
        let input = folder.appendingPathComponent("p3.heic"), output = folder.appendingPathComponent("p3.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(64, 64, space: CGColorSpace(name: CGColorSpace.displayP3)!), nil)
        try XCTSkipUnless(CGImageDestinationFinalize(destination), "HEIC cannot be written here")
        try ImageConversion.convertStill(input, to: .jpeg, output: output)
        let converted = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(converted.colorSpace?.name, CGColorSpace.displayP3)
    }

    /// R-1604: "keep WebP, AVIF and HEIC" applies to Plain folders only.
    func testModernFormatsAreKeptOnlyInPlainFolders() async throws {
        let folder = try folder()
        let input = folder.appendingPathComponent("photo.heic")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(32, 32), nil)
        try XCTSkipUnless(CGImageDestinationFinalize(destination), "HEIC cannot be written here")
        var policy = ConversionPolicy()
        policy.keepOriginalModernImages = true
        let converter = MediaConverter(ffmpeg: nil)
        let plain = try await converter.convert(input, policy: policy, layout: .plain, workDirectory: folder)
        XCTAssertFalse(plain.converted)
        XCTAssertEqual(plain.format, .heic)
        let archive = try await converter.convert(input, policy: policy, layout: .archive, workDirectory: folder)
        XCTAssertTrue(archive.converted)
        XCTAssertEqual(archive.format, .jpeg)
    }

    /// R-1608: sound that is not AAC becomes AAC when the output is MP4.
    func testNonAACSoundBecomesAAC() async throws {
        let ffmpeg = try ffmpeg()
        let folder = try folder()
        try ImageConversion.writePNG(image(64, 64), to: folder.appendingPathComponent("f.png"))
        var wav = Data("RIFF".utf8)
        func le32(_ value: Int) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
        }
        let samples = 22050
        wav += le32(36 + samples * 2) + Array("WAVEfmt ".utf8) + le32(16) + [1, 0, 1, 0] + le32(44100) + le32(88200) + [2, 0, 16, 0]
        wav += Array("data".utf8) + le32(samples * 2) + [UInt8](repeating: 0, count: samples * 2)
        try wav.write(to: folder.appendingPathComponent("a.wav"))
        let list = folder.appendingPathComponent("list.txt")
        try "ffconcat version 1.0\nfile 'f.png'\nduration 0.5\nfile 'f.png'\n".write(to: list, atomically: true, encoding: .utf8)
        let mkv = folder.appendingPathComponent("clip.mkv")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                                                 "-i", folder.appendingPathComponent("a.wav").path, "-c:v", "h264_videotoolbox",
                                                 "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-shortest", mkv.path])
        let result = try await MediaConverter(ffmpeg: ffmpeg).convert(mkv, policy: ConversionPolicy(), layout: .archive,
                                                                      workDirectory: folder)
        let info = try await ffmpeg.probe(result.url)
        XCTAssertEqual(result.format, .mp4)
        XCTAssertEqual(info.audioCodec, "aac")
        XCTAssertEqual(info.videoCodec, "h264", "the picture is copied, not encoded again")
    }

    /// R-3807: a cancelled Organise operation stops, and what it did can be undone.
    func testACancelledOperationCanBeUndone() async throws {
        let root = try folder()
        var files: [URL] = []
        for index in 0 ..< 300 {
            let file = root.appendingPathComponent("in/\(index).jpg")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(index)".utf8).write(to: file)
            files.append(file)
        }
        let journal = OperationJournal(folder: root.appendingPathComponent("journal", isDirectory: true))
        let plan = FolderOperations.move(files, to: root.appendingPathComponent("out", isDirectory: true))
        let task = Task { await journal.run(plan) { done, _ in if done == 50 { withUnsafeCurrentTask { $0?.cancel() } } } }
        let entry = await task.value
        XCTAssertFalse(entry.finished, "the run stopped when cancelled")
        let moved = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("out").path))?.count ?? 0
        XCTAssertGreaterThan(moved, 0)
        XCTAssertLessThan(moved, 300)
        _ = await journal.undo(entry.id)
        let back = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("in").path).count
        XCTAssertEqual(back, 300, "undo puts back what the cancelled run moved")
    }
}
