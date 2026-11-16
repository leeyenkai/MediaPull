import Foundation
@testable import MediaPullNet
import XCTest

final class NetworkGateTests: XCTestCase {
    private func cookie(_ domain: String, secure: Bool = false, path: String = "/") -> CookieRecord {
        CookieRecord(name: "id", value: "1", domain: domain, path: path, isSecure: secure, isHTTPOnly: true, expires: nil)
    }

    func testHostOnlyCookiesMatchTheirExactHost() {
        let table: [(domain: String, url: String, matches: Bool)] = [
            ("www.example.com", "https://www.example.com/a.jpg", true),
            ("www.example.com", "https://cdn.www.example.com/a.jpg", false),
            ("example.com", "https://example.com/a.jpg", true),
            ("example.com", "https://images.example.com/a.jpg", false),
            (".example.com", "https://images.example.com/a.jpg", true),
            (".example.com", "https://example.com/a.jpg", true),
            (".example.com", "https://example.com.evil.test/a.jpg", false),
            (".example.com", "https://badexample.com/a.jpg", false),
            ("WWW.Example.com", "https://www.example.com/", true),
        ]
        for row in table {
            XCTAssertEqual(cookie(row.domain).matches(URL(string: row.url)!), row.matches, "\(row.domain) \(row.url)")
        }
        XCTAssertFalse(cookie(".example.com", secure: true).matches(URL(string: "http://example.com/")!))
        XCTAssertFalse(cookie(".example.com", path: "/private").matches(URL(string: "https://example.com/public/a.jpg")!))
        XCTAssertFalse(cookie(".example.com", path: "/private").matches(URL(string: "https://example.com/privateer/a.jpg")!))
        XCTAssertTrue(cookie(".example.com", path: "/private").matches(URL(string: "https://example.com/private/a.jpg")!))
        XCTAssertTrue(cookie(".example.com", path: "/private").matches(URL(string: "https://example.com/private")!))
        let jar = CookieJar(cookies: [cookie("www.example.com"), CookieRecord(name: "site", value: "2", domain: ".example.com", path: "/",
                                                                              isSecure: false, isHTTPOnly: false, expires: nil)])
        XCTAssertEqual(jar.header(for: URL(string: "https://cdn.example.com/a.jpg")!), "site=2")
        XCTAssertEqual(jar.header(for: URL(string: "https://www.example.com/a.jpg")!), "id=1; site=2")
    }

    func testRedirectsKeepCookiesOnlyOnTheSameHost() throws {
        let headers = ["Cookie": "id=1", "Referer": "https://www.example.com/page", "Accept": "*/*"]
        let from = URL(string: "https://www.example.com/a.jpg")!
        let rows: [(to: String, keepsCookie: Bool)] = [
            ("https://www.example.com/b.jpg", true),
            ("https://cdn.example.com/b.jpg", false),
            ("https://collector.example.net/b.jpg", false),
        ]
        for row in rows {
            let next = try RedirectPolicy.nextHeaders(headers, method: "GET", from: from, to: URL(string: row.to)!).get()
            XCTAssertEqual(next["Cookie"] != nil, row.keepsCookie, row.to)
            XCTAssertEqual(next["Referer"], headers["Referer"])
        }
    }

    func testRedirectsAreCheckedAgainstThePolicy() {
        let from = URL(string: "https://www.example.com/a.jpg")!
        let withCookie = ["Cookie": "id=1"]
        // From https to http with cookies attached, whatever the host.
        for target in ["http://www.example.com/a.jpg", "http://other.example.net/a.jpg"] {
            XCTAssertThrowsError(try RedirectPolicy.nextHeaders(withCookie, method: "GET", from: from, to: URL(string: target)!).get())
        }
        func hop(_ method: String, _ target: String) throws -> [String: String] {
            try RedirectPolicy.nextHeaders([:], method: method, from: from, to: URL(string: target)!).get()
        }
        XCTAssertNoThrow(try hop("GET", "http://www.example.com/a.jpg"))
        XCTAssertThrowsError(try hop("GET", "file:///etc/hosts"))
        XCTAssertThrowsError(try hop("POST", "https://www.example.com/"))
    }

