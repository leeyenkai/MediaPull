import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MediaPullCore

/// Reads and writes ratings, keywords, dates taken and locations (section 45): inside JPEG and HEIC files without
/// touching their image data, or in a `.xmp` beside any other file (R-4502). Never on the main actor: it decodes images.
public enum MetadataWriter {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreadable
        case notWritten
        case pictureChanged
        case valuesNotKept

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The file could not be read."
            case .notWritten: "The new version could not be written."
            case .pictureChanged: "Writing into the file would have changed its picture."
            case .valuesNotKept: "The file did not keep the new values."
            }
        }
    }

    /// Formats written in place (R-4502, D-125); everything else gets a `.xmp`.
    public static func writesInFile(_ url: URL) -> Bool {
        guard let format = MediaFormat.fromExtension(url.pathExtension), format == .jpeg || format == .heic else { return false }
        return !MediaFormat.isSequenceExtension(url.pathExtension)
    }

    // MARK: Reading

    /// Every editable value the file itself holds.
    public static func values(of url: URL) -> MetadataValues {
        var out = MetadataValues(fields: Set(MetadataField.allCases))
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return out
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil)
        out.rating = metadata.flatMap { rating(in: $0) } ?? (iptc[kCGImagePropertyIPTCStarRating] as? Int).flatMap { $0 > 0 ? $0 : nil }
        out.keywords = metadata.flatMap { strings(in: $0, path: "dc:subject") } ?? (iptc[kCGImagePropertyIPTCKeywords] as? [String])
        if out.keywords?.isEmpty == true { out.keywords = nil }
        let taken = TakenDate(
            original: exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            originalOffset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String ?? exif[kCGImagePropertyExifOffsetTime] as? String,
            digitized: exif[kCGImagePropertyExifDateTimeDigitized] as? String,
            digitizedOffset: exif[kCGImagePropertyExifOffsetTimeDigitized] as? String ?? exif[kCGImagePropertyExifOffsetTime] as? String
        )
        out.taken = taken.isEmpty ? nil : taken
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double,
           lat != 0 || lon != 0
        {
            out.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            out.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        return out
    }

    /// The values a `.xmp` holds; only those it has are in `fields`, so they lie over the file's own (R-4502).
    public static func values(ofXMP data: Data) -> MetadataValues {
        var out = MetadataValues()
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return out }
        if CGImageMetadataCopyTagWithPath(metadata, nil, "xmp:Rating" as CFString) != nil {
            out.fields.insert(.rating)
            out.rating = rating(in: metadata)
        }
        if let words = strings(in: metadata, path: "dc:subject") {
            out.fields.insert(.keywords)
            out.keywords = words.isEmpty ? nil : words
        }
        let original = ["exif:DateTimeOriginal", "photoshop:DateCreated"].lazy.compactMap { string(in: metadata, path: $0) }.first
            .flatMap(XMPText.exif(fromDate:))
        let digitized = ["exif:DateTimeDigitized", "xmp:CreateDate"].lazy.compactMap { string(in: metadata, path: $0) }.first
            .flatMap(XMPText.exif(fromDate:))
        if original != nil || digitized != nil {
            out.fields.insert(.taken)
            out.taken = TakenDate(original: original?.text, originalOffset: original?.offset, digitized: digitized?.text,
                                  digitizedOffset: digitized?.offset)
        }
        if let lat = string(in: metadata, path: "exif:GPSLatitude").flatMap(XMPText.degrees),
           let lon = string(in: metadata, path: "exif:GPSLongitude").flatMap(XMPText.degrees)
        {
            out.fields.insert(.location)
            out.latitude = lat
            out.longitude = lon
        }
        return out
    }

    /// The `.xmp` read for a file (beside it, sharing its name), when there is one.
    public static func values(ofXMPAt url: URL) -> MetadataValues? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return values(ofXMP: data)
    }

    static func rating(in metadata: CGImageMetadata) -> Int? {
        guard let text = string(in: metadata, path: "xmp:Rating"), let value = Double(text) else { return nil }
        let stars = Int(value.rounded())
        return stars > 0 ? min(stars, 5) : nil
    }

    static func string(in metadata: CGImageMetadata, path: String) -> String? {
        (CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?)?.trimmedNonEmpty
    }

    static func strings(in metadata: CGImageMetadata, path: String) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let text = value as? String { return text.trimmedNonEmpty.map { [$0] } ?? [] }
        guard let items = value as? [CGImageMetadataTag] else { return nil }
        return items.compactMap { (CGImageMetadataTagCopyValue($0) as? String)?.trimmedNonEmpty }
    }

    // MARK: Writing in place (JPEG, HEIC)

    /// Writes a copy of `source` holding `values` at `staged`, then proves it: the same picture (R-4502) and the values
    /// read back. Throws (and leaves nothing at `staged`) otherwise.
    public static func writeCopy(of source: URL, setting values: MetadataValues, to staged: URL) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(input) else {
            throw Failure.unreadable
        }
        let index = CGImageSourceGetPrimaryImageIndex(input)
        let metadata = CGImageSourceCopyMetadataAtIndex(input, index, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        apply(values, toFile: metadata)
        do {
            guard let output = CGImageDestinationCreateWithURL(staged as CFURL, type, CGImageSourceGetCount(input), nil)
            else { throw Failure.notWritten }
            // A full copy, not a merge: a merge ignored dates and locations in HEIC and could not remove tags (D-125).
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
            guard CGImageDestinationCopyImageSource(output, input, options as CFDictionary, nil) else { throw Failure.notWritten }
            guard samePicture(source, staged) else { throw Failure.pictureChanged }
            guard Self.values(of: staged).agrees(with: values) else { throw Failure.valuesNotKept }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func apply(_ values: MetadataValues, toFile metadata: CGMutableImageMetadata) {
        func set(_ dictionary: CFString, _ key: CFString, _ value: CFTypeRef?) {
            remove(metadata, dictionary, key)
            if let value { _ = CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value) }
        }
        if values.fields.contains(.rating) {
            remove(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCStarRating)
            CGImageMetadataRemoveTagWithPath(metadata, nil, "xmp:Rating" as CFString)
            if let stars = values.rating { _ = CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, stars as CFNumber) }
        }
        if values.fields.contains(.keywords) {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
            set(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, values.keywords.map { $0 as CFArray })
        }
        if values.fields.contains(.taken) {
            let taken = values.taken ?? TakenDate()
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, taken.original as CFString?)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeOriginal,
                MetadataEdit.offset(taken.originalOffset) as CFString?)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, taken.digitized as CFString?)
            set(kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTimeDigitized,
                MetadataEdit.offset(taken.digitizedOffset) as CFString?)
            // The general offset would otherwise stand for a date that no longer has it.
            if taken.originalOffset == nil || taken.digitizedOffset == nil {
                remove(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifOffsetTime)
            }
        }
        if values.fields.contains(.location) {
            let lat = values.latitude, lon = values.longitude
            let has = lat != nil && lon != nil
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, has ? abs(lat!) as CFNumber : nil)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef, has ? (lat! < 0 ? "S" : "N") as CFString : nil)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, has ? abs(lon!) as CFNumber : nil)
            set(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, has ? (lon! < 0 ? "W" : "E") as CFString : nil)
        }
    }

    /// Removes the tag ImageIO keeps for an image property (and any alias of it).
    static func remove(_ metadata: CGMutableImageMetadata, _ dictionary: CFString, _ key: CFString) {
        var tries = 0
        while tries < 4, let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dictionary, key),
              let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag)
        {
            tries += 1
            guard CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString) else { break }
        }
    }

    // MARK: The same picture (R-4502)

    /// Whether `b` holds the same picture as `a`: as many images, each decoding to the same pixels, the same auxiliary
    /// images (gain maps, depth, mattes) and the same maker notes.
    public static func samePicture(_ a: URL, _ b: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let first = CGImageSourceCreateWithURL(a as CFURL, options), let second = CGImageSourceCreateWithURL(b as CFURL, options),
              CGImageSourceGetCount(first) == CGImageSourceGetCount(second),
              CGImageSourceGetPrimaryImageIndex(first) == CGImageSourceGetPrimaryImageIndex(second)
        else { return false }
        for index in 0 ..< CGImageSourceGetCount(first) {
            guard let one = pixelDigest(first, index), one == pixelDigest(second, index) else { return false }
            for type in auxiliaryTypes where auxiliaryDigest(first, index, type) != auxiliaryDigest(second, index, type) {
                return false
            }
            let p1 = CGImageSourceCopyPropertiesAtIndex(first, index, nil) as? [String: Any] ?? [:]
            let p2 = CGImageSourceCopyPropertiesAtIndex(second, index, nil) as? [String: Any] ?? [:]
            for key in Set(p1.keys).union(p2.keys) where key.hasPrefix("{Maker") {
                guard let m1 = p1[key] as? NSDictionary, let m2 = p2[key] as? NSDictionary, m1 == m2 else { return false }
            }
        }
        return true
    }

    static var auxiliaryTypes: [CFString] {
        [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap,
                                             kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                                             kCGImageAuxiliaryDataTypePortraitEffectsMatte,
                                             kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte,
                                             kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                                             kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte,
                                             kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
                                             kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
    }

    static func pixelDigest(_ source: CGImageSource, _ index: Int) -> String? {
        guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let data = image.dataProvider?.data as Data?
        else { return nil }
        let shape = "\(image.width)x\(image.height)x\(image.bitsPerPixel)x\(image.bitmapInfo.rawValue)|"
        return shape + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func auxiliaryDigest(_ source: CGImageSource, _ index: Int, _ type: CFString) -> String? {
        guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) as? [CFString: Any],
              let data = info[kCGImageAuxiliaryDataInfoData] as? Data else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: `.xmp` beside a file

    /// The `.xmp` with `values` set over `existing` (what else it holds is kept).
    public static func xmpData(setting values: MetadataValues, over existing: Data?) throws -> Data {
        let metadata = existing.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }.flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        func set(_ path: String, _ value: CFTypeRef?, removing aliases: [String] = []) {
            for alias in [path] + aliases {
                CGImageMetadataRemoveTagWithPath(metadata, nil, alias as CFString)
            }
            if let value { _ = CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, value) }
        }
        if values.fields.contains(.rating) {
            set("xmp:Rating", values.rating.map { "\($0)" as CFString })
        }
        if values.fields.contains(.keywords) {
            CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
            if let words = values.keywords, !words.isEmpty,
               let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                  "subject" as CFString, .arrayUnordered, words as CFArray)
            {
                CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
            }
        }
        if values.fields.contains(.taken) {
            let taken = values.taken ?? TakenDate()
            set("exif:DateTimeOriginal", taken.original.flatMap { XMPText.date(exif: $0, offset: taken.originalOffset) } as CFString?,
                removing: ["photoshop:DateCreated"])
            set("exif:DateTimeDigitized", taken.digitized.flatMap { XMPText.date(exif: $0, offset: taken.digitizedOffset) } as CFString?,
                removing: ["xmp:CreateDate"])
        }
        if values.fields.contains(.location) {
            let has = values.latitude != nil && values.longitude != nil
            set("exif:GPSLatitude", has ? XMPText.coordinate(values.latitude!, latitude: true) as CFString : nil)
            set("exif:GPSLongitude", has ? XMPText.coordinate(values.longitude!, latitude: false) as CFString : nil)
            for path in ["exif:GPSLatitudeRef", "exif:GPSLongitudeRef"] {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
        }
        guard let data = CGImageMetadataCreateXMPData(metadata, nil) as Data? else { throw Failure.notWritten }
        // Read back as MediaPull will read it.
        guard self.values(ofXMP: data).agrees(with: values) else { throw Failure.valuesNotKept }
        return data
    }

    /// The `.xmp` that belongs to `url`: beside it, sharing its name (`IMG_1.CR3` → `IMG_1.xmp`), whatever its case.
    public static func xmpURL(for url: URL, existing names: [String]) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = url.deletingLastPathComponent()
        if let found = names.first(where: { name in
            (name as NSString).pathExtension.lowercased() == "xmp" && (name as NSString).deletingPathExtension == stem
        }) {
            return folder.appendingPathComponent(found)
        }
        return folder.appendingPathComponent("\(stem).xmp")
    }
}
