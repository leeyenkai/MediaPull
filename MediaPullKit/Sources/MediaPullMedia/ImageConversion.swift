import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore
import UniformTypeIdentifiers

public struct ImageAnalysis: Sendable, Equatable {
    public var format: MediaFormat?
    public var width: Int
    public var height: Int
    public var hasAlpha: Bool
    public var bitsPerComponent: Int
    public var frameCount: Int
    public var isLossless: Bool

    /// Several images in an ICO or TIFF are sizes or pages, not frames: those convert to a still of the first (largest) one.
    public var isAnimated: Bool { frameCount > 1 && ![MediaFormat.ico, .tiff, .bmp].contains(format) }
}

public enum StillTarget: String, Sendable {
    case jpeg, png
}

public enum ImageConversionError: LocalizedError {
    case unreadable
    case cannotWrite

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The image could not be read."
        case .cannotWrite: "The converted image could not be written."
        }
    }
}

public enum ImageConversion {
    /// What a file holds, from its bytes and ImageIO's view of it.
    public static func analyze(_ url: URL) -> ImageAnalysis? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 4096)
        } ?? Data()
        let sniff = Sniffer.sniff(head)
        let count = CGImageSourceGetCount(source)
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        var hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8
        var lossless = sniff.format?.isLosslessImage ?? false
        if let webp = sniff.webp {
            lossless = webp.lossless
            hasAlpha = webp.alpha
        }
        if sniff.format == .avif || sniff.format == .heic || sniff.format == .jxl {
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                hasAlpha = hasAlpha && imageHasAlpha(image)
            }
        }
        return ImageAnalysis(
            format: sniff.format, width: width, height: height, hasAlpha: hasAlpha, bitsPerComponent: depth, frameCount: count,
            isLossless: lossless
        )
    }

    static func imageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The still format to write for `analysis` (SPEC R-1601).
    public static func stillTarget(for analysis: ImageAnalysis) -> StillTarget {
        guard let format = analysis.format else { return .png }
        switch format {
        case .jpeg: return .jpeg
        case .png, .gif, .bmp, .tiff, .ico, .svg: return .png
        case .webp: return analysis.isLossless || analysis.hasAlpha ? .png : .jpeg
        case .avif, .heic, .jxl: return analysis.hasAlpha || analysis.bitsPerComponent > 8 ? .png : .jpeg
        default: return .png
        }
    }

    /// Writes the first frame of `input` as JPEG (quality 1.0) or PNG, carrying over EXIF,
    /// orientation and the colour profile (SPEC R-1602).
    public static func convertStill(_ input: URL, to target: StillTarget, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ImageConversionError.unreadable
        }
        let type = target == .jpeg ? UTType.jpeg : UTType.png
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageConversionError.cannotWrite
        }
        var options: [CFString: Any] = [:]
        if target == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = 1.0
            if let image = CGImageSourceCreateImageAtIndex(source, 0, nil), imageHasAlpha(image) {
                // JPEG has no alpha: flatten onto white rather than black.
                let flattened = flatten(image) ?? image
                var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
                properties[kCGImageDestinationLossyCompressionQuality] = 1.0
                CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
                return
            }
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
    }

    static func flatten(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    public struct Frame: @unchecked Sendable {
        public var image: CGImage
        public var delay: Double
    }

    /// All frames of an animated image with their delays in seconds.
    public static func frames(of input: URL) throws -> (frames: [Frame], loopCount: Int) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ImageConversionError.unreadable }
        let count = CGImageSourceGetCount(source)
        var frames: [Frame] = []
        frames.reserveCapacity(count)
        var loop = 0
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary] {
                if let dictionary = properties[key] as? [CFString: Any] {
                    let loopKey: CFString = key == kCGImagePropertyGIFDictionary ? kCGImagePropertyGIFLoopCount
                        : key == kCGImagePropertyPNGDictionary ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyWebPLoopCount
                    loop = (dictionary[loopKey] as? NSNumber)?.intValue ?? loop
                }
            }
        }
        for index in 0 ..< count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(Frame(image: image, delay: delay(source, index)))
        }
        guard !frames.isEmpty else { throw ImageConversionError.unreadable }
        return (frames, loop)
    }

    static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dictionaryKey, unclamped, clamped) in pairs {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any] {
                let value = (dictionary[unclamped] as? NSNumber)?.doubleValue ?? (dictionary[clamped] as? NSNumber)?.doubleValue
                if let value, value > 0.005 { return value }
                return 0.1
            }
        }
        return 0.1
    }

    /// Writes frames with ImageIO as GIF or animated PNG.
    public static func writeAnimated(_ frames: [Frame], loopCount: Int, as type: UTType, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, frames.count, nil) else {
            throw ImageConversionError.cannotWrite
        }
        let isGIF = type == .gif
        let fileProperties: [CFString: Any] = isGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loopCount]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        for frame in frames {
            let frameProperties: [CFString: Any] = isGIF
                ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame.delay]]
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: frame.delay]]
            CGImageDestinationAddImage(destination, frame.image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
    }

    /// Writes one frame as PNG, for handing frame sequences to ffmpeg.
    public static func writePNG(_ image: CGImage, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageConversionError.cannotWrite
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageConversionError.cannotWrite }
    }

    /// Whether ImageIO can decode this format on this system.
    public static func canDecode(_ format: MediaFormat) -> Bool {
        let types = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        let identifier: String? = switch format {
        case .webp: UTType.webP.identifier
        case .avif: "public.avif"
        case .heic: UTType.heic.identifier
        case .jxl: "public.jpeg-xl"
        case .bmp: UTType.bmp.identifier
        case .tiff: UTType.tiff.identifier
        case .ico: UTType.ico.identifier
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        case .gif: UTType.gif.identifier
        default: nil
        }
        guard let identifier else { return false }
        return types.contains(identifier)
    }
}