    func testRedirectedRequestIsBuiltFromTheGateHeaders() throws {
        let context = RequestContext(referer: "https://www.example.com/", cookieHeader: "id=1")
        let start = GatedRequest.get(URL(string: "https://www.example.com/a.jpg")!, purpose: .save, context: context)
        var current = try RequestPolicy.urlRequest(for: start).get()
        current.timeoutInterval = 77
        // URLSession carries the original headers over, the cookie among them.
        var proposed = URLRequest(url: URL(string: "https://cdn.example.net/a.jpg")!)
        proposed.httpMethod = "GET"
        proposed.setValue("id=1", forHTTPHeaderField: "Cookie")
        let gateHeaders = current.allHTTPHeaderFields ?? [:]
        let (next, headers) = try RedirectPolicy.nextRequest(after: current, headers: gateHeaders, proposed: proposed).get()
        XCTAssertNil(next.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(headers["Cookie"])
        XCTAssertEqual(next.value(forHTTPHeaderField: "Referer"), "https://www.example.com/")
        XCTAssertEqual(next.url?.host, "cdn.example.net")
        XCTAssertEqual(next.timeoutInterval, 77)
        XCTAssertFalse(next.httpShouldHandleCookies)
    }
}

/// Answers https://a.test with a redirect (carrying the original headers over, as URLSession does) and anything else with
/// a small body, recording each request it sees. No network is used.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var target = "https://b.test/x.jpg"
    nonisolated(unsafe) static var seen: [URLRequest] = []
    static let lock = NSLock()

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.seen.append(request) }
        if request.url?.host == "a.test" {
            var next = request
            next.url = URL(string: Self.target)
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.target])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // A refused redirect ends with the redirect's own answer, as the HTTP loader does.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NetworkGateRedirectTests: XCTestCase {
    private func gate() -> NetworkGate {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingProtocol.self]
        return NetworkGate(configuration: config)
    }

    private let start = GatedRequest.get(URL(string: "https://a.test/a.jpg")!, purpose: .save,
                                         context: RequestContext(referer: "https://a.test/", cookieHeader: "session=secret"))

    func testCookiesStayBehindAndEveryHopIsLogged() async throws {
        RedirectingProtocol.lock.withLock { RedirectingProtocol.seen = [] }
        RedirectingProtocol.target = "https://b.test/x.jpg"
        let gate = gate()
        let (data, response) = try await gate.data(start)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("ok".utf8))
        let seen = RedirectingProtocol.lock.withLock { RedirectingProtocol.seen }
        XCTAssertEqual(seen.map { $0.url?.host }, ["a.test", "b.test"])
        XCTAssertEqual(seen.first?.value(forHTTPHeaderField: "Cookie"), "session=secret")
        XCTAssertNil(seen.last?.value(forHTTPHeaderField: "Cookie"))
        let entries = await gate.entries()
        XCTAssertEqual(entries.map(\.host), ["a.test", "b.test"])
        XCTAssertEqual(entries.map(\.status), [302, 200])
    }

    func testInsecureHopWithCookiesIsRefused() async {
        RedirectingProtocol.lock.withLock { RedirectingProtocol.seen = [] }
        RedirectingProtocol.target = "http://b.test/x.jpg"
        let gate = gate()
        do {
            _ = try await gate.data(start)
            XCTFail("The redirect to http was followed")
        } catch {
            guard case .denied = error as? GateError else { return XCTFail("\(error)") }
        }
        let seen = RedirectingProtocol.lock.withLock { RedirectingProtocol.seen }
        XCTAssertEqual(seen.map { $0.url?.host }, ["a.test"])
        let entries = await gate.entries()
        XCTAssertEqual(entries.map(\.status), [302])
    }
}
