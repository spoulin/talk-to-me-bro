import AppKit
import Observation
import os
import WebKit

/// One browser window: the regular web view, the reader web view laid over it,
/// and the speech controller that reads the reader content aloud.
@MainActor
@Observable
final class BrowserModel: NSObject {
    static let readerWorld = WKContentWorld.world(name: "BrowSpeakerReader")
    static let homeURL = URL(string: "https://duckduckgo.com/")!
    static let log = Logger(subsystem: "local.browspeaker", category: "reader")

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored let readerView: WKWebView
    let speech = SpeechController()

    var addressText = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress = 0.0
    var isReaderMode = false
    var isExtracting = false
    var errorMessage: String?
    var addressFocusRequest = 0

    var readerFontSize: Double = UserDefaults.standard.object(forKey: "readerFontSize") as? Double ?? 20 {
        didSet {
            UserDefaults.standard.set(readerFontSize, forKey: "readerFontSize")
            readerJS("__bs.setFontSize(\(Int(readerFontSize)))")
        }
    }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var speakWhenReaderLoads = false
    @ObservationIgnored private var readWhenPageLoads = false
    @ObservationIgnored private var readerBaseURL: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        let readerConfig = WKWebViewConfiguration()
        readerConfig.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: ReaderPage.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.readerWorld))
        readerConfig.userContentController = controller
        readerView = WKWebView(frame: .zero, configuration: readerConfig)

        super.init()

        controller.add(WeakScriptHandler(self), contentWorld: Self.readerWorld, name: "reader")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        readerView.navigationDelegate = self
        observeWebView()

        speech.onBlockStart = { [weak self] i in self?.readerJS("__bs.highlightBlock(\(i))") }
        speech.onWord = { [weak self] i, r in self?.readerJS("__bs.highlightWord(\(i),\(r.location),\(r.length))") }
        speech.onFinish = { [weak self] in self?.readerJS("__bs.clear()") }
        speech.onError = { [weak self] message in self?.errorMessage = message }

        webView.load(URLRequest(url: Self.homeURL))
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
            webView.observe(\.title) { [weak self] wv, _ in MainActor.assumeIsolated { self?.title = wv.title ?? "" } },
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in MainActor.assumeIsolated { self?.progress = wv.estimatedProgress } },
        ]
    }

    private func urlChanged() {
        addressText = webView.url?.absoluteString ?? ""
        if isReaderMode, webView.url != readerBaseURL { exitReader() }
    }

    // MARK: Navigation

    func submitAddress() {
        let text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url: URL?
        if text.contains("://") {
            url = URL(string: text)
        } else if text.hasPrefix("localhost") {
            url = URL(string: "http://" + text)
        } else if !text.contains(" "), text.contains(".") {
            url = URL(string: "https://" + text)
        } else {
            var components = URLComponents(url: Self.homeURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "q", value: text)]
            url = components.url
        }
        if let url { load(url) }
    }

    /// Pages sent from outside (share extension, "Open With", links): load the
    /// page, then switch to reader mode and start reading.
    func handleOpenURL(_ url: URL) {
        guard let page = Self.page(for: url) else { return }
        Self.log.info("Shared URL: \(page.absoluteString, privacy: .public)")
        speech.stop()
        load(page)
        readWhenPageLoads = true
        NSApp.activate()
    }

    /// Accepts `browspeaker://read?url=<page>`, http(s) links, `.webloc` and
    /// `.url` shortcuts, and local HTML files.
    private static func page(for url: URL) -> URL? {
        let isWeb = { (url: URL?) in ["http", "https"].contains(url?.scheme?.lowercased()) }
        switch url.scheme?.lowercased() {
        case "browspeaker":
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value
            return value.flatMap(URL.init(string:)).flatMap { isWeb($0) ? $0 : nil }
        case "http", "https":
            return url
        case "file":
            switch url.pathExtension.lowercased() {
            case "webloc":
                let plist = (try? Data(contentsOf: url))
                    .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
                let page = (plist?["URL"] as? String).flatMap(URL.init(string:))
                return isWeb(page) ? page : nil
            case "url":
                // Windows shortcut: an INI file with a "URL=" line.
                let line = (try? String(contentsOf: url, encoding: .utf8))?
                    .components(separatedBy: .newlines).first { $0.hasPrefix("URL=") }
                let page = line.flatMap { URL(string: String($0.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
                return isWeb(page) ? page : nil
            default:
                return url
            }
        default:
            return nil
        }
    }

    func load(_ url: URL) {
        readWhenPageLoads = false
        if isReaderMode { exitReader() }
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func zoom(by step: Int) {
        if isReaderMode {
            readerFontSize = min(max(readerFontSize + Double(step) * 2, 12), 44)
        } else {
            webView.pageZoom = min(max(webView.pageZoom + CGFloat(step) * 0.1, 0.5), 3)
        }
    }

    func resetZoom() {
        if isReaderMode { readerFontSize = 20 } else { webView.pageZoom = 1 }
    }

    // MARK: Reader mode

    func toggleReader() {
        if isReaderMode { exitReader() } else { Task { await enterReader(speak: false) } }
    }

    func enterReader(speak: Bool) async {
        guard !isExtracting, webView.url != nil else { return }
        guard let script = ReaderPage.extractionScript else {
            errorMessage = "Readability.js est introuvable dans l'application."
            return
        }
        isExtracting = true
        defer { isExtracting = false }
        guard let json = await webView.evaluate(script, in: .defaultClient),
              let article = try? JSONDecoder().decode(Article.self, from: Data(json.utf8))
        else {
            errorMessage = "Impossible d'extraire le contenu de cette page."
            return
        }
        readerBaseURL = webView.url
        speakWhenReaderLoads = speak
        readerView.loadHTMLString(ReaderPage.html(for: article, fontSize: readerFontSize), baseURL: webView.url)
        isReaderMode = true
    }

    func exitReader() {
        speech.stop()
        speakWhenReaderLoads = false
        isReaderMode = false
    }

    // MARK: Speech

    func togglePlayPause() {
        switch speech.state {
        case .speaking: speech.pause()
        case .paused: speech.resume()
        case .idle:
            Task {
                if isReaderMode { await startSpeaking(from: nil) } else { await enterReader(speak: true) }
            }
        }
    }

    /// Starts at `index`, or at the first paragraph visible on screen.
    func startSpeaking(from index: Int?) async {
        struct Blocks: Decodable { var blocks: [String]; var first: Int }
        guard let json = await readerView.evaluate("JSON.stringify({blocks: __bs.blocks(), first: __bs.firstVisible()})",
                                                   in: Self.readerWorld),
              let result = try? JSONDecoder().decode(Blocks.self, from: Data(json.utf8))
        else { return }
        speech.speak(result.blocks, from: index ?? result.first)
    }

    private func readerJS(_ js: String) {
        guard isReaderMode else { return }
        readerView.evaluateJavaScript(js, in: nil, in: Self.readerWorld)
    }
}

// MARK: - WebKit delegates

extension BrowserModel: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === readerView, navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else { return .allow }
        // In-article anchors (footnotes) scroll the reader; other links open in the browser.
        if url.fragment != nil, url.withoutFragment == readerBaseURL?.withoutFragment { return .allow }
        load(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { errorMessage = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView, readWhenPageLoads {
            readWhenPageLoads = false
            Task {
                // Give script-rendered pages a moment to fill in their content.
                try? await Task.sleep(for: .milliseconds(600))
                await enterReader(speak: true)
            }
        }
        guard webView === readerView, speakWhenReaderLoads else { return }
        speakWhenReaderLoads = false
        Task {
            await startSpeaking(from: 0)
            Self.log.info("Reading started: \(self.speech.state == .speaking, privacy: .public)")
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard webView === self.webView, nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" links and window.open: open in the current window.
        if navigationAction.targetFrame == nil { load(navigationAction.request.url ?? Self.homeURL) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host() ?? ""
        alert.informativeText = message
        alert.runModal()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let index = body["index"] as? Int else { return }
        // While reading, a click on a paragraph jumps there; ⌥-click always starts reading from it.
        if speech.hasBlocks {
            speech.jump(to: index)
        } else if body["alt"] as? Bool == true {
            Task { await startSpeaking(from: index) }
        }
    }
}

/// Avoids the retain cycle WKUserContentController creates with its handlers.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension WKWebView {
    /// Evaluates a script that returns a string (JSON), or nil on any failure.
    func evaluate(_ script: String, in world: WKContentWorld) async -> String? {
        await withCheckedContinuation { continuation in
            evaluateJavaScript(script, in: nil, in: world) { result in
                continuation.resume(returning: (try? result.get()) as? String)
            }
        }
    }
}

private extension URL {
    var withoutFragment: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }
}
