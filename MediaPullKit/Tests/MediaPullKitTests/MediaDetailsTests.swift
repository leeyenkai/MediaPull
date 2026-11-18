import CoreGraphics
import Foundation
import ImageIO
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// What a file records about how it was made, for the Preview pane's details (D-110).
final class MediaDetailsTests: XCTestCase {
    private func photo(_ properties: [CFString: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("details-\(UUID().uuidString).jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEveryCameraAndLocationFieldIsRead() async throws {
        let url = try photo([
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                                             kCGImagePropertyTIFFSoftware: "17.4"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "iPhone 15 Pro back camera 6.86mm f/1.78",
                kCGImagePropertyExifFocalLength: 6.86, kCGImagePropertyExifFocalLenIn35mmFilm: 24,
                kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0 / 120,
                kCGImagePropertyExifISOSpeedRatings: [64], kCGImagePropertyExifFlash: 16,
                kCGImagePropertyExifDateTimeOriginal: "2024:06:01 18:30:05", kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 35.0, kCGImagePropertyGPSAltitudeRef: 0,
            ],
        ])
        let details = await MediaDetailsReader.details(for: url)
        XCTAssertEqual(details.camera, "Apple iPhone 15 Pro")
        XCTAssertEqual(details.lens, "iPhone 15 Pro back camera 6.86mm f/1.78")
        XCTAssertEqual(try XCTUnwrap(details.focalLength), 6.86, accuracy: 0.01)
        XCTAssertEqual(details.focalLength35, 24)
        XCTAssertEqual(try XCTUnwrap(details.aperture), 1.78, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(details.exposure), 1.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(details.iso, 64)
        XCTAssertEqual(details.flashFired, false)
        XCTAssertEqual(details.software, "17.4")
        XCTAssertEqual(details.takenOffset, "+02:00")
        XCTAssertEqual(details.taken, ISO8601DateFormatter().date(from: "2024-06-01T16:30:05Z"))
        XCTAssertEqual(try XCTUnwrap(details.latitude), 48.8584, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.longitude), 2.2945, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.altitude), 35, accuracy: 0.1)
        XCTAssertTrue(details.hasLocation)
    }

    func testSouthWestAndMissingFields() async throws {
        let url = try photo([
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R5"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2093, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 4.0, kCGImagePropertyGPSAltitudeRef: 1,
            ],
        ])
        let details = await MediaDetailsReader.details(for: url)
        XCTAssertEqual(details.camera, "Canon EOS R5", "the make is not repeated")
        XCTAssertEqual(try XCTUnwrap(details.latitude), -33.8688, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.longitude), -151.2093, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(details.altitude), -4, accuracy: 0.1)
        XCTAssertNil(details.iso)
        XCTAssertNil(details.taken)
        // A photo that records nothing has no details and no location.
        let plain = await MediaDetailsReader.details(for: try photo([:]))
        XCTAssertNil(plain.camera)
        XCTAssertFalse(plain.hasLocation)
        XCTAssertEqual(MediaDetailsReader.codecName("hvc1"), "HEVC")
    }
}
