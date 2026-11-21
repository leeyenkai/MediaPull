import CoreGraphics
import CoreImage
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullLibrary
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 14: Edit/Frame for photos.
final class Audit2026Round14PhotoTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("B14-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static func bitmap(_ width: Int, _ height: Int, red: CGFloat = 0.6) -> CGImage {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(red: red, green: 0.4, blue: 0.3, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return c.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
    }

    func path(_ url: URL) -> String { url.standardizedFileURL.path }

    /// FileChanges.followMoves (FileChanges.swift:236-260): the store, then the window (EditModel.followMoves, the picture
    /// part, EditModel.swift:398-408).
    func move(_ store: RecipeStore, _ from: URL, _ to: URL, window open: inout EditRecipe, alreadyMoved: Bool = false) async throws {
        if !alreadyMoved {
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            let away = await store.awayIDs()
            try FileManager.default.moveItem(at: from, to: to)
            await store.movePaths([(from.path, to.path)], awayBefore: away)
        }
        let remap = PathMoves([(path(from), path(to))])
        // Never into a hidden name, as EditModel.followMoves since round 14 (B14-1).
        _ = RecipeStore.picturesFollow(&open) {
            RecipeStore.visible(remap.destination(of: URL(fileURLWithPath: $0).standardizedFileURL.path))
        }
    }

    /// EditModel.restore (EditModel.swift:316-321) for the open recipe, then scheduleSave's store and adopt
    /// (EditModel.swift:347-350, adopt copied from EditModel.swift:422-447).
    func undo(to previous: EditRecipe, open: inout EditRecipe, store: RecipeStore) async throws {
        var restored = previous
        restored.source = open.source
        open = restored
        let saved = open
        let keptOrNil = await store.store(saved)
        let kept = try XCTUnwrap(keptOrNil)
        // adopt
        guard open.id == saved.id else { return }
        open.id = kept.id
        open.source = kept.source
        // As EditModel.adopt since round 14: where the store kept a picture elsewhere than the window sent it.
        for index in open.layers.indices {
            let id = open.layers[index].id
            guard case let .image(path) = open.layers[index].kind,
                  let sent = saved.layers.first(where: { $0.id == id }), case let .image(sentPath) = sent.kind, sentPath == path,
                  let same = kept.layers.first(where: { $0.id == id }), case let .image(moved) = same.kind, moved != path
            else { continue }
            open.layers[index].kind = .image(path: moved)
        }
    }

    func newRecipe(_ photo: URL) -> EditRecipe {
        EditRecipe(source: EditSource(path: path(photo), reference: RecipeStore.reference(photo.path),
                                      created: RecipeStore.created(photo.path), kind: .image))
    }

    func logoPath(_ recipe: EditRecipe?) -> String? {
        recipe?.layers.compactMap { if case let .image(p) = $0.kind { p } else { nil } }.first
    }
}

// MARK: B13-1 follow-up: pictures the store corrects

