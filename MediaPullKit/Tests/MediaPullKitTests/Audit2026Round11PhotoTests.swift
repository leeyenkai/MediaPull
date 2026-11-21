import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullLibrary
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 11.
/// Audit 2026-11-21, round 11: an open recipe and a newcomer at its name, Replace through Undo and Redo, shadows, sizes.
final class Audit2026Round11PhotoTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("B11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func photo(_ url: URL, date: String = "2020:01:02 03:04:05") {
        MetadataEditTests.photo(url, type: .jpeg, date: date)
    }

    /// MediaPull's in-place metadata write: a checked copy with the file's creation date swapped into its place.
    func rewriteInPlace(_ url: URL) throws {
        let copy = url.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString).jpg")
        try MetadataWriter.writeCopy(of: url, setting: MetadataValues(fields: [.rating], rating: 4), to: copy)
        let created = try XCTUnwrap(RecipeStore.created(url.path))
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: copy.path)
        XCTAssertEqual(renamex_np(copy.path, url.path, UInt32(RENAME_SWAP)), 0)
        try FileManager.default.removeItem(at: copy)
    }

    /// EditModel.filesRewritten, as written since round 11 (only for the file the recipe was made for).
    func windowFilesRewritten(_ recipe: inout EditRecipe, _ paths: Set<String>) {
        guard paths.contains(recipe.source.path), RecipeStore.belongs(recipe, to: recipe.source.path) else { return }
        recipe.source.reference = RecipeStore.reference(recipe.source.path) ?? recipe.source.reference
    }

    /// A photo open (not yet changed) is renamed in the Finder and another photo is given its old name; that newcomer is
    /// rated in place from the Library. The window's recipe takes the newcomer's reference (filesRewritten never checks
    /// the file is the one the recipe was made for), so the first edits are kept for neither file: the renamed photo
    /// never shows them.
    func testB11FilesRewrittenNeverGivesAnOpenRecipeANewcomersReference() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let p = folder.appendingPathComponent("P.jpg"), q = folder.appendingPathComponent("Q.jpg")
        photo(p)
        let past = Date(timeIntervalSinceNow: -86400)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: p.path)
        // Opened: EditModel.newRecipe.
        var open = EditRecipe(source: EditSource(path: p.standardizedFileURL.path, reference: RecipeStore.reference(p.path),
                                                 created: RecipeStore.created(p.path), kind: .image))
        // In the Finder: P renamed to Q, a new photo saved as P.
        try FileManager.default.moveItem(at: p, to: q)
        photo(p, date: "2023:03:03 03:03:03")
        // Rated in place from the Library (FileChanges.editMetadata: refreshReferences, then each window's filesRewritten).
        _ = await store.awayIDs()
        try rewriteInPlace(p)
        await store.refreshReferences([p.path])
        windowFilesRewritten(&open, [p.standardizedFileURL.path])
        // Now the person edits the photo on the canvas (still the one renamed to Q) and it is saved.
        open.adjust.exposure = 0.7
        let kept = await store.store(open)
        XCTAssertNotNil(kept)
        let forP = await store.recipe(for: p)
        let forQ = await store.recipe(for: q)
        XCTAssertNil(forP, "never shown for the newcomer")
        XCTAssertEqual(forQ?.adjust.exposure, 0.7, "the edits stay with the photo they were made on (now Q)")
    }

    /// Control: the same without the rewrite of the newcomer keeps the edits with Q (B9-1), so the reference is the cause.
    func testB11ControlWithoutTheRewriteTheEditsFollowTheRenamedPhoto() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let p = folder.appendingPathComponent("P.jpg"), q = folder.appendingPathComponent("Q.jpg")
        photo(p)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: p.path)
        var open = EditRecipe(source: EditSource(path: p.standardizedFileURL.path, reference: RecipeStore.reference(p.path),
                                                 created: RecipeStore.created(p.path), kind: .image))
        try FileManager.default.moveItem(at: p, to: q)
        photo(p, date: "2023:03:03 03:03:03")
        open.adjust.exposure = 0.7
        _ = await store.store(open)
        let forQ = await store.recipe(for: q)
        XCTAssertEqual(forQ?.adjust.exposure, 0.7)
    }

    // MARK: Shadow (B10-5)

    func framed(_ frame: Frame, size: Int = 400) throws -> (CGImage, [UInt8]) {
        let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let out = FrameRenderer.compose(CIImage(cgImage: c.makeImage()!), frame: frame)
        let image = try XCTUnwrap(PhotoRenderer.cgImage(out, exact: true))
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image, px)
    }

    /// Red at (x, y), origin top left.
    func red(_ image: CGImage, _ px: [UInt8], _ x: Int, _ y: Int) -> Int { Int(px[(y * image.width + x) * 4]) }

    func testB11ShadowAtNoCornerAndAtHalfAndFilled() throws {
        var frame = Frame()
        frame.shape = .square
        (frame.top, frame.left, frame.right, frame.bottom) = (0.1, 0.1, 0.1, 0.1)
        frame.shadow = true
        for radius in [0.0, 0.5] {
            for fill in [false, true] {
                frame.cornerRadius = radius
                frame.fill = fill
                let (image, px) = try framed(frame)
                // Photo box 40 ... 360. Just below its bottom edge, centred: in the shadow.
                let below = red(image, px, 200, 362), away = red(image, px, 5, 5)
                let corner = red(image, px, 44, 44)
                XCTAssertLessThan(below, away - 10, "a shadow shows below the photo (r \(radius), fill \(fill))")
                XCTAssertGreaterThan(below, 60, "the shadow is soft, not black (r \(radius), fill \(fill))")
                if radius == 0.5 { XCTAssertGreaterThan(corner, away - 30, "no dark square corner outside a round photo") }
            }
        }
    }
}

