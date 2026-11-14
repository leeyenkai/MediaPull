import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore

public enum Thumbnailer {
    /// A downsampled image no larger than `maxPixel` on its long side, decoded off the main thread.
    public static func image(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(source, maxPixel: maxPixel)
    }

    public static func image(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return thumbnail(source, maxPixel: maxPixel)
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A poster frame from a local video file.
    public static func videoFrame(at url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let time = CMTime(seconds: min(1, max(duration * 0.1, 0)), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }
}

public enum ImageProbe {
    /// Image dimensions from the first bytes of a file, when the header holds them.
    public static func size(from data: Data, complete: Bool = false) -> PixelSize? {
        let incremental = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(incremental, data as CFData, complete)
        if let size = size(of: incremental) { return size }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            return size(of: source)
        }
        return nil
    }

    static func size(of source: CGImageSource) -> PixelSize? {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }

    public static func frameCount(from data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}

/// Reads video dimensions and duration from an MP4 or MOV `moov` box without decoding.
public enum MP4Probe {
    public struct Info: Sendable, Equatable {
        public var size: PixelSize?
        public var duration: Double?
    }

    public static func info(from data: Data) -> Info? {
        let bytes = [UInt8](data)
        guard let moov = findBox("moov", in: bytes, range: 0 ..< bytes.count, scanning: true) else { return nil }
        var info = Info()
        if let mvhd = findBox("mvhd", in: bytes, range: moov) {
            info.duration = parseMVHD(bytes, mvhd)
        }
        var cursor = moov.lowerBound
        while let trak = findBox("trak", in: bytes, range: cursor ..< moov.upperBound) {
            if let tkhd = findBox("tkhd", in: bytes, range: trak), let size = parseTKHD(bytes, tkhd), size.width > 0, size.height > 0 {
                info.size = size
                break
            }
            cursor = trak.upperBound
        }
        return info.size == nil && info.duration == nil ? nil : info
    }

    /// The content range of the first box named `type` within `range`.
    static func findBox(_ type: String, in bytes: [UInt8], range: Range<Int>, scanning: Bool = false) -> Range<Int>? {
        let target = Array(type.utf8)
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            // Sizes come from untrusted bytes: do the arithmetic in UInt64 and clamp to the buffer.
            var size = UInt64(read32(bytes, offset))
            let name = Array(bytes[offset + 4 ..< offset + 8])
            var header: UInt64 = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                size = read64(bytes, offset + 8)
                header = 16
            } else if size == 0 {
                size = UInt64(range.upperBound - offset)
            }
            let available = UInt64(range.upperBound - offset)
            if size < header {
                if scanning { return scanFor(target, in: bytes, from: offset + 1, to: range.upperBound) }
                return nil
            }
            if name == target {
                let end = offset + Int(min(size, available))
                let start = offset + Int(header)
                return start <= end ? start ..< end : nil
            }
            guard size <= available else { break }
            offset += Int(size)
        }
        if scanning { return scanFor(target, in: bytes, from: range.lowerBound, to: range.upperBound) }
        return nil
    }

    /// Finds a box by its name anywhere in a buffer that may start mid-file.
    static func scanFor(_ target: [UInt8], in bytes: [UInt8], from start: Int, to end: Int) -> Range<Int>? {
        var index = max(start, 4)
        while index + 4 <= end {
            if bytes[index] == target[0], Array(bytes[index ..< index + 4]) == target {
                let boxStart = index - 4
                let size = Int(read32(bytes, boxStart))
                if size >= 8 { return (index + 4) ..< min(boxStart + size, end) }
            }
            index += 1
        }
        return nil
    }

    static func parseMVHD(_ bytes: [UInt8], _ range: Range<Int>) -> Double? {
        let start = range.lowerBound
        guard start + 32 <= range.upperBound, start + 32 <= bytes.count else { return nil }
        let version = bytes[start]
        if version == 1 {
            guard start + 32 <= range.upperBound else { return nil }
            let timescale = read32(bytes, start + 20)
            let duration = read64(bytes, start + 24)
            return timescale > 0 ? Double(duration) / Double(timescale) : nil
        }
        let timescale = read32(bytes, start + 12)
        let duration = read32(bytes, start + 16)
        return timescale > 0 ? Double(duration) / Double(timescale) : nil
    }

    static func parseTKHD(_ bytes: [UInt8], _ range: Range<Int>) -> PixelSize? {
        let start = range.lowerBound
        guard start < range.upperBound, start < bytes.count else { return nil }
        let version = bytes[start]
        let offset = start + (version == 1 ? 88 : 76)
        guard offset + 8 <= range.upperBound else { return nil }
        let width = Int(read32(bytes, offset) >> 16)
        let height = Int(read32(bytes, offset + 4) >> 16)
        return PixelSize(width: width, height: height)
    }

    static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    static func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        UInt64(read32(bytes, offset)) << 32 | UInt64(read32(bytes, offset + 4))
    }
}

/// Details of a local video file.
public struct LocalVideoInfo: Sendable {
    public var size: PixelSize?
    public var duration: Double?
    public var codec: String?

    public static func load(_ url: URL) async -> LocalVideoInfo {
        let asset = AVURLAsset(url: url)
        var info = LocalVideoInfo()
        info.duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let natural = try? await track.load(.naturalSize), let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                info.size = PixelSize(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()))
            }
            if let descriptions = try? await track.load(.formatDescriptions), let first = descriptions.first {
                let subtype = CMFormatDescriptionGetMediaSubType(first)
                let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((subtype >> $0) & 0xFF))) }
                info.codec = String(chars)
            }
        }
        return info
    }
}
