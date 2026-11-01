import Foundation
import Observation
import WebKit

struct FeedSource: Codable, Identifiable, Hashable {
    enum Mode: String, Codable {
        /// An RSS or Atom feed: reliable titles and dates.
        case feed
        /// No feed found: article-like links taken from the page (approximate).
        case page
    }

    var id = UUID()
    /// What the user entered.
    let address: URL
    /// The feed, or the page whose links are read.
    var url: URL
    var mode: Mode
    var title: String
    var lastError: String?
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let title: String
    let date: Date?
    let sourceID: UUID
    let sourceTitle: String
}

/// Sites and feeds the user follows, and their latest articles. Accepts a feed
/// address or a site address: for a site, looks for its feed, then falls back
/// to the article links of the page.
@MainActor
@Observable
final class Feeds {
    static let shared = Feeds()
    private static let itemsPerSource = 30
    static let refreshInterval: TimeInterval = 30 * 60

    private(set) var sources: [FeedSource] = [] {
        didSet { save(sources, as: "feedSources") }
    }
    private(set) var items: [FeedItem] = [] {
        didSet { save(items, as: "feedItems") }
    }
    private(set) var isRefreshing = false
    private(set) var isAdding = false
    private(set) var addError: String?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    init() {
        sources = load("feedSources") ?? []
        items = load("feedItems") ?? []
    }

    /// Newest first; page links (no date) keep their page order after dated items.
    var latest: [FeedItem] {
        items.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): x > y
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Sources

    func add(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAdding else { return }
        guard let address = URL(string: text.contains("://") ? text : "https://" + text), address.host() != nil else {
            addError = String(localized: "“\(text)” is not a web address.")
            return
        }
        isAdding = true
        addError = nil
        defer { isAdding = false }
        guard let source = await Self.discover(address) else {
            addError = String(localized: "No articles found at this address.")
            return
        }
        guard !sources.contains(where: { $0.url == source.url }) else {
            addError = String(localized: "This source is already in the list.")
            return
        }
        sources.append(source)
        await refresh(source)
    }

    func remove(_ source: FeedSource) {
        sources.removeAll { $0.id == source.id }
        items.removeAll { $0.sourceID == source.id }
    }

    // MARK: Refresh

    func refreshIfNeeded() async {
        if Date().timeIntervalSince(lastRefresh) > Self.refreshInterval { await refreshAll() }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = Date()
        for source in sources { await refresh(source) }
    }

    private func refresh(_ source: FeedSource) async {
        var fetched: [(url: URL, title: String, date: Date?)] = []
        var error: String?
        switch source.mode {
        case .feed:
            if let data = await Self.fetch(source.url), let feed = FeedParser.parse(data) {
                fetched = feed.items.map { ($0.url, $0.title, $0.date) }
            } else {
                error = String(localized: "The feed could not be read.")
            }
        case .page:
            fetched = await PageLinks.extract(from: source.url).map { ($0.url, $0.title, nil) }
            if fetched.isEmpty { error = String(localized: "No article links found on the page.") }
        }
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].lastError = error
        guard !fetched.isEmpty else { return }
        let fresh = fetched.prefix(Self.itemsPerSource).map {
            FeedItem(url: $0.url, title: $0.title, date: $0.date, sourceID: source.id, sourceTitle: sources[index].title)
        }
        items = items.filter { $0.sourceID != source.id } + fresh
    }

    // MARK: Discovery

    /// 1. the address is a feed; 2. the page announces one; 3. a usual feed
    /// address answers; 4. otherwise, the page's article links.
    private static func discover(_ address: URL) async -> FeedSource? {
        // Typed without "www.": some sites only answer properly with it.
        if let host = address.host(), !host.hasPrefix("www."),
           var components = URLComponents(url: address, resolvingAgainstBaseURL: false) {
            if let source = await discover(at: address) { return source }
            components.host = "www." + host
            return await components.url.asyncFlatMap { await discover(at: $0) }
        }
        return await discover(at: address)
    }

    private static func discover(at requested: URL) async -> FeedSource? {
        guard let (data, address) = await fetchFollowingRedirects(requested) else { return nil }
        if let feed = FeedParser.parse(data), !feed.items.isEmpty {
            return FeedSource(address: address, url: address, mode: .feed, title: feed.title ?? address.host() ?? "")
        }
        let html = String(decoding: data.prefix(600_000), as: UTF8.self)
        // "Radio-Canada.ca | Information, radio, télé…" → "Radio-Canada.ca"
        let pageTitle = matchTitle(in: html)?.components(separatedBy: " | ").first ?? address.host() ?? ""
        var candidates = announcedFeeds(in: html, base: address)
        var withSlash = address.absoluteString
        if !withSlash.hasSuffix("/") { withSlash += "/" }
        candidates += ["rss", "feed"].compactMap { URL(string: withSlash + $0) }
        candidates += ["/feed", "/rss", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml", "/feed/"]
            .compactMap { URL(string: $0, relativeTo: address)?.absoluteURL }
        for candidate in candidates {
            if let data = await fetch(candidate), let feed = FeedParser.parse(data), !feed.items.isEmpty {
                return FeedSource(address: address, url: candidate, mode: .feed, title: feed.title ?? pageTitle)
            }
        }
        guard !(await PageLinks.extract(from: address)).isEmpty else { return nil }
        return FeedSource(address: address, url: address, mode: .page, title: pageTitle)
    }

    private static func announcedFeeds(in html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link[^>]+>", options: .caseInsensitive),
              let href = try? NSRegularExpression(pattern: "href=[\"']([^\"']+)[\"']", options: .caseInsensitive)
        else { return [] }
        return tag.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            let link = String(html[Range(match.range, in: html)!])
            let lower = link.lowercased()
            guard lower.contains("alternate"), lower.contains("rss+xml") || lower.contains("atom+xml"),
                  let result = href.firstMatch(in: link, range: NSRange(link.startIndex..., in: link)),
                  let range = Range(result.range(at: 1), in: link)
            else { return nil }
            return URL(string: link[range].replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
        }
    }

    private static func matchTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: .caseInsensitive),
              let result = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(result.range(at: 1), in: html)
        else { return nil }
        return html[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetch(_ url: URL) async -> Data? {
        await fetchFollowingRedirects(url)?.data
    }

    /// The page and the address it was finally served from, to resolve
    /// relative links and feed addresses against the right site.
    static func fetchFollowingRedirects(_ url: URL) async -> (data: Data, url: URL)? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request, delegate: SecureRedirects.shared),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return (data, response.url ?? url)
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

