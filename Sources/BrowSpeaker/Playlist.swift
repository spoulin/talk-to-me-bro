import Foundation
import Observation
import SwiftUI

struct PlaylistItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let url: URL
    var title: String?
    var site: String?

    var displayTitle: String { title ?? url.host() ?? url.lastPathComponent }
    var displaySite: String { site ?? url.host() ?? "" }
}

/// Articles waiting to be read after the current one. Shared by all windows
/// and kept between launches.
@MainActor
@Observable
final class Playlist {
    static let shared = Playlist()
    private static let defaultsKey = "playlist"

    private(set) var items: [PlaylistItem] = [] {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([PlaylistItem].self, from: data) {
            items = saved
        }
    }

    /// Returns false when the page is already waiting.
    @discardableResult
    func add(_ url: URL) -> Bool {
        guard !items.contains(where: { $0.url == url }) else { return false }
        let item = PlaylistItem(url: url)
        items.append(item)
        Task { await fetchTitle(of: item) }
        return true
    }

    func popFirst() -> PlaylistItem? {
        items.isEmpty ? nil : items.removeFirst()
    }

    func take(_ id: UUID) -> PlaylistItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
    }

    func clear() {
        items.removeAll()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.defaultsKey)
    }

    /// Fetches the page's title and site name, so the list shows more than an address.
    private func fetchTitle(of item: PlaylistItem) async {
        var title: String?, site: String?
        if item.url.isFileURL {
            title = item.url.deletingPathExtension().lastPathComponent
        } else {
            var request = URLRequest(url: item.url, timeoutInterval: 10)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { return }
            let html = String(decoding: data.prefix(400_000), as: UTF8.self)
            title = Self.meta("og:title", in: html) ?? Self.match("<title[^>]*>([^<]+)</title>", in: html)
            site = Self.meta("og:site_name", in: html)
        }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].title = title.map(Self.decodeEntities)
        items[index].site = site.map(Self.decodeEntities)
    }

    private static func meta(_ property: String, in html: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: property)
        return match("<meta[^>]+(?:property|name)=[\"']\(name)[\"'][^>]*content=[\"']([^\"']+)[\"']", in: html)
            ?? match("<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(name)[\"']", in: html)
    }

    private static func match(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(result.range(at: 1), in: html)
        else { return nil }
        let value = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeEntities(_ text: String) -> String {
        var text = text
        let named = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ",
                     "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&ndash;": "–",
                     "&mdash;": "—", "&hellip;": "…", "&laquo;": "«", "&raquo;": "»"]
        for (entity, character) in named { text = text.replacingOccurrences(of: entity, with: character) }
        // Numeric entities: &#39; &#x2019;
        let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for result in (regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).reversed() {
            guard let whole = Range(result.range, in: text),
                  let hex = Range(result.range(at: 1), in: text), let digits = Range(result.range(at: 2), in: text),
                  let code = UInt32(text[digits], radix: text[hex].isEmpty ? 10 : 16),
                  let scalar = Unicode.Scalar(code)
            else { continue }
            text.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return text
    }
}
