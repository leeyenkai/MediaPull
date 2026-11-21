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

/// Auditor B, round 13: Edit/Frame for photos.
final class Audit2026Round13PhotoTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("B13-\(UUID().uuidString)")
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
        c.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return px
    }
}

// MARK: Export size (R-4608)

extension Audit2026Round13PhotoTests {
    /// R-4608: "long edge 1080, 2048 or 4096 px". A 3000 × 2001 picture (a free crop, a frame) exported at Long Edge
    /// 1080 px is 1079 px on its long edge: `ExportSettings.Size.pixels` rounds the short side down to 720, and
    /// `PhotoRenderer.scaled` then scales again to fit that rounded box, rounding the long side down.
    func testB13LongEdge1080Is1080() throws {
        let original = folder.appendingPathComponent("wide.jpg")
        Self.write(Self.bitmap(3000, 2001), to: original, type: .jpeg)
        var made = recipe(original)
        made.export.size = .long1080
        let out = folder.appendingPathComponent("wide-edited.jpg")
        let size = try PhotoExporter.export(original, recipe: made, to: out)
        XCTAssertEqual(size, made.export.size.pixels(for: CGSize(width: 3000, height: 2001)), "the size the setting asks for")
        XCTAssertEqual(size.width, 1080, "the long edge of a Long Edge 1080 px export is \(size.width) px")
    }

    /// The same for every size setting over many picture sizes (free crops and frames give any size): how often the
    /// export is not the size `pixels(for:)` asks for. Measured without writing files, with the renderer's own scale.
    func testB13EverySizeSettingGivesTheSizeItAsks() {
        var wrong: [String] = []
        var checked = 0
        for width in stride(from: 1201, through: 4801, by: 97) {
            for height in stride(from: 1003, through: 5003, by: 89) {
                let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
                for setting in ExportSettings.Size.allCases where setting != .original {
                    let target = setting.pixels(for: input.extent.size)
                    // As PhotoExporter fits it since B13-m1: to the setting's own box.
                    let got = PhotoRenderer.scaled(input, toFit: setting.box ?? target).extent.size
                    checked += 1
                    if got != target { wrong.append("\(width)×\(height) \(setting.rawValue): \(got) for \(target)") }
                }
            }
        }
        print("B13 sizes not as asked: \(wrong.count) of \(checked)\n" + wrong.prefix(12).joined(separator: "\n"))
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) of \(checked) exports are not the size asked, e.g. \(wrong.first ?? "")")
    }
}

// MARK: pixelCrop (B12-m2)

extension Audit2026Round13PhotoTests {
    /// Round 12's crop: never outside the picture, a fixed shape exact (to a pixel's rounding), at least one pixel, through
    /// straighten and quarter turns, and for tiny pictures.
    func testB13PixelCropStaysInsideAndKeepsItsShape() {
        var bad: [String] = []
        var generator = SystemRandomNumberGenerator()
        let sizes = [CGSize(width: 1, height: 1), CGSize(width: 2, height: 3), CGSize(width: 3, height: 2), CGSize(width: 7, height: 5),
                     CGSize(width: 64, height: 48), CGSize(width: 4000, height: 3000), CGSize(width: 3024, height: 4032),
                     CGSize(width: 10000, height: 17)]
        for size in sizes {
            for aspect in EditAspect.allCases {
                for _ in 0 ..< 60 {
                    let w = Double.random(in: 0.0 ... 1.2, using: &generator), h = Double.random(in: 0.0 ... 1.2, using: &generator)
                    let crop = UnitRect(x: Double.random(in: -0.2 ... 1.2, using: &generator), y: Double.random(in: -0.2 ... 1.2,
                                                                                                                using: &generator),
                                        width: w, height: h).clamped
                    let ratio = aspect.ratio(original: Double(size.width / size.height))
                    let rect = PhotoRenderer.pixelCrop(crop, in: size, ratio: ratio)
                    if rect.minX < 0 || rect.minY < 0 || rect.maxX > size.width || rect.maxY > size.height || rect.width < 1
                        || rect.height < 1 || rect != rect.integral
                    {
                        bad.append("\(size) \(aspect) \(crop): \(rect) outside or not whole")
                    }
                    if let ratio, size.width >= 64, size.height >= 64, crop.width * size.width >= 32, crop.height * size.height >= 32 {
                        let exact = (rect.height * ratio).rounded() == rect.width || (rect.width / ratio).rounded() == rect.height
                        if !exact { bad.append("\(size) \(aspect) \(crop): \(rect) not \(ratio)") }
                    }
                }
            }
        }
        print("B13 pixel crops: \(bad.count) bad\n" + bad.prefix(10).joined(separator: "\n"))
        XCTAssertTrue(bad.isEmpty, bad.first ?? "")
    }