extension Audit2026Round11PhotoTests {
    /// The store after Undo then Redo of a Replace of an edited photo (FileChanges.undoChange / redoChange → movePaths).
    func testB11StoreAndWindowThroughUndoAndRedoOfAReplace() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let d = folder.appendingPathComponent("F")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let original = d.appendingPathComponent("P.jpg")
        photo(original)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -86400)], ofItemAtPath: original.path)
        var made = EditRecipe(source: EditSource(path: original.standardizedFileURL.path, reference: RecipeStore.reference(original.path),
                                                 created: RecipeStore.created(original.path), kind: .image))
        made.adjust.exposure = 0.9
        let r = await store.store(made)
        let journal = OperationJournal(folder: folder.appendingPathComponent("journal"))
        let edit = folder.appendingPathComponent("edit.jpg")
        photo(edit, date: "2021:01:01 00:00:00")
        var away = await store.awayIDs()
        let entry = try await journal.replace(original, identity: AccountFolderRecord.number(of: original), with: edit, named: original,
                                              metadata: nil, title: "Replace")
        await store.movePaths([(original.path, original.path)], awayBefore: away)
        let afterReplace = await store.recipe(for: original)
        away = await store.awayIDs()
        let undone = await journal.undo(entry.id)
        await store.movePaths(undone.moves, awayBefore: away)
        let afterUndo = await store.recipe(for: original)
        XCTAssertEqual(afterUndo?.id, r?.id, "the original's edits are back with it")
        away = await store.awayIDs()
        let redone = await journal.redo(entry.id)
        await store.movePaths(redone.moves, awayBefore: away)
        let afterRedo = await store.recipe(for: original)
        XCTAssertNotEqual(afterRedo?.id, r?.id, "the replaced file is never shown the original's recipe")
    }
}

extension Audit2026Round11PhotoTests {
    /// D-128: the canvas (a copy at most 2400 px) and an export at the photo's own size look alike. Each adjustment at
    /// 2400 px (the canvas's copy) and at 6000 px (a 24 MP export), both brought to 300 px: corner and centre brightness compared.
    func testB11AdjustmentsLookTheSameAtCanvasAndExportSizes() {
        func source(_ edge: Int) -> CIImage {
            let c = CGContext(data: nil, width: edge, height: edge * 3 / 4, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            // Some detail: stripes every 1/40 of the width.
            c.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1)
            for i in stride(from: 0, to: 40, by: 2) {
                c.fill(CGRect(x: edge * i / 40, y: 0, width: edge / 40, height: edge))
            }
            return CIImage(cgImage: c.makeImage()!)
        }
        func sample(_ image: CIImage) -> (corner: Double, centre: Double) {
            let small = PhotoRenderer.scaled(image, toFit: CGSize(width: 300, height: 300))
            let cg = PhotoRenderer.cgImage(small, exact: true)!
            var px = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &px, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            func mean(_ x0: Int, _ y0: Int, _ n: Int) -> Double {
                var s = 0.0
                for y in y0 ..< y0 + n { for x in x0 ..< x0 + n { s += Double(px[(y * cg.width + x) * 4]) } }
                return s / Double(n * n)
            }
            return (mean(0, 0, 20), mean(cg.width / 2 - 10, cg.height / 2 - 10, 20))
        }
        for key in [Adjustments.Key.vignette, .clarity, .sharpen, .grain, .highlights, .shadows] {
            var recipe = EditRecipe(source: EditSource(path: "/x.jpg", kind: .image))
            recipe.adjust[key] = key == .highlights ? -80 : 80
            let small = sample(PhotoRenderer.render(source(2400), recipe: recipe))
            let large = sample(PhotoRenderer.render(source(6000), recipe: recipe))
            XCTAssertEqual(small.corner, large.corner, accuracy: 12, "\(key): corner")
            XCTAssertEqual(small.centre, large.centre, accuracy: 12, "\(key): centre")
        }
    }
}

extension Audit2026Round11PhotoTests {
    /// The square shadow (radius 0) drawn by the generator matches the plain shadow it replaced.
    func testB11SquareShadowIsAsBefore() throws {
        let placed = CGRect(x: 40, y: 40, width: 320, height: 320)
        let old = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: placed)
        let gen = CIFilter.roundedRectangleGenerator()
        gen.extent = placed
        gen.radius = 0
        gen.color = CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)
        let new = try XCTUnwrap(gen.outputImage)
        func alpha(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> Int {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image
            blur.radius = 5
            let over = blur.outputImage!.composited(over: CIImage(color: .white)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 400))
            let cg = PhotoRenderer.cgImage(over, exact: true)!
            var px = [UInt8](repeating: 0, count: 4)
            let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: -x, y: -y, width: 400, height: 400))
            return Int(px[0])
        }
        for (x, y) in [(200.0, 200.0), (200, 38), (41, 41), (38, 200)] {
            XCTAssertEqual(alpha(old, x, y), alpha(new, x, y), accuracy: 3)
        }
    }
}

extension Audit2026Round11PhotoTests {
    /// EditModel.recipeChanged's guard (EditBatch.swift:165-168), as written.
    func told(current: String, recipe: EditRecipe, paths: Set<String>, ids: Set<UUID>) -> Bool {
        paths.contains(current) || paths.contains(recipe.source.path) || ids.contains(recipe.id)
    }
}
