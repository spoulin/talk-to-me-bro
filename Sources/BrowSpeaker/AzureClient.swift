import CryptoKit
import Foundation

struct AzureSynthesizer: ClipSynthesizer {
    func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        try await AzureClient.synthesize(text, voice: voice, speed: speed)
    }
}

/// Azure Speech REST API: voice list and synthesis.
/// https://learn.microsoft.com/azure/ai-services/speech-service/rest-text-to-speech
enum AzureClient {
    struct VoiceInfo: Decodable {
        let ShortName: String
        let LocalName: String
        let Locale: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func voices() async throws -> [VoiceInfo] {
        let data = try await send(path: "voices/list", method: "GET", body: nil, headers: [:])
        return try JSONDecoder().decode([VoiceInfo].self, from: data)
    }

    static func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        let percent = Int(((speed - 1) * 100).rounded())
        let rate = (percent >= 0 ? "+" : "") + "\(percent)%"
        let cacheFile = try cacheDirectory().appendingPathComponent(cacheName(voice, rate, text) + ".mp3")
        if let cached = try? Data(contentsOf: cacheFile) { return cached }

        let locale = voice.split(separator: "-").prefix(2).joined(separator: "-")
        let ssml = """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="\(locale)">\
        <voice name="\(escape(voice))"><prosody rate="\(rate)">\(escape(text))</prosody></voice></speak>
        """
        let data = try await send(path: "v1", method: "POST", body: Data(ssml.utf8), headers: [
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "audio-24khz-48kbitrate-mono-mp3",
        ])
        try? data.write(to: cacheFile)
        return data
    }

    private static func send(path: String, method: String, body: Data?, headers: [String: String]) async throws -> Data {
        guard let key = AzureConfig.key, !AzureConfig.region.isEmpty,
              let url = URL(string: "https://\(AzureConfig.region).tts.speech.microsoft.com/cognitiveservices/\(path)")
        else { throw Failure(errorDescription: "clé ou région manquante") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("TalkToMeBro", forHTTPHeaderField: "User-Agent")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401: throw Failure(errorDescription: "clé refusée (401) — vérifiez la clé et la région")
        case 429: throw Failure(errorDescription: "quota dépassé ou trop de requêtes (429)")
        default: throw Failure(errorDescription: "erreur \(status)")
        }
    }

    private static func cacheDirectory() throws -> URL {
        let dir = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("local.browspeaker/azure", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheName(_ parts: String...) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