    /// Through the whole geometry: turns, flips, straighten and a crop, the picture is never empty and never reaches past
    /// what was there (no clear pixels at the edges).
    func testB13GeometryWithTurnsStraightenAndCropIsInsideThePicture() throws {
        var bad: [String] = []
        let input = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 301, height: 199))
        for turns in 0 ..< 4 {
            for straighten in [-45.0, -12.5, 0, 3, 44.9] {
                for aspect in [EditAspect.free, .original, .square, .portrait45, .landscape169, .portrait916] {
                    var geometry = EditGeometry()
                    geometry.quarterTurns = turns
                    geometry.straighten = straighten
                    geometry.aspect = aspect
                    let turned = geometry.turnedSize(input.extent.size)
                    geometry.crop = aspect.ratio(original: turned.width / turned.height).map {
                        UnitRect.centred(ratio: $0, in: CGSize(width: turned.width / turned.height, height: 1))
                    } ?? UnitRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3)
                    let out = PhotoRenderer.geometry(input, geometry)
                    let image = try XCTUnwrap(PhotoRenderer.cgImage(out, exact: true))
                    if image.width < 1 || image.height < 1 { bad.append("\(turns) \(straighten) \(aspect): empty") }
                    for (x, y) in [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)] {
                        let px = Self.pixel(image, x: x, y: y)
                        if px[3] < 250 { bad.append("\(turns) \(straighten) \(aspect): corner \(x),\(y) is \(px)") }
                    }
                }
            }
        }
        print("B13 geometry: \(bad.count) bad\n" + bad.prefix(10).joined(separator: "\n"))
        XCTAssertTrue(bad.isEmpty, bad.first ?? "")
    }
}

// MARK: Metadata kept (R-4608)

