import CoreGraphics
import Foundation
import ImageIO
import MediaPullCore
import MediaPullEngines
import MediaPullMedia
import UniformTypeIdentifiers

public struct ConversionResult: Sendable {
    public var url: URL
    public var format: MediaFormat
    public var converted: Bool
    public var note: String?
    public var pixelSize: PixelSize?
    public var duration: Double?
}

public enum ConversionIssue: LocalizedError, Sendable {
    case notMedia
    case unknownFormat
    case notAllowed(String)
    case cannotDecode(String)

    public var errorDescription: String? {
        switch self {
        case .notMedia: "The site returned a web page instead of media."
        case .unknownFormat: "The file is not a format MediaPull recognises."
        case let .notAllowed(reason): reason
        case let .cannotDecode(reason): reason
        }
    }

    public var isSkip: Bool {
        if case .notAllowed = self { return true }
        return false
    }
}

/// Turns any downloaded file into a normal format, at the highest quality (SPEC section 16).
public struct MediaConverter: Sendable {
    public var ffmpeg: FFmpeg?
    /// Draws an SVG file at the given long-side pixel size. Supplied by the app's platform layer.
    public var svgRasterizer: (@Sendable (URL, Int) -> CGImage?)?

    public init(ffmpeg: FFmpeg?, svgRasterizer: (@Sendable (URL, Int) -> CGImage?)? = nil) {
        self.ffmpeg = ffmpeg?.isAvailable == true ? ffmpeg : nil
        self.svgRasterizer = svgRasterizer
    }

