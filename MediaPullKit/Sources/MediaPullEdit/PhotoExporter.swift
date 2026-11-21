import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MediaPullCore
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
        var blocks: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary]
        if settings.keepLocation { blocks.append(kCGImagePropertyGPSDictionary) }
        if settings.keepCamera { blocks += [kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary] }
        for key in blocks {
            if let value = original[key] { properties[key] = value }
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
        return properties
    }
}
