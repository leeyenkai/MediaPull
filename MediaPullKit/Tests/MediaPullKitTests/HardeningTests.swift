import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullMedia
import UniformTypeIdentifiers
@testable import MediaPullCore
@testable import MediaPullEngines
@testable import MediaPullLibrary
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

/// B6: the dependency versions update checks compare against are the ones scripts/fetch-engines.sh bundles.
final class BundledPinTests: XCTestCase {
    func testBundledDependenciesMatchTheFetchScript() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            root.deleteLastPathComponent()
        }
        let script = try String(contentsOf: root.appendingPathComponent("scripts/fetch-engines.sh"), encoding: .utf8)
        var pinned: [String: String] = [:]
        for line in script.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).split(separator: " ")
            guard parts.count == 3, parts[2].count == 64, parts[2].allSatisfy(\.isHexDigit) else { continue }
            pinned[String(parts[0])] = String(parts[1])
        }
        XCTAssertFalse(pinned.isEmpty, "no pins found in fetch-engines.sh")
        for (name, version) in EngineManager.bundledDependencies {
            XCTAssertEqual(pinned[name], version, "\(name) in EngineManager.bundledDependencies differs from fetch-engines.sh")
        }
        let dependencies = Set(pinned.keys).subtracting(["gallery-dl", "yt-dlp"])
        XCTAssertEqual(dependencies, Set(EngineManager.bundledDependencies.keys))
    }
}

/// 1.8 conversion fixes (SPEC 16): lossless WebP behind a large profile, oriented sizes, play counts kept.
final class ConversionFidelityTests: XCTestCase {
    private func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let length = UInt32(body.count)
        let bytes = Array(type.utf8) + [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
        return bytes + body + (body.count % 2 == 1 ? [0] : [])
    }

    func testLosslessWebPBehindALargeProfileIsFound() {
        let vp8x = chunk("VP8X", [0x20, 0, 0, 0, 9, 0, 0, 9, 0, 0])
        let iccp = chunk("ICCP", [UInt8](repeating: 7, count: 6000))
        let vp8l = chunk("VP8L", [0x2F, 0, 0, 0, 0])
        let body = Array("WEBP".utf8) + vp8x + iccp + vp8l
        let size = UInt32(body.count)
        let file = Data(Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + body)
        XCTAssertEqual(Sniffer.sniff(file).webp?.lossless, false, "the first 4 KB alone cannot see the lossless chunk")
        XCTAssertEqual(Sniffer.sniff(file, limit: 512 * 1024).webp?.lossless, true)
    }

    private func image(_ width: Int, _ height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    func testOrientedJPEGReportsItsUprightSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oriented-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(40, 20), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let analysis = try XCTUnwrap(ImageConversion.analyze(url))
        XCTAssertEqual(analysis.width, 20)
        XCTAssertEqual(analysis.height, 40)
    }

    /// R-3202: turning or flipping a JPEG only changes its orientation tag.
    func testRotationAndFlipComposeAndStayLossless() throws {
        var edit = ImageEditing.Reorientation()
        edit.rotate(clockwise: true)
        XCTAssertEqual(edit.applied(to: 1), 6)
        XCTAssertEqual(edit.applied(to: 6), 3)
        edit.flip()
        XCTAssertEqual(edit.applied(to: 1), 5, "rotate then flip is a transpose")
        var other = ImageEditing.Reorientation()
        other.flip()
        other.rotate(clockwise: true)
        XCTAssertEqual(other.applied(to: 1), 7, "flip then rotate is a transverse")
        for start in 1 ... 8 {
            var full = ImageEditing.Reorientation()
            for _ in 0 ..< 4 { full.rotate(clockwise: false) }
            full.flip()
            full.flip()
            XCTAssertEqual(full.applied(to: start), start)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rotate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("in.jpg"), output = folder.appendingPathComponent("out.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image(40, 20), [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var turn = ImageEditing.Reorientation()
        turn.rotate(clockwise: true)
        try ImageEditing.writeReoriented(input, by: turn, to: output)
        func pixels(_ url: URL) -> Data? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.dataProvider?.data as Data?
        }
        XCTAssertEqual(pixels(input), pixels(output), "the image data is copied, not encoded again")
        let analysis = try XCTUnwrap(ImageConversion.analyze(output))
        XCTAssertEqual(analysis.width, 20)
        XCTAssertEqual(analysis.height, 40)
    }

    func testPlayCountsSurviveConversion() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plays-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let frames = [ImageConversion.Frame(image: image(8, 8), delay: 0.05), ImageConversion.Frame(image: image(8, 8), delay: 0.05)]
        for plays in [0, 1, 3] {
            for type in [UTType.png, .gif] {
                let url = folder.appendingPathComponent("a\(plays).\(type == .png ? "png" : "gif")")
                try ImageConversion.writeAnimated(frames, plays: plays, as: type, to: url)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                XCTAssertEqual(ImageConversion.plays(of: source), plays, "\(type) playing \(plays) times")
            }
        }
        // The ffmpeg path, as saves use it (skipped when ffmpeg is not built).
        let tools = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MediaPullBuild/engines/ffmpeg")
        if FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("ffmpeg").path) {
            let ffmpeg = FFmpeg(ffmpeg: tools.appendingPathComponent("ffmpeg"), ffprobe: tools.appendingPathComponent("ffprobe"))
            try ImageConversion.writePNG(image(8, 8), to: folder.appendingPathComponent("f0.png"))
            try ImageConversion.writePNG(image(8, 8), to: folder.appendingPathComponent("f1.png"))
            let list = folder.appendingPathComponent("list.txt")
            try "ffconcat version 1.0\nfile 'f0.png'\nduration 0.1\nfile 'f1.png'\nduration 0.1\nfile 'f1.png'\n"
                .write(to: list, atomically: true, encoding: .utf8)
            for plays in [0, 1, 3] {
                let out = folder.appendingPathComponent("ff\(plays).gif")
                try await ffmpeg.gif(fromConcatList: list, output: out, plays: plays)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
                XCTAssertEqual(ImageConversion.plays(of: source), plays, "ffmpeg GIF playing \(plays) times")
            }
        }
        var seen = 0
        let png = folder.appendingPathComponent("a3.png")
        let result = try ImageConversion.forEachFrame(of: png, limit: 1) { _, _ in seen += 1 }
        XCTAssertEqual(seen, 1)
        XCTAssertTrue(result.truncated)
    }
}

