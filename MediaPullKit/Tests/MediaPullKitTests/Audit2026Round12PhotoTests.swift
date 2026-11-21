import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
@testable import MediaPullCore
@testable import MediaPullEdit
@testable import MediaPullLibrary
@testable import MediaPullMedia
import UniformTypeIdentifiers
import XCTest

/// Auditor B, round 12: Edit/Frame for photos.
final class Audit2026Round12PhotoTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("B12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static func bitmap(_ width: Int, _ height: Int, alpha: Bool = false, draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !alpha {
            c.setFillColor(red: 0.6, green: 0.4, blue: 0.3, alpha: 1)
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        draw(c)
        return c.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(d))
    }

    func recipe(_ url: URL) -> EditRecipe {
        EditRecipe(source: EditSource(path: url.standardizedFileURL.path, kind: .image))
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: 4)
        let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Top-left origin for x, y.
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }

    /// Everything a reader sees in a file's metadata: its properties and its XMP, as text.
    static func allMetadata(_ url: URL) -> String {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return "" }
        let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil).map { "\($0)" } ?? ""
        let xmp = CGImageSourceCopyMetadataAtIndex(s, 0, nil).flatMap { CGImageMetadataCreateXMPData($0, nil) }
            .map { String(decoding: $0 as Data, as: UTF8.self) } ?? ""
        return props + "\n" + xmp
    }
}

// MARK: Metadata left out as asked (R-4608)

extension Audit2026Round12PhotoTests {
    /// R-4608: "options to leave out the location". A photo whose place is written in its IPTC (the location shown and
    /// created, and the content location name, as photo apps and news agencies write them) keeps that place in an
    /// export with the location left out: only City, Sublocation, State and Country are removed.
    func testB12LocationLeftOutRemovesEveryPlaceInTheIPTC() throws {
        let original = folder.appendingPathComponent("placed.jpg")
        let shown: [CFString: Any] = [kCGImagePropertyIPTCExtLocationCity: "Porto",
                                      kCGImagePropertyIPTCExtLocationSublocation: "Ribeira Square"]
        let iptc: [CFString: Any] = [
            kCGImagePropertyIPTCCity: "Lisbon",
            kCGImagePropertyIPTCContentLocationName: "Alfama Viewpoint",
            kCGImagePropertyIPTCExtLocationShown: [shown],
            kCGImagePropertyIPTCExtLocationCreated: [kCGImagePropertyIPTCExtLocationCity: "Sintra"],
        ]
        Self.write(Self.bitmap(64, 48), to: original, type: .jpeg, properties: [
            kCGImagePropertyIPTCDictionary: iptc,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 38.71, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 9.13, kCGImagePropertyGPSLongitudeRef: "W"],
        ])
        let before = Self.allMetadata(original)
        for place in ["Lisbon", "Alfama Viewpoint"] {
            XCTAssertTrue(before.contains(place), "the source holds \(place)")
        }
        var made = recipe(original)
        made.adjust.exposure = 0.2
        made.export.keepLocation = false
        let out = folder.appendingPathComponent("placed-edited.jpg")
        _ = try PhotoExporter.export(original, recipe: made, to: out)
        let after = Self.allMetadata(out)
        XCTAssertFalse(after.contains("Lisbon"), "the city goes")
        XCTAssertFalse(after.contains("38.71"), "the coordinates go")
        for place in ["Alfama Viewpoint"] {
            XCTAssertFalse(after.contains(place), "with the location left out, “\(place)” is still in the export")
        }
    }

    /// R-4608: colour sRGB or Display P3. An sRGB photo (EXIF ColorSpace 1) exported in Display P3 keeps EXIF
    /// ColorSpace = 1 (sRGB) beside a Display P3 profile, so a reader that goes by the EXIF tag shows it in the wrong
    /// colours.
    func testB12DisplayP3ExportDoesNotSaySRGBInItsExif() throws {
        let original = folder.appendingPathComponent("srgb.jpg")
        Self.write(Self.bitmap(64, 48), to: original, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifColorSpace: 1,
                                             kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
        ])
        var made = recipe(original)
        made.export.displayP3 = true
        let out = folder.appendingPathComponent("srgb-edited.jpg")
        _ = try PhotoExporter.export(original, recipe: made, to: out)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let profile = image.colorSpace?.name as String? ?? props[kCGImagePropertyProfileName] as? String ?? "?"
        XCTAssertTrue(profile.contains("P3") || (props[kCGImagePropertyProfileName] as? String ?? "").contains("P3"),
                      "the export is in Display P3 (\(profile))")
        XCTAssertNotEqual(exif[kCGImagePropertyExifColorSpace] as? Int, 1,
                          "a Display P3 export says sRGB in its EXIF (ColorSpace 1)")
    }
}

