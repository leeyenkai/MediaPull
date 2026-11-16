import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MediaPullCore

/// Reads the facts analysis records without models: size, format, capture date, camera, GPS, animation, length (R-3601).
public enum MediaFactsReader {
    public static func facts(for url: URL) async -> MediaFacts {
        let format = MediaFormat.fromExtension(url.pathExtension)
        var facts = format?.kind == .video ? await videoFacts(url) : imageFacts(url)
        facts.format = format
        facts.screenCaptureMarker = facts.screenCaptureMarker || hasScreenCaptureAttribute(url)
        return facts
    }

    static func imageFacts(_ url: URL) -> MediaFacts {
        var facts = MediaFacts()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return facts }
        var width = props[kCGImagePropertyPixelWidth] as? Int
        var height = props[kCGImagePropertyPixelHeight] as? Int
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        facts.pixelWidth = width
        facts.pixelHeight = height
        // Sizes in an ICO or pages in a TIFF are not frames.
        let type = CGImageSourceGetType(source) as String?
        facts.isAnimated = CGImageSourceGetCount(source) > 1 && ![UTType.ico.identifier, UTType.tiff.identifier].contains(type)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        facts.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        facts.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        facts.hasCameraEXIF = facts.cameraMake != nil || facts.cameraModel != nil || exif[kCGImagePropertyExifExposureTime] != nil
            || exif[kCGImagePropertyExifFNumber] != nil
        if let comment = exif[kCGImagePropertyExifUserComment] as? String,
           comment.lowercased() == "screenshot"
        {
            facts.screenCaptureMarker = true
        }
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            facts.captureDate = exifDate(text, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           lat != 0 || lon != 0
        {
            facts.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            facts.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        return facts
    }

    /// EXIF dates have no time zone unless the offset tag is present; without it the Mac's own zone is assumed.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if let offset, offset.count == 6 {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let date = formatter.date(from: text + offset) {
                return date
            }
        }
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    static func videoFacts(_ url: URL) async -> MediaFacts {
        var facts = MediaFacts()
        let info = await LocalVideoInfo.load(url)
        facts.pixelWidth = info.size?.width
        facts.pixelHeight = info.size?.height
        facts.duration = info.duration
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            facts.captureDate = date
        }
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata {
                guard let id = item.identifier else { continue }
                switch id {
                case .quickTimeMetadataLocationISO6709, .commonIdentifierLocation:
                    if let text = try? await item.load(.stringValue), let (lat, lon) = parseISO6709(text) {
                        facts.latitude = lat
                        facts.longitude = lon
                    }
                case .quickTimeMetadataMake, .commonIdentifierMake:
                    facts.cameraMake = try? await item.load(.stringValue)
                case .quickTimeMetadataModel, .commonIdentifierModel:
                    facts.cameraModel = try? await item.load(.stringValue)
                default: break
                }
            }
        }
        facts.hasCameraEXIF = facts.cameraMake != nil || facts.cameraModel != nil
        return facts
    }

    /// "+37.3349-122.0090+030.000/" → (37.3349, -122.0090).
    public static func parseISO6709(_ text: String) -> (Double, Double)? {
        let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let latRange = Range(match.range(at: 1), in: text), let lonRange = Range(match.range(at: 2), in: text),
              let lat = Double(text[latRange]), let lon = Double(text[lonRange]) else { return nil }
        return (lat, lon)
    }

    static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, 0) > 0
        }
    }

    /// The average colour of each cell of an 8×8 grid (192 values), for the dominant colour (R-3606).
    public static func colourGrid(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &pixels, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
        var grid: [UInt8] = []
        grid.reserveCapacity(192)
        for cell in 0 ..< 64 {
            grid.append(contentsOf: pixels[cell * 4 ..< cell * 4 + 3])
        }
        return grid
    }
}
