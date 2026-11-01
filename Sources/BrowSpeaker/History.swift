import Foundation
import Observation

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    let url: URL
    var title: String
    var site: String
    var date: Date
}

/// The last articles opened, most recent first. Kept between launches.
@MainActor
@Observable
final class History {
    static let shared = History()
    static let limit = 50
    private static let defaultsKey = "history"

    private(set) var items: [HistoryItem] = [] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.defaultsKey) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = saved
        }
    }

    /// An article read again moves back to the top.
    func record(_ url: URL, title: String, site: String) {
        var list = items.filter { $0.url != url }
        list.insert(HistoryItem(url: url, title: title.isEmpty ? url.absoluteString : title, site: site, date: Date()), at: 0)
        items = Array(list.prefix(Self.limit))
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func clear() {
        items.removeAll()
    }
}
