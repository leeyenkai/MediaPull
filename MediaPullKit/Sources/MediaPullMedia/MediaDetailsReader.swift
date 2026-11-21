import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore

/// What a file itself records about how it was made (D-110, R-1009b): camera, exposure, date taken, location, and for
/// videos length, codec and frame rate.
public struct MediaDetails: Sendable, Equatable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    /// Millimetres.
    public var focalLength: Double?
    public var focalLength35: Int?
    public var aperture: Double?
    /// Seconds.
    public var exposure: Double?
    public var iso: Int?
    public var flashFired: Bool?
    public var taken: Date?
    /// "+02:00" when the file records its time zone.
    public var takenOffset: String?
    public var software: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Metres above sea level (negative below).
    public var altitude: Double?
    public var colorProfile: String?
    public var duration: Double?
    public var codec: String?
    public var frameRate: Double?
    /// An audio file's tags (R-4205).
    public var audio: AudioTags?

    public init() {}

    /// Make and model as one name, without the make repeated ("Apple iPhone 15 Pro", not "Apple Apple iPhone 15 Pro").
    public var camera: String? {
        guard let model = cameraModel?.nonEmpty else { return cameraMake?.nonEmpty }
        guard let make = cameraMake?.nonEmpty, !model.lowercased().hasPrefix(make.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

public enum MediaDetailsReader {
    @concurrent
    public static func details(for url: URL) async -> MediaDetails {
        switch MediaFormat.fromExtension(url.pathExtension)?.kind {
        case .video: await videoDetails(url)
        case .audio: await audioDetails(url)
        default: imageDetails(url)
        }
    }

    static func audioDetails(_ url: URL) async -> MediaDetails {
        let facts = await MediaFactsReader.audioFacts(url, probe: nil)
        var details = MediaDetails()
        details.duration = facts.duration
        details.codec = facts.audio?.codec
        details.audio = facts.audio
        return details
    }

    static func imageDetails(_ url: URL) -> MediaDetails {
        var details = MediaDetails()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
              as? [CFString: Any]
        else { return details }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        func number(_ value: Any?) -> Double? {
            guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value > 0 else { return nil }
            return value
        }
        details.cameraMake = text(tiff[kCGImagePropertyTIFFMake])
        details.cameraModel = text(tiff[kCGImagePropertyTIFFModel])
        details.software = text(tiff[kCGImagePropertyTIFFSoftware])
        details.lens = text(exif[kCGImagePropertyExifLensModel]) ?? text(exifAux[kCGImagePropertyExifAuxLensModel])
        details.focalLength = number(exif[kCGImagePropertyExifFocalLength])
        details.focalLength35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).flatMap { Int(exactly: $0.rounded()) }
        details.aperture = number(exif[kCGImagePropertyExifFNumber])
        details.exposure = number(exif[kCGImagePropertyExifExposureTime])
        if let speeds = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = speeds.first, first.intValue > 0 {
            details.iso = first.intValue
        }
        // Bit 0 of the EXIF flash value says whether it fired.
        if let flash = exif[kCGImagePropertyExifFlash] as? NSNumber { details.flashFired = flash.intValue & 1 == 1 }
        if let (date, offset) = MediaFactsReader.takenDate(exif) {
            details.taken = MediaFactsReader.exifDate(date, offset: offset)
            details.takenOffset = MediaFactsReader.normalizedOffset(offset)
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
           let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue,
           lat.isFinite, lon.isFinite, abs(lat) < 90, abs(lon) <= 180, lat != 0 || lon != 0
        {
            // The magnitude, signed by its reference in either case (R1-m13); a pole exactly is not a place a map can show.
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            details.latitude = south ? -abs(lat) : (lat < 0 ? lat : abs(lat))
            details.longitude = west ? -abs(lon) : (lon < 0 ? lon : abs(lon))
            if let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue, altitude.isFinite, abs(altitude) < 1e6 {
                details.altitude = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1 ? -abs(altitude) : altitude
            }
        }
        details.colorProfile = text(props[kCGImagePropertyProfileName])
        return details
    }

    static func videoDetails(_ url: URL) async -> MediaDetails {
        var details = MediaDetails()
        let info = await LocalVideoInfo.load(url)
        details.duration = info.duration
        details.codec = info.codec.map(codecName)
        let facts = await MediaFactsReader.videoFacts(url)
        details.taken = facts.captureDate
        details.cameraMake = facts.cameraMake
        details.cameraModel = facts.cameraModel
        if let lat = facts.latitude, let lon = facts.longitude, lat.isFinite, lon.isFinite, abs(lat) < 90, abs(lon) <= 180,
           lat != 0 || lon != 0
        {
            details.latitude = lat
            details.longitude = lon
        }
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first, let rate = try? await track.load(.nominalFrameRate),
           rate.isFinite, rate > 0
        {
            details.frameRate = Double(rate)
        }
        return details
    }

    /// Common four-character codec codes in plain words; others as they are.
    static func codecName(_ code: String) -> String {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "av01": "AV1"
        case "vp09": "VP9"
        case "ap4h", "apch", "apcn", "apcs", "apco": "ProRes"
        default: code
        }
    }
}