extension Audit2026Round14PhotoTests {
    /// The old logo.png is moved aside into Old (Organise). A new logo.png is saved in its place and put on a photo in
    /// Edit/Frame; a slider change follows (⌘Z holds the recipe with the new logo at its first name). The new logo is then
    /// moved into Logos. ⌘Z of the slider change: the store corrects the name the recipe had (`movedPictures`), but
    /// `PathMoves.destination` follows that name from the first move ever made of it, so the layer now draws the OLD logo,
    /// from Old, and the window shows it (adopt).
    func testB14UndoAfterANewLogoMovedDrawsTheNewLogoNotTheOldOne() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg")
        let logo = folder.appendingPathComponent("logo.png")
        let oldPlace = folder.appendingPathComponent("Old/logo.png"), newPlace = folder.appendingPathComponent("Logos/logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16, red: 0.1), to: logo, type: .png)
        var nothingOpen = newRecipe(photo)
        // The old logo goes aside (no recipe names it).
        try await move(store, logo, oldPlace, window: &nothingOpen)
        // The new logo, of the same name.
        Self.write(Self.bitmap(16, 16, red: 0.9), to: logo, type: .png)
        var open = newRecipe(photo)
        open.layers = [Layer(kind: .image(path: logo.path))]
        let firstOrNil = await store.store(open)
        let first = try XCTUnwrap(firstOrNil)
        open.id = first.id
        open.source = first.source
        XCTAssertEqual(logoPath(first), path(logo), "a picture that is there is never changed")
        let before = open
        open.adjust.exposure = 0.4
        _ = await store.store(open)
        try await move(store, logo, newPlace, window: &open)
        let followed = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(followed), path(newPlace), "the store follows the new logo (B12-1)")
        XCTAssertEqual(logoPath(open), path(newPlace), "the window follows it")
        try await undo(to: before, open: &open, store: store)
        let undone = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(undone), path(newPlace), "after ⌘Z the recipe draws the old logo from Old")
        XCTAssertEqual(logoPath(open), path(newPlace), "after ⌘Z the window shows the old logo from Old")
    }

    /// The logo is moved into Logos, and a different logo.png is then saved at its first name. ⌘Z of a change made
    /// before the move brings back the first name; that file exists, so the store and the window keep it: the recipe now
    /// draws the newcomer, not the logo it was made with.
    func testB14UndoAfterALogoMovedAndAnotherSavedAtItsNameKeepsTheMovedLogo() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg")
        let logo = folder.appendingPathComponent("logo.png"), moved = folder.appendingPathComponent("Logos/logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16, red: 0.1), to: logo, type: .png)
        var open = newRecipe(photo)
        open.layers = [Layer(kind: .image(path: logo.path))]
        let firstOrNil = await store.store(open)
        let first = try XCTUnwrap(firstOrNil)
        open.id = first.id
        open.source = first.source
        let before = open
        open.adjust.exposure = 0.4
        _ = await store.store(open)
        try await move(store, logo, moved, window: &open)
        Self.write(Self.bitmap(16, 16, red: 0.9), to: logo, type: .png)
        try await undo(to: before, open: &open, store: store)
        let undone = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(undone), path(moved), "after ⌘Z the recipe draws the other file saved at the logo's old name")
        XCTAssertEqual(logoPath(open), path(moved), "after ⌘Z the window shows the other file")
    }

    /// `movedPictures` holds the newest 20,000 moves of any file, not only pictures: one automatic sort of a large folder
    /// after the logo moved makes ⌘Z lose the logo again, as before B13-1.
    func testB14UndoAfterALogoMovedAndALargeSortKeepsTheLogo() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg")
        let logo = folder.appendingPathComponent("logo.png"), moved = folder.appendingPathComponent("logo-white.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16), to: logo, type: .png)
        var open = newRecipe(photo)
        open.layers = [Layer(kind: .image(path: logo.path))]
        let firstOrNil = await store.store(open)
        let first = try XCTUnwrap(firstOrNil)
        open.id = first.id
        open.source = first.source
        let before = open
        open.adjust.exposure = 0.4
        _ = await store.store(open)
        try await move(store, logo, moved, window: &open)
        // A sort of 20,000 photos elsewhere (only the journal's moves matter here).
        let sort = (0 ..< 20000).map { ("/Volumes/None/In/\($0).jpg", "/Volumes/None/Out/\($0).jpg") }
        await store.movePaths(sort)
        try await undo(to: before, open: &open, store: store)
        let undone = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(undone), path(moved), "after a large sort, ⌘Z names the logo's old name again")
    }

    /// Sanity of B13-1 (expected to pass): a chain of moves, a move back, a picture deleted, a picture that is there, and
    /// nothing else in the recipe changed.
    func testB14MovedPicturesChainsMoveBackAndDeletion() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg")
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("B/b.png"),
            c = folder.appendingPathComponent("C/c.png"), gone = folder.appendingPathComponent("gone.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16), to: a, type: .png)
        Self.write(Self.bitmap(16, 16), to: gone, type: .png)
        var open = newRecipe(photo)
        open.layers = [Layer(kind: .image(path: a.path)), Layer(kind: .image(path: gone.path)),
                       Layer(kind: .text(TextStyle(text: "Hi")))]
        open.adjust.contrast = 12
        open.frame = Frame()
        let firstOrNil = await store.store(open)
        let first = try XCTUnwrap(firstOrNil)
        open.id = first.id
        open.source = first.source
        let before = open
        open.adjust.exposure = 0.4
        _ = await store.store(open)
        try await move(store, a, b, window: &open)
        try await move(store, b, c, window: &open)
        try FileManager.default.removeItem(at: gone)
        try await undo(to: before, open: &open, store: store)
        let undoneOrNil = await store.recipe(for: photo)
        var undone = try XCTUnwrap(undoneOrNil)
        XCTAssertEqual(logoPath(undone), path(c), "a chain of moves")
        if case let .image(p) = undone.layers[1].kind { XCTAssertEqual(p, gone.path, "a deleted picture keeps its name") }
        var expected = before
        expected.layers[0].kind = .image(path: path(c))
        undone.modified = expected.modified
        undone.source = expected.source
        XCTAssertEqual(undone, expected, "nothing else changed")
        // Moved back to its first name: the name it has is kept.
        try await move(store, c, a, window: &open)
        try await undo(to: before, open: &open, store: store)
        let back = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(back), path(a), "moved back")
    }
}