// MARK: Canvas against export (D-128)

extension Audit2026Round12PhotoTests {
    /// D-128: what is shown is what is written. A transparent PNG (a logo, a sticker) set to export as JPEG, the default
    /// format, shows its transparent parts white on the canvas, as the JPEG writes them.
    func testB12TransparentPNGExportedAsJPEGIsAsShown() throws {
        let original = folder.appendingPathComponent("sticker.png")
        // Left half transparent, right half orange.
        let image = Self.bitmap(200, 100, alpha: true) { c in
            c.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
            c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        Self.write(image, to: original, type: .png)
        var made = recipe(original)
        made.adjust.contrast = 10
        // The canvas (EditModel.render → PhotoSession.preview).
        let session = try XCTUnwrap(PhotoSession(url: original))
        let preview = try XCTUnwrap(session.preview(made, fit: CGSize(width: 200, height: 100)))
        let shown = Self.pixel(preview, x: 20, y: 50)
        // The export (default JPEG).
        XCTAssertEqual(made.export.format, .jpeg)
        let out = folder.appendingPathComponent("sticker-edited.jpg")
        _ = try PhotoExporter.export(original, recipe: made, to: out)
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let px = Self.pixel(written, x: 20, y: 50)
        XCTAssertEqual(px, [255, 255, 255, 255], "the JPEG writes the transparent half white")
        XCTAssertEqual(shown, px, "the canvas shows see-through (\(shown)) what the JPEG export writes as \(px)")
    }
}

extension Audit2026Round12PhotoTests {
    /// The same with the place written as XMP (IPTC Extension LocationShown and Core Location), as photo apps write it.
    func testB12LocationLeftOutRemovesThePlaceWrittenAsXMP() throws {
        let original = folder.appendingPathComponent("xmpplace.jpg")
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(meta, "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/" as CFString,
                                                                "Iptc4xmpCore" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "Iptc4xmpCore:Location" as CFString, "Belem Tower" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "photoshop:City" as CFString, "Lisbon" as CFString))
        let d = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(d, Self.bitmap(64, 48), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        let before = Self.allMetadata(original)
        XCTAssertTrue(before.contains("Belem Tower"), before)
        var made = recipe(original)
        made.export.keepLocation = false
        let out = folder.appendingPathComponent("xmpplace-edited.jpg")
        _ = try PhotoExporter.export(original, recipe: made, to: out)
        let after = Self.allMetadata(out)
        XCTAssertFalse(after.contains("Lisbon"), "the city goes")
        XCTAssertFalse(after.contains("Belem Tower"), "the sublocation goes")
        print("B12 source props:", before)
    }
}

extension Audit2026Round12PhotoTests {
    /// D-128 "laid out in units of the canvas, so the export matches what was shown": a line's width as a share of the
    /// canvas, at a canvas of 800 px (the canvas pane) and 6000 px (a 24 MP export), for families with optical sizes.
    func testB12TextWidthIsTheSameShareOfTheCanvasAtEverySize() {
        let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        var families = ["Helvetica Neue", "NoSuchFamily-B12"]
        for candidate in ["New York", "SF Pro", "Skia", "Avenir Next", "Times New Roman",
                          "Bradley Hand"] where installed.contains(candidate) {
            families.append(candidate)
        }
        for family in families {
            var style = TextStyle(text: "Music by Someone   Produced by Someone   Written by Someone")
            style.family = family
            style.size = 0.009
            func share(_ height: CGFloat) -> Double {
                let line = CTLineCreateWithAttributedString(LayerRenderer.attributed(style, canvasHeight: height))
                return CTLineGetTypographicBounds(line, nil, nil, nil) / Double(height)
            }
            let small = share(800), large = share(6000)
            print("B12 text \(family): \(small) at 800 px, \(large) at 6000 px, \(String(format: "%.1f", (large / small - 1) * 100)) %")
            XCTAssertEqual(small, large, accuracy: small * 0.01,
                           "\(family): the line is \(String(format: "%.1f", (large / small - 1) * 100)) % wider in the export")
        }
    }
}

extension Audit2026Round12PhotoTests {
    /// The suggested fix: the optical size fixed (here to what a 1080 px canvas would use), not left to the point size.
    func testB12FixedOpticalSizeKeepsTheShare() {
        let base = CTFontCreateUIFontForLanguage(.system, 100, nil)!
        func share(_ height: CGFloat) -> Double {
            let cap = CTFontGetCapHeight(base)
            let point = 0.009 * height * 100 / cap
            let reference = 0.009 * 1080 * 100 / cap
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute: reference] as CFDictionary)
            let font = CTFontCreateCopyWithAttributes(base, point, nil, descriptor)
            let text = NSAttributedString(string: "Music by Someone   Produced by Someone   Written by Someone",
                                          attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil) / Double(height)
        }
        let small = share(800), large = share(6000)
        print("B12 fixed opsz: \(small) / \(large)")
        XCTAssertEqual(small, large, accuracy: small * 0.01)
    }
}

