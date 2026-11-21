import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
import MediaPullNet
import UniformTypeIdentifiers
import XCTest

/// Section 46: Edit/Frame recipes, rendering and export.
final class EditFrameTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("EditFrameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A 120 × 80 photo: a grey ramp left to right, with GPS and a camera.
    func photo(_ name: String = "photo.jpg", type: UTType = .jpeg) -> URL {
        let url = folder.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0 ..< 120 {
            context.setFillColor(red: 0.2 + CGFloat(x) / 240, green: 0.4, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: 80))
        }
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 20.0, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cam"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
        ]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(destination)
        return url
    }

    func recipe(for url: URL) -> EditRecipe {
        EditRecipe(source: EditSource(path: url.path, kind: .image))
    }

    /// Mean red, green and blue (0 to 1) of an image.
    func means(_ image: CGImage) -> (r: Double, g: Double, b: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum.0 += Double(pixels[i])
            sum.1 += Double(pixels[i + 1])
            sum.2 += Double(pixels[i + 2])
        }
        let n = Double(width * height) * 255
        return (sum.0 / n, sum.1 / n, sum.2 / n)
    }

    /// The colour at a point, origin top left.
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    // MARK: Recipes (R-4602)

    func testRecipesRoundTripAndReadOverABlankOne() throws {
        var recipe = recipe(for: URL(fileURLWithPath: "/x/a.jpg"))
        XCTAssertFalse(recipe.isEdited)
        recipe.adjust[.exposure] = 9
        XCTAssertEqual(recipe.adjust.exposure, 5, "clamped to its range")
        recipe.look = Look(name: .film, amount: 0.5)
        recipe.frame = Frame()
        recipe.layers = [Layer(kind: .text(TextStyle(text: "The Post")))]
        XCTAssertTrue(recipe.isEdited)
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(EditRecipe.decode(data), recipe)
        // A recipe written by an older MediaPull, with fields missing, reads with neutral values.
        let partial = #"{"id":"\#(recipe.id.uuidString)","source":{"path":"/x/a.jpg","kind":"image"},"adjust":{"exposure":1}}"#
        let read = try XCTUnwrap(EditRecipe.decode(Data(partial.utf8)))
        XCTAssertEqual(read.adjust.exposure, 1)
        XCTAssertEqual(read.adjust.contrast, 0)
        XCTAssertEqual(read.export, ExportSettings())
        XCTAssertNil(EditRecipe.decode(Data("{}".utf8)))
    }

    func testGeometryAndSizes() {
        XCTAssertEqual(EditGeometry.straightenScale(width: 100, height: 100, degrees: 0), 1)
        XCTAssertEqual(EditGeometry.straightenScale(width: 100, height: 100, degrees: 45), 1 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(UnitRect.centred(ratio: 1, in: CGSize(width: 200, height: 100)), UnitRect(x: 0.25, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(UnitRect.centred(ratio: 4, in: CGSize(width: 200, height: 100)), UnitRect(x: 0, y: 0.25, width: 1, height: 0.5))
        XCTAssertEqual(UnitRect(x: 0.9, y: -1, width: 0.5, height: 2).clamped, UnitRect(x: 0.5, y: 0, width: 0.5, height: 1))
        let cases: [(ExportSettings.Size, CGSize, CGSize)] = [
            (.original, CGSize(width: 4000, height: 3000), CGSize(width: 4000, height: 3000)),
            (.long1080, CGSize(width: 4000, height: 3000), CGSize(width: 1080, height: 810)),
            (.post45, CGSize(width: 4000, height: 5000), CGSize(width: 1080, height: 1350)),
            (.story, CGSize(width: 4000, height: 3000), CGSize(width: 1080, height: 810)),
            (.long4096, CGSize(width: 800, height: 600), CGSize(width: 800, height: 600)),
        ]
        for (size, input, expected) in cases {
            XCTAssertEqual(size.pixels(for: input), expected, "\(size)")
        }
    }

    func testFrameLayout() {
        var frame = Frame()
        frame.top = 0.1
        frame.left = 0.1
        frame.right = 0.1
        frame.bottom = 0.2
        // The photo's own shape grows by its border; insets are shares of the shorter side.
        let own = FrameRenderer.layout(picture: CGSize(width: 1000, height: 500), frame: frame)
        XCTAssertEqual(own.canvas, CGSize(width: 1100, height: 650))
        XCTAssertEqual(own.photo, CGRect(x: 50, y: 50, width: 1000, height: 500))
        // A fixed shape fits the photo inside the insets, centred.
        frame.shape = .square
        let square = FrameRenderer.layout(picture: CGSize(width: 1000, height: 500), frame: frame)
        XCTAssertEqual(square.canvas, CGSize(width: 1000, height: 1000))
        XCTAssertEqual(square.photo.width, 800)
        XCTAssertEqual(square.photo.minX, 100)
        XCTAssertLessThan(square.photo.maxY, 1000 - 200 + 1)
        // Filling, the photo takes the whole space inside the insets (a poster).
        frame.fill = true
        let filled = FrameRenderer.layout(picture: CGSize(width: 1000, height: 500), frame: frame)
        XCTAssertEqual(filled.photo, CGRect(x: 100, y: 100, width: 800, height: 700))
    }

    // MARK: Rendering (R-4603, R-4604)

    func testAdjustmentsMoveThePictureTheRightWay() throws {
        let url = photo()
        let input = try XCTUnwrap(PhotoRenderer.source(url))
        let base = means(try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: recipe(for: url)), exact: true)))
        func rendered(_ change: (inout EditRecipe) -> Void) throws -> (r: Double, g: Double, b: Double) {
            var edit = recipe(for: url)
            change(&edit)
            return means(try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: edit), exact: true)))
        }
        let brighter = try rendered { $0.adjust.exposure = 1 }
        XCTAssertGreaterThan(brighter.g, base.g + 0.05)
        let warmer = try rendered { $0.adjust.temperature = 80 }
        XCTAssertGreaterThan(warmer.r - warmer.b, base.r - base.b + 0.02)
        let mono = try rendered { $0.look = Look(name: .mono) }
        XCTAssertEqual(mono.r, mono.b, accuracy: 0.02)
        let grey = try rendered { $0.adjust.saturation = -100 }
        XCTAssertEqual(grey.r, grey.g, accuracy: 0.02)
        // Deterministic: the same recipe gives the same pixels.
        XCTAssertEqual(try rendered { $0.adjust.grain = 50 }.r, try rendered { $0.adjust.grain = 50 }.r)
    }

    func testGeometryTurnsCropsAndStraightens() throws {
        let url = photo()
        let input = try XCTUnwrap(PhotoRenderer.source(url))
        var edit = recipe(for: url)
        edit.geometry.quarterTurns = 1
        var image = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: edit)))
        XCTAssertEqual([image.width, image.height], [80, 120])
        edit.geometry = EditGeometry()
        edit.geometry.crop = UnitRect(x: 0, y: 0, width: 0.5, height: 1)
        image = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: edit), exact: true))
        XCTAssertEqual([image.width, image.height], [60, 80])
        // The left half of the ramp is the darker half.
        XCTAssertLessThan(means(image).r, means(try XCTUnwrap(PhotoRenderer.cgImage(input, exact: true))).r)
        edit.geometry = EditGeometry()
        edit.geometry.straighten = 10
        image = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.render(input, recipe: edit), exact: true))
        XCTAssertLessThan(image.width, 120)
        XCTAssertEqual(Double(image.width) / Double(image.height), 1.5, accuracy: 0.05)
        // No empty corners: the corner is picture, not transparent black.
        XCTAssertGreaterThan(pixel(image, 0, 0).g, 50)
    }

    // MARK: Frames and layers (R-4605, R-4606)

    func testAFrameAndTextAreDrawnWhereTheRecipeSays() throws {
        let url = photo()
        let input = try XCTUnwrap(PhotoRenderer.source(url))
        var edit = recipe(for: url)
        var frame = Frame()
        frame.background = .color(EditColor(red: 1, green: 0, blue: 0))
        frame.bottom = 0.3
        edit.frame = frame
        var title = TextStyle(text: "THE POST")
        title.color = .black
        title.size = 0.12
        title.family = "Helvetica Neue"
        title.face = "Bold"
        var layer = Layer(kind: .text(title))
        // In the thick bottom border.
        layer.x = 0.5
        layer.y = 0.88
        layer.width = 0.9
        layer.height = 0.15
        edit.layers = [layer]
        let canvas = PhotoRenderer.render(input, recipe: edit) { LayerRenderer.image(edit.layers, canvas: $0) }
        let image = try XCTUnwrap(PhotoRenderer.cgImage(canvas, exact: true))
        let layout = FrameRenderer.layout(picture: CGSize(width: 120, height: 80), frame: frame)
        XCTAssertEqual([image.width, image.height], [Int(layout.canvas.width), Int(layout.canvas.height)])
        // The border's colour at a corner, the photo inside.
        XCTAssertEqual(pixel(image, 1, 1).r, 255)
        XCTAssertLessThan(pixel(image, 1, 1).g, 10)
        XCTAssertGreaterThan(pixel(image, Int(layout.photo.midX), Int(layout.photo.midY)).g, 60)
        // Text drawn: dark pixels inside the layer's box, none of them in the top border.
        let box = LayerRenderer.rect(of: layer, canvas: layout.canvas)
        var dark = 0
        for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 1) {
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 2) where pixel(image, x, y).r < 80 {
                dark += 1
            }
        }
        XCTAssertGreaterThan(dark, 10, "the title is drawn in the bottom border")
        XCTAssertEqual(pixel(image, 2, Int(layout.photo.minY) / 2).r, 255, "nothing drawn in the top border")
        // The same rect at two scales, as preview and export.
        let small = LayerRenderer.rect(of: layer, canvas: CGSize(width: layout.canvas.width / 2, height: layout.canvas.height / 2))
        XCTAssertEqual(small.minX * 2, box.minX, accuracy: 0.001)
        // A missing font draws with the system font and says so (R-4607).
        var missing = title
        missing.family = "No Such Font Family"
        XCTAssertTrue(LayerRenderer.font(missing, canvasHeight: 100).missing)
        XCTAssertFalse(LayerRenderer.font(title, canvasHeight: 100).missing)
    }

    // MARK: Export (R-4608)

    func testExportWritesANewFileAndLeavesTheOriginal() throws {
        let url = photo()
        let before = try FileHasher.sha256(of: url)
        var edit = recipe(for: url)
        edit.adjust.exposure = 0.5
        edit.export.format = .heic
        edit.export.size = .long1080
        edit.export.keepLocation = false
        let output = folder.appendingPathComponent("photo-edited.heic")
        let size = try PhotoExporter.export(url, recipe: edit, to: output)
        XCTAssertEqual(size, CGSize(width: 120, height: 80), "never enlarged")
        XCTAssertEqual(try FileHasher.sha256(of: url), before)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "location left out")
        XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "Cam")
        XCTAssertEqual((props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String,
                       "2020:01:02 03:04:05")
    }

    // MARK: The store (R-4602)

    func testTheStoreKeepsRecipesFollowsMovesAndForgetsBlankOnes() async throws {
        let url = photo()
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        var edit = recipe(for: url)
        edit.adjust.contrast = 20
        await store.save(edit)
        let found = await store.recipe(for: url)
        XCTAssertEqual(found?.adjust.contrast, 20)
        XCTAssertNotNil(found?.source.reference)
        // A fresh store reads it back from disk.
        let reopened = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let read = await reopened.recipe(for: url)
        XCTAssertEqual(read?.adjust.contrast, 20)
        // Moved by MediaPull.
        let moved = folder.appendingPathComponent("moved.jpg")
        await reopened.movePaths([(url.standardizedFileURL.path, moved.standardizedFileURL.path)])
        let afterMove = await reopened.recipe(for: moved)
        XCTAssertEqual(afterMove?.adjust.contrast, 20)
        // Renamed outside MediaPull: found by its reference.
        let renamed = folder.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: url, to: renamed)
        let outside = RecipeStore(folder: folder.appendingPathComponent("Edits2"))
        var other = recipe(for: renamed)
        other.adjust.contrast = 5
        await outside.save(other)
        let later = folder.appendingPathComponent("later.jpg")
        try FileManager.default.moveItem(at: renamed, to: later)
        let followed = await outside.recipe(for: later)
        XCTAssertEqual(followed?.adjust.contrast, 5)
        // Revert: a blank recipe is removed.
        var blank = try XCTUnwrap(followed)
        blank.adjust = Adjustments()
        await outside.save(blank)
        let gone = await outside.recipe(for: later)
        XCTAssertNil(gone)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Edits2").path)
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: Audit round 1

    func testAStoredRecipeMissingNestedFieldsStillReads() throws {
        let id = UUID().uuidString
        let json = #"{"id":"\#(id)","source":{"path":"/x/a.jpg","kind":"image"},"adjust":{"exposure":1.5},"#
            + #""frame":{"shape":"square","top":0.1},"layers":[{"kind":{"text":{"_0":{"text":"Hi"}}},"x":0.2}]}"#
        let read = try XCTUnwrap(EditRecipe.decode(Data(json.utf8)))
        XCTAssertEqual(read.adjust.exposure, 1.5)
        XCTAssertEqual(read.frame?.shape, .square)
        XCTAssertEqual(read.frame?.top, 0.1)
        XCTAssertEqual(read.frame?.fill, false)
        XCTAssertEqual(read.layers.count, 1)
        XCTAssertEqual(read.layers.first?.x, 0.2)
        guard case let .text(style)? = read.layers.first?.kind else { return XCTFail("a text layer") }
        XCTAssertEqual(style.text, "Hi")
        XCTAssertEqual(style.family, "Helvetica Neue")
        XCTAssertTrue(read.isEdited)
    }

    func testMovesThatSwapPathsKeepBothRecipes() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let one = photo("1.jpg"), two = photo("2.jpg")
        var first = recipe(for: one)
        first.adjust.contrast = 10
        var second = recipe(for: two)
        second.adjust.contrast = 20
        await store.save(first)
        await store.save(second)
        let three = folder.appendingPathComponent("3.jpg").standardizedFileURL.path
        try FileManager.default.moveItem(atPath: two.path, toPath: three)
        try FileManager.default.moveItem(at: one, to: two)
        await store.movePaths([(two.standardizedFileURL.path, three), (one.standardizedFileURL.path, two.standardizedFileURL.path)])
        let atTwo = await store.recipe(for: two)
        let paths = await store.editedPaths()
        XCTAssertEqual(atTwo?.adjust.contrast, 10)
        XCTAssertEqual(paths.count, 2)
    }

    func testAnotherFileGivenTheSameNameDoesNotTakeTheEdits() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let url = photo("same.jpg")
        var edit = recipe(for: url)
        edit.adjust.contrast = 30
        await store.save(edit)
        try FileManager.default.removeItem(at: url)
        _ = photo("same.jpg")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(3600)], ofItemAtPath: url.path)
        let found = await store.recipe(for: url)
        XCTAssertNil(found)
    }

    func testThePhotosOwnShapeKeepsItsProportions() {
        var frame = Frame()
        frame.shape = .photoShape
        let layout = FrameRenderer.layout(picture: CGSize(width: 1600, height: 900), frame: frame)
        XCTAssertEqual(layout.canvas.width / layout.canvas.height, 16.0 / 9, accuracy: 0.01)
        XCTAssertLessThan(layout.photo.width, 1600)
    }

    // MARK: Audit round 2

    func testRecipesAreNeverDeletedAndFollowTheirFiles() async throws {
        let folderEdits = folder.appendingPathComponent("Edits")
        let store = RecipeStore(folder: folderEdits)
        // Moved by MediaPull to another disk: a new creation date, still the same file (B2-2).
        let url = photo("moved.jpg")
        var edit = recipe(for: url)
        edit.adjust.contrast = 40
        await store.save(edit)
        let destination = folder.appendingPathComponent("elsewhere.jpg")
        try FileManager.default.moveItem(at: url, to: destination)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(7200)], ofItemAtPath: destination.path)
        await store.movePaths([(url.path, destination.path)])
        let afterMove = await store.recipe(for: destination)
        XCTAssertEqual(afterMove?.adjust.contrast, 40)

        // Renamed in the Finder, then a new file takes the old name: the new one gets nothing, the renamed one keeps its
        // edits (B2-4).
        let original = photo("IMG_0001.jpg")
        var first = recipe(for: original)
        first.adjust.contrast = 15
        await store.save(first)
        let renamed = folder.appendingPathComponent("Sunset.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)
        _ = photo("IMG_0001.jpg")
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(3600)], ofItemAtPath: original.path)
        let newcomer = await store.recipe(for: original)
        XCTAssertNil(newcomer)
        let found = await store.recipe(for: renamed)
        XCTAssertEqual(found?.adjust.contrast, 15)

        // A file deleted: its recipe is kept on disk, never pruned (B2-3).
        try FileManager.default.removeItem(at: destination)
        let reopened = RecipeStore(folder: folderEdits)
        _ = await reopened.editedPaths()
        let files = try FileManager.default.contentsOfDirectory(atPath: folderEdits.path)
        XCTAssertEqual(files.count, 2, "\(files)")
    }

    // MARK: Audit round 3

    /// A file at `name` with its creation date set, as a card's file would have.
    func dated(_ name: String, created: Date) throws -> URL {
        let url = photo(name)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
        return url
    }

    func edited(_ url: URL, contrast: Double) -> EditRecipe {
        var made = recipe(for: url)
        made.adjust.contrast = contrast
        return made
    }

    func testTwoCardsWithOneNameKeepTheirOwnEdits() async throws {
        let edits = folder.appendingPathComponent("Edits")
        let store = RecipeStore(folder: edits)
        let cardA = Date().addingTimeInterval(-86400), cardB = Date().addingTimeInterval(-3600)
        let path = try dated("IMG_0001.JPG", created: cardA)
        await store.save(edited(path, contrast: 15))
        // Card B in its place: nothing shown or marked, and Revert there removes nothing of card A's (B3-1, B3-2).
        try FileManager.default.removeItem(at: path)
        _ = try dated("IMG_0001.JPG", created: cardB)
        let onB = await store.recipe(for: path)
        XCTAssertNil(onB)
        let marked = await store.editedPaths()
        XCTAssertFalse(marked.contains(path.standardizedFileURL.path))
        await store.remove(path.path)
        await store.save(edited(path, contrast: 70))
        let editedB = await store.recipe(for: path)
        XCTAssertEqual(editedB?.adjust.contrast, 70)
        // Card A back: its own edits, now and after a relaunch.
        try FileManager.default.removeItem(at: path)
        _ = try dated("IMG_0001.JPG", created: cardA)
        let onA = await store.recipe(for: path)
        XCTAssertEqual(onA?.adjust.contrast, 15)
        let relaunched = await RecipeStore(folder: edits).recipe(for: path)
        XCTAssertEqual(relaunched?.adjust.contrast, 15)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: edits.path).count, 2)
    }

    func testARenamedFileOpenedFirstKeepsItsEditsAndNothingIsWrittenOver() async throws {
        let edits = folder.appendingPathComponent("Edits")
        let store = RecipeStore(folder: edits)
        let old = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        await store.save(edited(old, contrast: 15))
        let renamed = folder.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: old, to: renamed)
        _ = try dated("a.jpg", created: Date())
        // The renamed file is found by its reference though a newcomer has its old name (B3-4).
        let forRenamed = await store.recipe(for: renamed)
        XCTAssertEqual(forRenamed?.adjust.contrast, 15)
        let marked = await store.editedPaths()
        XCTAssertEqual(marked, [renamed.standardizedFileURL.path])
        var newer = try XCTUnwrap(forRenamed)
        newer.adjust.contrast = 70
        await store.save(newer)
        let forNewcomer = await store.recipe(for: old)
        XCTAssertNil(forNewcomer)
        let again = await store.recipe(for: renamed)
        XCTAssertEqual(again?.adjust.contrast, 70)
        let relaunched = await RecipeStore(folder: edits).recipe(for: renamed)
        XCTAssertEqual(relaunched?.adjust.contrast, 70)
    }

    func testAMoveOntoAPathWithAKeptRecipeShowsTheMovedFilesEdits() async throws {
        for round in 0 ..< 10 {
            let store = RecipeStore(folder: folder.appendingPathComponent("Edits\(round)"))
            let kept = try dated("x\(round).jpg", created: Date().addingTimeInterval(-86400))
            await store.save(edited(kept, contrast: 11))
            try FileManager.default.removeItem(at: kept)
            let other = try dated("y\(round).jpg", created: Date().addingTimeInterval(-3600))
            await store.save(edited(other, contrast: 22))
            try FileManager.default.moveItem(at: other, to: kept)
            await store.movePaths([(other.path, kept.path)])
            let found = await store.recipe(for: kept)
            XCTAssertEqual(found?.adjust.contrast, 22, "round \(round) (B3-5)")
        }
    }

    func testASaveAfterAMoveToAnotherDiskKeepsTheNewCreationDate() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let original = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        await store.save(edited(original, contrast: 15))
        let stored = await store.recipe(for: original)
        var open = try XCTUnwrap(stored)
        let destination = folder.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: original, to: destination)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: destination.path)
        await store.movePaths([(original.path, destination.path)])
        // The open file's copy only knows the new path (B3-3).
        open.source.path = destination.standardizedFileURL.path
        open.adjust.exposure = 0.5
        await store.save(open)
        let found = await store.recipe(for: destination)
        XCTAssertEqual(found?.adjust.exposure, 0.5)
    }

    func testTheCanvasKeepsDisplayP3Colours() throws {
        let url = folder.appendingPathComponent("p3.png")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        CGImageDestinationFinalize(destination)
        let session = try XCTUnwrap(PhotoSession(url: url))
        var wide = recipe(for: url)
        wide.export.displayP3 = true
        let canvas = try XCTUnwrap(session.preview(wide, fit: CGSize(width: 64, height: 64)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let reader = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reader.draw(canvas, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 250, "\(pixel) (B3-m1)")
        XCTAssertLessThan(pixel[1], 5, "\(pixel)")
    }

    // MARK: Audit round 4

    func testAMoveToAnotherDiskTakesOnlyTheMovedFilesRecipe() throws {
        // Card A's recipe at a path card B's photo now has: not taken along when B's photo goes to another disk (B4-1).
        let cardB = try dated("IMG_0001.JPG", created: Date())
        var cardA = edited(cardB, contrast: 15)
        cardA.source.created = Date().addingTimeInterval(-86400)
        // After the move: card B's photo on the other disk, with the new creation date such a move gives.
        let destination = try dated("library-IMG_0001.JPG", created: Date()).path
        XCTAssertFalse(RecipeStore.follows(cardA, to: destination, crossesDisks: true, wasInPlace: false))
        // The moved file's own recipe goes.
        XCTAssertTrue(RecipeStore.follows(cardA, to: destination, crossesDisks: true, wasInPlace: true))
        // On one disk, the creation date or reference decides.
        XCTAssertFalse(RecipeStore.follows(cardA, to: cardB.path, crossesDisks: false, wasInPlace: true))
    }

    func testARecipeRestoredAfterAMoveIsKnownByItsFileAsItIsNow() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let original = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        await store.save(edited(original, contrast: 15))
        let stored = await store.recipe(for: original)
        let before = try XCTUnwrap(stored)
        // Reverted (the recipe goes), then the file moves to another disk and gets a new creation date.
        var blank = before
        blank.adjust = Adjustments()
        await store.save(blank)
        let destination = folder.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: original, to: destination)
        try FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: destination.path)
        await store.movePaths([(original.path, destination.path)])
        // ⇧⌘Z brings the edits back with the file as it is now (B4-2).
        var restored = before
        restored.source.path = destination.standardizedFileURL.path
        restored.source.created = nil
        restored.source.reference = nil
        await store.save(restored)
        let found = await store.recipe(for: destination)
        XCTAssertEqual(found?.adjust.contrast, 15)
    }
}
