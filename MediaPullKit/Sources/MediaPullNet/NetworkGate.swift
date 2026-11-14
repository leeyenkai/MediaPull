import Foundation
import MediaPullCore

public enum RequestPurpose: String, Codable, Sendable {
    case thumbnail, preview, probe, rewriteCheck, save, engineUpdate
}

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
}

/// A cookie as stored in the browser pane, kept as plain values so it can cross actors.
public struct CookieRecord: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    public var expires: Date?

    public init(name: String, value: String, domain: String, path: String, isSecure: Bool, isHTTPOnly: Bool, expires: Date?) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expires = expires
    }

    public init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly, expires: cookie.expiresDate
        )
    }

    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if isSecure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if isSecure, url.scheme != "https" { return false }
        if let expires, expires < Date() { return false }
        let domain = domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard host == bare || host.hasSuffix("." + bare) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return path.isEmpty || path == "/" || requestPath.hasPrefix(path)
    }
}

/// A snapshot of the browser pane's cookies.
public struct CookieJar: Sendable {
    public var cookies: [CookieRecord]

    public init(cookies: [CookieRecord] = []) {
        self.cookies = cookies
    }

    public func header(for url: URL) -> String? {
        let matching = cookies.filter { $0.matches(url) }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func cookies(forRegistrableDomain domain: String) -> [CookieRecord] {
        cookies.filter { cookie in
            let bare = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return PublicSuffix.shared.registrableDomain(bare) == domain
        }
    }
}

public struct RequestContext: Sendable {
    public var referer: String?
    public var cookieHeader: String?
    public var accept: String?
    public var userAgent: String?
    public var extraHeaders: [String: String]

    public init(referer: String? = nil, cookieHeader: String? = nil, accept: String? = nil, userAgent: String? = nil,
                extraHeaders: [String: String] = [:])
    {
        self.referer = referer
        self.cookieHeader = cookieHeader
        self.accept = accept
        self.userAgent = userAgent
        self.extraHeaders = extraHeaders
    }

    public static let imageAccept = "image/jpeg,image/png,image/gif;q=0.9,image/*;q=0.5,*/*;q=0.1"
    public static let anyAccept = "*/*"
}

/// The only kind of request MediaPull's Swift code can make (SPEC R-501). There is no way to set
/// a method other than GET or HEAD, or to attach a body.
public struct GatedRequest: Sendable {
    public let method: HTTPMethod
    public let url: URL
    public let purpose: RequestPurpose
    public var context: RequestContext
    public var range: String?
    public var timeout: TimeInterval

    private init(method: HTTPMethod, url: URL, purpose: RequestPurpose, context: RequestContext) {
        self.method = method
        self.url = url
        self.purpose = purpose
        self.context = context
        timeout = purpose == .save ? 120 : 30
    }

    public static func get(_ url: URL, purpose: RequestPurpose, context: RequestContext = RequestContext()) -> GatedRequest {
        GatedRequest(method: .get, url: url, purpose: purpose, context: context)
    }

    public static func head(_ url: URL, purpose: RequestPurpose, context: RequestContext = RequestContext()) -> GatedRequest {
        GatedRequest(method: .head, url: url, purpose: purpose, context: context)
    }
}

public enum PolicyDecision: Equatable, Sendable {
    case allowed
    case denied(String)
}

public enum RequestPolicy {
    public static let allowedHeaders: Set<String> = [
        "accept", "accept-language", "range", "referer", "cookie", "user-agent", "if-none-match", "if-modified-since",
    ]

    public static func evaluate(method: String, url: URL, headers: [String: String], hasBody: Bool) -> PolicyDecision {
        guard method == "GET" || method == "HEAD" else { return .denied("Only GET and HEAD requests are allowed.") }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .denied("Only http and https addresses are allowed.")
        }
        if hasBody { return .denied("Requests never carry a body.") }
        for name in headers.keys where !allowedHeaders.contains(name.lowercased()) {
            return .denied("The header \(name) is not allowed.")
        }
        return .allowed
    }

    public static func urlRequest(for request: GatedRequest) -> Result<URLRequest, GateError> {
        var headers: [String: String] = [:]
        if let accept = request.context.accept { headers["Accept"] = accept }
        if let referer = request.context.referer { headers["Referer"] = referer }
        if let cookie = request.context.cookieHeader { headers["Cookie"] = cookie }
        if let agent = request.context.userAgent { headers["User-Agent"] = agent }
        if let range = request.range { headers["Range"] = range }
        for (name, value) in request.context.extraHeaders where allowedHeaders.contains(name.lowercased()) {
            headers[name] = value
        }
        switch evaluate(method: request.method.rawValue, url: request.url, headers: headers, hasBody: false) {
        case let .denied(reason):
            return .failure(.denied(reason))
        case .allowed:
            var urlRequest = URLRequest(url: request.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: request.timeout)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.httpShouldHandleCookies = false
            for (name, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            return .success(urlRequest)
        }
    }
}

public enum GateError: LocalizedError, Sendable, Equatable {
    case denied(String)
    case http(Int)
    case notHTTP
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .denied(reason): "MediaPull refused to send a request: \(reason)"
        case let .http(status): Self.message(for: status)
        case .notHTTP: "The server did not answer with HTTP."
        case .cancelled: "Cancelled."
        }
    }

    static func message(for status: Int) -> String {
        switch status {
        case 401, 403: "The site refused access to this file (\(status))."
        case 404, 410: "The file no longer exists on the site (\(status))."
        case 429: "The site is limiting requests (429). Try again later."
        case 500 ..< 600: "The site had a server error (\(status))."
        default: "The site answered with status \(status)."
        }
    }
}

