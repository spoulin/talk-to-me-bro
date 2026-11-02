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
    /// Only the latest observation republishes.
    private var generation = 0

    private init() {
        let commands = MPRemoteCommandCenter.shared()
        handle(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        handle(commands.playCommand) { if !Self.isPlaying($0) { $0.togglePlayPause() } }
        handle(commands.pauseCommand) { if Self.isPlaying($0) { $0.togglePlayPause() } }
        handle(commands.nextTrackCommand) { $0.nextArticle() }
    }

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
        let nextTrack = MPRemoteCommandCenter.shared().nextTrackCommand
        // On the home page, nothing is playing: the media keys go back to the other apps.
        guard let model, model.phase != .empty else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            nextTrack.isEnabled = false
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
        nextTrack.isEnabled = !model.playlist.items.isEmpty
    }
}
