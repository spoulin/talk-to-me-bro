import AppKit
import Observation
import os
import WebKit

/// One player window. A hidden web view loads the page and extracts the
/// article; the reader web view shows it; the speech controller reads it.
@MainActor
@Observable
final class BrowserModel: NSObject {
    enum Phase { case empty, loading, ready }

    static let readerWorld = WKContentWorld.world(name: "BrowSpeakerReader")
    static let log = Logger(subsystem: "local.browspeaker", category: "reader")
    /// Average reading speed at 1×, to estimate the time left.
    private static let charactersPerSecond = 15.0

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored let readerView: WKWebView
    let speech = SpeechController()
    let playlist = Playlist.shared

    private(set) var phase: Phase = .empty
    private(set) var articleTitle = ""
    private(set) var siteName = ""
    private(set) var articleURL: URL?
    private(set) var loadingHost = ""
    private(set) var progress = 0.0
    var errorMessage: String?
    /// A short confirmation, shown for a moment ("Added to playlist").
    private(set) var notice: String?
    /// Length of each paragraph, for the progress bar and the time left.
    private(set) var blockLengths: [Int] = []
    /// The paragraph being read, or where reading stopped.
    private(set) var position = 0

    var readerFontSize: Double = UserDefaults.standard.object(forKey: "readerFontSize") as? Double ?? 20 {
        didSet {
            UserDefaults.standard.set(readerFontSize, forKey: "readerFontSize")
            readerJS("__bs.setFontSize(\(Int(readerFontSize)))")
        }
    }

    @ObservationIgnored private var blocks: [String] = []
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// The page being loaded in the hidden web view, until its article is extracted.
    @ObservationIgnored private var pendingPage: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        webView = WKWebView(frame: .zero, configuration: config)

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
        readerView.navigationDelegate = self
        observation = webView.observe(\.estimatedProgress) { [weak self] wv, _ in
            MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
        }

