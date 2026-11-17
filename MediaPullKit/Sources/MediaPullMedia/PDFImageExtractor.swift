import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore
import UniformTypeIdentifiers

/// One image found inside a PDF, written to disk at its original resolution.
public struct PDFExtractedImage: Sendable, Hashable {
    public var file: URL
    public var page: Int
    public var index: Int
    public var width: Int
    public var height: Int
    public var format: MediaFormat
    public var bytes: Int64
}

public enum PDFExtractionError: LocalizedError {
    case unreadable
    case locked

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The PDF could not be opened."
        case .locked: "The PDF is password protected."
        }
    }
}

/// Pulls the images embedded in a PDF (SPEC section 31). Images are taken from the file as stored,
/// not rendered from pages: JPEG data is copied byte for byte, everything else is decoded once and
/// written as lossless PNG.
public final class PDFImageExtractor {
    private let document: CGPDFDocument
    private let folder: URL
    private let baseName: String
    private let minimumSide: Int
    private var seen = Set<Int>()
    private var hashes = Set<Int>()
    private var results: [PDFExtractedImage] = []
    private var pageIndex = 0

    public static func pageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }

    private init(document: CGPDFDocument, folder: URL, baseName: String, minimumSide: Int) {
        self.document = document
        self.folder = folder
        self.baseName = baseName
        self.minimumSide = minimumSide
    }

    /// Extracts every embedded image of at least `minimumSide` pixels on both sides.
    public static func extract(
        pdf: URL,
        to folder: URL,
        baseName: String,
        minimumSide: Int = 24,
        progress: (Int, Int) -> Void = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> [PDFExtractedImage] {
        guard let document = CGPDFDocument(pdf as CFURL) else { throw PDFExtractionError.unreadable }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") { throw PDFExtractionError.locked }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let extractor = PDFImageExtractor(document: document, folder: folder, baseName: FileNaming.sanitize(baseName, maxBytes: 120),
                                          minimumSide: minimumSide)
        let pages = document.numberOfPages
        for number in 1 ... max(pages, 1) where pages > 0 {
            if isCancelled() { break }
            progress(number, pages)
            guard let page = document.page(at: number), let dictionary = page.dictionary else { continue }
            extractor.pageIndex = 0
            if let resources = Self.resources(of: dictionary) {
                extractor.walk(resources, page: number, depth: 0)
            }
        }
        return extractor.results
    }

    /// The page's resources, inherited from parent page-tree nodes when the page has none.
    static func resources(of page: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var node: CGPDFDictionaryRef? = page
        for _ in 0 ..< 32 {
            guard let current = node else { return nil }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent) else { return nil }
            node = parent
        }
        return nil
    }

    private func walk(_ resources: CGPDFDictionaryRef, page: Int, depth: Int) {
        guard depth < 6 else { return }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let stream { streams.append(stream) }
            return true
        }, nil)
        for stream in streams {
            let identity = unsafeBitCast(stream, to: Int.self)
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            guard let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
            switch Self.name(dictionary, "Subtype") {
            case "Image":
                // An image that could not be written takes neither a number nor its data's place, so a later copy of
                // the same data is still saved and the numbering has no gaps.
                let (index, seen) = (pageIndex, hashes)
                if let image = extractImage(stream, dictionary: dictionary, page: page) {
                    results.append(image)
                } else {
                    (pageIndex, hashes) = (index, seen)
                }
            case "Form":
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    walk(nested, page: page, depth: depth + 1)
                }
            default:
                break
            }
        }
    }

    private func extractImage(_ stream: CGPDFStreamRef, dictionary: CGPDFDictionaryRef, page: Int) -> PDFExtractedImage? {
        var isMask: CGPDFBoolean = 0
        if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &isMask), isMask != 0 { return nil }
        let width = Self.integer(dictionary, "Width") ?? 0
        let height = Self.integer(dictionary, "Height") ?? 0
        guard width >= minimumSide, height >= minimumSide else { return nil }
        var format = CGPDFDataFormat.raw
        guard let cfData = CGPDFStreamCopyData(stream, &format) else { return nil }
        let data = cfData as Data
        let hash = data.hashValue
        guard !hashes.contains(hash) else { return nil }
        hashes.insert(hash)
        pageIndex += 1
        let stem = String(format: "%@ p%03d %02d", baseName, page, pageIndex)

        switch format {
        case .jpegEncoded:
            let colorSpace = Self.colorSpaceComponents(dictionary)
            let hasMask = Self.hasStream(dictionary, "SMask")
            if colorSpace != 4, !hasMask {
                let file = folder.appendingPathComponent(stem + ".jpg")
                // The PDF keeps the image's colour profile beside the JPEG data; put it into the file (losslessly) so
                // wide-colour pictures keep their colours (R-1602).
                let bytes = Self.iccProfile(dictionary).map { Self.embedICC($0, in: data) } ?? data
                guard (try? bytes.write(to: file)) != nil else { return nil } // lint:allow silent-write an image that cannot be written is left out of the count shown
                return PDFExtractedImage(file: file, page: page, index: pageIndex, width: width, height: height, format: .jpeg,
                                         bytes: Int64(bytes.count))
            }
            // CMYK JPEGs and JPEGs with a soft mask are decoded and written as PNG.
            guard let source = CGImageSourceCreateWithData(cfData, nil), var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            if hasMask, let masked = applySoftMask(image, dictionary: dictionary) { image = masked }
            return writePNG(image, stem: stem, page: page)
        case .JPEG2000:
            guard let source = CGImageSourceCreateWithData(cfData, nil), var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            if let masked = applySoftMask(image, dictionary: dictionary) { image = masked }
            return writePNG(image, stem: stem, page: page)
        default:
            guard var image = Self.rawImage(data, dictionary: dictionary, width: width, height: height) else { return nil }
            if let masked = applySoftMask(image, dictionary: dictionary) { image = masked }
            return writePNG(image, stem: stem, page: page)
        }
    }

    private func writePNG(_ image: CGImage, stem: String, page: Int) -> PDFExtractedImage? {
        let file = folder.appendingPathComponent(stem + ".png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return PDFExtractedImage(file: file, page: page, index: pageIndex, width: image.width, height: image.height, format: .png,
                                 bytes: bytes)
    }

    /// Applies a PDF soft mask as alpha by drawing the image through it.
    private func applySoftMask(_ image: CGImage, dictionary: CGPDFDictionaryRef) -> CGImage? {
        var maskStream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "SMask", &maskStream), let maskStream,
              let maskDictionary = CGPDFStreamGetDictionary(maskStream)
        else { return nil }
        var format = CGPDFDataFormat.raw
        guard let maskData = CGPDFStreamCopyData(maskStream, &format) else { return nil }
        let maskWidth = Self.integer(maskDictionary, "Width") ?? 0
        let maskHeight = Self.integer(maskDictionary, "Height") ?? 0
        let mask: CGImage?
        if format == .raw {
            let bits = Self.integer(maskDictionary, "BitsPerComponent") ?? 8
            let rowBytes = (maskWidth * bits + 7) / 8
            guard maskWidth > 0, maskHeight > 0, (maskData as Data).count >= rowBytes * maskHeight,
                  let provider = CGDataProvider(data: maskData)
            else { return nil }
            mask = CGImage(
                width: maskWidth,
                height: maskHeight,
                bitsPerComponent: bits,
                bitsPerPixel: bits,
                bytesPerRow: rowBytes,
                // PDF samples are big-endian; 16-bit masks need the byte order said, as rawImage does.
                           space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        } else {
            mask = CGImageSourceCreateWithData(maskData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        guard let mask else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.clip(to: rect, mask: mask)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    // MARK: Raw samples

    static func rawImage(_ data: Data, dictionary: CGPDFDictionaryRef, width: Int, height: Int) -> CGImage? {
        let bits = integer(dictionary, "BitsPerComponent") ?? 8
        guard [1, 2, 4, 8, 16].contains(bits), let (space, components) = colorSpace(dictionary) else { return nil }
        let rowBytes = (width * bits * components + 7) / 8
        guard data.count >= rowBytes * height, let provider = CGDataProvider(data: data as CFData) else { return nil }
        var decode: [CGFloat]?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "Decode", &array), let array {
            var values: [CGFloat] = []
            for index in 0 ..< CGPDFArrayGetCount(array) {
                var number: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, index, &number) { values.append(number) }
            }
            if values.count == components * 2 { decode = values }
        }
        let info = CGBitmapInfo(rawValue: bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : 0)
        let image = decode.withOptionalPointer { pointer in
            CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components, bytesPerRow: rowBytes,
                    space: space, bitmapInfo: info, provider: provider, decode: pointer, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let image else { return nil }
        // CMYK and indexed images are flattened to RGB so every viewer shows them alike.
        if space.model == .cmyk || space.model == .indexed {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return image }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage() ?? image
        }
        return image
    }

    /// The colour space of an image and its component count, for the spaces images use in practice.
    static func colorSpace(_ dictionary: CGPDFDictionaryRef) -> (CGColorSpace, Int)? {
        if let name = name(dictionary, "ColorSpace") { return deviceSpace(name) }
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array else {
            return (CGColorSpaceCreateDeviceGray(), 1)
        }
        return arraySpace(array)
    }

    /// The ICC profile of an image whose colour space is ICCBased, when it is a profile this Mac can read.
    static func iccProfile(_ dictionary: CGPDFDictionaryRef) -> Data? {
        var array: CGPDFArrayRef?
        var kind: UnsafePointer<CChar>?
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetArray(dictionary, "ColorSpace", &array), let array, CGPDFArrayGetName(array, 0, &kind), let kind,
              String(cString: kind) == "ICCBased", CGPDFArrayGetStream(array, 1, &stream), let stream
        else { return nil }
        var format = CGPDFDataFormat.raw
        guard let profile = CGPDFStreamCopyData(stream, &format), format == .raw, CGColorSpace(iccData: profile) != nil else { return nil }
        return profile as Data
    }

    /// `jpeg` with `profile` added as APP2 ICC_PROFILE segments after its first APP0/APP1 segments; the image data is
    /// untouched. A JPEG that already has a profile is returned as it is.
    static func embedICC(_ profile: Data, in jpeg: Data) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8, !profile.isEmpty else { return jpeg }
        let signature = Array("ICC_PROFILE".utf8) + [0]
        var offset = 2
        // Skip the APP0 (JFIF) and APP1 (Exif) segments, which must come first; stop at anything else.
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else { return jpeg }
            if marker == 0xE2, Array(bytes[(offset + 4) ..< min(offset + 4 + signature.count, bytes.count)]) == signature { return jpeg }
            guard marker == 0xE0 || marker == 0xE1 else { break }
            offset += 2 + length
        }
        let chunkSize = 65535 - 2 - signature.count - 2
        let chunks = stride(from: 0, to: profile.count, by: chunkSize).map {
            profile[profile.startIndex + $0 ..< profile.startIndex + min($0 + chunkSize, profile.count)]
        }
        guard chunks.count <= 255 else { return jpeg }
        var segments: [UInt8] = []
        for (index, chunk) in chunks.enumerated() {
            let length = 2 + signature.count + 2 + chunk.count
            segments += [0xFF, 0xE2, UInt8(length >> 8), UInt8(length & 0xFF)] + signature + [UInt8(index + 1), UInt8(chunks.count)] + chunk
        }
        return Data(bytes[..<offset] + segments + bytes[offset...])
    }

    static func deviceSpace(_ name: String) -> (CGColorSpace, Int)? {
        switch name {
        case "DeviceRGB", "CalRGB": (CGColorSpace(name: CGColorSpace.sRGB)!, 3)
        case "DeviceGray", "CalGray": (CGColorSpaceCreateDeviceGray(), 1)
        case "DeviceCMYK": (CGColorSpaceCreateDeviceCMYK(), 4)
        default: nil
        }
    }

    static func arraySpace(_ array: CGPDFArrayRef) -> (CGColorSpace, Int)? {
        var kindPointer: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(array, 0, &kindPointer), let kindPointer else { return nil }
        switch String(cString: kindPointer) {
        case "ICCBased":
            var stream: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, 1, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
            let components = integer(dictionary, "N") ?? 3
            var format = CGPDFDataFormat.raw
            if let profile = CGPDFStreamCopyData(stream, &format), let space = CGColorSpace(iccData: profile),
               space.numberOfComponents == components
            {
                return (space, components)
            }
            return components == 1 ? deviceSpace("DeviceGray") : components == 4 ? deviceSpace("DeviceCMYK") : deviceSpace("DeviceRGB")
        case "CalRGB": return deviceSpace("DeviceRGB")
        case "CalGray": return deviceSpace("DeviceGray")
        case "Indexed":
            var baseName: UnsafePointer<CChar>?
            var base: (CGColorSpace, Int)?
            if CGPDFArrayGetName(array, 1, &baseName), let baseName {
                base = deviceSpace(String(cString: baseName))
            } else {
                var baseArray: CGPDFArrayRef?
                if CGPDFArrayGetArray(array, 1, &baseArray), let baseArray { base = arraySpace(baseArray) }
            }
            guard let base else { return nil }
            var high: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, 2, &high), high >= 0, high < 256 else { return nil }
            var table = Data()
            var string: CGPDFStringRef?
            var stream: CGPDFStreamRef?
            if CGPDFArrayGetString(array, 3, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            } else if CGPDFArrayGetStream(array, 3, &stream), let stream {
                var format = CGPDFDataFormat.raw
                table = (CGPDFStreamCopyData(stream, &format) as Data?) ?? Data()
            }
            let needed = (Int(high) + 1) * base.1
            guard table.count >= needed else { return nil }
            let space = table.withUnsafeBytes { buffer -> CGColorSpace? in
                guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return CGColorSpace(indexedBaseSpace: base.0, last: Int(high), colorTable: pointer)
            }
            return space.map { ($0, 1) }
        default:
            return nil
        }
    }

    static func colorSpaceComponents(_ dictionary: CGPDFDictionaryRef) -> Int {
        colorSpace(dictionary)?.1 ?? 3
    }

    static func hasStream(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var stream: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(dictionary, key, &stream)
    }

    static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var pointer: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &pointer), let pointer else { return nil }
        return String(cString: pointer)
    }

    static func integer(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Int? {
        var value: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, key, &value) else { return nil }
        // Values come from the PDF; clamping keeps the row and buffer arithmetic from overflowing.
        return min(max(Int(value), 0), 200_000)
    }
}

private extension [CGFloat]? {
    func withOptionalPointer<R>(_ body: (UnsafePointer<CGFloat>?) -> R) -> R {
        switch self {
        case let .some(values): values.withUnsafeBufferPointer { body($0.baseAddress) }
        case .none: body(nil)
        }
    }
}
