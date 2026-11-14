import ApplicationServices
import AppKit
import AVFoundation

/// The voice chosen in System Settings › Accessibility › Spoken Content, Siri
/// voices included. AVSpeechSynthesizer keeps Siri voices out of reach, but the
/// older Speech Synthesis Manager (what `say` uses) speaks with the system
/// voice whatever it is. Each segment is rendered to a file and played like a
/// Piper clip: speaking live, it stops after a word when the volume is very low.
struct SiriSynthesizer: ClipSynthesizer {
    func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data {
        try await SiriVoice.render(text, speed: speed)
    }
}

@MainActor
enum SiriVoice {
    /// The Spoken Content voice is one AVSpeechSynthesizer can't use (a Siri voice).
    static var isSystemVoice: Bool {
        AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue) == nil
    }

    /// "Siri — Pierre", from the Spoken Content voice of the system speech language.
    static var label: String {
        let selections = UserDefaults(suiteName: "com.apple.Accessibility")?
            .array(forKey: "SpokenContentDefaultVoiceSelectionsByLanguage") ?? []
        // Language, then its selection, in turn.
        let language = String(AVVoices.systemLanguage.prefix(2))
        let voiceID = stride(from: 0, to: selections.count - 1, by: 2)
            .first { (selections[$0] as? String) == language }
            .flatMap { (selections[$0 + 1] as? [String: Any])?["voiceId"] as? String }
        guard let voiceID, voiceID.contains(".siri.") else { return "Siri" }
        return "Siri — " + (voiceID.split(separator: ".").last.map(String.init) ?? "")
    }

    /// The text spoken by the system voice into an AIFF file, at the Spoken
    /// Content rate times `speed`.
    static func render(_ text: String, speed: Double) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        defer { try? FileManager.default.removeItem(at: url) }
        var newChannel: SpeechChannel?
        let status = NewSpeechChannel(nil, &newChannel)
        guard status == noErr, let channel = newChannel else { throw failure(Int(status)) }
        defer { DisposeSpeechChannel(channel) }
        var rate: AnyObject?
        if CopySpeechProperty(channel, kSpeechRateProperty, &rate) == noErr, let wpm = (rate as? NSNumber)?.doubleValue, wpm > 0 {
            SetSpeechProperty(channel, kSpeechRateProperty, wpm * speed as CFNumber)
        }
        SetSpeechProperty(channel, kSpeechOutputToFileURLProperty, url as CFURL)
        let done = Done()
        let relay = Unmanaged.passRetained(done)
        defer { relay.release() }
        SetSpeechProperty(channel, kSpeechRefConProperty, Int(bitPattern: relay.toOpaque()) as CFNumber)
        SetSpeechProperty(channel, kSpeechSpeechDoneCallBack, unsafeBitCast(Self.finished, to: Int.self) as CFNumber)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            done.wait(continuation)
            let status = SpeakCFString(channel, text as CFString, nil)
            if status != noErr { done.finish(throwing: failure(Int(status))) }
            // A voice that never answers must not stall the reading.
            Task {
                try? await Task.sleep(for: .seconds(60))
                done.finish(throwing: failure(nil))
            }
        }
        return try Data(contentsOf: url)
    }

    /// nil: no answer in time.
    private static func failure(_ status: Int?) -> Error {
        NSError(domain: "SpeechSynthesis", code: status ?? -1, userInfo: [
            NSLocalizedDescriptionKey: status.map { String(localized: "The system voice failed (error \($0)).") }
                ?? String(localized: "The system voice didn't answer.")
        ])
    }

    /// Called on the speech thread when the file is written.
    private static let finished: SpeechDoneProcPtr = { _, refCon in
        Unmanaged<Done>.fromOpaque(refCon).takeUnretainedValue().finish(throwing: nil)
    }

    /// Resumes the rendering once, whichever comes first: the end, an error, or the time limit.
    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        func wait(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func finish(throwing error: Error?) {
            let continuation = lock.withLock {
                defer { self.continuation = nil }
                return self.continuation
            }
            if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        }
    }
}
