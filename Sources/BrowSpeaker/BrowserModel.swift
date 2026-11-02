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
    let history = History.shared

    private(set) var phase: Phase = .empty
    /// The open article is a video page, shown with its own player.
    private(set) var isVideo = false
    /// The video's position, length and state, for the player bar.
    private(set) var videoTime = 0.0
    private(set) var videoDuration = 0.0
    private(set) var videoPlaying = false
    /// An ad is playing (and muted).
    private(set) var videoAd = false
    @ObservationIgnored private var videoPolling: Task<Void, Never>?
    /// A YouTube video, played in YouTube's own embeddable player (see `VideoPage.YouTube`).
    @ObservationIgnored private var isYouTube = false
    private(set) var articleTitle = ""
    private(set) var siteName = ""
    /// When the article or video was published, if known (shown in the player bar).
    private(set) var articleDate: Date?
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
    @ObservationIgnored private var kinds: [BlockKind] = []
    @ObservationIgnored private var language = ""
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// The page being loaded in the hidden web view, until its article is extracted.
    @ObservationIgnored private var pendingPage: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        // The player bar's ▶︎ starts videos from a script, not a click in the page.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: VideoPage.nextTrack, injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: false, in: .defaultClient))
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
        webView.configuration.userContentController.add(WeakScriptHandler(self), contentWorld: .defaultClient, name: "video")
        // The YouTube player page reports the end of the video from its own scripts.
        webView.configuration.userContentController.add(WeakScriptHandler(self), contentWorld: .page, name: "video")
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
        speech.onComplete = { [weak self] in self?.articleFinished() }

        // Playlist items added before titles were kept: fill them in from the sources and history.
        let feeds = Feeds.shared, history = History.shared
        playlist.repairTitles { url in
            let key = Self.readKey(url)
            if let item = feeds.items.first(where: { Self.readKey($0.url) == key }) { return (item.title, item.sourceTitle) }
            if let item = history.items.first(where: { Self.readKey($0.url) == key }) { return (item.title, item.site) }
            return nil
        }
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

    /// Back to the home page (✕, Escape); the playlist is left as it is.
    func closeArticle() {
        speech.stop()
        pendingPage = nil
        webView.stopLoading()
        if isVideo {
            webView.loadHTMLString("", baseURL: nil)
            isVideo = false
        }
        phase = .empty
    }

    /// The next article of the playlist (⏭), or the home page when it is empty.
    func nextArticle() {
        if !playNextInPlaylist() { closeArticle() }
    }

    /// The article was read (or the video watched) to the end: on to the next
    /// one of the playlist, or else back to the home page after a moment.
    private func articleFinished() {
        guard !playNextInPlaylist() else { return }
        let finished = articleURL
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // Unless something else was started meanwhile.
            guard articleURL == finished, phase == .ready, speech.state == .idle, !videoPlaying else { return }
            closeArticle()
        }
    }

    /// Starts the first article of the playlist and removes it from the list.
    @discardableResult
    func playNextInPlaylist() -> Bool {
        guard let next = playlist.popFirst() else { return false }
        start(next.url)
        return true
    }

    /// Reads an article from the history again, from the start.
    func reopen(_ item: HistoryItem) {
        start(item.url)
    }

    func play(_ url: URL) {
        start(url)
    }

    /// Queues the articles and starts the first one if nothing is playing.
    func listenToAll(_ articles: [FeedItem]) {
        articles.forEach { playlist.add($0.url, title: $0.title, site: $0.sourceTitle) }
        if phase != .ready || speech.state == .idle { playNextInPlaylist() }
    }

    /// Whether an article is in the history (query and fragment ignored).
    func hasRead(_ url: URL) -> Bool {
        let key = Self.readKey(url)
        return history.items.contains { Self.readKey($0.url) == key }
    }

    /// The same article whatever its tracking parameters: site and path. A YouTube
    /// video by its ID, which is in the query ("watch?v=…").
    static func readKey(_ url: URL) -> String {
        if let id = VideoPage.YouTube.videoID(in: url) { return "youtube/" + id }
        return (url.host() ?? "") + url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The publication date the sources already know for a page.
    private static func knownDate(of page: URL) -> Date? {
        let key = readKey(page)
        return Feeds.shared.items.first { readKey($0.url) == key }?.date
    }

    func addToPlaylist(_ url: URL, title: String? = nil, site: String? = nil) {
        showNotice(playlist.add(url, title: title, site: site) ? String(localized: "Added to playlist") : String(localized: "Already in the playlist"))
    }

    func playNow(_ id: UUID) {
        guard let item = playlist.take(id) else { return }
        start(item.url)
    }

    private func start(_ page: URL) {
        NowPlaying.shared.follow(self)
        speech.stop()
        isVideo = false
        isYouTube = false
        articleDate = Self.knownDate(of: page)
        if let id = VideoPage.YouTube.videoID(in: page) { return startYouTube(page, videoID: id) }
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
        if await isVideoPage(words: article.words ?? 0) {
            guard pendingPage == page else { return }
            return showVideo(article)
        }
        pendingPage = nil
        articleURL = webView.url ?? page
        articleTitle = article.kicker.flatMap { $0.isEmpty ? nil : "\($0) — \(article.title)" } ?? article.title
        language = article.lang
        articleDate = articleDate ?? article.published.flatMap(Feeds.parseDate)
        siteName = article.siteName
        readerView.loadHTMLString(ReaderPage.html(for: article, fontSize: readerFontSize), baseURL: articleURL)
        // The page itself is no longer needed: stop its scripts and media.
        webView.loadHTMLString("", baseURL: nil)
    }

    /// A video address, or very few words, with a large video on the page.
    /// Players are often added by scripts after the page loads: wait for them a little.
    private func isVideoPage(words: Int) async -> Bool {
        let byAddress = webView.url.map(VideoPage.looksLikeVideo) ?? false
        guard byAddress || words < VideoPage.shortArticleWords else { return false }
        for _ in 0..<(byAddress ? 16 : 6) {
            if await webView.evaluate(VideoPage.detect, in: .defaultClient) == "true" { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// YouTube: straight to video mode, in the privacy player, without loading youtube.com.
    private func startYouTube(_ page: URL, videoID: String) {
        errorMessage = nil
        pendingPage = nil
        articleURL = page
        articleTitle = String(localized: "YouTube video")
        siteName = "YouTube"
        blocks = []
        blockLengths = []
        isYouTube = true
        isVideo = true
        phase = .ready
        webView.loadHTMLString(VideoPage.YouTube.playerPage(videoID: videoID, speed: speech.speed,
                                                            language: String(AVVoices.systemLanguage.prefix(2))),
                               baseURL: URL(string: "https://www.youtube-nocookie.com/"))
        startVideoPolling()
        Task {
            if let details = await VideoPage.YouTube.details(of: page), articleURL == page {
                articleTitle = details.title
                siteName = details.channel
            }
            if articleURL == page { history.record(page, title: articleTitle, site: siteName) }
            if articleDate == nil, let date = await VideoPage.YouTube.publishDate(videoID: videoID), articleURL == page {
                articleDate = date
            }
        }
    }

    private var videoWorld: WKContentWorld { isYouTube ? .page : .defaultClient }

    private func runVideo(_ siteScript: String, youtube youTubeScript: String) {
        webView.evaluateJavaScript(isYouTube ? youTubeScript : siteScript, in: nil, in: videoWorld)
    }

    /// Video mode: the page stays, with its player isolated over the window.
    private func showVideo(_ article: Article) {
        pendingPage = nil
        articleURL = webView.url
        articleTitle = article.kicker.flatMap { $0.isEmpty ? nil : "\($0) — \(article.title)" } ?? article.title
        siteName = article.siteName
        articleDate = articleDate ?? article.published.flatMap(Feeds.parseDate)
        blocks = []
        blockLengths = []
        isVideo = true
        phase = .ready
        if let articleURL { history.record(articleURL, title: articleTitle, site: siteName) }
        webView.evaluateJavaScript(VideoPage.focus, in: nil, in: .defaultClient)
        // Opened to be watched: start it, like articles start reading. Wait for the
        // site's player to be ready, then act once: a second press disrupts some players.
        Task {
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(1))
                guard isVideo,
                      await webView.evaluate(VideoPage.autoplay, in: .defaultClient) == "none"
                else { return }
            }
        }
        startVideoPolling()
    }

    /// Follows the video's position and state for the player bar.
    private func startVideoPolling() {
        videoTime = 0
        videoDuration = 0
        videoPlaying = false
        videoAd = false
        videoPolling?.cancel()
        videoPolling = Task { [weak self] in
            while let self, self.isVideo, !Task.isCancelled {
                struct State: Decodable { var t: Double; var d: Double; var p: Bool }
                let script = self.isYouTube ? VideoPage.YouTube.state : VideoPage.state
                if let json = await self.webView.evaluate(script, in: self.videoWorld),
                   let state = try? JSONDecoder().decode(State.self, from: Data(json.utf8)) {
                    self.videoTime = state.t
                    self.videoDuration = state.d
                    if state.p, !self.videoPlaying { self.applyVideoSpeed() }
                    self.videoPlaying = state.p
                }
                // YouTube's player is in another site's frame: nothing to inspect there.
                if !self.isYouTube {
                    self.videoAd = await self.webView.evaluate(VideoPage.adPlaying, in: .defaultClient) == "true"
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func videoSeek(to seconds: Double) {
        videoTime = seconds
        runVideo(VideoPage.seek(to: seconds), youtube: VideoPage.YouTube.seek(to: seconds))
    }

    /// The reading speed also applies to videos.
    func applyVideoSpeed() {
        guard isVideo else { return }
        runVideo(VideoPage.rate(speech.speed), youtube: VideoPage.YouTube.rate(speech.speed))
    }

    /// Once the article is displayed: split it into paragraphs and start reading.
    private func articleDisplayed() async {
        struct Paragraphs: Decodable { var blocks: [String]; var kinds: [String] }
        guard let json = await readerView.evaluate("JSON.stringify({blocks: __bs.blocks(), kinds: __bs.kinds()})",
                                                   in: Self.readerWorld),
              let paragraphs = try? JSONDecoder().decode(Paragraphs.self, from: Data(json.utf8)),
              !paragraphs.blocks.isEmpty
        else { return fail(String(localized: "This article has no text to read.")) }
        blocks = paragraphs.blocks
        kinds = paragraphs.kinds.map { BlockKind(rawValue: $0) ?? .text }
        blockLengths = blocks.map(\.count)
        position = 0
        phase = .ready
        if let articleURL { history.record(articleURL, title: articleTitle, site: siteName) }
        speech.speak(blocks, kinds: kinds, language: language, from: 0)
        Self.log.info("Reading started: \(self.speech.state == .speaking, privacy: .public)")
    }

    private func fail(_ message: String) {
        pendingPage = nil
        errorMessage = message
        phase = .empty
    }

    // MARK: Playback

    func togglePlayPause() {
        NowPlaying.shared.follow(self)
        if isVideo { return runVideo(VideoPage.togglePlayback, youtube: VideoPage.YouTube.togglePlayback) }
        switch speech.state {
        case .speaking: speech.pause()
        case .paused: speech.resume()
        case .idle: Task { await startSpeaking(from: nil) }
        }
    }

    func seek(to index: Int) {
        guard blocks.indices.contains(index) else { return }
        position = index
        if speech.hasBlocks { speech.jump(to: index) } else { speech.speak(blocks, kinds: kinds, language: language, from: index) }
    }

    func previous() {
        if isVideo { return runVideo(VideoPage.skip(by: -15), youtube: VideoPage.YouTube.skip(by: -15)) }
        speech.hasBlocks ? speech.previous() : seek(to: max(position - 1, 0))
    }

    func next() {
        if isVideo { return runVideo(VideoPage.skip(by: 15), youtube: VideoPage.YouTube.skip(by: 15)) }
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
        guard !isVideo else { return }
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
        // The video of a video page ended: on to the next article of the playlist
        // (not at the end of an ad, which may play in the same player).
        if message.name == "video" {
            if isVideo, !videoAd, message.body as? String == "ended" { articleFinished() }
            if message.body as? String == "close" { closeArticle() }
            // ⏭ while a video plays (see `VideoPage.nextTrack`); like the menu, only with a playlist.
            if isVideo, message.body as? String == "next", !playlist.items.isEmpty { nextArticle() }
            return
        }
        guard let body = message.body as? [String: Any] else { return }
        switch body["type"] as? String {
        case "toggle": togglePlayPause()
        case "close": closeArticle()
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
