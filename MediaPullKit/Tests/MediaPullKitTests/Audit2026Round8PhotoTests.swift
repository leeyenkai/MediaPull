import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 8.
extension EditFrameTests {
    /// Two windows: B's first changes were registered for ⌘Z under its own new id, which the store merged into A's (adopt).
    /// After a Finder rename and a newcomer at the old name, B's ⌘Z must change the file's one recipe, never the newcomer's.
    func testB8UndoUnderAnAdoptedIDNeverGivesEditsToANewcomer() async throws {
        let edits = folder.appendingPathComponent("Edits")
        let store = RecipeStore(folder: edits)
        let photo = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        // Window A keeps a recipe for a.jpg.
        var windowA = recipe(for: photo)
        windowA.source.reference = RecipeStore.reference(photo.path)
        windowA.source.created = RecipeStore.created(photo.path)
        windowA.adjust.contrast = 10
        let storedA = await store.store(windowA)
        let keptA = try XCTUnwrap(storedA)
        // Window B opened a.jpg before that and made two quick changes (contrast 5, then 20): its ⌘Z snapshot is contrast 5
        // under B's own new id. Its save is merged into A's recipe and B adopts that id.
        var windowB = recipe(for: photo)
        windowB.source.reference = RecipeStore.reference(photo.path)
        windowB.source.created = RecipeStore.created(photo.path)
        var undoSnapshot = windowB
        undoSnapshot.adjust.contrast = 5
        windowB.adjust.contrast = 20
        let storedB = await store.store(windowB)
        let keptB = try XCTUnwrap(storedB)
        XCTAssertEqual(keptB.id, keptA.id, "adopted")
        // Renamed in the Finder; a newcomer takes the old name.
        let renamed = folder.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: photo, to: renamed)
        _ = try dated("a.jpg", created: Date())
        // B's ⌘Z: EditModel.restore sees an id other than the open recipe's and stores the snapshot (EditModel.swift:316-321).
        _ = await store.store(undoSnapshot)
        let newcomer = await store.recipe(for: photo)
        XCTAssertNil(newcomer, "the newcomer at the old name is given nothing")
        let followed = await store.recipe(for: renamed)
        XCTAssertEqual(followed?.id, keptA.id, "the renamed file keeps its one recipe")
        XCTAssertEqual(followed?.adjust.contrast, 5, "and the ⌘Z changed it")
    }

    /// Paste Settings onto a Media pane entry whose file was renamed or deleted in the Finder (the pane is listed again only
    /// after MediaPull's own changes): a recipe is kept with no creation date and no reference, and a later file at that
    /// name is shown those edits.
    func testB8APasteOntoAFileNoLongerThereGivesALaterFileNothing() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let gone = folder.appendingPathComponent("a.jpg")
        // EditBatch.pasteSettings: `stored ?? EditRecipe(source: EditSource(path: ..., kind: kind))`, then save.
        var pasted = EditRecipe(source: EditSource(path: gone.standardizedFileURL.path, kind: .image))
        pasted.adjust.contrast = 40
        let saved = await store.save(pasted)
        XCTAssertFalse(saved, "no recipe is kept for a file that is not there")
        _ = try dated("a.jpg", created: Date())
        let shown = await store.recipe(for: gone)
        XCTAssertNil(shown, "a later file at that name is not given the paste")
    }
}

extension EditFrameTests {
    /// R-4608: a PNG or HEIC export at a smaller size is opaque to its edges, like the photo (no alpha channel and no
    /// see-through border from the scaling filter reading past the picture's edge).
    func testB8AScaledPNGOrHEICExportIsOpaqueToItsEdges() throws {
        let original = folder.appendingPathComponent("big.jpg")
        let context = CGContext(data: nil, width: 3001, height: 2001, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3001, height: 2001))
        let destination = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        for format in [ExportSettings.PhotoFormat.png, .heic] {
            var made = recipe(for: original)
            made.export.format = format
            made.export.size = .long1080
            let out = folder.appendingPathComponent("out.\(format.fileExtension)")
            _ = try PhotoExporter.export(original, recipe: made, to: out)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            var px = [UInt8](repeating: 0, count: 4)
            let probe = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            probe.draw(image, in: CGRect(x: -(image.width - 1), y: -(image.height / 2), width: image.width, height: image.height))
            XCTAssertEqual(px[3], 255, "\(format): the right edge is opaque, got alpha \(px[3])")
            XCTAssertFalse([.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo),
                           "\(format): no alpha channel")
        }
    }
}

extension EditFrameTests {
    /// A photo opened unedited (EditModel.newRecipe knows it: its reference and creation date), then renamed in the Finder
    /// with a newcomer at its old name before the first change is kept: the edits made on the canvas (still the opened
    /// photo) go with the opened photo, never to the newcomer (B7-1's "its file as it is when first kept").
    func testB8AFirstKeptRecipeStaysWithTheFileItWasMadeFor() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("Edits"))
        let photo = try dated("a.jpg", created: Date().addingTimeInterval(-86400))
        var opened = recipe(for: photo)
        opened.source.reference = RecipeStore.reference(photo.path)
        opened.source.created = RecipeStore.created(photo.path)
        let renamed = folder.appendingPathComponent("b.jpg")
        try FileManager.default.moveItem(at: photo, to: renamed)
        _ = try dated("a.jpg", created: Date())
        opened.adjust.contrast = 15
        _ = await store.store(opened)
        let newcomer = await store.recipe(for: photo)
        XCTAssertNil(newcomer, "the newcomer is given nothing")
        let followed = await store.recipe(for: renamed)
        XCTAssertEqual(followed?.adjust.contrast, 15, "the opened photo keeps its edits")
    }
}
