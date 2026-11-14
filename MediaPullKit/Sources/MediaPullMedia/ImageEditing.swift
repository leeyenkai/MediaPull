import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore
import UniformTypeIdentifiers

/// Basic edits for the editor (SPEC section 32): rotate, flip and crop at full resolution.
public enum ImageEditing {
    /// The full-size image with its camera orientation applied, so edits act on what people see.
    public static func loadOriented(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Rotates by quarter turns; positive turns are clockwise.
    public static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        guard let context = context(width: width, height: height, like: image) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        return context.makeImage()
    }

    public static func flippedHorizontally(_ image: CGImage) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, like: image) else { return nil }
        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Crops to a rectangle given in fractions of the image (origin at the top left).
    public static func cropped(_ image: CGImage, to unit: CGRect) -> CGImage? {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = CGRect(x: (unit.minX * full.width).rounded(), y: (unit.minY * full.height).rounded(),
                          width: (unit.width * full.width).rounded(), height: (unit.height * full.height).rounded()).intersection(full)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        if rect == full { return image }
        return image.cropping(to: rect)
    }

    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    /// Writes the edited image as JPEG (quality 1.0) or PNG, carrying over the source's metadata
    /// except orientation, which the pixels now already reflect.
    public static func write(_ image: CGImage, format: MediaFormat, metadataFrom source: URL?, to output: URL) throws {
        let target: MediaFormat = format == .jpeg ? .jpeg : .png
        let type = target == .jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageConversionError.cannotWrite
        }
        var properties: [CFString: Any] = [:]
        if let source, let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary] {
                if let value = original[key] { properties[key] = value }
            }
            if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = image.width
                exif[kCGImagePropertyExifPixelYDimension] = image.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
        }
        properties[kCGImagePropertyOrientation] = 1
        if target == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
    }
}
