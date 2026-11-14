import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import Observation
import WebKit

/// Drives one browser pane (SPEC section 8). The UI delegate deliberately has no open-panel
/// method, so file inputs on web pages do nothing (SPEC R-508).
@Observable
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, Identifiable {
    let id = UUID()
    let webView: WKWebView
    let handler = ExtractionMessageHandler()
    var addressText = ""
    var title = ""
    var url: URL?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress = 0.0
    var lastError: String?
    @ObservationIgnored var onMessage: ((ExtractionMessage) -> Void)?
    @ObservationIgnored var onCommit: ((URL) -> Void)?
    @ObservationIgnored var onFinish: ((URL) -> Void)?
    @ObservationIgnored var onDownload: ((URL, String?) -> Void)?
    @ObservationIgnored var onPDF: ((URL) -> Void)?
    /// A link that asks for a new window, or a ⌘-click: open it in a tab (selected when the Bool is true).
    @ObservationIgnored var onOpenInNewTab: ((URL, Bool) -> Void)?
    @ObservationIgnored var onTitle: ((URL, String) -> Void)?
    var isShowingPDF = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var ruleListInstalled = false

    override init() {
        let configuration = WebViewSetup.configuration(handler: handler, ruleList: nil)
        webView = ReadOnlyWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        handler.onMessage = { [weak self] message in self?.onMessage?(message) }
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.syncState(view) }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.title = view.title ?? ""
                    if let url = view.url, let title = view.title, !title.isEmpty { self?.onTitle?(url, title) }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
    }

    private func syncState(_ view: WKWebView) {
        url = view.url
        if let url = view.url { addressText = url.absoluteString }
    }

    func install(ruleList: WKContentRuleList?) {
        guard let ruleList, !ruleListInstalled else { return }
        webView.configuration.userContentController.add(ruleList)
        ruleListInstalled = true
    }

    func load(_ url: URL) {
        lastError = nil
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func userAgent() async -> String? {
        try? await webView.evaluateJavaScript("navigator.userAgent") as? String
    }

    // MARK: Extraction helpers

    func rescan() {
        webView.evaluateJavaScript("window.__mediapullRescan && window.__mediapullRescan()", in: nil, in: WebViewSetup.world) { _ in }
    }

    func scrollStep() async -> (atBottom: Bool, moved: Bool, total: Int) {
        let result = try? await webView.callAsyncJavaScript(
            "return window.__mediapullScrollStep ? window.__mediapullScrollStep() : null", arguments: [:], in: nil,
            contentWorld: WebViewSetup.world
        )
        guard let dictionary = result as? [String: Any] else { return (true, false, 0) }
        return (dictionary["atBottom"] as? Bool ?? true, dictionary["moved"] as? Bool ?? false, dictionary["total"] as? Int ?? 0)
    }

    func readBlob(_ url: URL) async -> Data? {
        let result = try? await webView.callAsyncJavaScript(
            "return window.__mediapullReadBlob ? await window.__mediapullReadBlob(u) : null", arguments: ["u": url.absoluteString],
            in: nil, contentWorld: WebViewSetup.world
        )
        return (result as? String).flatMap { Data(base64Encoded: $0) }
    }

    // MARK: Navigation

    func webView(_: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload, let url = navigationAction.request.url {
            onDownload?(url, nil)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http", let open = onOpenInNewTab
        {
            open(url, navigationAction.modifierFlags.contains(.shift))
            return .cancel
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme)
        {
            return .cancel
        }
        return .allow
    }

    func webView(_: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        if navigationResponse.isForMainFrame {
            let isPDF = response.mimeType == "application/pdf"
            isShowingPDF = isPDF
            if isPDF, let url = response.url { onPDF?(url) }
        }
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment"),
           let url = response.url
        {
            onDownload?(url, response.mimeType)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
        lastError = nil
        if let url = webView.url { onCommit?(url) }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        if let url = webView.url { onFinish?(url) }
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        lastError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: UI delegate (no runOpenPanel: file inputs stay inert)

    func webView(_ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures _: WKWindowFeatures) -> WKWebView?
    {
        // Pop-ups need a user action in WebKit by default; open them as a tab instead of a window.
        if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" {
            if let open = onOpenInNewTab { open(url, true) } else { webView.load(URLRequest(url: url)) }
        }
        return nil
    }

    func webView(_: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame _: WKFrameInfo) async -> String?
    {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
