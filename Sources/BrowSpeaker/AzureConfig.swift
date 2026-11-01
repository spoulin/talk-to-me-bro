import Foundation
import Observation
import Security

/// The user's own Azure Speech resource: the key lives in the Keychain, the
/// region (not a secret) in UserDefaults. Nothing is configured by default.
enum AzureConfig {
    private static let service = "local.browspeaker"
    private static let account = "azure-speech-key"
    /// Read once per launch: each Keychain read can prompt for access after a rebuild.
    private static var cachedKey: String??

    static var region: String {
        UserDefaults.standard.string(forKey: "azureRegion") ?? ""
    }

    static var key: String? {
        if let cachedKey { return cachedKey }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let key = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            : nil
        cachedKey = .some(key)
        return key
    }

    static var isConfigured: Bool { !(key ?? "").isEmpty && !region.isEmpty }

    static func save(key: String, region: String) {
        UserDefaults.standard.set(region.trimmingCharacters(in: .whitespaces).lowercased(), forKey: "azureRegion")
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            var add = match
            add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
        cachedKey = .some(key.isEmpty ? nil : key)
    }
}

/// Azure voices offered in the voice menu, shared by all windows. Limited to
/// the system speech language: Azure has several hundred voices.
@MainActor
@Observable
final class AzureVoices {
    static let shared = AzureVoices()

    private(set) var voices: [Voice] = []
    private(set) var status: String?
    @ObservationIgnored private var loaded = false

    func loadIfNeeded() async {
        guard !loaded else { return }
        await refresh()
    }

    func refresh() async {
        loaded = true
        guard AzureConfig.isConfigured else {
            voices = []
            status = nil
            return
        }
        do {
            let prefix = String(AVVoices.systemLanguage.prefix(2))
            voices = try await AzureClient.voices()
                .filter { $0.Locale.hasPrefix(prefix) }
                .sorted { ($0.Locale, $0.LocalName) < ($1.Locale, $1.LocalName) }
                .map { Voice(engine: .azure, id: $0.ShortName, label: "\($0.LocalName) — Azure (\($0.Locale))") }
            status = "Connecté : \(voices.count) voix en « \(prefix) »."
        } catch {
            voices = []
            status = "Échec : \(error.localizedDescription)"
        }
    }
}