extension Audit2026Round13PhotoTests {
    /// R-4608 "metadata kept": a JPEG rated and given keywords by MediaPull's own metadata edit (section 45, written in
    /// place as XMP, D-125) keeps its rating and keywords in an Edit/Frame export.
    func testB13ExportKeepsTheRatingAndKeywordsMediaPullWrote() throws {
        let photo = folder.appendingPathComponent("rated.jpg")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
        ])
        let staged = folder.appendingPathComponent("rated-staged.jpg")
        let values = MetadataValues(fields: [.rating, .keywords], rating: 4, keywords: ["harbour", "dusk"])
        try MetadataWriter.writeCopy(of: photo, setting: values, to: staged)
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.moveItem(at: staged, to: photo)
        let read = MetadataWriter.values(of: photo)
        XCTAssertEqual(read.rating, 4, "written")
        XCTAssertEqual(read.keywords, ["harbour", "dusk"], "written")
        var made = recipe(photo)
        made.adjust.exposure = 0.2
        let out = folder.appendingPathComponent("rated-edited.jpg")
        _ = try PhotoExporter.export(photo, recipe: made, to: out)
        let exported = MetadataWriter.values(of: out)
        XCTAssertEqual(exported.rating, 4, "the export lost the rating")
        XCTAssertEqual(exported.keywords, ["harbour", "dusk"], "the export lost the keywords")
    }

    /// The same for a date and a place MediaPull wrote in place, and a place removed in place stays removed.
    func testB13ExportKeepsTheDateAndPlaceMediaPullWrote() throws {
        let photo = folder.appendingPathComponent("placed.jpg")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg, properties: [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
        ])
        let staged = folder.appendingPathComponent("placed-staged.jpg")
        let values = MetadataValues(fields: [.taken, .location], taken: TakenDate(original: "2021:06:07 08:09:10",
                                                                                  originalOffset: "+02:00"),
                                    latitude: 41.15, longitude: -8.61)
        try MetadataWriter.writeCopy(of: photo, setting: values, to: staged)
        try FileManager.default.removeItem(at: photo)
        try FileManager.default.moveItem(at: staged, to: photo)
        var made = recipe(photo)
        made.adjust.exposure = 0.2
        let out = folder.appendingPathComponent("placed-edited.jpg")
        _ = try PhotoExporter.export(photo, recipe: made, to: out)
        let exported = MetadataWriter.values(of: out)
        XCTAssertEqual(exported.taken?.original, "2021:06:07 08:09:10", "the export's date")
        XCTAssertEqual(exported.latitude ?? 0, 41.15, accuracy: 0.001, "the export's place")
        made.export.keepLocation = false
        let without = folder.appendingPathComponent("placed-noloc.jpg")
        _ = try PhotoExporter.export(photo, recipe: made, to: without)
        XCTAssertNil(MetadataWriter.values(of: without).latitude, "the place left out")
    }

    /// A title and caption a photo app wrote as XMP only (dc:title, dc:description), and the creator.
    func testB13ExportKeepsTheCaptionWrittenAsXMP() throws {
        let photo = folder.appendingPathComponent("caption.jpg")
        let meta = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "dc:description" as CFString, "Boats at dusk" as CFString))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "dc:creator" as CFString, ["A. Person"] as CFArray))
        let d = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(d, Self.bitmap(64, 48), meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(d))
        var made = recipe(photo)
        made.adjust.exposure = 0.2
        let out = folder.appendingPathComponent("caption-edited.jpg")
        _ = try PhotoExporter.export(photo, recipe: made, to: out)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateXMPData($0, nil) }
            .map { String(decoding: $0 as Data, as: UTF8.self) } ?? ""
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil).map { "\($0)" } ?? ""
        XCTAssertTrue((xmp + props).contains("Boats at dusk"), "the caption is lost")
        XCTAssertTrue((xmp + props).contains("A. Person"), "the creator is lost")
    }
}

// MARK: Fonts after the fixed optical size (B12-m3)

