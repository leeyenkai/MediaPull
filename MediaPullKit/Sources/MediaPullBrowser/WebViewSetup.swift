import Foundation
import MediaPullCore
import MediaPullNet
import WebKit

/// A batch of extraction candidates from one frame.
public struct ExtractionMessage: Sendable {
    public var json: String
    public var frameURL: URL?
    public var isMainFrame: Bool
    public var origin: String?
}

/// Receives extraction batches. It only hands the raw JSON on: decoding happens off the main
/// thread in the ingestor (SPEC R-907).
@MainActor
public final class ExtractionMessageHandler: NSObject, WKScriptMessageHandler {
    public var onMessage: (ExtractionMessage) -> Void = { _ in }

    public func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        let frame = message.frameInfo
        let origin = frame.securityOrigin
        let originText = origin.host.isEmpty ? nil : "\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")"
        onMessage(ExtractionMessage(json: body, frameURL: frame.request.url, isMainFrame: frame.isMainFrame, origin: originText))
    }
}

/// Weak wrapper so the content controller does not keep the handler's owner alive.
@MainActor
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: ExtractionMessageHandler?

    init(_ target: ExtractionMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

@MainActor
public enum WebViewSetup {
    public static let world = WKContentWorld.world(name: "MediaPull")
    public static let handlerName = "mediapull"

    static func script(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }

    /// The configuration for a browser pane: shared persistent data store, extraction and guard
    /// scripts in an isolated world, no automatic pop-ups.
    public static func configuration(handler: ExtractionMessageHandler, ruleList: WKContentRuleList?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: script("guard"), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(
            source: script("guard-page"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page
        ))
        controller.addUserScript(WKUserScript(
            source: script("extract"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: world
        ))
        controller.add(WeakMessageHandler(handler), contentWorld: world, name: handlerName)
        if let ruleList { controller.add(ruleList) }
        configuration.userContentController = controller
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        return configuration
    }

    /// Blocks well-known upload endpoints in the browser pane (SPEC R-508).
    public static func uploadBlockingRules() async throws -> UploadRules? {
        let rules = """
        [
          {"trigger": {"url-filter": "^https?://rupload\\\\."}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "rupload_igphoto"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "rupload_igvideo"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^https?://upload\\\\.twitter\\\\.com/"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^https?://upload\\\\.x\\\\.com/"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^https?://[^/]*\\\\.?upload\\\\.facebook\\\\.com/"}, "action": {"type": "block"}}
        ]
        """
        let list = try await WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "MediaPullUploadBlock",
            encodedContentRuleList: rules
        )
        return list.map(UploadRules.init)
    }

    public static func callAsync<T>(_ webView: WKWebView, _ body: String, arguments: [String: Any] = [:], as _: T.Type) async -> T? {
        let result = try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world)
        return result as? T
    }
}

/// The upload-blocking content rules, compiled once and installed in every tab; app code holds them without WebKit (R-401).
public struct UploadRules: @unchecked Sendable {
    public let list: WKContentRuleList
}

/// The browser's cookies and website data. The app reaches the shared data store only through here (R-401).
@MainActor
public enum CookieBridge {
    /// The store every browser tab shares (WebViewSetup uses the default website data store).
    public static var browserStore: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    public static func allCookies(_ store: WKHTTPCookieStore = browserStore) async -> [CookieRecord] {
        await store.allCookies().map(CookieRecord.init)
    }

    public static func cookies(_ store: WKHTTPCookieStore = browserStore, registrableDomain: String) async -> [CookieRecord] {
        CookieJar(cookies: await allCookies(store)).cookies(forRegistrableDomain: registrableDomain)
    }

    /// Writes cookies an engine refreshed back into the browser's store, so both stay in step.
    /// Only values change: the browser's own flags and expiry are kept, `csrftoken` is never
    /// replaced, and cookies the browser did not already have are ignored.
    public static func update(_ records: [CookieRecord], in store: WKHTTPCookieStore = browserStore, existing: [CookieRecord]) async {
        let current = Dictionary(existing.map { ("\($0.domain)|\($0.path)|\($0.name)", $0) }, uniquingKeysWith: { a, _ in a })
        for record in records where record.name != "csrftoken" {
            let key = "\(record.domain)|\(record.path)|\(record.name)"
            guard var original = current[key], original.value != record.value, !record.value.isEmpty else { continue }
            original.value = record.value
            guard let cookie = original.httpCookie else { continue }
            await store.setCookie(cookie)
        }
    }

    public static func isSignedInToInstagram(_ cookies: [CookieRecord]) -> Bool {
        let instagram = cookies.filter { $0.domain.hasSuffix("instagram.com") && ($0.expires ?? .distantFuture) > Date() }
        return instagram.contains { $0.name == "sessionid" && !$0.value.isEmpty } && instagram.contains { $0.name == "ds_user_id" }
    }

    public static func clearWebsiteData(matching domains: [String]?, in dataStore: WKWebsiteDataStore = .default()) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await dataStore.dataRecords(ofTypes: types)
        let selected = domains.map { domains in
            records.filter { record in domains.contains { record.displayName.contains($0) } }
        } ?? records
        await dataStore.removeData(ofTypes: types, for: selected)
        if let domains {
            let store = dataStore.httpCookieStore
            for cookie in await store.allCookies() where domains.contains(where: { cookie.domain.contains($0) }) {
                await store.deleteCookie(cookie)
            }
        }
    }
}
