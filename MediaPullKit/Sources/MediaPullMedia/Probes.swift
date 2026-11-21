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

    /// `hdr`: decoded in high dynamic range where the picture has it (a gain map), for the preview (R-4204).
    public static func image(at url: URL, maxPixel: Int, hdr: Bool = false) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        // RAW and HEIC carry a preview of the whole picture; using it keeps grids of large files quick (R-4204). An HDR
        // preview needs the full picture.
        let format = MediaFormat.fromExtension(url.pathExtension)
        return thumbnail(source, maxPixel: maxPixel, embeddedFirst: !hdr && (format == .raw || format == .heic), hdr: hdr)
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int, embeddedFirst: Bool = false, hdr: Bool = false) -> CGImage? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if hdr { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
        if embeddedFirst {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
            if let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
               embeddedPreviewWillDo(image, source: source, index: index, maxPixel: maxPixel)
            {
                return image
            }
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        }
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    /// An embedded preview is used only when it is as large as asked and shows the whole picture (no letterbox bars).
    static func embeddedPreviewWillDo(_ image: CGImage, source: CGImageSource, index: Int, maxPixel: Int) -> Bool {
        guard max(image.width, image.height) >= maxPixel * 9 / 10,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, width > 0, height > 0
        else { return false }
        let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        let expected = turned ? height / width : width / height
        let actual = Double(image.width) / Double(max(image.height, 1))
        return abs(actual - expected) / expected < 0.02
    }

    /// Where a frame is taken from.
    public enum FramePosition: Sendable {
        /// Early (a tenth of the way in, at most a second): a poster that looks like the start.
        case poster
        /// A tenth of the way in, past title cards and fades (R-3601).
        case analysis
    }

    /// An audio file's embedded artwork (R-4205), or nil.
    public static func audioArtwork(at url: URL, maxPixel: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = image(from: data, maxPixel: maxPixel) { return image }
        }
        return nil
    }

    /// A frame from a local video file.
    public static func videoFrame(at url: URL, maxPixel: Int, position: FramePosition = .poster) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let loaded = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let duration = loaded.isFinite ? max(loaded, 0) : 0
        let seconds = position == .poster ? min(1, duration * 0.1) : duration * 0.1
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
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
              let properties = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
              as? [CFString: Any],
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
        // Zero or all ones means "unknown" (a fragmented MP4 keeps its length in the fragments): no length, not 0:00.
        if version == 1 {
            let timescale = read32(bytes, start + 20)
            let duration = read64(bytes, start + 24)
            guard timescale > 0, duration != 0, duration != .max else { return nil }
            return Double(duration) / Double(timescale)
        }
        let timescale = read32(bytes, start + 12)
        let duration = read32(bytes, start + 16)
        guard timescale > 0, duration != 0, duration != .max else { return nil }
        return Double(duration) / Double(timescale)
    }

    static func parseTKHD(_ bytes: [UInt8], _ range: Range<Int>) -> PixelSize? {
        let start = range.lowerBound
        guard start < range.upperBound, start < bytes.count else { return nil }
        let version = bytes[start]
        let matrix = start + (version == 1 ? 52 : 40)
        let offset = start + (version == 1 ? 88 : 76)
        guard offset + 8 <= range.upperBound else { return nil }
        let width = Int(read32(bytes, offset) >> 16)
        let height = Int(read32(bytes, offset + 4) >> 16)
        // A quarter turn in the display matrix (a and d zero, b and c not) shows the stored frame on its side,
        // as phones record portrait video.
        let a = read32(bytes, matrix), b = read32(bytes, matrix + 4), c = read32(bytes, matrix + 12), d = read32(bytes, matrix + 16)
        if a == 0, d == 0, b != 0, c != 0 { return PixelSize(width: height, height: width) }
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
        // An indefinite or invalid length is NaN, which a metadata file cannot hold: no length is better.
        info.duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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
