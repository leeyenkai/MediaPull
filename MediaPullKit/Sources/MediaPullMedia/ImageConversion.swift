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
        func head(_ bytes: Int) -> Data {
            (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: bytes)
            } ?? Data()
        }
        var sniff = Sniffer.sniff(head(4096))
        // A WebP's lossless chunk can come after a large colour profile chunk: read further before deciding it is lossy.
        if sniff.format == .webp, sniff.webp?.lossless == false { sniff = Sniffer.sniff(head(512 * 1024), limit: 512 * 1024) }
        var count = CGImageSourceGetCount(source)
        // Several images in a HEIC or AVIF are an animation only when they are a sequence with frame timing; a stereo
        // pair (spatial photo) or an image with its depth map is one picture.
        if sniff.format == .heic || sniff.format == .avif, count > 1, !Self.hasFrameTiming(source) { count = 1 }
        guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        // The size as the picture is seen: orientations 5 to 8 turn it a quarter, as ImageProbe.size does (R-1503).
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5 ... 8).contains(orientation) {
            swap(&width, &height)
        }
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

    static func hasFrameTiming(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return properties[kCGImagePropertyHEICSDictionary] != nil || properties[kCGImagePropertyAVISDictionary] != nil
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

    /// The most frames converted from one animation; longer ones are cut there, with a note.
    public static let maxFrames = 3000

    /// How many times an animation plays: 0 for forever. ImageIO reports plays for every format, GIF included (a GIF
    /// with no loop block reads as 1; measured on macOS 27).
    public static func plays(of source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else { return 0 }
        if let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            return (gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue ?? 1
        }
        let keys: [(CFString, CFString)] = [
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
            (kCGImagePropertyAVISDictionary, kCGImagePropertyHEICSLoopCount),
        ]
        for (dictionaryKey, loopKey) in keys {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any] {
                return (dictionary[loopKey] as? NSNumber)?.intValue ?? 0
            }
        }
        return 0
    }

    /// Hands each frame to `body` with its delay in seconds, one at a time, so a long animation is never held in memory
    /// whole (at most `maxFrames`). Returns the number of frames handed over and whether the animation was cut short.
    @discardableResult
    public static func forEachFrame(of input: URL, limit: Int = maxFrames, _ body: (CGImage, Double) throws -> Void) throws
        -> (count: Int, truncated: Bool)
    {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ImageConversionError.unreadable
        }
        let total = CGImageSourceGetCount(source)
        var handed = 0
        for index in 0 ..< min(total, limit) {
            try autoreleasepool {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return }
                try body(image, delay(source, index))
                handed += 1
            }
        }
        guard handed > 0 else { throw ImageConversionError.unreadable }
        return (handed, total > limit)
    }

    /// The frames of an animated image with their delays (at most `maxFrames`), for ImageIO's own writers, which need
    /// them all at once; and how many times it plays.
    public static func frames(of input: URL) throws -> (frames: [Frame], plays: Int) {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ImageConversionError.unreadable }
        var frames: [Frame] = []
        try forEachFrame(of: input) { image, delay in frames.append(Frame(image: image, delay: delay)) }
        return (frames, plays(of: source))
    }

    static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        let pairs: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
            // Animated AVIF uses the HEIC sequence keys inside its own dictionary.
            (kCGImagePropertyAVISDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
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
    /// `plays` is how many times the animation plays (0: forever), kept from the source (R-1603).
    public static func writeAnimated(_ frames: [Frame], plays: Int, as type: UTType, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, frames.count, nil) else {
            throw ImageConversionError.cannotWrite
        }
        let isGIF = type == .gif
        // ImageIO takes plays for GIF too, and writes the file's repeat count (and no loop block for a single play).
        let fileProperties: [CFString: Any] = isGIF
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: plays]]
            : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: plays]]
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
