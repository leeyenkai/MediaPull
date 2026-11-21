import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MediaPullCore

/// Reads the facts analysis records without models: size, format, capture date, camera, GPS, animation, length (R-3601).
public enum MediaFactsReader {
    /// Reads an audio file the system cannot open (Ogg, Opus): tags, codec, bit rate and length. Given by the app, which
    /// runs the bundled ffprobe (MediaPullEngines); this module cannot start processes.
    public typealias AudioProbe = @Sendable (URL) async -> (tags: AudioTags, duration: Double?)?

    @concurrent
    public static func facts(for url: URL, audioProbe: AudioProbe? = nil) async -> MediaFacts {
        let format = MediaFormat.fromExtension(url.pathExtension)
        var facts = switch format?.kind {
        case .video: await videoFacts(url)
        case .audio: await audioFacts(url, probe: audioProbe)
        default: imageFacts(url)
        }
        facts.format = format
        facts.screenCaptureMarker = facts.screenCaptureMarker || hasScreenCaptureAttribute(url)
        return facts
    }

    static func imageFacts(_ url: URL) -> MediaFacts {
        var facts = MediaFacts()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
              as? [CFString: Any]
        else { return facts }
        var width = props[kCGImagePropertyPixelWidth] as? Int
        var height = props[kCGImagePropertyPixelHeight] as? Int
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        facts.pixelWidth = width
        facts.pixelHeight = height
        // Sizes in an ICO or pages in a TIFF are not frames; nor is a HEIC stereo pair (ImageConversion.analyze).
        let type = CGImageSourceGetType(source) as String?
        let still = type.map { [UTType.ico.identifier, UTType.tiff.identifier, UTType.bmp.identifier].contains($0) } ?? false
        let heif = type.map { [UTType.heic.identifier, UTType.heif.identifier, "public.avif"].contains($0) } ?? false
        facts.isAnimated = CGImageSourceGetCount(source) > 1 && !still && (!heif || ImageConversion.hasFrameTiming(source))
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
        if let (text, offset) = takenDate(exif) { facts.captureDate = exifDate(text, offset: offset) }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           lat != 0 || lon != 0
        {
            facts.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            facts.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        // Stars and keywords (R-4507): XMP first, IPTC as older writers left them.
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let metadata = CGImageSourceCopyMetadataAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
        facts.rating = metadata.flatMap { MetadataWriter.rating(in: $0) }
            ?? (iptc[kCGImagePropertyIPTCStarRating] as? Int).flatMap { $0 > 0 ? min($0, 5) : nil }
        let words = metadata.flatMap { MetadataWriter.strings(in: $0, path: "dc:subject") }
            ?? iptc[kCGImagePropertyIPTCKeywords] as? [String]
        facts.keywords = words?.isEmpty == false ? words : nil
        return facts
    }

    /// EXIF dates have no time zone unless the offset tag is present; without it the Mac's own zone is assumed.
    /// Made once: analysis reads a date from every photo.
    private static let withOffset: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        return formatter
    }()

