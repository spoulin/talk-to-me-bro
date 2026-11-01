import AppKit
import AVFoundation

/// The free, built-in engine: macOS voices through AVSpeechSynthesizer, with
/// the voice and rate set in System Settings › Accessibility › Read & Speak.
@MainActor
final class SystemSpeechEngine: NSObject, SpeechEngine {
    var events = SpeechEngineEvents()

    private struct Piece {
        let segment: SpeechSegment
        let isLast: Bool
    }

    private var synth: AVSpeechSynthesizer?
    private var pieces: [ObjectIdentifier: Piece] = [:]

    /// One utterance per segment, each followed by its silence. A fresh
    /// synthesizer is used each time: enqueuing right after `stopSpeaking` on
    /// the same instance can drop utterances.
    func start(_ segments: [SpeechSegment], voiceID: String?, speed: Double) {
        stop()
        let voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.systemVoice()
        let rate = Self.utteranceRate(speed: speed)
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        self.synth = synth
        for (i, segment) in segments.enumerated() {
            let utterance = AVSpeechUtterance(string: segment.spoken)
            utterance.voice = voice
            utterance.rate = rate
            utterance.postUtteranceDelay = segment.pauseAfter
            pieces[ObjectIdentifier(utterance)] = Piece(segment: segment, isLast: i == segments.count - 1)
            synth.speak(utterance)
        }
    }

    func pause() { synth?.pauseSpeaking(at: .word) }
    func resume() { synth?.continueSpeaking() }

    func stop() {
        pieces.removeAll()
        synth?.delegate = nil
        synth?.stopSpeaking(at: .immediate)
        synth = nil
    }

    // MARK: Delegate events (already hopped to the main actor)

    private func piece(for utterance: ObjectIdentifier, from synthID: ObjectIdentifier) -> Piece? {
        guard let synth, ObjectIdentifier(synth) == synthID else { return nil }
        return pieces[utterance]
    }

    fileprivate func utteranceStarted(_ id: ObjectIdentifier, synth: ObjectIdentifier) {
        guard let piece = piece(for: id, from: synth), piece.segment.isFirstInBlock else { return }
        events.blockStarted(piece.segment.block)
    }

    fileprivate func utteranceFinished(_ id: ObjectIdentifier, synth: ObjectIdentifier) {
        guard let piece = piece(for: id, from: synth), piece.isLast else { return }
        stop()
        events.finished()
    }

    fileprivate func willSpeak(_ range: NSRange, in id: ObjectIdentifier, synth: ObjectIdentifier) {
        guard let piece = piece(for: id, from: synth) else { return }
        let original = piece.segment.map.original(for: range)
        if original.location != NSNotFound { events.willSpeak(piece.segment.block, original) }
    }

    // MARK: System voice

    /// The voice selected in Read & Speak, read fresh on each call so a change
    /// in System Settings is picked up on the next playback.
    static func systemVoice() -> AVSpeechSynthesisVoice? {
        if let voice = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue) {
            return voice
        }
        // Siri voices are not exposed to third-party apps: fall back to the system TTS language.
        return AVSpeechSynthesisVoice(language: AVVoices.systemLanguage)
    }

    static var systemVoiceDescription: String {
        guard let voice = systemVoice() else { return String(localized: "Default voice") }
        let exact = voice.identifier == NSSpeechSynthesizer.defaultVoice.rawValue
        return AVVoices.label(for: voice) + (exact ? "" : String(localized: " — fallback"))
    }

    /// Maps the system rate (words per minute, ~175 by default) times the user
    /// multiplier onto AVSpeech's 0…1 scale, where 0.5 is normal speed.
    static func utteranceRate(speed: Double) -> Float {
        let systemWPM = Double(NSSpeechSynthesizer().rate)
        let factor = max(0.25, speed * (systemWPM > 0 ? systemWPM / 175 : 1))
        let rate = Double(AVSpeechUtteranceDefaultSpeechRate) + 0.25 * log2(factor)
        return Float(min(max(rate, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }
}

extension SystemSpeechEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), sid = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceStarted(id, synth: sid) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), sid = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.utteranceFinished(id, synth: sid) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance), sid = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.willSpeak(characterRange, in: id, synth: sid) } }
    }
}

/// Installed macOS voices, for the voice menu.
enum AVVoices {
    static var systemLanguage: String {
        UserDefaults(suiteName: "com.apple.speech.voice.prefs")?.string(forKey: "SystemTTSLanguage")
            ?? AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// "Nicolas — Enhanced (fr-CA)"
    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let name = voice.name.components(separatedBy: " (").first ?? voice.name
        let quality = switch voice.quality {
        case .premium: String(localized: "Premium")
        case .enhanced: String(localized: "Enhanced")
        default: String(localized: "Standard")
        }
        return "\(name) — \(quality) (\(voice.language))"
    }

    static func label(forID id: String) -> String {
        AVSpeechSynthesisVoice(identifier: id).map(label(for:)) ?? id
    }

    /// Installed voices, best quality first: those in the system speech language,
    /// then all the others sorted by language.
    static func installed() -> (main: [Voice], others: [Voice]) {
        let prefix = String(systemLanguage.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name)
        }
        let main = voices.filter { $0.language.hasPrefix(prefix) }
            .sorted { (-$0.quality.rawValue, $0.name) < (-$1.quality.rawValue, $1.name) }
        let others = voices.filter { !$0.language.hasPrefix(prefix) }
        let voice = { (v: AVSpeechSynthesisVoice) in Voice(engine: .system, id: v.identifier, label: label(for: v)) }
        return (main.map(voice), others.map(voice))
    }
}
