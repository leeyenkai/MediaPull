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
    /// "lax" or "strict"; nil when the cookie set none. Kept so a value written back keeps its protection.
    public var sameSite: String?

    public init(name: String, value: String, domain: String, path: String, isSecure: Bool, isHTTPOnly: Bool, expires: Date?,
                sameSite: String? = nil)
    {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.expires = expires
        self.sameSite = sameSite
    }

    public init(_ cookie: HTTPCookie) {
        self.init(
            name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path, isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly, expires: cookie.expiresDate, sameSite: cookie.sameSitePolicy?.rawValue
        )
    }

    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path.isEmpty ? "/" : path,
        ]
        if isSecure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if isSecure, url.scheme != "https" { return false }
        if let expires, expires < Date() { return false }
        let domain = domain.lowercased()
        // A cookie set without a Domain attribute is stored without the leading dot and belongs to that host alone.
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            guard host == bare || host.hasSuffix("." + bare) else { return false }
        } else {
            guard host == domain else { return false }
        }
        let requestPath = url.path.isEmpty ? "/" : url.path
        // RFC 6265 path match: /foo matches /foo and /foo/bar, never /foobar.
        return path.isEmpty || path == "/" || requestPath == path || requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
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
        // Plain http is for media only (D-21); engine updates come over https alone (R-502).
        if request.purpose == .engineUpdate, request.url.scheme?.lowercased() != "https" {
            return .failure(.denied("Engine updates are downloaded over https only."))
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

/// What may follow a redirect (SPEC R-501). The cookie header was chosen for the first origin, so it goes no further than
/// that exact scheme, host and port, and a hop from https to http is refused while cookies are attached. The Referer is
/// worked out again for every hop, as a browser does, so a full page address never reaches another site or plain http.
public enum RedirectPolicy {
    public static func nextHeaders(_ headers: [String: String], method: String, from: URL, to: URL) -> Result<[String: String], GateError> {
        let hasCookie = headers.keys.contains { $0.lowercased() == "cookie" }
        if hasCookie, from.scheme?.lowercased() == "https", to.scheme?.lowercased() != "https" {
            return .failure(.denied("A redirect to an insecure address would have exposed cookies."))
        }
        var next = headers
        let sameOrigin = from.scheme?.lowercased() == to.scheme?.lowercased() && from.host?.lowercased() == to.host?.lowercased()
            && from.port == to.port
        if hasCookie, !sameOrigin {
            next = next.filter { $0.key.lowercased() != "cookie" }
        }
        if let key = next.keys.first(where: { $0.lowercased() == "referer" }) {
            let referer = next.removeValue(forKey: key).flatMap(URL.init(string:))
            if let value = URLNormalizer.referer(for: to, from: referer) { next[key] = value }
        }
        switch RequestPolicy.evaluate(method: method, url: to, headers: next, hasBody: false) {
        case let .denied(reason): return .failure(.denied(reason))
        case .allowed: return .success(next)
        }
    }

    /// The request for the next hop, built from the headers MediaPull chose rather than those URLSession carried over.
    public static func nextRequest(after current: URLRequest, headers: [String: String], proposed: URLRequest)
        -> Result<(URLRequest, [String: String]), GateError>
    {
        guard let to = proposed.url, let from = current.url else { return .failure(.denied("The redirect has no address.")) }
        let method = proposed.httpMethod ?? "GET"
        return nextHeaders(headers, method: method, from: from, to: to).map { next in
            var request = URLRequest(url: to, cachePolicy: current.cachePolicy, timeoutInterval: current.timeoutInterval)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            for (name, value) in next {
                request.setValue(value, forHTTPHeaderField: name)
            }
            return (request, next)
        }
    }
}

public enum GateError: LocalizedError, Sendable, Equatable {
    case denied(String)
    case http(Int)
    case notHTTP
    case cancelled
    case tooLarge(Int64)
    case truncated(received: Int64, expected: Int64)

    public var errorDescription: String? {
        switch self {
        case let .denied(reason): "MediaPull refused to send a request: \(reason)"
        case let .http(status): Self.message(for: status)
        case .notHTTP: "The server did not answer with HTTP."
        case .cancelled: "Cancelled."
        case let .tooLarge(limit): "The file is larger than MediaPull reads for this (\(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)))."
        case let .truncated(received, expected):
            "The download was cut short (\(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) of "
                + "\(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)))."
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
            // In memory only: responses fetched with the browser's cookies (signed-in or private media) must never be
            // left on disk after the person clears website data.
            config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 0, directory: nil)
            return config
        }()
        session = URLSession(configuration: config)
        if configuration == nil {
            // Versions before 1.8 kept a disk cache here.
            Task.detached(priority: .utility) {
                if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? FileManager.default.removeItem(at: caches.appendingPathComponent("MediaPull/URLCache", isDirectory: true))
                }
            }
        }
    }

    /// Clear All Website Data clears what the gate remembers too.
    public func clearCache() {
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    /// The most `data()` reads for each purpose; larger answers are refused rather than held in memory.
    public static func dataLimit(for purpose: RequestPurpose) -> Int64 {
        switch purpose {
        case .thumbnail: 32 << 20
        default: 64 << 20
        }
    }

    public func entries() -> [EgressEntry] { log }

    private func record(_ request: GatedRequest) -> Int {
        record(method: request.method.rawValue, url: request.url, purpose: request.purpose)
    }

    private func record(method: String, url: URL, purpose: RequestPurpose) -> Int {
        counter += 1
        let entry = EgressEntry(id: counter, time: Date(), method: method, host: url.host ?? "", path: url.path, purpose: purpose)
        log.append(entry)
        if log.count > Self.logCapacity { log.removeFirst(log.count - Self.logCapacity) }
        return counter
    }

    private func hop(from previous: Int, status: Int, to url: URL, method: String, purpose: RequestPurpose) -> Int {
        finish(previous, status: status, bytes: nil)
        return record(method: method, url: url, purpose: purpose)
    }

    private func logHop(_ purpose: RequestPurpose) -> RedirectGuard.Log {
        { [self] previous, status, url, method in await hop(from: previous, status: status, to: url, method: method, purpose: purpose) }
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

    /// The whole body of a small response, at most `dataLimit(for:)` bytes.
    public func data(_ request: GatedRequest) async throws -> (Data, HTTPURLResponse) {
        let urlRequest = try prepare(request)
        let hops = RedirectGuard(request: urlRequest, id: record(request), log: logHop(request.purpose), limiter: limiter,
                                 httpsOnly: request.purpose == .engineUpdate)
        await limiter.acquire(hops.currentHost)
        defer { Task { await hops.endTransfer() } }
        let limit = Self.dataLimit(for: request.purpose)
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: hops)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            if hops.refusal != nil {
                bytes.task.cancel()
                finish(hops.currentID, status: http.statusCode, bytes: nil)
                try hops.checkRefusal()
            }
            if http.expectedContentLength > limit {
                bytes.task.cancel()
                finish(hops.currentID, status: http.statusCode, bytes: nil)
                throw GateError.tooLarge(limit)
            }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    finish(hops.currentID, status: http.statusCode, bytes: Int64(data.count))
                    throw GateError.tooLarge(limit)
                }
            }
            finish(hops.currentID, status: http.statusCode, bytes: Int64(data.count))
            return (data, http)
        } catch let error as GateError {
            // An HTTP status, or the redirect that was refused, is already in the request log.
            if case .http = error {} else if error != hops.refusal { finish(hops.currentID, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(hops.currentID, status: nil, bytes: nil)
            throw Self.mapped(error)
        }
    }

    /// At most `maxBytes` from the start of a resource. The connection closes once enough arrived.
    public func head(_ request: GatedRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if request.method == .get, request.range == nil { request.range = "bytes=0-\(maxBytes - 1)" }
        let urlRequest = try prepare(request)
        let hops = RedirectGuard(request: urlRequest, id: record(request), log: logHop(request.purpose), limiter: limiter)
        await limiter.acquire(hops.currentHost)
        defer { Task { await hops.endTransfer() } }
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest, delegate: hops)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            if hops.refusal != nil {
                bytes.task.cancel()
                finish(hops.currentID, status: http.statusCode, bytes: nil)
                try hops.checkRefusal()
            }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 65536))
            if request.method == .get, (200 ..< 300).contains(http.statusCode) {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= maxBytes { break }
                }
            }
            bytes.task.cancel()
            finish(hops.currentID, status: http.statusCode, bytes: Int64(data.count))
            return (data, http)
        } catch let error as GateError {
            // An HTTP status, or the redirect that was refused, is already in the request log.
            if case .http = error {} else if error != hops.refusal { finish(hops.currentID, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(hops.currentID, status: nil, bytes: nil)
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
        let delegate = DownloadProgressDelegate(request: urlRequest, id: record(request), log: logHop(request.purpose),
                                                limiter: limiter, httpsOnly: request.purpose == .engineUpdate, progress: progress)
        await limiter.acquire(delegate.currentHost)
        defer { Task { await delegate.endTransfer() } }
        do {
            let (location, response) = try await session.download(for: urlRequest, delegate: delegate)
            guard let http = response as? HTTPURLResponse else { throw GateError.notHTTP }
            guard (200 ..< 300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: location)
                finish(delegate.currentID, status: http.statusCode, bytes: nil)
                try delegate.checkRefusal()
                throw GateError.http(http.statusCode)
            }
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value
            // R-1401 step 3: a body shorter than the server announced is a cut-short download, never a file to keep. With a
            // content encoding the announced length is of the encoded body, so it cannot be compared.
            let encoded = http.value(forHTTPHeaderField: "Content-Encoding").map { !$0.isEmpty && $0.lowercased() != "identity" } ?? false
            if !encoded, request.range == nil, http.statusCode == 200, http.expectedContentLength > 0, let size,
               size != http.expectedContentLength
            {
                try? manager.removeItem(at: location) // lint:allow silent-write a temporary file
                finish(delegate.currentID, status: http.statusCode, bytes: size)
                throw GateError.truncated(received: size, expected: http.expectedContentLength)
            }
            try? manager.removeItem(at: destination) // lint:allow silent-write the destination may not exist yet
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: location, to: destination)
            finish(delegate.currentID, status: http.statusCode, bytes: size)
            return http
        } catch let error as GateError {
            // An HTTP status, or the redirect that was refused, is already in the request log.
            if case .http = error {} else if error != delegate.refusal { finish(delegate.currentID, status: nil, bytes: nil) }
            throw error
        } catch {
            finish(delegate.currentID, status: nil, bytes: nil)
            throw Self.mapped(error)
        }
    }

    static func mapped(_ error: Error) -> Error {
        if let urlError = error as? URLError, urlError.code == .cancelled { return GateError.cancelled }
        if error is CancellationError { return GateError.cancelled }
        return error
    }
}

