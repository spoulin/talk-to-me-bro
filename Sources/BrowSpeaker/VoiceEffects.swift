@preconcurrency import AVFoundation
import Foundation
import Observation

/// An effect on the voice, to give it more body.
enum VoiceEffect: String, CaseIterable, Identifiable {
    case none, warmth, room, studio, hall, cathedral, echo

    var id: Self { self }

    var label: String {
        switch self {
        case .none: String(localized: "No effect")
        case .warmth: String(localized: "Warmth")
        case .room: String(localized: "Room")
        case .studio: String(localized: "Studio")
        case .hall: String(localized: "Hall")
        case .cathedral: String(localized: "Cathedral")
        case .echo: String(localized: "Echo")
        }
    }

    fileprivate var reverb: AVAudioUnitReverbPreset? {
        switch self {
        case .room: .mediumRoom
        // Plate: the classic studio reverb for voices.
        case .studio: .plate
        case .hall: .mediumHall
        case .cathedral: .cathedral
        default: nil
        }
    }
}

/// The voice effect chosen in Settings, kept between launches.
@MainActor
@Observable
final class VoiceEffects {
    static let shared = VoiceEffects()
    static let changedNotification = Notification.Name("VoiceEffectsChanged")

    var effect = VoiceEffect(rawValue: UserDefaults.standard.string(forKey: "voiceEffect") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(effect.rawValue, forKey: "voiceEffect"); changed() }
    }

    /// 0…1: how much of the effect is heard.
    var amount = UserDefaults.standard.object(forKey: "voiceEffectAmount") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(amount, forKey: "voiceEffectAmount"); changed() }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }
}

/// Plays a voice's clips through the effect chosen in Settings. The effect
/// follows the settings live, while a clip plays.
@MainActor
final class EffectPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Brings each voice's format (often 22 kHz mono) to the effects' format.
    private let mixer = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let reverb = AVAudioUnitReverb()
    private let delay = AVAudioUnitDelay()
    private var reverbPreset: AVAudioUnitReverbPreset?
    private var format: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var onEnd: (() -> Void)?
    private var isPaused = false
    /// The player has no position while paused: keep the last one.
    private var lastTime = 0.0
    /// Identifies the clip being played: a clip that was stopped must not report its end.
    private var clip = 0
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        for node in [player, mixer, eq, reverb, delay] { engine.attach(node) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        engine.connect(mixer, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: delay, format: format)
        engine.connect(delay, to: engine.mainMixerNode, format: format)
        applyEffect()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: VoiceEffects.changedNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyEffect() }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.outputChanged() }
            },
        ]
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Reads an audio file (WAV) into memory.
    static func buffer(from data: Data) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: buffer)
        return buffer
    }

    /// Plays a clip from its start; `onEnd` runs once it has been heard.
    func play(_ buffer: AVAudioPCMBuffer, onEnd: @escaping () -> Void) throws {
        stop()
        self.buffer = buffer
        self.onEnd = onEnd
        if format != buffer.format {
            engine.connect(player, to: mixer, format: buffer.format)
            format = buffer.format
        }
        try startEngine()
        lastTime = 0
        let clip = clip
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(clip) } }
        }
        player.play()
        isPaused = false
    }

    /// Seconds into the clip.
    var currentTime: Double {
        updatePosition()
        return lastTime
    }

    var duration: Double {
        buffer.map { Double($0.frameLength) / $0.format.sampleRate } ?? 0
    }

    /// 0…1, heard at once (the effect's tail too).
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// Also pauses the audio output, which would otherwise keep the Mac awake.
    func pause() {
        isPaused = true
        updatePosition()
        player.pause()
        engine.pause()
    }

    func resume() throws {
        isPaused = false
        guard buffer != nil else { return }
        try startEngine()
        player.play()
    }

    /// The effect's tail (reverb, echo) fades out on its own.
    func stop() {
        clip += 1
        buffer = nil
        onEnd = nil
        player.stop()
    }

    /// Nothing more to play for now: lets the tail fade, then frees the audio output.
    func finish() {
        stop()
        let clip = clip
        Task {
            try? await Task.sleep(for: .seconds(3))
            if clip == self.clip { engine.stop() }
        }
    }

    private func updatePosition() {
        if let now = player.lastRenderTime, let time = player.playerTime(forNodeTime: now) {
            lastTime = Double(time.sampleTime) / time.sampleRate
        }
    }

    private func startEngine() throws {
        guard !engine.isRunning else { return }
        try engine.start()
        // The reverb preset doesn't survive the engine starting: load it again.
        reverbPreset = nil
        applyEffect()
    }

    private func ended(_ clip: Int) {
        guard clip == self.clip, let onEnd else { return }
        buffer = nil
        self.onEnd = nil
        onEnd()
    }

    /// Another output (headphones plugged in) stops the engine: play the clip
    /// again from its start there.
    private func outputChanged() {
        guard let buffer, let onEnd else { return }
        let wasPaused = isPaused
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: engine.outputNode.outputFormat(forBus: 0))
        do {
            try play(buffer, onEnd: onEnd)
            if wasPaused { pause() }
        } catch {
            // Without an output, end the clip so the reading moves on rather than hangs.
            onEnd()
        }
    }

    private func applyEffect() {
        let effect = VoiceEffects.shared.effect
        let amount = Float(VoiceEffects.shared.amount)

        eq.bypass = effect != .warmth
        if effect == .warmth {
            // More low-mids and a little presence, with less overall level so the boost doesn't clip.
            let low = eq.bands[0]
            low.filterType = .lowShelf
            low.frequency = 220
            low.gain = amount * 9
            low.bypass = false
            let presence = eq.bands[1]
            presence.filterType = .parametric
            presence.frequency = 3000
            presence.bandwidth = 1
            presence.gain = amount * 3
            presence.bypass = false
            eq.globalGain = -amount * 2
        }

        reverb.bypass = effect.reverb == nil
        if let preset = effect.reverb {
            // Loading a preset while playing can click: only when it changes.
            if preset != reverbPreset {
                reverb.loadFactoryPreset(preset)
                reverbPreset = preset
            }
            reverb.wetDryMix = amount * 50
        }

        delay.bypass = effect != .echo
        if effect == .echo {
            delay.delayTime = 0.25
            delay.feedback = 30
            delay.lowPassCutoff = 4000
            delay.wetDryMix = amount * 40
        }
    }
}
