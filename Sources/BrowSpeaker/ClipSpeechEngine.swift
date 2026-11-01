@preconcurrency import AVFoundation
import Foundation

/// Turns a piece of text into an audio file (WAV, MP3…).
protocol ClipSynthesizer {
    func synthesize(_ text: String, voice: String, speed: Double) async throws -> Data
}

/// Engine for voices that produce audio clips (Piper, or a cloud service): each
/// segment is synthesized, then played and followed by its silence, while the
/// next ones are synthesized.
///
/// These services return audio without word timings, so the spoken word is
/// estimated from the playback position.
@MainActor
final class ClipSpeechEngine: NSObject, SpeechEngine {
    var events = SpeechEngineEvents()
    private let synthesizer: ClipSynthesizer

    init(_ synthesizer: ClipSynthesizer) {
        self.synthesizer = synthesizer
    }

    private var generation = 0
    private var segments: [SpeechSegment] = []
    private var voiceID = ""
    private var speed = 1.0
    private var index = 0
    private var isPaused = false
    /// The next segment, when pause was pressed during the silence before it.
    private var pendingNext: (() -> Void)?
    private var player: AVAudioPlayer?
    private var downloads: [Int: Task<Data, Error>] = [:]
    private var wordTimer: Timer?

    func start(_ segments: [SpeechSegment], voiceID: String?, speed: Double) {
        stop()
        self.segments = segments
        self.voiceID = voiceID ?? ""
        self.speed = speed
        play(0, generation: generation)
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        isPaused = false
        if let pendingNext {
            self.pendingNext = nil
            pendingNext()
        } else {
            player?.play()
        }
    }

    func stop() {
        generation += 1
        downloads.values.forEach { $0.cancel() }
        downloads = [:]
        wordTimer?.invalidate()
        wordTimer = nil
        player?.stop()
        player = nil
        isPaused = false
        pendingNext = nil
    }

    private func audio(for i: Int) -> Task<Data, Error> {
        if let task = downloads[i] { return task }
        let text = segments[i].spoken, voice = voiceID, speed = speed
        let synthesizer = synthesizer
        let task = Task { try await synthesizer.synthesize(text, voice: voice, speed: speed) }
        downloads[i] = task
        return task
    }

    private func play(_ i: Int, generation: Int) {
        guard i < segments.count else { return events.finished() }
        index = i
        let current = audio(for: i)
        for ahead in (i + 1)..<min(i + 3, segments.count) { _ = audio(for: ahead) }
        Task {
            do {
                let data = try await current.value
                guard generation == self.generation else { return }
                downloads[i] = nil
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                if segments[i].isFirstInBlock { events.blockStarted(segments[i].block) }
                player.play()
                if isPaused { player.pause() }
                trackWords(of: segments[i], in: player)
            } catch {
                guard generation == self.generation, !(error is CancellationError) else { return }
                stop()
                events.failed(error)
            }
        }
    }

    /// Estimates the spoken word from the playback position, weighting each
    /// word by its length.
    private func trackWords(of segment: SpeechSegment, in player: AVAudioPlayer) {
        let text = segment.spoken as NSString
        var words: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byWords) { _, range, _, _ in
            words.append(range)
        }
        guard !words.isEmpty, player.duration > 0 else { return }
        let total = Double(words.reduce(0) { $0 + $1.length })
        var ends: [Double] = []
        var sum = 0.0
        for word in words {
            sum += Double(word.length)
            ends.append(sum / total)
        }
        var last = -1
        wordTimer?.invalidate()
        wordTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self, weak player] _ in
            MainActor.assumeIsolated {
                guard let self, let player, player === self.player else { return }
                let progress = player.currentTime / player.duration
                let w = ends.firstIndex { $0 >= progress } ?? words.count - 1
                guard w != last else { return }
                last = w
                let original = segment.map.original(for: words[w])
                if original.location != NSNotFound { self.events.willSpeak(segment.block, original) }
            }
        }
    }

    fileprivate func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        wordTimer?.invalidate()
        let generation = generation, next = index + 1, pause = segments[index].pauseAfter
        Task {
            try? await Task.sleep(for: .seconds(pause))
            guard generation == self.generation else { return }
            if isPaused {
                pendingNext = { [weak self] in self?.play(next, generation: generation) }
            } else {
                play(next, generation: generation)
            }
        }
    }
}

extension ClipSpeechEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.playerFinished(id) } }
    }
}