extension Audit2026Round13PhotoTests {
    /// The optical size added in round 12 must not change the face drawn: every listed face of every installed family is
    /// drawn in the same font (PostScript name, weight and width) with and without it.
    func testB13FixedOpticalSizeKeepsEveryFace() {
        var changed: [String] = []
        var checked = 0
        for family in FontCatalog.families() where family.installed {
            for face in FontCatalog.faces(of: family.name) {
                var style = TextStyle(text: "Aa")
                style.family = family.name
                style.face = face
                let fixed = LayerRenderer.font(style, canvasHeight: 2000).font
                var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family.name, kCTFontStyleNameAttribute: face]
                attributes[kCTFontSizeAttribute] = CTFontGetSize(fixed)
                let plain = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary),
                                                           CTFontGetSize(fixed), nil)
                checked += 1
                let a = CTFontCopyPostScriptName(fixed) as String, b = CTFontCopyPostScriptName(plain) as String
                func weight(_ font: CTFont) -> Double {
                    let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
                    return (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
                }
                func variations(_ font: CTFont) -> [String: Double] {
                    var out: [String: Double] = [:]
                    for (k, v) in (CTFontCopyVariation(font) as? [NSNumber: NSNumber]) ?? [:] {
                        let tag = k.uint32Value
                        let name = String(bytes: [UInt8(tag >> 24 & 0xFF), UInt8(tag >> 16 & 0xFF), UInt8(tag >> 8 & 0xFF),
                                                  UInt8(tag & 0xFF)],
                                          encoding: .ascii) ?? "\(tag)"
                        if name != "opsz" { out[name] = v.doubleValue }
                    }
                    return out
                }
                if a != b || abs(weight(fixed) - weight(plain)) > 0.01 || variations(fixed) != variations(plain) {
                    changed.append("\(family.name) \(face): \(b) \(weight(plain)) \(variations(plain)) drawn as \(a) "
                        + "\(weight(fixed)) \(variations(fixed))")
                }
            }
        }
        print("B13 faces changed by the optical size: \(changed.count) of \(checked)\n" + changed.prefix(30).joined(separator: "\n"))
        XCTAssertTrue(changed.isEmpty, "\(changed.count) of \(checked) faces are drawn in another font, e.g. \(changed.first ?? "")")
    }

    /// Fonts without optical sizes (no opsz axis, no trak table) are drawn exactly as before round 12.
    func testB13FontsWithoutOpticalSizesAreUnchanged() {
        var changed: [String] = []
        let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        for family in ["Georgia", "Times New Roman", "Courier New", "Verdana", "Arial", "Menlo", "Bradley Hand", "Futura"]
            where installed.contains(family)
        {
            var style = TextStyle(text: "Music by Someone   Produced by Someone")
            style.family = family
            for height in [800.0, 6000.0] {
                let fixed = LayerRenderer.font(style, canvasHeight: height).font
                let plain = CTFontCreateCopyWithAttributes(fixed, CTFontGetSize(fixed), nil, nil)
                let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
                let base = CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(fixed), nil)
                func width(_ font: CTFont) -> Double {
                    let text = NSAttributedString(string: style.text,
                                                  attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                    return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
                }
                _ = plain
                if abs(width(fixed) - width(base)) > 0.001 * width(base) {
                    changed.append("\(family) at \(height): \(width(base)) before, \(width(fixed)) now")
                }
            }
        }
        print("B13 fonts without optical sizes changed: \(changed)")
        XCTAssertTrue(changed.isEmpty, changed.first ?? "")
    }

    /// Canvas against export with text, whole: the layer bitmap at the canvas's size and at a 6000 px export's, the export
    /// scaled down to the canvas, ink in the same columns (a line wrapping at another word would move ink a lot).
    func testB13TextLayerOnCanvasAndExportCoversTheSameColumns() throws {
        let installed = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        var bad: [String] = []
        for (family, face) in [("Helvetica Neue", nil), ("SF Pro", "Bold"), ("New York", "Heavy"), ("Avenir Next", "Demi Bold"),
                               ("Georgia", nil), ("NoSuchFamily-B13", nil)] as [(String, String?)]
            where installed.contains(family) || family.hasPrefix("NoSuch")
        {
            var style = TextStyle(text: "Produced and written by Someone, recorded in a small room by the sea")
            style.family = family
            style.face = face
            style.size = 0.03
            var layer = Layer(kind: .text(style))
            layer.width = 0.62
            layer.height = 0.2
            func columns(_ size: CGSize, down: CGSize) throws -> [Int] {
                let image = try XCTUnwrap(LayerRenderer.image([layer], canvas: size))
                let small = PhotoRenderer.scaled(CIImage(cgImage: image), toFit: down)
                let bitmap = try XCTUnwrap(PhotoRenderer.cgImage(small, exact: true))
                // Ink per row band: the last inked row tells the line count.
                var rows: [Int] = []
                for y in stride(from: 0, to: bitmap.height, by: 1) {
                    var ink = 0
                    for x in stride(from: 0, to: bitmap.width, by: 3) where Self.pixel(bitmap, x: x, y: y)[3] > 60 {
                        ink += 1
                    }
                    rows.append(ink)
                }
                return rows
            }
            let canvas = CGSize(width: 900, height: 600)
            let a = try columns(canvas, down: canvas)
            let b = try columns(CGSize(width: 6000, height: 4000), down: canvas)
            let lastA = a.lastIndex { $0 > 0 } ?? 0, lastB = b.lastIndex { $0 > 0 } ?? 0
            if abs(lastA - lastB) > 3 {
                bad.append("\(family) \(face ?? ""): text ends at row \(lastA) on the canvas, \(lastB) in the export")
            }
        }
        print("B13 text canvas/export: \(bad)")
        XCTAssertTrue(bad.isEmpty, bad.first ?? "")
    }
}