public struct EgressEntry: Identifiable, Sendable {
    public let id: Int
    public let time: Date
    public let method: String
    public let host: String
    public let path: String
    public let purpose: RequestPurpose
    public var status: Int?
    public var bytes: Int64?
}

/// The single choke point for MediaPull's own network traffic (SPEC 5.2).
public actor NetworkGate {
    public static let shared = NetworkGate()

    private let session: URLSession
    private var log: [EgressEntry] = []
    private var counter = 0
    private let limiter = HostLimiter()
    public static let logCapacity = 2000

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? {
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            config.httpMaximumConnectionsPerHost = 6
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600
            config.waitsForConnectivity = false
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("MediaPull/URLCache", isDirectory: true)
            config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, directory: caches)
            return config
        }()
        session = URLSession(configuration: config)
    }

    public func entries() -> [EgressEntry] { log }

    private func record(_ request: GatedRequest) -> Int {
        counter += 1
        let entry = EgressEntry(
            id: counter, time: Date(), method: request.method.rawValue, host: request.url.host ?? "",
            path: request.url.path, purpose: request.purpose
        )
        log.append(entry)
        if log.count > Self.logCapacity { log.removeFirst(log.count - Self.logCapacity) }
        return counter
    }

    private func finish(_ id: Int, status: Int?, bytes: Int64?) {
        if let index = log.lastIndex(where: { $0.id == id }) {
            log[index].status = status
            log[index].bytes = bytes
        }
    }

    private func prepare(_ request: GatedRequest) throws -> URLRequest {
        switch RequestPolicy.urlRequest(for: request) {
        case let .success(urlRequest): return urlRequest
        case let .failure(error): throw error
        }
    }

    /// The whole body of a small response.
    public func data(_ request: GatedRequest) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try prepare(request)
        let id = record(request)
        let host = request.url.host ?? ""
        await limiter.acquire(host)
        defer { Task { await limiter.release(host) } }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            finish(id, status: http.statusCode, bytes: Int64(data.count))
            return (data, http)
        } catch let error as GateError {
            // An HTTP status was already recorded; keep it in the request log.
            if case .http = error {} else { finish(id, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(id, status: nil, bytes: nil)
            throw Self.mapped(error)
        }
    }

    /// At most `maxBytes` from the start of a resource. The connection closes once enough arrived.
    public func head(_ request: GatedRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.method == .get, request.range == nil { request.range = "bytes=0-\(maxBytes - 1)" }
        let urlRequest = try prepare(request)
        let id = record(request)
        let host = request.url.host ?? ""
        await limiter.acquire(host)
        defer { Task { await limiter.release(host) } }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 65536))
            if request.method == .get, (200 ..< 300).contains(http.statusCode) {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= maxBytes { break }
                }
            }
            bytes.task.cancel()
            finish(id, status: http.statusCode, bytes: Int64(data.count))
            return (data, http)
        } catch let error as GateError {
            // An HTTP status was already recorded; keep it in the request log.
            if case .http = error {} else { finish(id, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(id, status: nil, bytes: nil)
            throw Self.mapped(error)
        }
    }

    /// Downloads to `destination`, reporting progress. Throws for non-2xx answers.
    public func download(
        _ request: GatedRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> HTTPURLResponse {
        let urlRequest = try prepare(request)
        let id = record(request)
        let host = request.url.host ?? ""
        await limiter.acquire(host)
        defer { Task { await limiter.release(host) } }
        let delegate = DownloadProgressDelegate(progress: progress)
        do {
            let (location, response) = try await session.download(for: urlRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            guard (200 ..< 300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: location)
                finish(id, status: http.statusCode, bytes: nil)
                throw GateError.http(http.statusCode)
            }
            let manager = FileManager.default
            try? manager.removeItem(at: destination)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: location, to: destination)
            let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            finish(id, status: http.statusCode, bytes: size)
            return http
        } catch let error as GateError {
            // An HTTP status was already recorded; keep it in the request log.
            if case .http = error {} else { finish(id, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(id, status: nil, bytes: nil)
            throw Self.mapped(error)
        }
    }

    static func mapped(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled { return GateError.cancelled }
        if error is CancellationError { return GateError.cancelled }
        return error
    }
}

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64?) -> Void
    private var last = Date.distantPast

    init(progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.progress = progress
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64)
    {
        let now = Date()
        guard now.timeIntervalSince(last) > 0.2 else { return }
        last = now
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
}

/// Limits concurrent requests per host (SPEC 4.4).
public actor HostLimiter {
    private var active: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var total = 0
    private var totalWaiting: [(String, CheckedContinuation<Void, Never>)] = []
    public var perHost = 6
    public var maximum = 16

    public init() {}

    private func limit(for host: String) -> Int {
        if host.hasSuffix("cdninstagram.com") || host.hasSuffix("fbcdn.net") { return 2 }
        return perHost
    }

    public func acquire(_ host: String) async {
        if active[host, default: 0] < limit(for: host), total < maximum {
            active[host, default: 0] += 1
            total += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting[host, default: []].append(continuation)
        }
    }

    public func release(_ host: String) {
        active[host, default: 1] -= 1
        total -= 1
        // Wake the next waiter for this host, or any host with spare capacity.
        if var queue = waiting[host], !queue.isEmpty, active[host, default: 0] < limit(for: host) {
            let next = queue.removeFirst()
            waiting[host] = queue
            active[host, default: 0] += 1
            total += 1
            next.resume()
            return
        }
        for (other, var queue) in waiting where !queue.isEmpty && active[other, default: 0] < limit(for: other) && total < maximum {
            let next = queue.removeFirst()
            waiting[other] = queue
            active[other, default: 0] += 1
            total += 1
            next.resume()
            return
        }
    }
}
