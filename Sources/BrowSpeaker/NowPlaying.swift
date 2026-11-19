import AppKit
import MediaPlayer
import Observation

/// Media keys (⏯ ⏭), headphones, Control Center and Stream Deck's multimedia
/// buttons: the article or video playing is shown in Now Playing, and these
/// commands reach the app without bringing it to the front.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    /// The window that started playing last: the commands go to it.
    private weak var model: BrowserModel?
    /// The window playing, for the mini player.
    var current: BrowserModel? { model }
    /// Only the latest observation republishes.
    private var generation = 0

    private init() {
        let commands = MPRemoteCommandCenter.shared()
        handle(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        handle(commands.playCommand) { if !Self.isPlaying($0) { $0.togglePlayPause() } }
        handle(commands.pauseCommand) {
            // Our own pause, sent to the other apps, can come back to us: it is not for us.
            guard Date.now >= NowPlaying.shared.ignoresPauseUntil else { return }
            if Self.isPlaying($0) { $0.togglePlayPause() }
        }
        handle(commands.nextTrackCommand) { $0.nextArticle() }
        // A Stream Deck's Multimedia ⏭, or a press a bit long on the keyboard, arrives as a seek, not a
        // next track. There is nothing to move fast through: it goes to the next article too.
        commands.seekForwardCommand.addTarget { event in
            guard (event as? MPSeekCommandEvent)?.type == .beginSeeking else { return .success }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let model = NowPlaying.shared.model { model.nextArticle() }
                }
            }
            return .success
        }
    }

    // MARK: Pausing the other apps

    /// Settings: before reading or a video starts, pause what another app plays (music, a podcast…).
    static let pausesOtherAppsKey = "pauseOtherApps"
    private var ignoresPauseUntil = Date.distantPast

    /// Sends the system's Pause, like the ⏸ key, to the app playing now. Pause, not Play/Pause:
    /// with nothing playing, nothing happens. macOS no longer tells other apps what plays, but
    /// still takes this command.
    func pauseOtherApps() {
        guard UserDefaults.standard.bool(forKey: Self.pausesOtherAppsKey), let send = Self.sendCommand else { return }
        ignoresPauseUntil = .now.addingTimeInterval(1.5)
        _ = send(1, nil)  // kMRPause
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(framework, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    /// A window starts an article or a video: Now Playing follows it.
    func follow(_ model: BrowserModel) {
        guard model !== self.model else { return }
        self.model = model
        update()
    }

    /// The window is closing: give the media keys back to the other apps.
    func forget(_ model: BrowserModel) {
        guard model === self.model else { return }
        self.model = nil
        publish()
    }

    private static func isPlaying(_ model: BrowserModel) -> Bool {
        model.isVideo ? model.videoPlaying : model.speech.state == .speaking
    }

    private func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (BrowserModel) -> Void) {
        command.addTarget { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let model = NowPlaying.shared.model { action(model) }
                }
            }
            return .success
        }
    }

    /// Publishes the state, then again each time it changes.
    private func update() {
        generation += 1
        let generation = generation
        withObservationTracking {
            publish()
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if generation == NowPlaying.shared.generation { NowPlaying.shared.update() }
                }
            }
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        // On the home page, nothing is playing: the media keys go back to the other apps.
        guard let model, model.phase != .empty else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            commands.nextTrackCommand.isEnabled = false
            commands.seekForwardCommand.isEnabled = false
            return
        }
        let playing = Self.isPlaying(model)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: model.phase == .ready ? model.articleTitle : model.loadingHost,
            MPMediaItemPropertyArtist: model.siteName,
            MPNowPlayingInfoPropertyMediaType: (model.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? model.speech.speed : 0,
        ]
        if model.isVideo, model.videoDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = model.videoDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = model.videoTime
        }
        if let icon = NSApp.applicationIconImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: icon.size) { _ in icon }
        }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
        // Like the menu: ⏭ only when something waits in the playlist.
        commands.nextTrackCommand.isEnabled = !model.playlist.items.isEmpty
        commands.seekForwardCommand.isEnabled = !model.playlist.items.isEmpty
    }
}
