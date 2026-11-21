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
        case unreadable, notWritten, tooLargeForLayers

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The photo could not be read."
            case .notWritten: "The edited photo could not be written."
            case .tooLargeForLayers: "This picture is too large to draw text and shapes on. Choose a smaller export size."
            }
        }
    }

    /// The edited result of `source` at the recipe's export size, as a bitmap.
    public static func rendered(_ source: URL, recipe: EditRecipe, exact: Bool = false) throws -> CGImage {
        guard let input = PhotoRenderer.source(source) else { throw Failure.unreadable }
        let full = PhotoRenderer.render(input, recipe: recipe)
        let target = recipe.export.size.pixels(for: full.extent.size)
        var layersDrawn = true
        let canvas = PhotoRenderer.render(input, recipe: recipe, fit: target) { size in
            let overlay = LayerRenderer.image(recipe.layers, canvas: size)
            layersDrawn = overlay != nil
            return overlay
        }
        // Never written without its text and shapes (a canvas over 30,000 px cannot hold them).
        guard layersDrawn || recipe.layers.allSatisfy(\.hidden) else { throw Failure.tooLargeForLayers }
        guard let image = PhotoRenderer.cgImage(canvas, displayP3: recipe.export.displayP3, exact: exact) else { throw Failure.notWritten }
        return image
    }

    /// Writes the result to `output` (a new file the caller places), with the source's metadata as the export settings
    /// allow, upright.
    public static func export(_ source: URL, recipe: EditRecipe, to output: URL) throws -> CGSize {
        let image = try rendered(source, recipe: recipe)
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
            tiff[kCGImagePropertyTIFFOrientation] = nil
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
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
                        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode]
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