extension Audit2026Round12PhotoTests {
    /// R-4607: every family the font list offers as installed is drawn in its own face, never said missing; and every
    /// face the Style picker offers for it is found.
    func testB12EveryListedFamilyAndFaceIsFound() {
        var missingFamilies: [String] = []
        var missingFaces: [String] = []
        for family in FontCatalog.families() where family.installed {
            var style = TextStyle(text: "Aa")
            style.family = family.name
            if LayerRenderer.font(style, canvasHeight: 100).missing { missingFamilies.append(family.name) }
            for face in FontCatalog.faces(of: family.name) {
                style.face = face
                if LayerRenderer.font(style, canvasHeight: 100).missing { missingFaces.append("\(family.name) \(face)") }
            }
        }
        print("B12 families said missing: \(missingFamilies.count) \(missingFamilies.prefix(20))")
        print("B12 faces said missing: \(missingFaces.count) \(missingFaces.prefix(40))")
        XCTAssertTrue(missingFamilies.isEmpty, "listed families drawn with the system font: \(missingFamilies.prefix(10))")
        XCTAssertTrue(missingFaces.isEmpty, "listed faces said missing: \(missingFaces.prefix(10))")
    }
}

extension Audit2026Round12PhotoTests {
    /// R-4604: a Square, 4:5 or 9:16 crop exports in that shape. EditModel.setAspect (EditModel.swift:539) measures the
    /// picture from the crop view's bitmap (`cropRatio`, EditModel.swift:533, rounded to the canvas's pixels), so the
    /// crop is made for a slightly different shape than the photo's.
    func testB12SquareCropExportsSquare() throws {
        let original = folder.appendingPathComponent("wide.jpg")
        Self.write(Self.bitmap(4000, 3000), to: original, type: .jpeg)
        let session = try XCTUnwrap(PhotoSession(url: original))
        var bad: [String] = []
        for straighten in [0.0, 7.0] {
            for canvas in [CGSize(width: 900, height: 700), CGSize(width: 913, height: 611), CGSize(width: 1201, height: 777),
                           CGSize(width: 640, height: 517), CGSize(width: 1500, height: 860)]
            {
                for (aspect, wanted) in [(EditAspect.square, 1.0), (.portrait45, 0.8), (.portrait916, 9.0 / 16)] {
                    var made = recipe(original)
                    made.geometry.straighten = straighten
                    // EditModel.render: fit = canvas points × 2, at most the proxy's edge.
                    let fit = CGSize(width: min(canvas.width * 2, PhotoSession.proxyEdge), height: min(canvas.height * 2,
                                                                                                       PhotoSession.proxyEdge))
                    let crop = try XCTUnwrap(session.uncropped(made, fit: fit))
                    let ratio = Double(crop.width) / Double(crop.height)
                    made.geometry.aspect = aspect
                    made.geometry.crop = UnitRect.centred(ratio: wanted, in: CGSize(width: ratio, height: 1))
                    let out = try PhotoExporter.rendered(original, recipe: made)
                    let got = Double(out.width) / Double(out.height)
                    let exact = (Double(out.height) * wanted).rounded() == Double(out.width)
                        || (Double(out.width) / wanted).rounded() == Double(out.height)
                    if !exact {
                        bad.append("\(aspect.label) at \(Int(canvas.width))×\(Int(canvas.height)), straighten \(straighten): "
                            + "\(out.width)×\(out.height) (\(got))")
                    }
                }
            }
        }
        print("B12 crops not in their shape: \(bad.count)\n" + bad.joined(separator: "\n"))
        XCTAssertTrue(bad.isEmpty, "\(bad.count) crops are not in their shape, e.g. \(bad.first ?? "")")
    }
}

