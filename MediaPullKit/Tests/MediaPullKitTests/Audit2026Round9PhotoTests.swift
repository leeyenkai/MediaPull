import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 9.
extension EditFrameTests {
    /// RGBA8 pixels of an image, top row first.
    func pixels(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let c = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    /// A picture with distinct corners and a sloping line, so a mirror and a tilt both show.
    func asymmetric() -> CIImage {
        let w = 400, h = 300
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0 ..< w {
            c.setFillColor(red: CGFloat(x) / CGFloat(w), green: 0.3, blue: 0.6, alpha: 1)
            c.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        c.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        c.fill(CGRect(x: 20, y: 200, width: 120, height: 60))
        return CIImage(cgImage: c.makeImage()!)
    }

    func mirrored(_ image: CGImage) -> CGImage {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: CGFloat(image.width), y: 0)
        c.scaleBy(x: -1, y: 1)
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return c.makeImage()!
    }

    /// Mean absolute difference per channel, 0 to 255.
    func difference(_ a: CGImage, _ b: CGImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0.0
        for i in 0 ..< pa.count { sum += abs(Double(pa[i]) - Double(pb[i])) }
        return sum / Double(pa.count)
    }

    /// The Inspector's Flip (EditInspector.swift:140-146): toggles `flipped` and mirrors the crop's x.
    func inspectorFlip(_ recipe: inout EditRecipe) {
        recipe.geometry.flip()
    }

    /// R-4604 / B8-5: Flip shows the edited picture mirrored, keeping the part chosen. With quarter turns it does.
    func testB9FlipWithAQuarterTurnMirrorsTheResult() throws {
        let input = asymmetric()
        for turns in 0 ..< 4 {
            var made = EditRecipe(source: EditSource(path: "/x.jpg", kind: .image))
            made.geometry.quarterTurns = turns
            made.geometry.crop = UnitRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6)
            let before = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.picture(input, recipe: made), exact: true))
            inspectorFlip(&made)
            let after = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.picture(input, recipe: made), exact: true))
            XCTAssertLessThan(difference(mirrored(before), after), 2, "\(turns) quarter turns: Flip mirrors the result")
        }
    }

    /// B9-x: a straightened photo flipped is not the mirror of what was shown: the straighten angle keeps its sign, so the
    /// level horizon the person set tilts by twice the angle, and the crop then holds another part of the picture.
    func testB9FlipOfAStraightenedPhotoMirrorsTheResult() throws {
        let input = asymmetric()
        var made = EditRecipe(source: EditSource(path: "/x.jpg", kind: .image))
        made.geometry.straighten = 8
        made.geometry.crop = UnitRect(x: 0.05, y: 0.1, width: 0.6, height: 0.7)
        let before = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.picture(input, recipe: made), exact: true))
        inspectorFlip(&made)
        let after = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.picture(input, recipe: made), exact: true))
        let diff = difference(mirrored(before), after)
        var negated = made
        negated.geometry.straighten = -8
        let fixed = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.picture(input, recipe: negated), exact: true))
        XCTAssertLessThan(diff, 2, "Flip mirrors the straightened result")
    }

    /// B8-6's clamped Lanczos: the scaled picture keeps its size and is not shifted.
    func testB9ScaledKeepsSizeAndPlace() throws {
        let w = 3001, h = 2001
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(gray: 0, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(gray: 1, alpha: 1)
        c.fill(CGRect(x: 1500, y: 0, width: 1501, height: h)) // right half white from x = 1500
        let input = CIImage(cgImage: c.makeImage()!)
        let out = PhotoRenderer.scaled(input, toFit: CGSize(width: 1080, height: 1080))
        let target = ExportSettings.Size.long1080.pixels(for: input.extent.size)
        XCTAssertEqual(out.extent.size, target)
        let image = try XCTUnwrap(PhotoRenderer.cgImage(out, exact: true))
        let px = pixels(image)
        let row = image.height / 2
        // The edge at 1500 / 3001 × 1080 = 539.8.
        var edge = -1
        for x in 0 ..< image.width where px[(row * image.width + x) * 4] > 127 { edge = x; break }
        XCTAssertTrue((539 ... 541).contains(edge), "not shifted: \(edge)")
        XCTAssertEqual(px[3], 255)
    }
}

extension EditFrameTests {
    /// B9-x: a photo opened unedited (EditModel.newRecipe knows its reference and creation date) and renamed in the Finder
    /// before the first change is kept, with nothing at its old name: every save is refused ("no longer there"), so the
    /// edits are lost when another file is opened (flushSave drops them), though its own reference leads to it.
    func testB9FirstKeptRecipeOfAFileRenamedInTheFinderFollowsIt() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let photo = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        var opened = recipe(for: photo)
        opened.source.reference = RecipeStore.reference(photo.path)
        opened.source.created = RecipeStore.created(photo.path)
        let renamed = folder.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: photo, to: renamed)
        opened.adjust.contrast = 15
        let kept = await store.store(opened)
        XCTAssertNotNil(kept, "kept for the renamed file its reference leads to")
        let followed = await store.recipe(for: renamed)
        XCTAssertEqual(followed?.adjust.contrast, 15, "the renamed photo keeps its edits")
    }
}

extension EditFrameTests {
    /// B9-x: B8-1's rule ("a new recipe takes the identity of the file at its path only when that is the file it was made
    /// for") is kept only when no recipe is at the path. When the newcomer already has one (pasted onto it, or edited in
    /// another window), the opened photo's first save merges into the newcomer's recipe, overwriting its edits.
    func testB9FirstKeptRecipeNeverMergesIntoANewcomersRecipe() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let photo = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        // Window 1 opens a.jpg unedited (EditModel.newRecipe).
        var opened = recipe(for: photo)
        opened.source.reference = RecipeStore.reference(photo.path)
        opened.source.created = RecipeStore.created(photo.path)
        // In the Finder: renamed, and another photo takes its name; that one is given edits (Paste Settings).
        let renamed = folder.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: photo, to: renamed)
        _ = try dated("a.jpg", created: Date())
        var pasted = EditRecipe(source: EditSource(path: photo.standardizedFileURL.path, kind: .image))
        pasted.adjust.saturation = 50
        let newcomerKept = await store.save(pasted)
        XCTAssertTrue(newcomerKept)
        // Window 1's first change on the photo it shows.
        opened.adjust.contrast = 15
        _ = await store.store(opened)
        let newcomer = await store.recipe(for: photo)
        XCTAssertEqual(newcomer?.adjust.saturation, 50, "the newcomer keeps its own edits")
        XCTAssertEqual(newcomer?.adjust.contrast, 0, "and is not given the other photo's")
        let followed = await store.recipe(for: renamed)
        XCTAssertEqual(followed?.adjust.contrast, 15, "the opened photo keeps its edits")
    }
}