// MARK: Pictures follow (B12-1, B12-m5)

extension Audit2026Round13PhotoTests {
    /// A logo whose folder MediaPull moves or renames is followed too, in the store and in the window's rule.
    func testB13PictureLayerFollowsAMovedFolder() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg")
        let logos = folder.appendingPathComponent("Logos", isDirectory: true)
        try FileManager.default.createDirectory(at: logos, withIntermediateDirectories: true)
        let logo = logos.appendingPathComponent("logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16), to: logo, type: .png)
        var open = EditRecipe(source: EditSource(path: photo.standardizedFileURL.path, kind: .image))
        open.layers = [Layer(kind: .image(path: logo.path))]
        _ = await store.store(open)
        let renamed = folder.appendingPathComponent("Brand", isDirectory: true)
        try FileManager.default.moveItem(at: logos, to: renamed)
        await store.movePaths([(logos.path, renamed.path)])
        let stored = await store.recipe(for: photo)
        XCTAssertEqual(stored?.layers.first?.kind, .image(path: renamed.appendingPathComponent("logo.png").standardizedFileURL.path))
        let remap = PathMoves([(logos.standardizedFileURL.path, renamed.standardizedFileURL.path)])
        XCTAssertTrue(RecipeStore.picturesFollow(&open) { remap.destination(of: URL(fileURLWithPath: $0).standardizedFileURL.path) })
        XCTAssertEqual(open.layers.first?.kind, .image(path: renamed.appendingPathComponent("logo.png").standardizedFileURL.path))
    }
}

// MARK: JPEG canvas (B12-m4)

extension Audit2026Round13PhotoTests {
    /// The canvas and the export agree for every format: a transparent PNG as PNG and HEIC keeps see-through parts (the
    /// canvas shows them clear), as JPEG both are white; Display P3 too.
    func testB13TransparentPNGCanvasMatchesEveryFormat() throws {
        let original = folder.appendingPathComponent("sticker.png")
        let image = Self.bitmap(200, 100, alpha: true) { c in
            c.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
            c.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        Self.write(image, to: original, type: .png)
        let session = try XCTUnwrap(PhotoSession(url: original))
        var bad: [String] = []
        for format in ExportSettings.PhotoFormat.allCases {
            for p3 in [false, true] {
                var made = recipe(original)
                made.adjust.contrast = 10
                made.export.format = format
                made.export.displayP3 = p3
                let preview = try XCTUnwrap(session.preview(made, fit: CGSize(width: 200, height: 100)))
                let out = folder.appendingPathComponent("s-\(format.rawValue)-\(p3).\(format.fileExtension)")
                _ = try PhotoExporter.export(original, recipe: made, to: out)
                let written = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
                let shown = Self.pixel(preview, x: 20, y: 50), px = Self.pixel(written, x: 20, y: 50)
                if zip(shown, px).contains(where: { abs(Int($0) - Int($1)) > 3 }) {
                    bad.append("\(format) P3 \(p3): canvas \(shown), export \(px)")
                }
            }
        }
        print("B13 transparent canvas/export: \(bad)")
        XCTAssertTrue(bad.isEmpty, bad.first ?? "")
    }
}

// MARK: Canvas against export, each tool (D-128)

extension Audit2026Round13PhotoTests {
    static func detailed(_ width: Int, _ height: Int) -> CGImage {
        bitmap(width, height) { c in
            let colors = [CGColor(srgbRed: 0.1, green: 0.2, blue: 0.7, alpha: 1), CGColor(srgbRed: 0.95, green: 0.8, blue: 0.3, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
            c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            c.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            c.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 3, height: height / 3))
            c.setFillColor(CGColor(gray: 0.98, alpha: 1))
            c.fill(CGRect(x: width * 2 / 3, y: height / 2, width: width / 5, height: height / 6))
        }
    }

