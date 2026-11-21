import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore
import UniformTypeIdentifiers

/// Basic edits for the editor (SPEC section 32): rotate, flip and crop at full resolution.
public enum ImageEditing {
    /// The full-size image with its camera orientation applied, so edits act on what people see.
    public static func loadOriented(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if orientation == 1 { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
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
        let hasAlpha = ImageConversion.imageHasAlpha(image)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
    }

    /// Quarter turns and mirroring, composed in the order they were made (they do not commute): the picture as shown is
    /// rotated `rotation` quarter turns clockwise after being mirrored left to right when `mirrored`.
    public struct Reorientation: Sendable, Equatable {
        public var rotation = 0
        public var mirrored = false

        public init() {}

        public mutating func rotate(clockwise: Bool) { rotation += clockwise ? 1 : -1 }

        /// A flip after a rotation by r equals a rotation by -r after a flip.
        public mutating func flip() {
            rotation = -rotation
            mirrored.toggle()
        }

        var normalised: (rotation: Int, mirrored: Bool) { (((rotation % 4) + 4) % 4, mirrored) }

        /// The EXIF orientation (1 to 8) for (rotation, mirrored).
        static func exif(_ rotation: Int, _ mirrored: Bool) -> Int {
            switch (((rotation % 4) + 4) % 4, mirrored) {
            case (0, false): 1
            case (0, true): 2
            case (2, false): 3
            case (2, true): 4
            case (3, true): 5
            case (1, false): 6
            case (1, true): 7
            default: 8
            }
        }

        static func components(_ exif: Int) -> (rotation: Int, mirrored: Bool) {
            switch exif {
            case 2: (0, true)
            case 3: (2, false)
            case 4: (2, true)
            case 5: (3, true)
            case 6: (1, false)
            case 7: (1, true)
            case 8: (3, false)
            default: (0, false)
            }
        }

        /// The orientation tag that shows the picture with this edit made on top of `current`.
        public func applied(to current: Int) -> Int {
            let (r0, m0) = Self.components(current)
            let (re, me) = normalised
            return me ? Self.exif(re - r0, !m0) : Self.exif(re + r0, m0)
        }
    }

    /// Whether the picture carries an HDR gain map, which an edited copy cannot keep yet (R-4203).
    public static func hasGainMap(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap].contains { type in
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil
        }
    }

    /// A rotate or flip of a JPEG or HEIC without re-encoding (R-3202, D-34 as amended, R-4203): the image data is copied
    /// as it is and only the orientation tag changes.
    public static func writeReoriented(_ source: URL, by edit: Reorientation, to output: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(imageSource),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), nil)
              as? [CFString: Any],
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil)
        else { throw ImageConversionError.unreadable }
        let current = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let options: [CFString: Any] = [kCGImageDestinationOrientation: edit.applied(to: current)]
        guard CGImageDestinationCopyImageSource(destination, imageSource, options as CFDictionary, nil) else {
            throw ImageConversionError.cannotWrite
        }
    }

    /// Writes the edited image as JPEG (quality 1.0), HEIC (quality 1.0; a HEIC stays HEIC, R-4203) or PNG, carrying over
    /// every metadata block of the source (EXIF, IPTC, GPS, the camera maker's) except orientation, which the pixels now
    /// already reflect.
    public static func write(_ image: CGImage, format: MediaFormat, metadataFrom source: URL?, to output: URL) throws {
        let target: MediaFormat = [.jpeg, .heic].contains(format) ? format : .png
        let type = switch target {
        case .jpeg: UTType.jpeg
        case .heic: UTType.heic
        default: UTType.png
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageConversionError.cannotWrite
        }
        var properties: [CFString: Any] = [:]
        if let source, let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), nil)
           as? [CFString: Any]
        {
            let blocks = [
                kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyGPSDictionary,
                kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary,
            ]
            for key in blocks {
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
        if target != .png { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
    }
}
