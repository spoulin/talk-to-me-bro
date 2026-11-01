import Foundation
import Observation
import os
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
    /// Last time a source read from its page was checked for a feed, and with
    /// which version of the discovery (an improved one checks again at once).
    var feedCheckedAt: Date?
    var feedCheckRevision: Int?
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let title: String
    /// Publication date: from the feed, or read in the article.
    var date: Date?
    let sourceID: UUID
    let sourceTitle: String
    /// A picture for the magazine view: from the feed, the page, or the article's sharing image.
    var image: URL?
    /// When the app first listed the article.
    var firstSeen: Date?
    /// For an article with no date: the date of its neighbor on the source page,
    /// to keep it in place when sorting (not shown).
    var estimatedDate: Date?
    /// The article itself was read for a missing date or picture (not done again).
    var detailsChecked: Bool?
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
    static let log = Logger(subsystem: "local.browspeaker", category: "feeds")

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
    private static let feedCheckInterval: TimeInterval = 7 * 24 * 3600
    /// Bump when discovery finds feeds it could not before (2: feed listing pages).
    private static let feedCheckRevision = 2

    init() {
        sources = load("feedSources") ?? []
        items = load("feedItems") ?? []
    }

    /// Newest first, all sources mixed: by publication date, or for an article
    /// with no date, by when it first appeared.
    /// An article listed by several sources appears once, with the best details.
    var latest: [FeedItem] {
        var best: [URL: FeedItem] = [:]
        for item in items {
            guard var kept = best[item.url] else { best[item.url] = item; continue }
            if kept.date == nil, item.date != nil { kept = item }
            if kept.image == nil { kept.image = item.image }
            best[item.url] = kept
        }
        var seen = Set<URL>()
        return items.enumerated().filter { seen.insert($0.element.url).inserted }
            .compactMap { pair in best[pair.element.url].map { (pair.offset, $0) } }
            .sorted { a, b in
                let x = a.1.date ?? a.1.estimatedDate ?? a.1.firstSeen ?? .distantPast
                let y = b.1.date ?? b.1.estimatedDate ?? b.1.firstSeen ?? .distantPast
                return x != y ? x > y : a.0 < b.0
            }
            .map(\.1)
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
        // All at once: the wait is the slowest source, not the sum.
        await withTaskGroup(of: Void.self) { group in
            for source in sources { group.addTask { await self.refresh(source) } }
        }
    }

    private func refresh(_ source: FeedSource) async {
        let started = Date()
        defer { Self.log.info("refreshed \(source.title, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1), privacy: .public)s") }
        var source = source
        // A source read from its page (or added before feeds were found this way):
        // look for a feed again, once a week.
        if source.mode == .page, source.feedCheckRevision != Self.feedCheckRevision
            || Date().timeIntervalSince(source.feedCheckedAt ?? .distantPast) > Self.feedCheckInterval {
            let feed = await Self.discover(source.address, feedsOnly: true)
            if let index = sources.firstIndex(where: { $0.id == source.id }) {
                sources[index].feedCheckedAt = Date()
                sources[index].feedCheckRevision = Self.feedCheckRevision
                if let feed {
                    sources[index].url = feed.url
                    sources[index].mode = .feed
                    sources[index].title = feed.title
                }
                source = sources[index]
            }
        }
        var fetched: [(url: URL, title: String, date: Date?, image: URL?)] = []
        var error: String?
        switch source.mode {
        case .feed:
            if let data = await Self.fetch(source.url), let feed = FeedParser.parse(data) {
                fetched = feed.items.map { ($0.url, $0.title, $0.date, $0.image) }
            } else {
                error = String(localized: "The feed could not be read.")
            }
        case .page:
            fetched = await PageLinks.extract(from: source.url).map { ($0.url, $0.title, nil, $0.image) }
            if fetched.isEmpty { error = String(localized: "No article links found on the page.") }
        }
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index].lastError = error
        guard !fetched.isEmpty else { return }
        let previous = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        var fresh = fetched.prefix(Self.itemsPerSource).map { entry -> FeedItem in
            let old = previous[entry.url]
            return FeedItem(url: entry.url, title: entry.title, date: entry.date ?? old?.date, sourceID: source.id,
                            sourceTitle: sources[index].title, image: entry.image ?? old?.image,
                            firstSeen: old?.firstSeen ?? now, detailsChecked: old?.detailsChecked)
        }
        items = items.filter { $0.sourceID != source.id } + fresh
        // Articles without a date or a picture: read them in the article itself
        // (article:published_time, og:image…), once per article, in the background.
        let missing = Set(fresh.filter { ($0.date == nil || $0.image == nil) && $0.detailsChecked != true }.map(\.url))
        let found: [URL: ArticleDetails] = missing.isEmpty ? [:] : await withTaskGroup(of: (URL, ArticleDetails?).self) { group in
            for url in missing { group.addTask { (url, await Self.articleDetails(of: url)) } }
            var found: [URL: ArticleDetails] = [:]
            for await (url, details) in group { found[url] = details }
            return found
        }
        for i in fresh.indices where missing.contains(fresh[i].url) {
            let details = found[fresh[i].url]
            fresh[i].date = fresh[i].date ?? details?.date
            fresh[i].image = fresh[i].image ?? details?.image
            fresh[i].detailsChecked = true
        }
        // Still no date: borrow the one of the previous article on the page (or
        // the next one), since a page lists its articles from newest to oldest.
        var previousDate = fresh.first { $0.date != nil }?.date
        for i in fresh.indices {
            if let date = fresh[i].date { previousDate = date } else { fresh[i].estimatedDate = previousDate }
        }
        items = items.filter { $0.sourceID != source.id } + fresh
    }

    // MARK: Discovery

    /// 1. the address is a feed; 2. the page announces one; 3. a usual feed
    /// address answers; 4. otherwise, the page's article links.
    private static func discover(_ address: URL, feedsOnly: Bool = false) async -> FeedSource? {
        // Typed without "www.": some sites only answer properly with it.
        if let host = address.host(), !host.hasPrefix("www."),
           var components = URLComponents(url: address, resolvingAgainstBaseURL: false) {
            if let source = await discover(at: address, feedsOnly: feedsOnly) { return source }
            components.host = "www." + host
            return await components.url.asyncFlatMap { await discover(at: $0, feedsOnly: feedsOnly) }
        }
        return await discover(at: address, feedsOnly: feedsOnly)
    }

    private static func discover(at requested: URL, feedsOnly: Bool) async -> FeedSource? {
        guard let (data, address) = await fetchFollowingRedirects(requested) else { return nil }
        if let feed = FeedParser.parse(data), !feed.items.isEmpty {
            return FeedSource(address: address, url: address, mode: .feed, title: feed.title ?? address.host() ?? "")
        }
        // The whole page: YouTube announces its feed after 800 KB of scripts.
        let html = String(decoding: data, as: UTF8.self)
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
        // A page listing the site's feeds, linked from the home page ("Flux RSS"…).
        for listingURL in links(in: html, base: address).filter({ isFeedListing($0, of: address) }).prefix(4) {
            guard let data = await fetch(listingURL) else { continue }
            if let feed = FeedParser.parse(data), !feed.items.isEmpty {
                return FeedSource(address: address, url: listingURL, mode: .feed, title: feed.title ?? pageTitle)
            }
            let listing = String(decoding: data, as: UTF8.self)
            let feeds = announcedFeeds(in: listing, base: listingURL) + links(in: listing, base: listingURL).filter {
                let path = $0.path().lowercased()
                return path.hasSuffix(".xml") || path.hasSuffix(".rss") || path.contains("/rss/") || path.contains("/feed")
            }
            for candidate in feeds.prefix(12) {
                if let data = await fetch(candidate), let feed = FeedParser.parse(data), !feed.items.isEmpty {
                    return FeedSource(address: address, url: candidate, mode: .feed, title: feed.title ?? pageTitle)
                }
            }
        }
        guard !feedsOnly, !(await PageLinks.extract(from: address)).isEmpty else { return nil }
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

    /// Every link of a page, as absolute addresses.
    private static func links(in html: String, base: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "href=[\"']([^\"'#]+)[\"']", options: .caseInsensitive) else { return [] }
        var seen = Set<URL>()
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { result in
            Range(result.range(at: 1), in: html).flatMap {
                URL(string: html[$0].replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
            }
        }.filter { $0.scheme?.hasPrefix("http") == true && seen.insert($0).inserted }
    }

    /// A same-site page whose address mentions feeds: "/flux-rss", "/rss", "/feeds"…
    private static func isFeedListing(_ url: URL, of site: URL) -> Bool {
        let host = { (url: URL) in (url.host() ?? "").replacingOccurrences(of: "www.", with: "") }
        let path = url.path().lowercased()
        return host(url) == host(site) && (path.contains("rss") || path.contains("feed") || path.contains("atom"))
    }

    struct ArticleDetails {
        var image: URL?
        var date: Date?
    }

    /// What an article page says about itself: its sharing image (og:image,
    /// twitter:image) and publication date (article:published_time, datePublished…).
    nonisolated static func articleDetails(of page: URL) async -> ArticleDetails? {
        guard let data = await fetch(page) else { return nil }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        func meta(_ names: String) -> String? {
            for pattern in ["<meta[^>]+(?:property|name|itemprop)=[\"'](?:\(names))[\"'][^>]*content=[\"']([^\"']+)[\"']",
                            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name|itemprop)=[\"'](?:\(names))[\"']"] {
                if let value = firstMatch(pattern, in: html) { return value }
            }
            return nil
        }
        let image = meta("og:image|twitter:image").flatMap {
            URL(string: $0.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL
        }
        let dateText = meta("article:published_time|og:published_time|datePublished|pubdate|publish-date|date")
            ?? firstMatch("\"datePublished\"\\s*:\\s*\"([^\"]+)\"", in: html)
            ?? firstMatch("<time[^>]+datetime=[\"']([^\"']+)[\"']", in: html)
        return ArticleDetails(image: image, date: dateText.flatMap(parseDate))
    }

    nonisolated static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// "2026-11-01T09:31:41-05:00", with or without fractions of a second, or a plain day.
    nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime], [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    private static func matchTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: .caseInsensitive),
              let result = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(result.range(at: 1), in: html)
        else { return nil }
        return html[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func fetch(_ url: URL) async -> Data? {
        await fetchFollowingRedirects(url)?.data
    }

    /// The page and the address it was finally served from, to resolve
    /// relative links and feed addresses against the right site.
    nonisolated static func fetchFollowingRedirects(_ url: URL) async -> (data: Data, url: URL)? {
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
        var items: [(url: URL, title: String, date: Date?, image: URL?)] = []
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
    private var itemTitle = "", itemLink = "", itemDate = "", itemImage = "", itemHTML = ""

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = element.lowercased()
        if ["rss", "feed", "rdf:rdf", "rdf"].contains(name) { isFeed = true }
        if name == "item" || name == "entry" {
            inItem = true
            itemTitle = ""; itemLink = ""; itemDate = ""; itemImage = ""; itemHTML = ""
        }
        // Pictures: <enclosure type="image/…">, <media:content>, <media:thumbnail>, <itunes:image>
        if inItem, itemImage.isEmpty {
            let type = attributes["type"] ?? ""
            switch name {
            case "enclosure" where type.hasPrefix("image"), "media:thumbnail":
                itemImage = attributes["url"] ?? ""
            case "media:content" where type.hasPrefix("image") || attributes["medium"] == "image":
                itemImage = attributes["url"] ?? ""
            case "itunes:image":
                itemImage = attributes["href"] ?? ""
            default: break
            }
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
            case "description", "content:encoded", "content", "summary": itemHTML += value
            case "published", "updated", "dc:date": if itemDate.isEmpty { itemDate = value }
            case "item", "entry":
                inItem = false
                if let url = URL(string: itemLink), url.scheme?.hasPrefix("http") == true, !itemTitle.isEmpty {
                    let image = URL(string: itemImage.isEmpty ? Self.firstImage(in: itemHTML) ?? "" : itemImage)
                    feed.items.append((url, itemTitle, Self.date(itemDate), image?.scheme?.hasPrefix("http") == true ? image : nil))
                }
            default: break
            }
        } else if name == "title", feed.title == nil, !value.isEmpty {
            feed.title = value
        }
        text = ""
    }

    /// The first <img src="…"> of an item's HTML description.
    private static func firstImage(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]+src=[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let result = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(result.range(at: 1), in: html)
        else { return nil }
        return html[range].replacingOccurrences(of: "&amp;", with: "&")
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
        let image: URL?
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
        // Let scripts fill in the page: read the links until they stop changing (3 s at most).
        var links: [Link] = []
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(500))
            let found = await readLinks()
            if found.count >= 10, found.count == links.count { return found }
            links = found
        }
        return links
    }

    private func readLinks() async -> [Link] {
        let script = """
        (() => {
          const seen = new Set(), out = [];
          const norm = s => (s || "").replace(/\\s+/g, " ").trim();
          // The lines of an element: by layout when there is one, else by its parts
          // (<span class="suptitle">…</span><span>…</span>).
          const lines = el => {
            const byLayout = (el.innerText || "").split("\\n").map(norm).filter(Boolean);
            if (byLayout.length > 1) return byLayout;
            const kids = Array.from(el.children).filter(c => norm(c.textContent));
            const loose = Array.from(el.childNodes).some(n => n.nodeType === 3 && norm(n.textContent));
            if (kids.length > 1 && !loose && (/sup|kick|surtit|over|eyebrow|rubri|categ/i.test(kids[0].getAttribute("class") || "") ||
                /block|flex|grid/.test(getComputedStyle(kids[0]).display))) return kids.map(c => norm(c.textContent));
            return [norm(el.textContent)];
          };
          for (const a of document.querySelectorAll("a[href]")) {
            const url = new URL(a.href, location.href);
            // A link in parts → "Kicker — Title": its heading when it has one (not the
            // summary under it), and never "Publié à 5 h 00".
            const heading = a.querySelector("h1, h2, h3, h4, h5, h6");
            const parts = heading && norm(heading.textContent).length >= 25 ? lines(heading) : lines(a);
            const title = (parts.join("") ? parts : [norm(a.getAttribute("aria-label"))])
              .filter(s => s && !/^(publié|mis à jour|published|updated)\\b/i.test(s))
              .join(" — ");
            if (url.hostname !== location.hostname || url.pathname.split("/").filter(Boolean).length < 2) continue;
            if (title.length < 25 || title.split(" ").length < 4 || seen.has(url.pathname)) continue;
            seen.add(url.pathname);
            url.hash = "";
            const img = a.querySelector("img") || a.closest("article, li, figure")?.querySelector("img");
            const src = img && (img.currentSrc || img.src || img.dataset.src || "");
            out.push({ url: url.href, title: title.slice(0, 200),
                       image: src && src.startsWith("http") ? src : null });
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