    /// Mean difference (0 to 255) between two bitmaps drawn at the same size, and the largest mean over a 10 × 10 grid.
    static func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, worst: Double) {
        let w = min(a.width, b.width), h = min(a.height, b.height)
        func pixels(_ image: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let c = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        let pa = pixels(a), pb = pixels(b)
        var total = 0.0
        var cells = [Double](repeating: 0, count: 100), counts = [Double](repeating: 0, count: 100)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 4
                var d = 0.0
                for k in 0 ..< 3 { d += abs(Double(pa[i + k]) - Double(pb[i + k])) }
                d /= 3
                total += d
                let cell = min(9, y * 10 / h) * 10 + min(9, x * 10 / w)
                cells[cell] += d
                counts[cell] += 1
            }
        }
        let worst = zip(cells, counts).map { $1 > 0 ? $0 / $1 : 0 }.max() ?? 0
        return (total / Double(w * h), worst)
    }

    func testB13CanvasMatchesExportForEachTool() throws {
        let original = folder.appendingPathComponent("big.jpg")
        Self.write(Self.detailed(6000, 4000), to: original, type: .jpeg)
        let session = try XCTUnwrap(PhotoSession(url: original))
        var cases: [(String, (inout EditRecipe) -> Void)] = []
        for key in Adjustments.Key.allCases {
            cases.append((key.rawValue, { $0.adjust[key] = key.range.upperBound * 0.8 }))
        }
        for look in LookName.allCases {
            cases.append(("look \(look.rawValue)", { $0.look = Look(name: look, amount: 0.7) }))
        }
        cases.append(("blurred frame, round, shadow", { r in
            var f = Frame()
            f.shape = .portrait45
            f.background = .blurredPhoto
            f.cornerRadius = 0.08
            f.shadow = true
            r.frame = f
        }))
        cases.append(("text and shape", { r in
            var style = TextStyle(text: "Harbour at dusk, a long caption that wraps onto two lines")
            style.size = 0.04
            style.shadow = true
            style.outline = .black
            var text = Layer(kind: .text(style))
            text.width = 0.5
            text.height = 0.2
            text.rotation = 8
            var shape = Layer(kind: .shape(LayerShape(kind: .ellipse)))
            shape.x = 0.2
            shape.y = 0.8
            r.layers = [text, shape]
        }))
        cases.append(("straighten and crop", { r in
            r.geometry.straighten = 9
            r.geometry.quarterTurns = 1
            r.geometry.crop = UnitRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)
        }))
        var report: [String] = []
        var bad: [String] = []
        for (name, apply) in cases {
            var made = recipe(original)
            apply(&made)
            let shown = try XCTUnwrap(session.preview(made, fit: CGSize(width: 1800, height: 1400)))
            let written = try PhotoExporter.rendered(original, recipe: made)
            let small = try XCTUnwrap(PhotoRenderer.cgImage(PhotoRenderer.scaled(CIImage(cgImage: written),
                                                                                 toFit: CGSize(width: shown.width, height: shown.height))))
            let d = Self.difference(shown, small)
            report.append("\(name): \(shown.width)×\(shown.height) vs \(written.width)×\(written.height), "
                + "mean \(String(format: "%.2f", d.mean)) worst \(String(format: "%.2f", d.worst))")
            if d.worst > 6 { bad.append(report.last!) }
        }
        print("B13 canvas vs export:\n" + report.joined(separator: "\n"))
        XCTAssertTrue(bad.isEmpty, "canvas and export differ: \(bad)")
    }
}

