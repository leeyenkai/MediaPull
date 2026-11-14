import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullLibrary
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Draws a test picture: a gradient with shapes whose placement depends on `seed`.
private func picture(seed: Int, width: Int = 800, height: Int = 600, flat: Bool = false) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if flat {
        context.setFillColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    let colors = [CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1), CGColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: seed % 2 == 0 ? height : 0), options: [])
    var generator = seed
    func next() -> CGFloat {
        generator = (generator &* 1_103_515_245 &+ 12345) & 0x7FFF_FFFF
        return CGFloat(generator % 1000) / 1000
    }
    for _ in 0 ..< 6 {
        context.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        context.fillEllipse(in: CGRect(x: next() * CGFloat(width) * 0.8, y: next() * CGFloat(height) * 0.8,
                                       width: CGFloat(width) * (0.1 + next() * 0.3), height: CGFloat(height) * (0.1 + next() * 0.3)))
    }
    return context.makeImage()!
}

private func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 1, scale: Double = 1) {
    var output = image
    if scale != 1 {
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        output = context.makeImage()!
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

final class DuplicateFinderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dupes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFingerprintsMatchResizedCopiesButNotOtherPictures() throws {
        let a = picture(seed: 3), b = picture(seed: 11)
        let original = folder.appendingPathComponent("a.png"), resized = folder.appendingPathComponent("a-small.jpg")
        let other = folder.appendingPathComponent("b.png")
        write(a, to: original, type: .png)
        write(a, to: resized, type: .jpeg, quality: 0.6, scale: 0.4)
        write(b, to: other, type: .png)
        let fa = try XCTUnwrap(PerceptualHash.fingerprint(of: original))
        let fr = try XCTUnwrap(PerceptualHash.fingerprint(of: resized))
        let fb = try XCTUnwrap(PerceptualHash.fingerprint(of: other))
        XCTAssertLessThanOrEqual(fa.distance(to: fr), 4)
        XCTAssertGreaterThan(fa.distance(to: fb), 12)
        XCTAssertLessThan(fa.colorDifference(to: fr), 10)
        XCTAssertEqual(PerceptualHash.fingerprint(of: original), fa, "fingerprints are deterministic")
        let flat = folder.appendingPathComponent("flat.png")
        write(picture(seed: 0, flat: true), to: flat, type: .png)
        XCTAssertNil(PerceptualHash.fingerprint(of: flat), "flat images are not compared for similarity")
    }

    func testColourVersionsOfOnePhotoAreNotDuplicates() async throws {
        let shape = picture(seed: 21)
        let recoloured = CGContext(data: nil, width: shape.width, height: shape.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        recoloured.draw(shape, in: CGRect(x: 0, y: 0, width: shape.width, height: shape.height))
        recoloured.setBlendMode(.hue)
        recoloured.setFillColor(red: 0.9, green: 0.1, blue: 0.6, alpha: 1)
        recoloured.fill(CGRect(x: 0, y: 0, width: shape.width, height: shape.height))
        write(shape, to: folder.appendingPathComponent("blue.png"), type: .png)
        write(recoloured.makeImage()!, to: folder.appendingPathComponent("pink.png"), type: .png)
        let report = await DuplicateFinder(storeURL: nil).scan(root: folder, sensitivity: .nearIdentical)
        XCTAssertTrue(report.groups.isEmpty, "the same photo in another colour is not a duplicate")
        // A small subject recoloured on a large plain background (a product shot) is not a duplicate either.
        let product = { (red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage in
            let context = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fillEllipse(in: CGRect(x: 220, y: 120, width: 160, height: 360))
            context.setFillColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
            context.fill(CGRect(x: 230, y: 260, width: 140, height: 50))
            return context.makeImage()!
        }
        let products = folder.appendingPathComponent("products", isDirectory: true)
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        write(product(0.35, 0.15, 0.22), to: products.appendingPathComponent("burgundy.png"), type: .png)
        write(product(0.1, 0.1, 0.1), to: products.appendingPathComponent("black.png"), type: .png)
        let productReport = await DuplicateFinder(storeURL: nil).scan(root: products, sensitivity: .nearIdentical)
        XCTAssertTrue(productReport.groups.isEmpty, "a recoloured product on white is not a duplicate")
    }

    func testGroupsIdenticalAndSimilarFilesAcrossFolders() async throws {
        let a = picture(seed: 5), b = picture(seed: 9)
        write(a, to: folder.appendingPathComponent("a.png"), type: .png)
        try FileManager.default.copyItem(at: folder.appendingPathComponent("a.png"), to: folder.appendingPathComponent("sub/a copy.png"))
        write(a, to: folder.appendingPathComponent("sub/a resized.jpg"), type: .jpeg, quality: 0.7, scale: 0.5)
        write(b, to: folder.appendingPathComponent("b.png"), type: .png)
        write(picture(seed: 0, flat: true), to: folder.appendingPathComponent("flat1.png"), type: .png)
        write(picture(seed: 0, width: 400, height: 300, flat: true), to: folder.appendingPathComponent("flat2.png"), type: .png)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("a.png.json"))

        let store = folder.appendingPathComponent("cache.json")
        let finder = DuplicateFinder(storeURL: store)

        let exact = await finder.scan(root: folder, sensitivity: .exact)
        XCTAssertEqual(exact.filesChecked, 6)
        XCTAssertEqual(exact.groups.count, 1)
        XCTAssertTrue(exact.groups[0].identical)
        XCTAssertEqual(Set(exact.groups[0].members.map(\.lastPathComponent)), ["a.png", "a copy.png"])

        let near = await finder.scan(root: folder, sensitivity: .nearIdentical)
        XCTAssertEqual(near.groups.count, 1, "the flat images and the other picture stay apart")
        XCTAssertFalse(near.groups[0].identical)
        XCTAssertEqual(Set(near.groups[0].members.map(\.lastPathComponent)), ["a.png", "a copy.png", "a resized.jpg"])
        XCTAssertNotNil(near.group(for: folder.appendingPathComponent("sub/a resized.jpg")))
        XCTAssertNil(near.group(for: folder.appendingPathComponent("b.png")))
        XCTAssertTrue(near.isIdentical(folder.appendingPathComponent("sub/a copy.png")))
        XCTAssertFalse(near.isIdentical(folder.appendingPathComponent("sub/a resized.jpg")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path), "hashes are cached between scans")

        let again = await DuplicateFinder(storeURL: store).scan(root: folder, sensitivity: .nearIdentical)
        XCTAssertEqual(again, near)
    }
}

final class VideoToolsTests: XCTestCase {
    /// Writes a 3-second 320×240 H.264 clip whose colour changes every second.
    private func makeClip(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< 30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.bindMemory(to: UInt8.self, capacity: CVPixelBufferGetDataSize(pixels))
            let shade: [UInt8] = [[40, 40, 220], [40, 200, 40], [220, 40, 40]][frame / 10]
            for offset in stride(from: 0, to: CVPixelBufferGetBytesPerRow(pixels) * 240, by: 4) {
                base[offset] = shade[0]; base[offset + 1] = shade[1]; base[offset + 2] = shade[2]; base[offset + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testFrameGrabIsFullSizeAndTrimKeepsTheSelection() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("clip.mp4")
        try await makeClip(at: clip)
        let measured = await VideoTools.duration(of: clip)
        let duration = try XCTUnwrap(measured)
        XCTAssertEqual(duration, 3, accuracy: 0.05)

        let frame = try await VideoTools.frame(of: clip, at: 1.5)
        XCTAssertEqual(frame.width, 320)
        XCTAssertEqual(frame.height, 240)

        let trimmed = folder.appendingPathComponent("trimmed.mp4")
        try await VideoTools.trim(clip, from: 1.0, to: 2.0, output: trimmed)
        let trimmedMeasured = await VideoTools.duration(of: trimmed)
        let trimmedDuration = try XCTUnwrap(trimmedMeasured)
        XCTAssertEqual(trimmedDuration, 1.0, accuracy: 0.11)
        let first = try await VideoTools.frame(of: trimmed, at: 0.05)
        XCTAssertEqual(first.width, 320)
    }
}