/// Checks every redirect hop against the request policy and logs it (SPEC R-501). URLSession would otherwise follow a 3xx
/// anywhere, with the Cookie and Referer headers MediaPull set by hand for the first host.
class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias Log = @Sendable (_ previous: Int, _ status: Int, _ next: URL, _ method: String) async -> Int

    private struct State {
        var id: Int
        var request: URLRequest
        var headers: [String: String]
        var refusal: GateError?
    }

    private let lock = NSLock()
    private var state: State
    private let log: Log
    private let limiter: HostLimiter?
    /// The host whose request slot this transfer holds ("" while it waits for the next hop's slot).
    private var host: String
    private var ended = false
    private let httpsOnly: Bool

    init(request: URLRequest, id: Int, log: @escaping Log, limiter: HostLimiter? = nil, httpsOnly: Bool = false) {
        state = State(id: id, request: request, headers: request.allHTTPHeaderFields ?? [:])
        self.log = log
        self.limiter = limiter
        self.httpsOnly = httpsOnly
        host = request.url?.host ?? ""
    }

    /// The request log entry of the hop the answer came from.
    var currentID: Int { lock.withLock { state.id } }
    /// The host whose request slot this transfer holds; it follows redirects, so per-host limits hold for every hop.
    var currentHost: String { lock.withLock { host } }

    /// Called once the transfer is over: gives back the slot it holds. A slot still being waited for at that moment is
    /// given back as soon as it arrives.
    func endTransfer() async {
        let held: String? = lock.withLock {
            ended = true
            defer { host = "" }
            return host.isEmpty ? nil : host
        }
        if let held, let limiter { await limiter.release(held) }
    }
    var refusal: GateError? { lock.withLock { state.refusal } }

    func checkRefusal() throws {
        if let refusal { throw refusal }
    }

    // The completion-handler form: the async form of this callback crashes the compiler's Objective-C thunk.
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest proposed: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        let current = lock.withLock { state }
        if httpsOnly, proposed.url?.scheme?.lowercased() != "https" {
            lock.withLock { state.refusal = .denied("Engine updates are downloaded over https only.") }
            return completionHandler(nil)
        }
        switch RedirectPolicy.nextRequest(after: current.request, headers: current.headers, proposed: proposed) {
        case let .failure(error):
            lock.withLock { state.refusal = error }
            completionHandler(nil)
        case let .success((next, headers)):
            guard let url = next.url else { return completionHandler(nil) }
            let status = response.statusCode
            Task {
                let id = await log(current.id, status, url, next.httpMethod ?? "GET")
                let nextHost = url.host ?? ""
                if let limiter, nextHost != currentHost {
                    // The finished hop's slot is given back before waiting for the next host's, so two transfers can
                    // never wait on each other.
                    let previous: String = lock.withLock { defer { host = "" }; return host }
                    if !previous.isEmpty { await limiter.release(previous) }
                    await limiter.acquire(nextHost)
                    let keep = lock.withLock { () -> Bool in
                        if ended { return false }
                        host = nextHost
                        return true
                    }
                    if !keep { await limiter.release(nextHost) }
                }
                lock.withLock { state = State(id: id, request: next, headers: headers) }
                completionHandler(next)
            }
        }
    }
}

final class DownloadProgressDelegate: RedirectGuard, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: @Sendable (Int64, Int64?) -> Void
    private var last = Date.distantPast

    init(request: URLRequest, id: Int, log: @escaping Log, limiter: HostLimiter? = nil, httpsOnly: Bool = false,
         progress: @escaping @Sendable (Int64, Int64?) -> Void)
    {
        self.progress = progress
        super.init(request: request, id: id, log: log, limiter: limiter, httpsOnly: httpsOnly)
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
