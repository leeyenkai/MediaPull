import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 10.
extension EditFrameTests {
    /// What MediaPull's in-place metadata write does (MetadataEdits.putInPlace): a checked copy with the file's creation
    /// date swapped into its place, then the recipes told (FileChanges.editMetadata → refreshReferences).
    func rewriteInPlace(_ url: URL) throws {
        let copy = folder.appendingPathComponent(".copy-\(UUID().uuidString).jpg")
        try MetadataWriter.writeCopy(of: url, setting: MetadataValues(fields: [.rating], rating: 4), to: copy)
        let created = try XCTUnwrap(RecipeStore.created(url.path))
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: copy.path)
        XCTAssertEqual(renamex_np(copy.path, url.path, UInt32(RENAME_SWAP)), 0)
        try FileManager.default.removeItem(at: copy)
    }

    /// R-4608 "metadata kept": a rating and keywords MediaPull wrote into the photo (section 45, in its XMP) go with an
    /// export.
    func testB10ExportKeepsTheRatingAndKeywordsWrittenIntoThePhoto() throws {
        let original = photo("rated.jpg")
        let staged = folder.appendingPathComponent(".staged.jpg")
        try MetadataWriter.writeCopy(of: original, setting: MetadataValues(fields: [.rating, .keywords], rating: 4,
                                                                           keywords: ["harbour"]), to: staged)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: staged, to: original)
        XCTAssertEqual(MetadataWriter.values(of: original).rating, 4)
        var made = recipe(for: original)
        made.adjust.exposure = 0.3
        let out = folder.appendingPathComponent("rated-edited.jpg")
        _ = try PhotoExporter.export(original, recipe: made, to: out)
        let kept = MetadataWriter.values(of: out)
        XCTAssertEqual(kept.rating, 4, "the rating is kept")
        XCTAssertEqual(kept.keywords, ["harbour"], "the keywords are kept")
    }

    /// R-4605: a photo with rounded corners and a shadow casts a rounded shadow; the square shadow behind a round photo
    /// shows dark corners outside it.
    func testB10ShadowOfARoundedPhotoIsRounded() throws {
        let c = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        var frame = Frame()
        frame.shape = .square
        (frame.top, frame.left, frame.right, frame.bottom) = (0.1, 0.1, 0.1, 0.1)
        frame.cornerRadius = 0.5
        frame.shadow = true
        let out = FrameRenderer.compose(CIImage(cgImage: c.makeImage()!), frame: frame)
        let image = try XCTUnwrap(PhotoRenderer.cgImage(out, exact: true))
        let px = pixels(image)
        // The photo's box is 60 ... 540; its corners lie well outside the round photo.
        let corner = (70 * image.width + 70) * 4
        let away = (10 * image.width + 10) * 4
        print("SHADOW corner \(px[corner]) \(px[corner + 1]) \(px[corner + 2]) background \(px[away])")
        XCTAssertGreaterThan(Double(px[corner]), Double(px[away]) - 20, "no square shadow outside the rounded photo")
    }

    /// R-4608: values MediaPull wrote into the photo (a new place, a removed place, a shifted date) are what an export keeps.
    func testB10ExportCarriesLocationAndDateWrittenIntoThePhoto() throws {
        func written(_ name: String, _ values: MetadataValues) throws -> URL {
            let original = photo(name)
            let staged = folder.appendingPathComponent(".staged-\(name)")
            try MetadataWriter.writeCopy(of: original, setting: values, to: staged)
            try FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: staged, to: original)
            return original
        }
        func export(_ url: URL, keepLocation: Bool) throws -> MetadataValues {
            var made = recipe(for: url)
            made.adjust.exposure = 0.2
            made.export.keepLocation = keepLocation
            let out = folder.appendingPathComponent("\(UUID().uuidString).jpg")
            _ = try PhotoExporter.export(url, recipe: made, to: out)
            return MetadataWriter.values(of: out)
        }
        let moved = try written("moved.jpg", MetadataValues(fields: [.location], latitude: -33.5, longitude: 151.25))
        let kept = try export(moved, keepLocation: true)
        print("LOC moved kept", kept.latitude as Any, kept.longitude as Any)
        XCTAssertEqual(kept.latitude ?? 0, -33.5, accuracy: 0.01)
        let dropped = try export(moved, keepLocation: false)
        print("LOC moved dropped", dropped.latitude as Any)
        XCTAssertNil(dropped.latitude)
        let removed = try written("removed.jpg", MetadataValues(fields: [.location]))
        XCTAssertNil(MetadataWriter.values(of: removed).latitude)
        let fromRemoved = try export(removed, keepLocation: true)
        print("LOC removed", fromRemoved.latitude as Any)
        XCTAssertNil(fromRemoved.latitude, "a removed place stays removed")
        let shifted = try written("shifted.jpg", MetadataValues(fields: [.taken], taken: TakenDate(original: "2021:05:06 07:08:09")))
        let date = try export(shifted, keepLocation: true)
        print("DATE", date.taken as Any)
        XCTAssertEqual(date.taken?.original, "2021:05:06 07:08:09")
    }

    /// B1-16's rule ("no export without its layers") for picture layers: Export Selected (EditBatch.exportSelected) writes
    /// a photo whose logo file is gone without the logo and counts it exported; nothing says so.
    func testB10ExportWithAMissingPictureLayerIsNotWrittenSilently() throws {
        let original = photo("logo-on.jpg")
        var made = recipe(for: original)
        var logo = Layer(kind: .image(path: folder.appendingPathComponent("moved-away-logo.png").path))
        logo.width = 0.3
        logo.height = 0.3
        made.layers = [logo]
        let out = folder.appendingPathComponent("logo-on-edited.jpg")
        XCTAssertThrowsError(try PhotoExporter.export(original, recipe: made, to: out), "refused, or said, never written without it")
    }
}