extension Audit2026Round12PhotoTests {
    /// R-4608 with R-4604: a 4:5 crop exported as "Post (fits 1080 × 1350)" from the canvas as it opens (900 × 700 pt,
    /// Retina) is 1080 × 1349, and a Square crop as "Square Post" from a canvas of 913 × 611 pt is 1080 × 1079.
    func testB12FourByFivePostIs1080By1350() throws {
        let original = folder.appendingPathComponent("post.jpg")
        Self.write(Self.bitmap(4000, 3000), to: original, type: .jpeg)
        let session = try XCTUnwrap(PhotoSession(url: original))
        func exported(_ aspect: EditAspect, _ wanted: Double, _ size: ExportSettings.Size, canvas: CGSize) throws -> CGSize {
            var made = recipe(original)
            let crop = try XCTUnwrap(session.uncropped(made, fit: CGSize(width: canvas.width * 2, height: canvas.height * 2)))
            let ratio = Double(crop.width) / Double(crop.height)
            made.geometry.aspect = aspect
            made.geometry.crop = UnitRect.centred(ratio: wanted, in: CGSize(width: ratio, height: 1))
            made.export.size = size
            let out = folder.appendingPathComponent("post-\(UUID().uuidString).jpg")
            return try PhotoExporter.export(original, recipe: made, to: out)
        }
        XCTAssertEqual(try exported(.portrait45, 0.8, .post45, canvas: CGSize(width: 900, height: 700)), CGSize(width: 1080, height: 1350))
        XCTAssertEqual(try exported(.square, 1, .square, canvas: CGSize(width: 913, height: 611)), CGSize(width: 1080, height: 1080))
    }
}

// MARK: Picture layers of the open recipe (R-4602, R-4606)

extension Audit2026Round12PhotoTests {
    /// EditModel.followMoves as written since round 12: the open recipe's file and its pictures follow the moves.
    func windowFollowMoves(_ recipe: inout EditRecipe, current: inout URL, _ moves: [(from: String, to: String)]) {
        let remap = PathMoves(moves.map {
            (URL(fileURLWithPath: $0.from).standardizedFileURL.path, URL(fileURLWithPath: $0.to).standardizedFileURL.path)
        })
        if let moved = remap.destination(of: current.standardizedFileURL.path) {
            current = URL(fileURLWithPath: moved)
            recipe.source.path = moved
            recipe.source.created = RecipeStore.created(moved) ?? recipe.source.created
            recipe.source.reference = RecipeStore.reference(moved) ?? recipe.source.reference
        }
        _ = RecipeStore.picturesFollow(&recipe) { remap.destination(of: URL(fileURLWithPath: $0).standardizedFileURL.path) }
    }

