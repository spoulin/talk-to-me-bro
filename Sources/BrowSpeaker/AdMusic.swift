import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Music during ads: while a video page mutes an ad, a radio or music chosen
/// in Settings plays instead, fading in and out. The source is a radio
/// playlist (.pls, .m3u), a stream or audio file address, or a file or folder
/// on this Mac. A radio comes back at its live point; files go on where they
/// stopped. A stream that fails moves on to its next mirror.
@MainActor @Observable
final class AdMusic {
    static let shared = AdMusic()

    /// "" for silence.
    var source = UserDefaults.standard.string(forKey: "adMusicSource") ?? "" {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source, forKey: "adMusicSource")
            fade?.cancel()
            player.pause()
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            prepared = nil
            problem = nil
        }
    }
    /// 0…1, its own: radios are often louder than the voices.
    var volume: Double = UserDefaults.standard.object(forKey: "adMusicVolume") as? Double ?? 0.7 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "adMusicVolume")
            if isPlaying, wanted { ramp(to: volume, seconds: 0.15) }
        }
    }
    /// Fades of the music and of the video coming back, in seconds (0: none).
    var fadeSeconds: Double = UserDefaults.standard.object(forKey: "adFadeSeconds") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(fadeSeconds, forKey: "adFadeSeconds") }
    }
    /// Audible, or fading out.
    private(set) var isPlaying = false
    /// Why the source doesn't play, for Settings.
    private(set) var problem: String?

    var hasSource: Bool { !source.trimmingCharacters(in: .whitespaces).isEmpty }

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var prepared: Task<Bool, Never>?
    @ObservationIgnored private var sources: [URL] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var live = false
    /// Mirrors that failed in a row: once all have, the source is given up.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var adPlaying = false
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var previewEnd: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    private init() {
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.ended(note.object as? AVPlayerItem) }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil,
                                               queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.failed(note.object as? AVPlayerItem) }
        }
    }

    func adStarted() {
        adPlaying = true
        previewEnd?.cancel()
        play()
    }

    func adEnded() {
        adPlaying = false
        stop()
    }

    /// Plays the source for a few seconds (Listen, in Settings).
    func preview() {
        play()
        previewEnd?.cancel()
        previewEnd = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, !adPlaying { stop() }
        }
    }

    private func play() {
        wanted = true
        Task {
            guard await prepare(), wanted else { return }
            failures = 0
            // A paused radio would go on with what it buffered minutes ago: back to the live point.
            if live || player.currentItem == nil { load(index) }
            if !isPlaying { player.volume = 0 }
            player.play()
            isPlaying = true
            ramp(to: volume, seconds: fadeSeconds)
        }
    }

    private func stop() {
        wanted = false
        guard isPlaying else { return }
        ramp(to: 0, seconds: fadeSeconds) { [weak self] in
            guard let self, !self.wanted else { return }
            self.player.pause()
            self.isPlaying = false
        }
    }

    private func ramp(to target: Double, seconds: Double, then done: (() -> Void)? = nil) {
        fade?.cancel()
        let from = Double(player.volume)
        guard seconds > 0 else {
            player.volume = Float(target)
            done?()
            return
        }
        fade = Task {
            let steps = max(1, Int(seconds / 0.04))
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
                player.volume = Float(from + (target - from) * Double(step) / Double(steps))
            }
            done?()
        }
    }

    /// Finds what to play for the source (again if it changed).
    private func prepare() async -> Bool {
        if let prepared { return await prepared.value }
        let text = source.trimmingCharacters(in: .whitespaces)
        let task = Task { () -> Bool in
            guard !text.isEmpty else { return false }
            guard let (list, isLive) = await Self.resolve(text), !list.isEmpty else {
                problem = String(localized: "Nothing to play at this address.")
                return false
            }
            sources = list
            live = isLive
            index = 0
            failures = 0
            problem = nil
            player.replaceCurrentItem(with: nil)
            return true
        }
        prepared = task
        let ready = await task.value
        // Offline, say: try again at the next ad.
        if !ready, prepared == task { prepared = nil }
        return ready
    }

    private func load(_ position: Int) {
        guard !sources.isEmpty else { return }
        index = position % sources.count
        let item = AVPlayerItem(url: sources[index])
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in
                if status == .failed { self?.failed(item) }
                if status == .readyToPlay { self?.failures = 0 }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    /// Next file of a folder, or the same file again; a radio that stops starts over.
    private func ended(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        load(live ? index : index + 1)
        if wanted { player.play() }
    }

    /// The next mirror, or the next file; once all have failed, silence.
    private func failed(_ item: AVPlayerItem?) {
        guard let item, item === player.currentItem else { return }
        failures += 1
        guard failures < sources.count else {
            problem = String(localized: "This source doesn't play.")
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            return
        }
        load(index + 1)
        if wanted { player.play() }
    }

    /// The addresses to play for a source, and whether it is a live stream.
    nonisolated static func resolve(_ source: String) async -> (list: [URL], live: Bool)? {
        // A file or folder on this Mac.
        let path = source.hasPrefix("file://") ? URL(string: source)?.path(percentEncoded: false) : (source as NSString).expandingTildeInPath
        if let path, path.hasPrefix("/") {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return nil }
            let url = URL(filePath: path)
            guard isFolder.boolValue else { return ([url], false) }
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return (files.filter(isAudioFile).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }, false)
        }
        guard let url = URL(string: source.contains("://") ? source : "https://" + source), url.host() != nil else { return nil }
        // A playlist that points to the stream (.pls, .m3u): its addresses, mirrors first to last.
        let ext = url.pathExtension.lowercased()
        if ext == "pls" || ext == "m3u" {
            guard let data = await fetchSecurely(url),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            let addresses = ext == "pls"
                ? lines.compactMap { line in
                    line.range(of: #"^File\d+="#, options: [.regularExpression, .caseInsensitive]).map { String(line[$0.upperBound...]) }
                }
                : lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            return (addresses.compactMap { URL(string: $0) }.filter { $0.scheme == "http" || $0.scheme == "https" }, true)
        }
        // A stream or a single audio file.
        return ([url], !isAudioFile(url))
    }

    /// macOS blocks http:// outside of media: try the playlist over https first.
    nonisolated private static func fetchSecurely(_ url: URL) async -> Data? {
        guard url.scheme == "http", var secure = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return await Feeds.fetch(url)
        }
        secure.scheme = "https"
        if let https = secure.url, let data = await Feeds.fetch(https) { return data }
        return await Feeds.fetch(url)
    }

    nonisolated private static func isAudioFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
    }
}