/// R-1607, D-13: HEVC is always tagged hvc1, and an MP4 with no picture is audio. Uses the bundled ffmpeg (skipped
/// when it is not built).
final class VideoFidelityTests: XCTestCase {
    private var tools: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MediaPullBuild/engines/ffmpeg")
    }

    private func ffmpeg() throws -> FFmpeg {
        let ffmpeg = FFmpeg(ffmpeg: tools.appendingPathComponent("ffmpeg"), ffprobe: tools.appendingPathComponent("ffprobe"))
        try XCTSkipUnless(ffmpeg.isAvailable, "ffmpeg is not built")
        return ffmpeg
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testHEVCTaggedHev1IsRetaggedWithoutReencoding() async throws {
        let ffmpeg = try ffmpeg()
        let folder = try folder()
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        try ImageConversion.writePNG(context.makeImage()!, to: folder.appendingPathComponent("f.png"))
        let list = folder.appendingPathComponent("list.txt")
        try "ffconcat version 1.0\nfile 'f.png'\nduration 0.5\nfile 'f.png'\n".write(to: list, atomically: true, encoding: .utf8)
        let hev1 = folder.appendingPathComponent("hev1.mp4")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                                                 "-c:v", "hevc_videotoolbox", "-tag:v", "hev1", "-pix_fmt", "yuv420p", hev1.path])
        let before = try await ffmpeg.probe(hev1)
        XCTAssertEqual(before.videoTag, "hev1")
        let result = try await MediaConverter(ffmpeg: ffmpeg).convert(hev1, policy: ConversionPolicy(), layout: .archive, workDirectory: folder)
        let after = try await ffmpeg.probe(result.url)
        XCTAssertEqual(after.videoTag, "hvc1")
        XCTAssertEqual(after.videoCodec, "hevc")
        XCTAssertTrue(result.converted)
        XCTAssertEqual(result.note, "Repackaged as MP4 without re-encoding")
    }

    func testAudioOnlyMP4IsAudio() async throws {
        let ffmpeg = try ffmpeg()
        let folder = try folder()
        // One second of silence as WAV, encoded to AAC in an MP4 container (brand isom), as a page's audio may be.
        var wav = Data("RIFF".utf8)
        let samples = 44100
        func le32(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)] }
        wav += le32(36 + samples * 2) + Array("WAVEfmt ".utf8) + le32(16) + [1, 0, 1, 0] + le32(44100) + le32(88200) + [2, 0, 16, 0]
        wav += Array("data".utf8) + le32(samples * 2) + [UInt8](repeating: 0, count: samples * 2)
        let wavURL = folder.appendingPathComponent("a.wav")
        try wav.write(to: wavURL)
        let mp4 = folder.appendingPathComponent("audio.mp4")
        _ = try await FFmpeg.run(ffmpeg.ffmpeg, ["-hide_banner", "-nostdin", "-y", "-i", wavURL.path, "-c:a", "aac", mp4.path])
        let result = try await MediaConverter(ffmpeg: ffmpeg).convert(mp4, policy: ConversionPolicy(), layout: .archive, workDirectory: folder)
        XCTAssertEqual(result.format, .m4a)
    }
}