    /// Decodes and encodes whole images and runs ffmpeg: never on the caller's actor.
    @concurrent
    public func convert(_ file: URL, policy: ConversionPolicy, layout: SaveLayout, workDirectory: URL) async throws -> ConversionResult {
        let head = Self.head(of: file)
        let sniff = Sniffer.sniff(head)
        guard let format = sniff.format else {
            throw sniff.isMarkup ? ConversionIssue.notMedia : ConversionIssue.unknownFormat
        }
        if policy.keepDownloadedMedia, format.kind == .video || format.kind == .audio {
            // M4A audio and MP4 video share their first bytes; the extension the engine gave the file tells them apart.
            let named = MediaFormat.fromExtension(file.pathExtension)
            let kept = named.map { $0.kind == .video || $0.kind == .audio } == true ? named! : format
            return ConversionResult(url: file, format: kept, converted: false)
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        switch format.kind {
        case .image, .animatedImage:
            return try await convertImage(file, format: format, policy: policy, layout: layout, workDirectory: workDirectory)
        case .vector:
            if layout == .plain { return ConversionResult(url: file, format: .svg, converted: false) }
            guard policy.rasterizeSVGInArchive, let svgRasterizer else {
                throw ConversionIssue.notAllowed("SVG files are saved only in the Plain layout.")
            }
            return try rasterize(file, with: svgRasterizer, workDirectory: workDirectory)
        case .video:
            return try await convertVideo(file, format: format, policy: policy, workDirectory: workDirectory)
        case .audio:
            if layout == .plain { return ConversionResult(url: file, format: format, converted: false) }
            throw ConversionIssue.notAllowed("Audio files are saved only in the Plain layout.")
        case .stream:
            throw ConversionIssue.notAllowed("Streams must be downloaded with the stream downloader.")
        }
    }

    public static func head(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)) ?? Data()
    }

    // MARK: Images

    func convertImage(_ file: URL, format: MediaFormat, policy: ConversionPolicy, layout: SaveLayout, workDirectory: URL) async throws
        -> ConversionResult
    {
        // An APNG is converted like any animation: GIF by default, MP4 or APNG as chosen (SPEC 16.1, D-06).
        if format == .png, policy.animated != .apng, let analysis = ImageConversion.analyze(file), analysis.isAnimated {
            let size = PixelSize(width: analysis.width, height: analysis.height)
            return try await convertAnimated(file, policy: policy.animated, size: size, workDirectory: workDirectory)
        }
        if format == .jpeg || format == .gif || format == .png {
            let analysis = ImageConversion.analyze(file)
            return ConversionResult(url: file, format: format, converted: false,
                                    pixelSize: analysis.map { PixelSize(width: $0.width, height: $0.height) })
        }
        guard ImageConversion.canDecode(format) || format == .ico, let analysis = ImageConversion.analyze(file) else {
            throw ConversionIssue.cannotDecode("This Mac cannot read \(format.label) images.")
        }
        let size = PixelSize(width: analysis.width, height: analysis.height)
        let keepModern = layout == .plain && policy.keepOriginalModernImages && [.webp, .avif, .heic, .jxl].contains(format)
        if keepModern { return ConversionResult(url: file, format: format, converted: false, pixelSize: size) }

        if analysis.isAnimated {
            return try await convertAnimated(file, policy: policy.animated, size: size, workDirectory: workDirectory)
        }
        let target = ImageConversion.stillTarget(for: analysis)
        let output = workDirectory.appendingPathComponent(UUID().uuidString + (target == .jpeg ? ".jpg" : ".png"))
        try ImageConversion.convertStill(file, to: target, output: output)
        let note = "Converted \(format.label) to \(target == .jpeg ? "JPEG (maximum quality)" : "PNG (lossless)")"
        return ConversionResult(url: output, format: target == .jpeg ? .jpeg : .png, converted: true, note: note, pixelSize: size)
    }

    func convertAnimated(_ file: URL, policy: AnimatedPolicy, size: PixelSize, workDirectory: URL) async throws -> ConversionResult {
        let plays = CGImageSourceCreateWithURL(file as CFURL, nil).map(ImageConversion.plays(of:)) ?? 0
        let cut = "; only the first \(ImageConversion.maxFrames) frames were kept"
        switch policy {
        case .apng:
            let (frames, _) = try ImageConversion.frames(of: file)
            let output = workDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try ImageConversion.writeAnimated(frames, plays: plays, as: .png, to: output)
            return ConversionResult(url: output, format: .png, converted: true,
                                    note: "Converted animation to animated PNG" + (frames.count == ImageConversion.maxFrames ? cut : ""),
                                    pixelSize: size)
        case .gif, .mp4:
            if let ffmpeg {
                let folder = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                // One frame decoded and written at a time: a long animation never sits in memory whole.
                var list = "ffconcat version 1.0\n"
                var index = 0
                let written = try ImageConversion.forEachFrame(of: file) { image, delay in
                    let name = String(format: "f%05d.png", index)
                    index += 1
                    try ImageConversion.writePNG(image, to: folder.appendingPathComponent(name))
                    list += "file '\(name)'\nduration \(String(format: "%.3f", max(delay, 0.02)))\n"
                }
                list += "file '\(String(format: "f%05d.png", written.count - 1))'\n"
                let listURL = folder.appendingPathComponent("frames.txt")
                try list.write(to: listURL, atomically: true, encoding: .utf8)
                let ext = policy == .gif ? "gif" : "mp4"
                let output = workDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
                do {
                    if policy == .gif {
                        try await ffmpeg.gif(fromConcatList: listURL, output: output, plays: plays)
                    } else {
                        try await ffmpeg.mp4(fromConcatList: listURL, output: output)
                    }
                    return ConversionResult(url: output, format: policy == .gif ? .gif : .mp4, converted: true,
                                            note: "Converted animation to \(policy.label)" + (written.truncated ? cut : ""), pixelSize: size)
                } catch where policy == .mp4 {
                    throw error
                } catch {
                    // Fall through to ImageIO's GIF writer.
                }
            }
            if policy == .mp4 { throw ConversionIssue.cannotDecode("Converting animations to video needs ffmpeg.") }
            let (frames, _) = try ImageConversion.frames(of: file)
            let output = workDirectory.appendingPathComponent(UUID().uuidString + ".gif")
            try ImageConversion.writeAnimated(frames, plays: plays, as: .gif, to: output)
            return ConversionResult(url: output, format: .gif, converted: true, note: "Converted animation to GIF", pixelSize: size)
        }
    }

    /// SVG to PNG at a size that keeps detail: four times its own size, at least 1024 and at most
    /// 4096 pixels on the long side (D-13).
    func rasterize(_ file: URL, with rasterizer: @Sendable (URL, Int) -> CGImage?, workDirectory: URL) throws -> ConversionResult {
        let intrinsic = Self.svgIntrinsicLongSide(file) ?? 512
        let longSide = min(4096, max(1024, intrinsic * 4))
        guard let image = rasterizer(file, longSide) else {
            throw ConversionIssue.cannotDecode("This SVG could not be drawn.")
        }
        let output = workDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try ImageConversion.writePNG(image, to: output)
        return ConversionResult(url: output, format: .png, converted: true, note: "Converted SVG to PNG",
                                pixelSize: PixelSize(width: image.width, height: image.height))
    }

    static func svgIntrinsicLongSide(_ file: URL) -> Int? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let header = String(text.prefix(4000))
        func number(_ name: String) -> Double? {
            guard let range = header.range(of: name + #"="\s*([0-9.]+)"#, options: .regularExpression) else { return nil }
            return Double(header[range].filter { $0.isNumber || $0 == "." })
        }
        if let width = number("width"), let height = number("height") { return Int(min(max(width, height, 0), 100_000)) }
        if let range = header.range(of: #"viewBox="[^"]+""#, options: .regularExpression) {
            let parts = header[range].dropFirst(9).dropLast().split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            if parts.count == 4, parts[2].isFinite, parts[3].isFinite { return Int(min(max(parts[2], parts[3], 0), 100_000)) }
        }
        return nil
    }

    // MARK: Video

    func convertVideo(_ file: URL, format: MediaFormat, policy: ConversionPolicy, workDirectory: URL) async throws -> ConversionResult {
        guard let ffmpeg else {
            if format == .mp4 || format == .mov { return ConversionResult(url: file, format: format, converted: false) }
            throw ConversionIssue.cannotDecode("Converting \(format.label) video needs ffmpeg.")
        }
        let info = (try? await ffmpeg.probe(file)) ?? VideoStreamInfo()
        let size = info.width.flatMap { width in info.height.map { PixelSize(width: width, height: $0) } }
        let codec = info.videoCodec?.lowercased() ?? ""
        let isMP4Family = format == .mp4 || format == .mov
        let incompatible = info.needsReencodeForCompatibility
        let output = workDirectory.appendingPathComponent(UUID().uuidString + ".mp4")

        // An MP4 with sound and no picture is audio (an .m4a), which Archive folders do not take (D-13, R-1502).
        if info.videoCodec == nil, info.audioCodec != nil, isMP4Family || format == .m4a {
            if !info.audioNeedsConversion { return ConversionResult(url: file, format: .m4a, converted: false, duration: info.duration) }
            let audio = workDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            try await ffmpeg.remuxToMP4(file, output: audio, convertAudio: true)
            return ConversionResult(url: audio, format: .m4a, converted: true, note: "Audio converted to AAC", duration: info.duration)
        }
        if !incompatible {
            if isMP4Family, !info.audioNeedsConversion, !info.needsHVC1Tag {
                return ConversionResult(url: file, format: format, converted: false, pixelSize: size, duration: info.duration)
            }
            try await ffmpeg.remuxToMP4(file, output: output, convertAudio: info.audioNeedsConversion, hevc: info.needsHVC1Tag)
            return ConversionResult(url: output, format: .mp4, converted: true, note: "Repackaged as MP4 without re-encoding",
                                    pixelSize: size, duration: info.duration)
        }
        // "Highest compatible" never re-encodes (R-1607): when only VP9 or AV1 was there, it is kept as it is.
        if policy.video == .keepOriginal || policy.video == .highestCompatible {
            try await ffmpeg.remuxToMP4(file, output: output, convertAudio: info.audioNeedsConversion)
            return ConversionResult(url: output, format: .mp4, converted: true,
                                    note: "Kept \(codec.uppercased()) video in MP4 (may not play in QuickTime)", pixelSize: size,
                                    duration: info.duration)
        }
        if codec == "av1", !FFmpeg.canDecodeAV1 {
            throw ConversionIssue.cannotDecode("This Mac cannot decode AV1 video, so it cannot be converted to HEVC.")
        }
        do {
            try await ffmpeg.transcodeToHEVC(file, output: output, convertAudio: info.audioNeedsConversion, hardwareDecode: codec == "av1")
        } catch {
            // A conversion that fails is treated like one that cannot be done, so the next version, or the original
            // codec, is used with a note (D-32), never a failed save.
            throw ConversionIssue.cannotDecode("The \(codec.uppercased()) video could not be converted to HEVC: \(error.localizedDescription)")
        }
        return ConversionResult(url: output, format: .mp4, converted: true, note: "Converted \(codec.uppercased()) to HEVC",
                                pixelSize: size, duration: info.duration)
    }
}