// MARK: B13-m1: sizes

extension Audit2026Round14PhotoTests {
    /// Every size setting, over picture sizes, crops of each shape, straighten, quarter turns and every frame shape:
    /// the export canvas (PhotoExporter.rendered's `render(fit:)`) is exactly `pixels(for:)` of the unfitted result.
    /// Extents only, nothing is drawn.
    func testB14EverySizeSettingIsExactWithFramesAndCrops() {
        var wrong: [String] = []
        var checked = 0
        var generator = SystemRandomNumberGenerator()
        let shapes: [Frame.Shape?] = [nil] + Frame.Shape.allCases.map { $0 }
        for _ in 0 ..< 400 {
            let w = Int.random(in: 300 ... 7000, using: &generator), h = Int.random(in: 300 ... 7000, using: &generator)
            let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            var recipe = EditRecipe(source: EditSource(path: "/x.jpg", kind: .image))
            recipe.geometry.quarterTurns = Int.random(in: 0 ... 3, using: &generator)
            recipe.geometry.straighten = Bool.random(using: &generator) ? Double.random(in: -45 ... 45, using: &generator) : 0
            let aspect = EditAspect.allCases.randomElement(using: &generator)!
            recipe.geometry.aspect = aspect
            if aspect != .free {
                let turned = recipe.geometry.turnedSize(input.extent.size)
                recipe.geometry.crop = aspect.ratio(original: turned.width / turned.height).map {
                    UnitRect.centred(ratio: $0, in: CGSize(width: turned.width / turned.height, height: 1))
                }
            } else if Bool.random(using: &generator) {
                recipe.geometry.crop = UnitRect(x: 0.1, y: 0.07, width: Double.random(in: 0.2 ... 0.9, using: &generator),
                                                height: Double.random(in: 0.2 ... 0.9, using: &generator))
            }
            if let shape = shapes.randomElement(using: &generator)! {
                var frame = Frame()
                frame.shape = shape
                frame.fill = Bool.random(using: &generator)
                frame.top = Double.random(in: 0 ... 0.2, using: &generator)
                frame.bottom = Double.random(in: 0 ... 0.3, using: &generator)
                recipe.frame = frame
            }
            let full = PhotoRenderer.render(input, recipe: recipe).extent.size
            for setting in ExportSettings.Size.allCases {
                recipe.export.size = setting
                let target = setting.pixels(for: full)
                let got = PhotoRenderer.render(input, recipe: recipe, fit: setting.box ?? target).extent.size
                checked += 1
                if got != target {
                    wrong.append("\(w)×\(h) \(setting.rawValue) \(String(describing: recipe.frame?.shape)): \(got) for \(target)")
                }
                if let box = setting.box, got.width > box.width || got.height > box.height {
                    wrong.append("\(w)×\(h) \(setting.rawValue): \(got) outside \(box)")
                }
            }
        }
        print("B14 sizes not as asked: \(wrong.count) of \(checked)\n" + wrong.prefix(10).joined(separator: "\n"))
        XCTAssertTrue(wrong.isEmpty, wrong.first ?? "")
    }
}

// MARK: Replace of a picture a layer draws (FileChanges.swift:186-201)