// MARK: - RSS / Atom

/// Reads RSS 2.0, RSS 1.0 (RDF) and Atom feeds.
final class FeedParser: NSObject, XMLParserDelegate {
    struct Feed {
        var title: String?
        var items: [(url: URL, title: String, date: Date?)] = []
    }

    static func parse(_ data: Data) -> Feed? {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.isFeed else { return nil }
        return delegate.feed
    }

    private var feed = Feed()
    private var isFeed = false
    private var inItem = false
    private var text = ""
    private var itemTitle = "", itemLink = "", itemDate = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = element.lowercased()
        if ["rss", "feed", "rdf:rdf", "rdf"].contains(name) { isFeed = true }
        if name == "item" || name == "entry" {
            inItem = true
            itemTitle = ""; itemLink = ""; itemDate = ""
        }
        // Atom: <link rel="alternate" href="…"/>
        if inItem, name == "link", let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate" {
            itemLink = href
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let name = element.lowercased(), value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title": itemTitle = value
            case "link" where !value.isEmpty: itemLink = value
            case "pubdate": itemDate = value
            case "published", "updated", "dc:date": if itemDate.isEmpty { itemDate = value }
            case "item", "entry":
                inItem = false
                if let url = URL(string: itemLink), url.scheme?.hasPrefix("http") == true, !itemTitle.isEmpty {
                    feed.items.append((url, itemTitle, Self.date(itemDate)))
                }
            default: break
            }
        } else if name == "title", feed.title == nil, !value.isEmpty {
            feed.title = value
        }
        text = ""
    }

    private static func date(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}

// MARK: - Links from a page

/// For sites without a feed: loads the page in a hidden web view (many home
/// pages are built by JavaScript), then keeps links that look like articles —
/// same site, with a title of a few words.
@MainActor
final class PageLinks: NSObject, WKNavigationDelegate {
    struct Link: Decodable {
        let url: URL
        let title: String
    }

    static func extract(from page: URL) async -> [Link] {
        let loader = PageLinks()
        return await loader.load(page)
    }

    private let webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: config)
    }()
    private var finished: CheckedContinuation<Void, Never>?

    private func load(_ page: URL) async -> [Link] {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            finished = continuation
            webView.load(URLRequest(url: page, timeoutInterval: 20))
        }
        // Let scripts fill in the page.
        try? await Task.sleep(for: .seconds(2))
        let script = """
        (() => {
          const seen = new Set(), out = [];
          for (const a of document.querySelectorAll("a[href]")) {
            const url = new URL(a.href, location.href);
            const title = (a.innerText || a.getAttribute("aria-label") || "").replace(/\\s+/g, " ").trim();
            if (url.hostname !== location.hostname || url.pathname.split("/").filter(Boolean).length < 2) continue;
            if (title.length < 25 || title.split(" ").length < 4 || seen.has(url.pathname)) continue;
            seen.add(url.pathname);
            url.hash = "";
            out.push({ url: url.href, title: title.slice(0, 200) });
          }
          return JSON.stringify(out.slice(0, 40));
        })()
        """
        guard let json = await webView.evaluate(script, in: .defaultClient),
              let links = try? JSONDecoder().decode([Link].self, from: Data(json.utf8))
        else { return [] }
        return links
    }

    private func done() {
        finished?.resume()
        finished = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done() }
}

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

/// Some sites redirect to an http:// address (e.g. "/news" →
/// "http://www.example.com/news/"), which macOS blocks. Follow such
/// redirects over https instead.
final class SecureRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = SecureRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return request }
        components.scheme = "https"
        var secure = request
        secure.url = components.url
        return secure
    }
}