// MARK: ⌘Z after a picture moved (R-4602, D-128)

extension Audit2026Round13PhotoTests {
    /// EditModel.followMoves (EditModel.swift:365-410), the picture part, as written.
    func windowFollowMoves(_ recipe: inout EditRecipe, _ moves: [(from: String, to: String)]) {
        let remap = PathMoves(moves.map {
            (URL(fileURLWithPath: $0.from).standardizedFileURL.path, URL(fileURLWithPath: $0.to).standardizedFileURL.path)
        })
        _ = RecipeStore.picturesFollow(&recipe) { remap.destination(of: URL(fileURLWithPath: $0).standardizedFileURL.path) }
    }

    /// EditModel.restore (EditModel.swift:306-321) for the open recipe: the edits of the change come back, the source
    /// stays the window's.
    func windowRestore(_ previous: EditRecipe, open: inout EditRecipe) {
        var restored = previous
        restored.source = open.source
        open = restored
    }

    /// A photo with a logo layer is open in Edit/Frame in one window; a slider change was made (⌘Z holds the recipe from
    /// before it, logo and all). In a second window the logo is renamed in the Library (or an automatic sort moves it).
    /// Both the store and the open recipe follow the logo (B12-1). ⌘Z of the slider change then puts back the recipe as
    /// it was, with the logo's old name, and saves it: the canvas says the logo is gone, Export is refused, and ⇧⌘Z
    /// brings back the old name too, so the layer has lost its picture for good.
    func testB13UndoAfterALogoMovedKeepsTheLogo() async throws {
        let store = RecipeStore(folder: folder.appendingPathComponent("edits"))
        let photo = folder.appendingPathComponent("P.jpg"), logo = folder.appendingPathComponent("logo.png")
        Self.write(Self.bitmap(64, 48), to: photo, type: .jpeg)
        Self.write(Self.bitmap(16, 16), to: logo, type: .png)
        var open = EditRecipe(source: EditSource(path: photo.standardizedFileURL.path, reference: RecipeStore.reference(photo.path),
                                                 created: RecipeStore.created(photo.path), kind: .image))
        open.layers = [Layer(kind: .image(path: logo.path))]
        let first = await store.store(open)
        let kept = try XCTUnwrap(first)
        open.id = kept.id
        open.source = kept.source
        // A slider change: registerUndo(before) keeps the recipe from before it (EditModel.swift:271-279).
        let before = open
        open.adjust.exposure = 0.4
        let after = open
        _ = await store.store(open)
        // The second window renames the logo (FileChanges.followMoves: the store, then every window).
        let renamed = folder.appendingPathComponent("logo-white.png")
        try FileManager.default.moveItem(at: logo, to: renamed)
        let away = await store.awayIDs()
        await store.movePaths([(logo.path, renamed.path)], awayBefore: away)
        windowFollowMoves(&open, [(logo.path, renamed.path)])
        XCTAssertEqual(open.layers.first?.kind, .image(path: renamed.standardizedFileURL.path), "round 12: the window follows")
        // ⌘Z in the first window, then its save (scheduleSave → store).
        windowRestore(before, open: &open)
        _ = await store.store(open)
        let undone = await store.recipe(for: photo)
        let missing = (undone?.layers ?? []).compactMap { layer -> String? in
            guard case let .image(path) = layer.kind, !FileManager.default.fileExists(atPath: path) else { return nil }
            return (path as NSString).lastPathComponent
        }
        XCTAssertTrue(missing.isEmpty, "after ⌘Z the recipe names a logo that is no longer there: \(missing)")
        // ⇧⌘Z: the recipe from after the change, also from before the move.
        windowRestore(after, open: &open)
        _ = await store.store(open)
        let redone = await store.recipe(for: photo)
        XCTAssertEqual(redone?.layers.first?.kind, .image(path: renamed.standardizedFileURL.path), "after ⇧⌘Z the logo is still lost")
    }
}