extension Audit2026Round14PhotoTests {
    /// A test disk image (the journal trashes): MEDIAPULL_TEST_VOLUME.
    var testVolume: URL? {
        ProcessInfo.processInfo.environment["MEDIAPULL_TEST_VOLUME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A logo used by a picture layer is cropped in the Preview pane's quick editor and replaced (same name), then ⌘Z
    /// takes the Replace back: the original logo is back at its name. The Undo's moves (`report.moves`) hold the edit's
    /// step to its hidden name (`logo.png → .mediapull-edit-….png`, OperationJournal.swift:1333), FileChanges passes
    /// them to `RecipeStore.movePaths` and every window's `followMoves` (FileChanges.swift:201, 244, 259), and both move
    /// picture layers with no check (RecipeStore.swift:281, EditModel.swift:401-402): the layer now names a hidden file
    /// that has gone to the Trash. The canvas says the logo is gone and Export is refused, though it is back where it was.
    func testB14UndoOfAReplaceOfALogoKeepsTheLayersLogo() async throws {
        guard let volume = testVolume else { throw XCTSkip("needs a test disk image (MEDIAPULL_TEST_VOLUME)") }
        let d = volume.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let journal = OperationJournal(folder: folder.appendingPathComponent("journal"))
        let photo = d.appendingPathComponent("P.jpg"), logo = d.appendingPathComponent("logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16, red: 0.1), to: logo, type: .png)
        var open = newRecipe(photo)
        open.layers = [Layer(kind: .image(path: logo.path))]
        let firstOrNil = await store.store(open)
        let first = try XCTUnwrap(firstOrNil)
        open.id = first.id
        open.source = first.source
        // Replace (FileChanges.replaceFile, FileChanges.swift:32-42).
        let edit = d.appendingPathComponent("staged.png")
        Self.write(Self.bitmap(12, 12, red: 0.9), to: edit, type: .png)
        var away = await store.awayIDs()
        let entry = try await journal.replace(logo, identity: nil, with: edit, named: URL(fileURLWithPath: logo.path), metadata: nil,
                                              title: "Edit")
        // (A URL of its own, as EditorModel.swift:330 builds it: the same instance would carry the original's cached size.)
        let placed = entry.moves.last { !$0.to.hasSuffix(".json") }?.to ?? logo.path
        await store.movePaths([(logo.path, placed)], awayBefore: away)
        try await move(store, logo, logo, window: &open, alreadyMoved: true)
        let afterReplace = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(afterReplace), path(logo), "the layer keeps the logo's name through the Replace")
        // ⌘Z of the Replace (FileChanges.swift:186-201).
        away = await store.awayIDs()
        let report = await journal.undo(entry.id)
        print("B14 undo moves: \(report.moves) skipped: \(report.skipped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logo.path), "the original logo is back")
        await store.movePaths(report.moves, awayBefore: away)
        let remap = PathMoves(report.moves.map { (path(URL(fileURLWithPath: $0.from)), path(URL(fileURLWithPath: $0.to))) })
        _ = RecipeStore.picturesFollow(&open) {
            RecipeStore.visible(remap.destination(of: URL(fileURLWithPath: $0).standardizedFileURL.path))
        }
        let undone = await store.recipe(for: photo)
        XCTAssertEqual(logoPath(undone), path(logo), "after ⌘Z of the Replace the store's layer names a hidden file in the Trash")
        XCTAssertEqual(logoPath(open), path(logo), "after ⌘Z of the Replace the window's layer names a hidden file in the Trash")
        // The window's next save keeps it so.
        let savedOrNil = await store.store(open)
        XCTAssertEqual(logoPath(savedOrNil), path(logo), "the next save keeps the hidden name")
    }
}

// MARK: Picture layers the system cannot draw

extension Audit2026Round14PhotoTests {
    /// Add Picture offers every image type (EditInspector.swift:319-321, `allowedContentTypes = [.image]`), SVG among them,
    /// the usual form of a logo. ImageIO opens an SVG but cannot draw it, so the layer is drawn as nothing on the canvas
    /// and in the export, the export succeeds, and nothing says why: `missingPictures` (EditModel.swift:778-783) and
    /// `PhotoExporter.rendered` (PhotoExporter.swift:28-32) only ask whether the file exists.
    func testB14AnSVGLogoIsDrawnOrSaid() throws {
        XCTAssertTrue(UTType.svg.conforms(to: .image), "Add Picture's panel offers SVG files")
        let photo = folder.appendingPathComponent("P.jpg"), logo = folder.appendingPathComponent("logo.svg")
        Self.write(Self.bitmap(200, 100), to: photo, type: .jpeg)
        try "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'><rect width='100' height='100' fill='blue'/></svg>"
            .write(to: logo, atomically: true, encoding: .utf8)
        var layer = Layer(kind: .image(path: logo.path))
        layer.width = 0.5
        layer.height = 0.5
        let overlay = try XCTUnwrap(LayerRenderer.image([layer], canvas: CGSize(width: 200, height: 100)))
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(overlay, in: CGRect(x: -100, y: -50, width: 200, height: 100))
        // EditModel.swift:778-783, copied: what the canvas says.
        let said = [layer].compactMap { layer -> String? in
            guard !layer.hidden, case let .image(path) = layer.kind, !FileManager.default.fileExists(atPath: path) else { return nil }
            return (path as NSString).lastPathComponent
        }
        var recipe = EditRecipe(source: EditSource(path: path(photo), kind: .image))
        recipe.layers = [layer]
        let exported = try? PhotoExporter.export(photo, recipe: recipe, to: folder.appendingPathComponent("P-edited.jpg"))
        XCTAssertTrue(px[3] > 0 || !said.isEmpty || exported == nil,
                      "the SVG logo is drawn as nothing (centre \(px)), nothing is said, and the export is written without it")
    }
}
