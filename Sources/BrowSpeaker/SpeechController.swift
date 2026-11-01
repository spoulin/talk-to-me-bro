import Foundation
import Observation

/// Something that reads segments aloud, with the silence each one asks for.
/// Once `stop()` returns, an engine must not send any more events.
@MainActor
protocol SpeechEngine: AnyObject {
    var events: SpeechEngineEvents { get set }
    /// `voiceID` is engine-specific; nil means its default voice.
    func start(_ segments: [SpeechSegment], voiceID: String?, speed: Double)
    func pause()
    func resume()
    func stop()
}

/// Silences between paragraphs and sentences: a steady flow with no breaks
/// quickly becomes tiring to listen to.
enum Pacing: String, CaseIterable, Identifiable {
    case none, short, medium, long

    var id: Self { self }

    var label: String {
        switch self {
        case .none: String(localized: "None")
        case .short: String(localized: "Short")
        case .medium: String(localized: "Medium")
        case .long: String(localized: "Long")
        }
    }

    /// Seconds after each paragraph.
    var paragraph: Double {
        switch self {
        case .none: 0.12
        case .short: 0.5
        case .medium: 1.0
        case .long: 1.8
        }
    }

    /// Seconds after each sentence within a paragraph.
    var sentence: Double {
        switch self {
        case .none: 0
        case .short: 0.15
        case .medium: 0.35
        case .long: 0.6
        }
    }
}

struct SpeechEngineEvents {
    var blockStarted: (Int) -> Void = { _ in }
    var willSpeak: (Int, NSRange) -> Void = { _, _ in }
    var finished: () -> Void = {}
    var failed: (Error) -> Void = { _ in }
}

/// Reads the reader page aloud: keeps the playback state and routes to the
/// engine of the selected voice (macOS voices by default, Piper when installed).
@MainActor
@Observable
final class SpeechController {
    enum State { case idle, speaking, paused }

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private(set) var state: State = .idle
    private(set) var currentIndex: Int?

    /// Multiplier applied on top of the voice's normal rate.
    var speed: Double = UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(speed, forKey: "speechSpeed")
            restartIfSpeaking()
        }
    }

    var pacing: Pacing = Pacing(rawValue: UserDefaults.standard.string(forKey: "pacing") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(pacing.rawValue, forKey: "pacing")
            restartIfSpeaking()
        }
    }

    /// The chosen voice as "engine:id" (see `Voice.key`); nil follows the Spoken Content voice.
    var voiceKey: String? = SpeechController.savedVoiceKey() {
        didSet {
            UserDefaults.standard.set(voiceKey, forKey: "voice")
            restartIfSpeaking()
        }
    }

    var voiceLabel: String {
        switch Voice.parse(voiceKey) {
        case (.piper, let id?):
            PiperService.shared.voices.first { $0.id == id }?.label ?? "\(id) — Piper"
        case (_, let id?):
            AVVoices.label(forID: id)
        default:
            SystemSpeechEngine.systemVoiceDescription
        }
    }

    @ObservationIgnored var onBlockStart: ((Int) -> Void)?
    @ObservationIgnored var onWord: ((Int, NSRange) -> Void)?
    @ObservationIgnored var onFinish: (() -> Void)?
    /// Reading reached the end of the article (not stopped by the user).
    @ObservationIgnored var onComplete: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    @ObservationIgnored private let systemEngine = SystemSpeechEngine()
    @ObservationIgnored private let piperEngine = ClipSpeechEngine(PiperSynthesizer())
    @ObservationIgnored private var engine: SpeechEngine?
    @ObservationIgnored private var blocks: [String] = []

    var hasBlocks: Bool { !blocks.isEmpty && state != .idle }

    init() {
        let engines: [(SpeechEngine, String)] = [(systemEngine, "macOS"), (piperEngine, "Piper")]
        for (engine, name) in engines {
            engine.events = SpeechEngineEvents(
                blockStarted: { [weak self] i in
                    self?.currentIndex = i
                    self?.onBlockStart?(i)
                },
                willSpeak: { [weak self] i, range in self?.onWord?(i, range) },
                finished: { [weak self] in
                    self?.engine = nil
                    self?.finish()
                    self?.onComplete?()
                },
                failed: { [weak self] error in self?.fallBackToSystemVoice(after: error, in: name) }
            )
        }
    }

    func speak(_ blocks: [String], from start: Int) {
        self.blocks = blocks
        jump(to: start)
    }

    func jump(to index: Int) {
        engine?.stop()
        engine = nil
        let segments = blocks.indices.contains(index) ? segments(from: index) : []
        guard !segments.isEmpty else {
            finish()
            // "Next paragraph" past the last one also ends the article.
            if !blocks.isEmpty { onComplete?() }
            return
        }
        let (engine, voiceID) = resolveEngine()
        self.engine = engine
        currentIndex = index
        state = .speaking
        engine.start(segments, voiceID: voiceID, speed: speed)
    }

    func pause() {
        guard state == .speaking else { return }
        engine?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        engine?.resume()
        state = .speaking
    }

    func stop() {
        guard state != .idle else { return }
        engine?.stop()
        engine = nil
        finish()
    }

    func next() {
        guard state != .idle, let currentIndex else { return }
        jump(to: currentIndex + 1)
    }

    func previous() {
        guard state != .idle, let currentIndex else { return }
        jump(to: max(currentIndex - 1, 0))
    }

    private func segments(from index: Int) -> [SpeechSegment] {
        SpeechScript.segments(for: blocks, from: index, pacing: pacing, entries: Pronunciations.shared.entries)
    }

    private func resolveEngine() -> (SpeechEngine, String?) {
        switch Voice.parse(voiceKey) {
        case (.piper, let id?) where PiperService.shared.isInstalled:
            (piperEngine, id)
        case (.system, let id):
            (systemEngine, id)
        default:
            (systemEngine, nil)
        }
    }

    /// A cloud voice that fails (no network, bad key, quota) must not leave the
    /// reader silent: carry on with the macOS voice from the same paragraph.
    private func fallBackToSystemVoice(after error: Error, in engineName: String) {
        onError?(String(localized: "\(engineName): \(error.localizedDescription) — reading with the system voice."))
        let index = currentIndex ?? 0
        engine = systemEngine
        state = .speaking
        systemEngine.start(segments(from: index), voiceID: nil, speed: speed)
    }

    private func restartIfSpeaking() {
        if state == .speaking, let currentIndex { jump(to: currentIndex) }
    }

    private func finish() {
        state = .idle
        currentIndex = nil
        onFinish?()
    }

    private static func savedVoiceKey() -> String? {
        if let key = UserDefaults.standard.string(forKey: "voice") { return key }
        // Before engines, the setting held a bare AVSpeech voice identifier.
        return UserDefaults.standard.string(forKey: "voiceIdentifier").map { "system:" + $0 }
    }
}

/// A voice from any engine, as listed in the voice menu.
struct Voice: Hashable, Identifiable {
    enum Engine: String { case system, piper }

    let engine: Engine
    let id: String
    let label: String

    /// Stored selection and picker tag: "system:com.apple.voice…" or "piper:fr_FR-siwis-medium".
    var key: String { "\(engine.rawValue):\(id)" }

    static func parse(_ key: String?) -> (Engine?, String?) {
        guard let key, let colon = key.firstIndex(of: ":") else { return (nil, nil) }
        return (Engine(rawValue: String(key[..<colon])), String(key[key.index(after: colon)...]))
    }
}