    /// A photo with a logo layer is open in Edit/Frame; the logo is renamed (or its folder sorted) in the Library or
    /// Organise. The store moves the layer to the logo's new name (B1-15), but the window keeps the old one: the canvas
    /// says the logo is gone, Export is refused, and the window's next save (any slider) writes the old name over the
    /// store's, so the recipe loses its logo for good.
    func testB12OpenRecipesPictureLayerFollowsAMovedLogo() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg"), logo = folder.appendingPathComponent("logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16), to: logo, type: .png)
        // Opened (EditModel.newRecipe), a logo added, saved.
        var open = EditRecipe(source: EditSource(path: photo.standardizedFileURL.path, reference: RecipeStore.reference(photo.path),
                                                 created: RecipeStore.created(photo.path), kind: .image))
        var layer = Layer(kind: .image(path: logo.path))
        layer.x = 0.8
        open.layers = [layer]
        let first = await store.store(open)
        let kept = try XCTUnwrap(first)
        open.id = kept.id
        open.source = kept.source
        var current = photo
        // The Library renames the logo (FileChanges.followMoves: the store first, then each window).
        let renamed = folder.appendingPathComponent("logo-white.png")
        try FileManager.default.moveItem(at: logo, to: renamed)
        let away = await store.awayIDs()
        await store.movePaths([(logo.path, renamed.path)], awayBefore: away)
        windowFollowMoves(&open, current: &current, [(logo.path, renamed.path)])
        let stored = await store.recipe(for: photo)
        XCTAssertEqual(stored?.layers.first?.kind, .image(path: renamed.standardizedFileURL.path), "the store follows the logo")
        // What the canvas checks on its next render (FontLookup.missingPictures).
        let missing = open.layers.compactMap { layer -> String? in
            guard case let .image(path) = layer.kind, !FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        }
        XCTAssertTrue(missing.isEmpty, "the open window says its logo is no longer there: \(missing)")
        // A slider moved: the window's save (scheduleSave → store) keeps the window's layers.
        open.adjust.exposure = 0.3
        _ = await store.store(open)
        let after = await store.recipe(for: photo)
        XCTAssertEqual(after?.layers.first?.kind, .image(path: renamed.standardizedFileURL.path),
                       "the window's save wrote the logo's old name over the store's")
    }
}

extension Audit2026Round12PhotoTests {
    /// R-4602 with R-4610: an audio recipe's artwork picture (chosen from the library) does not follow a move MediaPull
    /// makes, as picture layers do (RecipeStore.movePaths), so the export then fails on a picture that is not there.
    func testB12AudioArtworkFollowsAMovedPicture() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let song = folder.appendingPathComponent("song.m4a"), cover = folder.appendingPathComponent("cover.jpg")
        try Data("audio".utf8).write(to: song)
        Self.write(Self.bitmap(16, 16), to: cover, type: .jpeg)
        var recipe = EditRecipe(source: EditSource(path: song.standardizedFileURL.path, reference: RecipeStore.reference(song.path),
                                                   created: RecipeStore.created(song.path), kind: .audio))
        var tags = AudioTagEdit()
        tags.artworkPath = cover.path
        recipe.tags = tags
        _ = await store.store(recipe)
        let moved = folder.appendingPathComponent("Covers/cover.jpg")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: cover, to: moved)
        await store.movePaths([(cover.path, moved.path)])
        let after = await store.recipe(for: song)
        XCTAssertEqual(after?.tags?.artworkPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }, moved.standardizedFileURL.path,
                       "the artwork still names the picture's old place")
    }
}
