import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MediaPullCore
import MediaPullMedia
import UniformTypeIdentifiers

/// Writes an edited photo as a new file (R-4608). The original is only read.
public enum PhotoExporter {
    public enum Failure: Error, LocalizedError {
        case unreadable, notWritten, tooLargeForLayers, missingPicture(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The photo could not be read."
            case .notWritten: "The edited photo could not be written."
            case .tooLargeForLayers: "This picture is too large to draw text and shapes on. Choose a smaller export size."
            case let .missingPicture(name): "The picture “\(name)” of a layer is no longer there."
            }
        }
    }

    /// The edited result of `source` at the recipe's export size, as a bitmap.
    public static func rendered(_ source: URL, recipe: EditRecipe, exact: Bool = false) throws -> CGImage {
        guard let input = PhotoRenderer.source(source) else { throw Failure.unreadable }
        // Never written without a picture layer the person sees missing (audit 2026-11-21-10, B10-4).
        for layer in recipe.layers where !layer.hidden {
            if case let .image(path) = layer.kind, !FileManager.default.fileExists(atPath: path) {
                throw Failure.missingPicture((path as NSString).lastPathComponent)
            }
        }
        let full = PhotoRenderer.render(input, recipe: recipe)
        let target = recipe.export.size.pixels(for: full.extent.size)
        var layersDrawn = true
        // Fitted to the setting's own box, so the scale is the one `pixels(for:)` worked out and no side is rounded down
        // twice (Long Edge 1080 is 1080, audit 2026-11-21-13, B13-m1).
        let canvas = PhotoRenderer.render(input, recipe: recipe, fit: recipe.export.size.box ?? target) { size in
            let overlay = LayerRenderer.image(recipe.layers, canvas: size)
            layersDrawn = overlay != nil
            return overlay
        }
        // Never written without its text and shapes (a canvas over 30,000 px cannot hold them).
        guard layersDrawn || recipe.layers.allSatisfy(\.hidden) else { throw Failure.tooLargeForLayers }
        guard let image = PhotoRenderer.cgImage(canvas, displayP3: recipe.export.displayP3, exact: exact) else { throw Failure.notWritten }
        return image
    }

    static func hasAlpha(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
              as? [CFString: Any]
        else { return false }
        return properties[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// The image drawn without an alpha channel, in its own colour space.
    static func opaqueCopy(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Writes the result to `output` (a new file the caller places), with the source's metadata as the export settings
    /// allow, upright.
    public static func export(_ source: URL, recipe: EditRecipe, to output: URL) throws -> CGSize {
        var image = try rendered(source, recipe: recipe)
        // A photo with no transparency is written without an alpha channel, as it came (B8-6); a transparent PNG keeps it.
        if !hasAlpha(source), let opaque = opaqueCopy(image) { image = opaque }
        let settings = recipe.export
        let type: UTType = switch settings.format {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw Failure.notWritten
        }
        var properties = metadata(of: source, settings: settings, size: CGSize(width: image.width, height: image.height))
        if settings.format != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(settings.quality, 0.5), 1)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw Failure.notWritten
        }
        return CGSize(width: image.width, height: image.height)
    }

    /// The source's EXIF, IPTC and GPS (and camera maker blocks), minus what the settings leave out; orientation upright.
    static func metadata(of source: URL, settings: ExportSettings, size: CGSize) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyPropertiesAtIndex(imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), nil)
              as? [CFString: Any]
        else { return properties }
        var blocks: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary]
        if settings.keepLocation { blocks.append(kCGImagePropertyGPSDictionary) }
        if settings.keepCamera { blocks.append(kCGImagePropertyExifAuxDictionary) }
        for key in blocks {
            if let value = original[key] { properties[key] = value }
        }
        // Without camera details, the camera goes but the photographer's copyright, artist and caption stay (R-4608,
        // audit 2026-11-21-4, B4-m4).
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            // Orientation and tiling are the source's, not the export's (B5-m3).
            tiff[kCGImagePropertyTIFFOrientation] = nil
            tiff[kCGImagePropertyTIFFTileWidth] = nil
            tiff[kCGImagePropertyTIFFTileLength] = nil
            if !settings.keepCamera {
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware,
                            kCGImagePropertyTIFFHostComputer]
                {
                    tiff[key] = nil
                }
            }
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if !settings.keepLocation, var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            // Every place IPTC can hold, the content location and the extension's too (round 12, B12-m1).
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
                        kCGImagePropertyIPTCContentLocationName, kCGImagePropertyIPTCContentLocationCode,
                        kCGImagePropertyIPTCExtLocationCreated, kCGImagePropertyIPTCExtLocationShown]
            {
                iptc[key] = nil
            }
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
            exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
            if !settings.keepCamera {
                for key in [kCGImagePropertyExifLensMake, kCGImagePropertyExifLensModel, kCGImagePropertyExifBodySerialNumber,
                            kCGImagePropertyExifLensSerialNumber, kCGImagePropertyExifCameraOwnerName]
                {
                    exif[key] = nil
                }
            }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        overlayXMP(of: source, on: &properties, settings: settings)
        return properties
    }

    /// The photo's `.xmp` lies over its own values (R-4502), cleared ones included: a location removed there is not
    /// exported, a date shifted there is.
    static func overlayXMP(of source: URL, on properties: inout [CFString: Any], settings: ExportSettings) {
        let stem = source.deletingPathExtension()
        guard let xmp = ["xmp", "XMP"].lazy.map({ stem.appendingPathExtension($0) }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }), let values = MetadataWriter.values(ofXMPAt: xmp) else { return }
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if values.fields.contains(.rating) { iptc[kCGImagePropertyIPTCStarRating] = values.rating }
        if values.fields.contains(.keywords) { iptc[kCGImagePropertyIPTCKeywords] = values.keywords }
        properties[kCGImagePropertyIPTCDictionary] = iptc
        if values.fields.contains(.taken), let taken = values.taken {
            var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            exif[kCGImagePropertyExifDateTimeOriginal] = taken.original
            exif[kCGImagePropertyExifOffsetTimeOriginal] = MetadataEdit.offset(taken.originalOffset)
            if taken.digitized != nil {
                exif[kCGImagePropertyExifDateTimeDigitized] = taken.digitized
                exif[kCGImagePropertyExifOffsetTimeDigitized] = MetadataEdit.offset(taken.digitizedOffset)
            }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        if values.fields.contains(.location) {
            if let lat = values.latitude, let lon = values.longitude, settings.keepLocation {
                properties[kCGImagePropertyGPSDictionary] = [
                    kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                    kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon < 0 ? "W" : "E",
                ] as [CFString: Any]
            } else {
                properties[kCGImagePropertyGPSDictionary] = nil
            }
        }
    }
}
