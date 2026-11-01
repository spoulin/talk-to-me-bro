import AppKit
import os
import UniformTypeIdentifiers

/// "Share › BrowSpeaker": forwards the shared link to the app as
/// `browspeaker://read?url=…`, which loads the page and starts reading it.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private static let log = Logger(subsystem: "local.browspeaker", category: "share")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task {
            let page = await sharedURL()
            Self.log.info("Shared page: \(page?.absoluteString ?? "none", privacy: .public)")
            if let page, let target = Self.readURL(for: page) {
                let opened = NSWorkspace.shared.open(target)
                Self.log.info("Opened BrowSpeaker: \(opened, privacy: .public)")
            }
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private static func readURL(for page: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "browspeaker"
        components.host = "read"
        components.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        return components.url
    }

    /// The first web link among the shared items: a URL, or the first link found in shared text.
    private func sharedURL() async -> URL? {
        // The shared items can arrive after viewDidLoad: wait for them a little.
        var items: [NSExtensionItem] = []
        for _ in 0..<30 {
            items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
            if !items.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        Self.log.info("""
            Shared items: \(items.count, privacy: .public), \
            types: \(providers.map(\.registeredTypeIdentifiers).description, privacy: .public), \
            text: \(items.compactMap { $0.attributedContentText?.string }.description, privacy: .public)
            """)
        // Some hosts (Dia) put the link in the item's text rather than in an attachment.
        for text in items.compactMap({ $0.attributedContentText?.string }) {
            if let url = Self.firstLink(in: text) { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL ?? (item as? Data).flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }),
               ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let url = Self.firstLink(in: text) {
                return url
            }
        }
        return nil
    }

    private static func firstLink(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        guard let match = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .first(where: { ["http", "https"].contains($0.url?.scheme?.lowercased()) }),
            let url = match.url, let range = Range(match.range, in: text)
        else { return nil }
        // A bare "example.com/…" is detected as http: prefer https.
        if !text[range].lowercased().hasPrefix("http"), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            return components.url ?? url
        }
        return url
    }
}