    private static let local: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    /// The taken date and the offset recorded with that same date (R-4204): the original's, else the digitized one's,
    /// each falling back to the general offset.
    static func takenDate(_ exif: [CFString: Any]) -> (String, String?)? {
        let general = exif[kCGImagePropertyExifOffsetTime] as? String
        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            return (original, exif[kCGImagePropertyExifOffsetTimeOriginal] as? String ?? general)
        }
        if let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            return (digitized, exif[kCGImagePropertyExifOffsetTimeDigitized] as? String ?? general)
        }
        return nil
    }

    /// `+08:00`, `+0800`, `+08` and `Z` as `+08:00`; anything else is nil.
    static func normalizedOffset(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text == "Z" { return "+00:00" }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == text.dropFirst().filter({ $0 != ":" }).count else { return nil }
        switch digits.count {
        case 2: return "\(sign)\(digits):00"
        case 4: return "\(sign)\(digits.prefix(2)):\(digits.suffix(2))"
        default: return nil
        }
    }

    static func exifDate(_ text: String, offset: String?) -> Date? {
        if let offset = normalizedOffset(offset), let date = withOffset.date(from: text + offset) {
            return date
        }
        return local.date(from: text)
    }

    // MARK: Audio (R-4205)

    static func audioFacts(_ url: URL, probe: AudioProbe?) async -> MediaFacts {
        var facts = MediaFacts()
        let asset = AVURLAsset(url: url)
        var tags = AudioTags()
        if let seconds = try? await CMTimeGetSeconds(asset.load(.duration)), seconds.isFinite, seconds > 0 { facts.duration = seconds }
        let items = ((try? await asset.load(.commonMetadata)) ?? []) + ((try? await asset.load(.metadata)) ?? [])
        for item in items {
            let text = try? await item.load(.stringValue)
            let number = try? await item.load(.numberValue)
            switch item.commonKey {
            case .commonKeyTitle?: tags.title = tags.title ?? text
            case .commonKeyArtist?: tags.artist = tags.artist ?? text
            case .commonKeyAlbumName?: tags.album = tags.album ?? text
            case .commonKeyCreationDate?: tags.year = tags.year ?? text.flatMap(Self.year)
            default: break
            }
            switch item.identifier {
            case .iTunesMetadataAlbumArtist?, .id3MetadataBand?: tags.albumArtist = tags.albumArtist ?? text
            case .iTunesMetadataUserGenre?, .id3MetadataContentType?, .quickTimeMetadataGenre?: tags.genre = tags.genre ?? text
            case .id3MetadataYear?, .id3MetadataRecordingTime?, .iTunesMetadataReleaseDate?:
                tags.year = tags.year ?? text.flatMap(Self.year)
            case .id3MetadataTrackNumber?: tags.track = tags.track ?? text.flatMap(Self.trackNumber)
            case .iTunesMetadataTrackNumber?:
                // Big-endian: two bytes of padding, then the track number.
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    tags.track = tags.track ?? (Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3]))
                } else if let number {
                    tags.track = tags.track ?? number.intValue
                }
            default: break
            }
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 { tags.bitrate = Int(rate) }
            if let description = try? await track.load(.formatDescriptions).first {
                tags.codec = Self.codecName(CMFormatDescriptionGetMediaSubType(description))
            }
        }
        if facts.duration == nil || tags.codec == nil, let probed = await probe?(url) {
            facts.duration = facts.duration ?? probed.duration
            tags = Self.merged(tags, probed.tags)
        }
        facts.audio = tags
        return facts
    }

    static func year(_ text: String) -> Int? {
        let digits = text.prefix(4)
        guard digits.count == 4, let year = Int(digits), (1000 ... 9999).contains(year) else { return nil }
        return year
    }

    /// "3" or "3/12".
    static func trackNumber(_ text: String) -> Int? {
        text.split(separator: "/").first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatAC3: "AC-3"
        case kAudioFormatEnhancedAC3: "E-AC-3"
        default:
            String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? "Audio"
        }
    }

    static func merged(_ first: AudioTags, _ second: AudioTags) -> AudioTags {
        var out = first
        out.title = out.title ?? second.title
        out.artist = out.artist ?? second.artist
        out.album = out.album ?? second.album
        out.albumArtist = out.albumArtist ?? second.albumArtist
        out.year = out.year ?? second.year
        out.genre = out.genre ?? second.genre
        out.track = out.track ?? second.track
        out.codec = out.codec ?? second.codec
        out.bitrate = out.bitrate ?? second.bitrate
        return out
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
    /// Transparent areas count as white, the same grid duplicate detection uses.
    public static func colourGrid(_ image: CGImage) -> [UInt8] {
        PerceptualHash.colorGrid(image)
    }
}