        speech.onBlockStart = { [weak self] i in
            self?.position = i
            self?.readerJS("__bs.highlightBlock(\(i))")
        }
        speech.onWord = { [weak self] i, r in self?.readerJS("__bs.highlightWord(\(i),\(r.location),\(r.length))") }
        speech.onFinish = { [weak self] in self?.readerJS("__bs.clear()") }
        speech.onComplete = { [weak self] in self?.playNextInPlaylist() }
        speech.onError = { [weak self] message in self?.errorMessage = message }
    }

    // MARK: Opening articles

    /// Pages sent from outside (share extension, "Open With", drag and drop).
    func handleOpenURL(_ url: URL) {
        guard let page = Self.page(for: url) else { return }
        Self.log.info("Shared URL: \(page.absoluteString, privacy: .public)")
        openOrQueue(page)
    }

    /// While an article is playing or paused, new ones wait in the playlist;
    /// otherwise the new one starts right away.
    private func openOrQueue(_ page: URL) {
        guard phase == .loading || (phase == .ready && speech.state != .idle) else {
            start(page)
            NSApp.activate()
            return
        }
        showNotice(playlist.add(page) ? String(localized: "Added to playlist") : String(localized: "Already in the playlist"))
        // Stay in the browser so more articles can be queued; a bounce confirms it.
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if notice == text { notice = nil }
        }
    }

    /// A link pasted or dropped as text. Returns false when it isn't one.
    @discardableResult
    func open(text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = text.contains("://") ? URL(string: text)
            : (!text.contains(" ") && text.contains(".")) ? URL(string: "https://" + text) : nil
        guard let candidate, let page = Self.page(for: candidate) else {
            errorMessage = String(localized: "“\(String(text.prefix(60)))” is not an article link.")
            return false
        }
        openOrQueue(page)
        return true
    }

    func openFromPasteboard() {
        open(text: NSPasteboard.general.string(forType: .string) ?? "")
    }

    func openInBrowser() {
        if let articleURL { NSWorkspace.shared.open(articleURL) }
    }

    /// Closes the article; the next one in the playlist, if any, starts.
    func closeArticle() {
        speech.stop()
        pendingPage = nil
        webView.stopLoading()
        if !playNextInPlaylist() { phase = .empty }
    }

    /// Starts the first article of the playlist and removes it from the list.
    @discardableResult
    func playNextInPlaylist() -> Bool {
        guard let next = playlist.popFirst() else { return false }
        start(next.url)
        return true
    }

    func playNow(_ id: UUID) {
        guard let item = playlist.take(id) else { return }
        start(item.url)
    }

    private func start(_ page: URL) {
        speech.stop()
        errorMessage = nil
        pendingPage = page
        loadingHost = page.isFileURL ? page.lastPathComponent : (page.host() ?? page.absoluteString)
        progress = 0
        phase = .loading
        if page.isFileURL {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: page))
        }
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

    /// Runs Readability on the loaded page, then shows the article.
    private func extractArticle() async {
        guard let page = pendingPage else { return }
        guard let script = ReaderPage.extractionScript else {
            return fail(String(localized: "Readability.js is missing from the app."))
        }
        guard let json = await webView.evaluate(script, in: .defaultClient),
              let article = try? JSONDecoder().decode(Article.self, from: Data(json.utf8))
        else { return fail(String(localized: "Couldn’t extract the content of this page.")) }
        guard pendingPage == page else { return }
        pendingPage = nil
        articleURL = webView.url ?? page
        articleTitle = article.title
        siteName = article.siteName
        readerView.loadHTMLString(ReaderPage.html(for: article, fontSize: readerFontSize), baseURL: articleURL)
        // The page itself is no longer needed: stop its scripts and media.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Once the article is displayed: split it into paragraphs and start reading.
    private func articleDisplayed() async {
        guard let json = await readerView.evaluate("JSON.stringify(__bs.blocks())", in: Self.readerWorld),
              let blocks = try? JSONDecoder().decode([String].self, from: Data(json.utf8)), !blocks.isEmpty
        else { return fail(String(localized: "This article has no text to read.")) }
        self.blocks = blocks
        blockLengths = blocks.map(\.count)
        position = 0
        phase = .ready
        speech.speak(blocks, from: 0)
        Self.log.info("Reading started: \(self.speech.state == .speaking, privacy: .public)")
    }

    private func fail(_ message: String) {
        pendingPage = nil
        errorMessage = message
        phase = .empty
    }

    // MARK: Playback

    func togglePlayPause() {
        switch speech.state {
        case .speaking: speech.pause()
        case .paused: speech.resume()
        case .idle: Task { await startSpeaking(from: nil) }
        }
    }

    func seek(to index: Int) {
        guard blocks.indices.contains(index) else { return }
        position = index
        if speech.hasBlocks { speech.jump(to: index) } else { speech.speak(blocks, from: index) }
    }

    func previous() {
        speech.hasBlocks ? speech.previous() : seek(to: max(position - 1, 0))
    }

    func next() {
        speech.hasBlocks ? speech.next() : seek(to: position + 1)
    }

    /// Starts at `index`, or at the first paragraph visible on screen.
    func startSpeaking(from index: Int?) async {
        guard phase == .ready else { return }
        if let index { return seek(to: index) }
        let first = await readerView.evaluate("String(__bs.firstVisible())", in: Self.readerWorld).flatMap(Int.init)
        seek(to: first ?? position)
    }

    /// "−12 min", from the given paragraph to the end, at the current speed and pauses.
    func timeLeftLabel(from index: Int) -> String {
        guard blockLengths.indices.contains(index) else { return "" }
        let characters = Double(blockLengths[index...].reduce(0, +))
        let pauses = Double(blockLengths.count - index) * speech.pacing.paragraph
        let seconds = characters / (Self.charactersPerSecond * speech.speed) + pauses
        return seconds < 60 ? "−\(Int(seconds)) s" : "−\(Int((seconds / 60).rounded())) min"
    }

    func zoom(by step: Int) {
        readerFontSize = min(max(readerFontSize + Double(step) * 2, 12), 44)
    }

    func resetZoom() {
        readerFontSize = 20
    }

    private func readerJS(_ js: String) {
        guard phase == .ready else { return }
        readerView.evaluateJavaScript(js, in: nil, in: Self.readerWorld)
    }
}

// MARK: - WebKit delegates

extension BrowserModel: WKNavigationDelegate, WKScriptMessageHandler {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === readerView, navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else { return .allow }
        // In-article anchors (footnotes) scroll the reader; other links open in the user's browser.
        if url.fragment != nil, url.withoutFragment == articleURL?.withoutFragment { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView, pendingPage != nil {
            Task {
                // Give script-rendered pages a moment to fill in their content.
                try? await Task.sleep(for: .milliseconds(600))
                await extractArticle()
            }
        } else if webView === readerView, phase == .loading {
            Task { await articleDisplayed() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        guard webView === self.webView, pendingPage != nil, nsError.code != NSURLErrorCancelled else { return }
        fail(nsError.localizedDescription)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "toggle": togglePlayPause()
        case "prev": previous()
        case "next": next()
        case "click":
            guard let index = body["index"] as? Int else { return }
            // While reading, a click on a paragraph jumps there; ⌥-click always starts reading from it.
            if speech.hasBlocks || body["alt"] as? Bool == true { seek(to: index) }
        default: break
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
