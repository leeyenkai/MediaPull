import Foundation

/// What a file's first bytes say it is. Twelve to a few hundred bytes are enough.
public struct SniffResult: Equatable, Sendable {
    public var format: MediaFormat?
    /// HTML, JSON or other text served where media was expected.
    public var isMarkup: Bool
    public var webp: WebPInfo?
    public var isAnimatedPNG: Bool

    public init(format: MediaFormat? = nil, isMarkup: Bool = false, webp: WebPInfo? = nil, isAnimatedPNG: Bool = false) {
        self.format = format
        self.isMarkup = isMarkup
        self.webp = webp
        self.isAnimatedPNG = isAnimatedPNG
    }
}

public struct WebPInfo: Equatable, Sendable {
    public var lossless: Bool
    public var alpha: Bool
    public var animated: Bool
}

public enum Sniffer {
    public static func sniff(_ data: Data) -> SniffResult {
        let bytes = [UInt8](data.prefix(4096))
        guard !bytes.isEmpty else { return SniffResult() }

        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset ..< offset + prefix.count]) == prefix
        }
        func ascii(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        if starts([0xFF, 0xD8, 0xFF]) { return SniffResult(format: .jpeg) }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return SniffResult(format: .png, isAnimatedPNG: pngIsAnimated(bytes))
        }
        if ascii("GIF87a") || ascii("GIF89a") { return SniffResult(format: .gif) }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return SniffResult(format: .webp, webp: webpInfo(bytes)) }
        if ascii("RIFF"), ascii("WAVE", at: 8) { return SniffResult(format: .wav) }
        if ascii("ftyp", at: 4) { return SniffResult(format: isoFormat(bytes)) }
        if starts([0xFF, 0x0A]) || starts([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) {
            return SniffResult(format: .jxl)
        }
        if ascii("BM"), bytes.count > 14 { return SniffResult(format: .bmp) }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return SniffResult(format: .tiff) }
        if starts([0x00, 0x00, 0x01, 0x00]) || starts([0x00, 0x00, 0x02, 0x00]) { return SniffResult(format: .ico) }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) {
            let head = String(decoding: bytes.prefix(64), as: UTF8.self)
            return SniffResult(format: head.contains("webm") ? .webm : .mkv)
        }
        if ascii("ID3") || (bytes.count > 1 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 && (bytes[1] & 0x06) != 0) {
            return SniffResult(format: .mp3)
        }
        if ascii("OggS") {
            let head = String(decoding: bytes.prefix(64), as: UTF8.self)
            return SniffResult(format: head.contains("OpusHead") ? .opus : .ogg)
        }
        if ascii("fLaC") { return SniffResult(format: .flac) }
        if bytes.count > 1, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return SniffResult(format: .aac) }

        let text = String(decoding: bytes.prefix(1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        let lower = text.lowercased()
        if lower.hasPrefix("#extm3u") { return SniffResult(format: .hls) }
        if lower.contains("<mpd") { return SniffResult(format: .dash) }
        if lower.contains("<svg") && !lower.contains("<html") { return SniffResult(format: .svg) }
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<head") || lower.hasPrefix("<body")
            || lower.hasPrefix("<?xml") || lower.hasPrefix("{") || lower.hasPrefix("[") || lower.hasPrefix("<")
        {
            return SniffResult(isMarkup: true)
        }
        return SniffResult()
    }

    private static func isoFormat(_ bytes: [UInt8]) -> MediaFormat? {
        guard bytes.count >= 12 else { return nil }
        let size = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        var brands: [String] = [String(decoding: bytes[8 ..< 12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= min(max(size, 16), bytes.count) {
            brands.append(String(decoding: bytes[offset ..< offset + 4], as: UTF8.self))
            offset += 4
        }
        let major = brands[0]
        if brands.contains(where: { $0 == "avif" || $0 == "avis" }) { return .avif }
        if ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"].contains(major) { return .heic }
        if major == "qt  " { return .mov }
        if major == "M4A " || major == "M4B " { return .m4a }
        if major == "crx " { return nil }
        return .mp4
    }

    private static func pngIsAnimated(_ bytes: [UInt8]) -> Bool {
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            if type == "acTL" { return true }
            if type == "IDAT" { return false }
            offset += 12 + length
        }
        return false
    }

    private static func webpInfo(_ bytes: [UInt8]) -> WebPInfo {
        var info = WebPInfo(lossless: false, alpha: false, animated: false)
        var offset = 12
        while offset + 8 <= bytes.count {
            let type = String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
            let length = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            switch type {
            case "VP8X":
                if offset + 8 < bytes.count {
                    let flags = bytes[offset + 8]
                    info.alpha = info.alpha || flags & 0x10 != 0
                    info.animated = flags & 0x02 != 0
                }
            case "VP8L":
                info.lossless = true
                info.alpha = true
                return info
            case "VP8 ":
                return info
            case "ALPH":
                info.alpha = true
            case "ANIM", "ANMF":
                info.animated = true
                return info
            default:
                break
            }
            offset += 8 + length + (length & 1)
        }
        return info
    }
}
