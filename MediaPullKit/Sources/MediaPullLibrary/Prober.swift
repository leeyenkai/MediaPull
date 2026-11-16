import CoreGraphics
import Foundation
import MediaPullCore
import MediaPullMedia
import MediaPullNet

/// Fills in unknown size, format and duration with one range request per variant (SPEC R-911).
public actor MediaProber {
    private let gate: NetworkGate
    private var cache: [String: ProbeResult] = [:]
    private var inflight: [String: Task<ProbeResult, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public var maxConcurrent = 6

    public init(gate: NetworkGate) {
        self.gate = gate
    }

    public func cached(_ id: String) -> ProbeResult? { cache[id] }

    public func probe(_ variant: MediaVariant, context: RequestContext) async -> ProbeResult {
        if let cached = cache[variant.id] { return cached }
        if let running = inflight[variant.id] { return await running.value }
        let task = Task { await self.run(variant, context: context) }
        inflight[variant.id] = task
        let result = await task.value
        inflight[variant.id] = nil
        cache[variant.id] = result
        if cache.count > 20000 { cache.removeAll(keepingCapacity: true) }
        return result
    }

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func run(_ variant: MediaVariant, context: RequestContext) async -> ProbeResult {
        if variant.url.scheme == "data" {
            let data = SavePipeline.decodeDataURI(variant.url.absoluteString) ?? Data()
            return Self.analyze(data, total: Int64(data.count), contentType: nil)
        }
        if variant.url.isFileURL {
            let data = (try? FileHandle(forReadingFrom: variant.url)).flatMap { handle -> Data? in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 1 << 20)
            } ?? Data()
            let size = (try? FileManager.default.attributesOfItem(atPath: variant.url.path)[.size] as? NSNumber)?.int64Value
            return Self.analyze(data, total: size, contentType: nil)
        }
        guard variant.url.scheme == "https" || variant.url.scheme == "http" else { return ProbeResult() }
        await acquire()
        defer { release() }
        do {
            let (data, response) = try await gate.head(.get(variant.url, purpose: .probe, context: context), maxBytes: 65536)
            guard (200 ..< 300).contains(response.statusCode) else { return ProbeResult(failedStatus: response.statusCode) }
            let total = Self.totalSize(response, received: data.count)
            var result = Self.analyze(data, total: total, contentType: response.value(forHTTPHeaderField: "Content-Type"))
            // Follow-up ranges only when the server honours ranges, and never more than the range asked for.
            let rangesWork = response.statusCode == 206
                || response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
            if rangesWork, let format = result.format, format.kind == .image || format.kind == .animatedImage, result.pixelSize == nil,
               let total, total > Int64(data.count)
            {
                var more = GatedRequest.get(variant.url, purpose: .probe, context: context)
                let end = min(total, 1_048_576) - 1
                more.range = "bytes=\(data.count)-\(end)"
                if let (extra, extraResponse) = try? await gate.head(more, maxBytes: Int(end) - data.count + 1), extraResponse.statusCode == 206 {
                    result.pixelSize = ImageProbe.size(from: data + extra, complete: Int64(data.count + extra.count) >= total)
                }
            }
            if rangesWork, result.format?.kind == .video, result.pixelSize == nil, let total, total > Int64(data.count) {
                var tail = GatedRequest.get(variant.url, purpose: .probe, context: context)
                let start = max(Int64(data.count), total - 1_048_576)
                tail.range = "bytes=\(start)-\(total - 1)"
                if let (tailData, tailResponse) = try? await gate.head(tail, maxBytes: Int(total - start)), tailResponse.statusCode == 206,
                   let info = MP4Probe.info(from: tailData)
                {
                    result.pixelSize = info.size
                    result.duration = info.duration
                }
            }
            if result.format == .hls, let text = String(data: data, encoding: .utf8) {
                result.pixelSize = Self.bestHLSResolution(text)
            }
            if result.format == .dash, let text = String(data: data, encoding: .utf8) {
                result.pixelSize = Self.bestDASHResolution(text)
            }
            return result
        } catch {
            if case let GateError.http(status) = error { return ProbeResult(failedStatus: status) }
            return ProbeResult()
        }
    }

    static func totalSize(_ response: HTTPURLResponse, received: Int) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") {
            return Int64(range[range.index(after: slash)...])
        }
        if response.statusCode == 200, let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
            return length
        }
        return nil
    }

    static func analyze(_ data: Data, total: Int64?, contentType: String?) -> ProbeResult {
        let sniff = Sniffer.sniff(data)
        var result = ProbeResult(format: sniff.format ?? contentType.flatMap(MediaFormat.fromMIME), byteCount: total, isMarkup: sniff.isMarkup)
        guard let format = result.format else { return result }
        switch format.kind {
        case .image, .animatedImage:
            result.pixelSize = ImageProbe.size(from: data, complete: total.map { $0 <= Int64(data.count) } ?? false)
        case .video:
            if let info = MP4Probe.info(from: data) {
                result.pixelSize = info.size
                result.duration = info.duration
            }
        default:
            break
        }
        return result
    }

    static func bestHLSResolution(_ text: String) -> PixelSize? {
        var best: PixelSize?
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let range = line.range(of: "RESOLUTION=") else { continue }
            let value = line[range.upperBound...].prefix { $0 != "," }
            let parts = value.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 {
                let size = PixelSize(width: parts[0], height: parts[1])
                if best == nil || size.pixels > best!.pixels { best = size }
            }
        }
        return best
    }

    static func bestDASHResolution(_ text: String) -> PixelSize? {
        guard let regex = try? NSRegularExpression(pattern: #"width="(\d+)"[^>]*height="(\d+)""#) else { return nil }
        var best: PixelSize?
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString
            if let width = Int(ns.substring(with: match.range(at: 1))), let height = Int(ns.substring(with: match.range(at: 2))) {
                let size = PixelSize(width: width, height: height)
                if best == nil || size.pixels > best!.pixels { best = size }
            }
        }
        return best
    }
}

