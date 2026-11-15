import AppKit
import Foundation
import MediaPullBrowser
import MediaPullCore
import Observation
import WebKit

/// Drives one browser pane (SPEC section 8). The UI delegate deliberately has no open-panel
/// method, so file inputs on web pages do nothing (SPEC R-508).
@Observable
final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, Identifiable {
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
    /// A file the page offers for download: where to save it (nil cancels), then the result (SPEC R-807).
    @ObservationIgnored var onChooseDownloadDestination: ((String) async -> URL?)?
    @ObservationIgnored var onDownloadFinished: ((URL?, String?) -> Void)?
    @ObservationIgnored private var downloadDestinations: [ObjectIdentifier: URL] = [:]
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

    // MARK: Page zoom (R-802a)

    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    var zoom: CGFloat = 1

    func zoomIn() { setZoom(Self.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom) }
    func zoomOut() { setZoom(Self.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom) }
    func resetZoom() { setZoom(1) }

    func setZoom(_ value: CGFloat) {
        zoom = value
        webView.pageZoom = value
    }

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
        if navigationAction.shouldPerformDownload {
            return .download
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
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    // MARK: Downloads the page offers (SPEC R-807)

    func webView(_: WKWebView, navigationAction _: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_: WKWebView, navigationResponse _: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing _: URLResponse, suggestedFilename: String) async -> URL? {
        guard let chosen = await onChooseDownloadDestination?(suggestedFilename) else { return nil }
        // The save panel already asked about replacing; WebKit refuses to write over an existing file.
        try? FileManager.default.removeItem(at: chosen)
        downloadDestinations[ObjectIdentifier(download)] = chosen
        return chosen
    }

    func downloadDidFinish(_ download: WKDownload) {
        onDownloadFinished?(downloadDestinations.removeValue(forKey: ObjectIdentifier(download)), nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData _: Data?) {
        let file = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        onDownloadFinished?(file, error.localizedDescription)
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
