import Foundation
import MediaPullCore
import MediaPullEngines
import MediaPullNet

public enum EngineFetchError: LocalizedError, Sendable {
    case checkpoint(kind: String, url: URL?, message: String)
    case failed(String)
    case nothingDownloaded

    public var errorDescription: String? {
        switch self {
        case let .checkpoint(kind, _, _):
            switch kind {
            case "login": "Instagram asked you to sign in again."
            case "rate_limit": "Instagram is limiting requests. Wait a while before trying again."
            default: "Instagram asked for verification. Open the page in the browser pane to continue."
            }
        case let .failed(message): message
        case .nothingDownloaded: "The download engine did not return a file."
        }
    }
}

/// Fetches DASH videos, streams and refreshed signed URLs through the bridge.
public struct BridgeEngineFetcher: EngineFetching {
    public let client: BridgeClient
    public let video: VideoCodecPolicy
    public let cookies: @Sendable (_ registrableDomain: String) async -> [CookieRecord]
    public let userAgent: String?
    public let onCheckpoint: @Sendable (String, URL?) -> Void

    public init(
        client: BridgeClient,
        video: VideoCodecPolicy,
        userAgent: String?,
        cookies: @escaping @Sendable (String) async -> [CookieRecord],
        onCheckpoint: @escaping @Sendable (String, URL?) -> Void = { _, _ in }
    ) {
        self.client = client
        self.video = video
        self.userAgent = userAgent
        self.cookies = cookies
        self.onCheckpoint = onCheckpoint
    }

    public func fetch(_ item: MediaItem, variant: MediaVariant?, workDirectory: URL, progress: @escaping @Sendable (Double?) -> Void)
        async throws -> URL
    {
        let job = UUID().uuidString
        let staging = workDirectory.appendingPathComponent("engine-\(job.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let cookieFile = CookieFile.privateLocation(job: job)
        defer { try? FileManager.default.removeItem(at: cookieFile.deletingLastPathComponent()) }

        var request: BridgeRequest
        var isInstagram = false
        let selector = video.selector(av1Decodable: FFmpeg.canDecodeAV1)
        switch item.source {
        case let .engine(context):
            request = BridgeRequest(op: "fetch")
            let postURL = context.postURL?.absoluteString
                ?? context.postShortcode.map { "https://www.instagram.com/p/\($0)/" }
                ?? context.sourceURL?.absoluteString
            guard let postURL else { throw EngineFetchError.failed("This item has no post address to fetch it from.") }
            request.url = postURL
            if let num = context.num { request.filter = "num == \(num)" }
            let domain = PublicSuffix.shared.registrableDomain(URL(string: postURL)?.host ?? "instagram.com")
            isInstagram = context.category == "instagram" || domain == "instagram.com"
            try CookieFile.write(await cookies(domain), to: cookieFile)
            request.cookies = cookieFile.path
            request.userAgent = userAgent
            request.setPacing([2, 4])
        case let .web(context):
            request = BridgeRequest(op: "stream")
            guard let url = variant?.url ?? item.best?.url ?? item.variants.first?.url else { throw EngineFetchError.nothingDownloaded }
            request.url = url.absoluteString
            request.referer = URLNormalizer.referer(for: url, from: context.frameURL ?? context.pageURL)
            request.userAgent = userAgent
            if URLNormalizer.isSameSite(context.pageURL, url) {
                let domain = PublicSuffix.shared.registrableDomain(url.host ?? "")
                try CookieFile.write(await cookies(domain), to: cookieFile)
                request.cookies = cookieFile.path
            }
            request.key = item.id
        }
        request.staging = staging.path
        request.video = BridgeRequest.Video(format: selector.format, formatSort: selector.sort)

        var file: URL?
        var failure: String?
        for try await event in client.run(request, workingDirectory: staging) {
            switch event {
            case let .file(found):
                if file == nil, found.isInside(staging) { file = found.path }
            case let .progress(received, total, _):
                if let received, let total, total > 0 { progress(Double(received) / Double(total)) }
            case let .checkpoint(kind, url, message):
                // Only Instagram has a cooldown and a sign-in to send the person to; any other site's limit is a failure.
                guard isInstagram else {
                    failure = message
                    continue
                }
                onCheckpoint(kind, url)
                throw EngineFetchError.checkpoint(kind: kind, url: url, message: message)
            case let .error(_, message, _, fatal):
                if fatal || failure == nil { failure = message }
            case let .policyViolation(method, host, _, reason):
                failure = "Blocked a \(method) request to \(host): \(reason)"
            default:
                break
            }
        }
        if let file, FileManager.default.fileExists(atPath: file.path) { return file }
        throw failure.map { EngineFetchError.failed($0) } ?? EngineFetchError.nothingDownloaded
    }
}