/// A decoded thumbnail that can cross actor boundaries.
public final class Thumbnail: @unchecked Sendable {
    public let image: CGImage
    public init(_ image: CGImage) {
        self.image = image
    }
}

/// Loads downsampled thumbnails through the gate, caching within a byte budget (SPEC R-1002).
public actor ThumbnailLoader {
    private let gate: NetworkGate
    private let cache = NSCache<NSString, Thumbnail>()
    private var inflight: [String: Task<Thumbnail?, Never>] = [:]
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(gate: NetworkGate, budgetBytes: Int = 150 << 20) {
        self.gate = gate
        cache.totalCostLimit = budgetBytes
    }

    public func thumbnail(for url: URL, maxPixel: Int, context: RequestContext) async -> Thumbnail? {
        let key = "\(url.absoluteString)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        if let running = inflight[key as String] { return await running.value }
        let task = Task<Thumbnail?, Never> {
            await self.acquire()
            defer { self.release() }
            return await Self.load(url, maxPixel: maxPixel, context: context, gate: self.gate)
        }
        inflight[key as String] = task
        let result = await task.value
        inflight[key as String] = nil
        if let result {
            cache.setObject(result, forKey: key, cost: result.image.width * result.image.height * 4)
        }
        return result
    }

    public func localThumbnail(for file: URL, maxPixel: Int) async -> Thumbnail? {
        let key = "file:\(file.path)#\(maxPixel)" as NSString
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
        let stamp = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let stampedKey = "\(key)#\(stamp)" as NSString
        if let hit = cache.object(forKey: stampedKey) { return hit }
        await acquire()
        defer { release() }
        let image = await Self.decodeLocal(file, maxPixel: maxPixel)
        guard let image else { return nil }
        let thumbnail = Thumbnail(image)
        cache.setObject(thumbnail, forKey: stampedKey, cost: image.width * image.height * 4)
        return thumbnail
    }

    @concurrent
    static func decodeLocal(_ file: URL, maxPixel: Int) async -> CGImage? {
        let ext = file.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            return await Thumbnailer.videoFrame(at: file, maxPixel: maxPixel)
        }
        return Thumbnailer.image(at: file, maxPixel: maxPixel)
    }

    private func acquire() async {
        if active < 4 {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    @concurrent
    static func load(_ url: URL, maxPixel: Int, context: RequestContext, gate: NetworkGate) async -> Thumbnail? {
        if url.isFileURL {
            return Thumbnailer.image(at: url, maxPixel: maxPixel).map(Thumbnail.init)
        }
        let data: Data
        if url.scheme == "data" {
            guard let decoded = SavePipeline.decodeDataURI(url.absoluteString) else { return nil }
            data = decoded
        } else {
            guard url.scheme == "https" || url.scheme == "http",
                  let (body, response) = try? await gate.data(.get(url, purpose: .thumbnail, context: context)),
                  (200 ..< 300).contains(response.statusCode)
            else { return nil }
            data = body
        }
        return Thumbnailer.image(from: data, maxPixel: maxPixel).map(Thumbnail.init)
    }
}
