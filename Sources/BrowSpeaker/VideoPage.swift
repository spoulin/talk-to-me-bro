import Foundation

/// Video pages ("articles" that are only a video): instead of reading the few
/// words around it, the original page is shown with its player isolated and
/// stretched over the window. The site's own player is used as is.
enum VideoPage {
    /// Address segments that mark a video page, e.g. ici.radio-canada.ca/info/videos/…
    static func looksLikeVideo(_ url: URL) -> Bool {
        url.path().lowercased().split(separator: "/").contains { ["video", "videos", "vidéo", "vidéos", "watch", "shorts"].contains($0.removingPercentEncoding ?? String($0)) }
    }

    /// Fewer words than this around a video: the page is the video.
    static let shortArticleWords = 150

    /// Shared by `detect` and `focus`: the largest video on the page (a
    /// <video>, or an embedded player like YouTube), ignoring ad frames.
    private static let finder = """
    const area = e => { const r = e.getBoundingClientRect(); return r.width * r.height; };
    const candidates = [...document.querySelectorAll("video, iframe")].filter(e => {
      const r = e.getBoundingClientRect();
      if (r.width < 240 || r.height < 130) return false;
      if (e.tagName !== "IFRAME") return true;
      return /youtube|youtu\\.be|vimeo|dailymotion|player|embed|video/i.test(e.src) && !/imasdk|doubleclick|googlesyndication/i.test(e.src);
    }).sort((a, b) => area(b) - area(a));
    const target = candidates[0];
    """

    /// "true" when the page has a large video.
    static let detect = "(() => { \(finder) return String(!!target); })()"

    /// Shows the player's box as large as the window allows, keeping its proportions
    /// (black bars around it), hides the rest, and reports the end of the video.
    static let focus = """
    (() => {
      \(finder)
      if (!target) return "none";
      // The player box: the highest ancestor that is still about the video's size (it holds the controls).
      const base = target.getBoundingClientRect();
      let box = target;
      while (box.parentElement && box.parentElement !== document.body) {
        const r = box.parentElement.getBoundingClientRect();
        if (r.width > base.width * 1.15 || r.height > base.height * 1.4) break;
        box = box.parentElement;
      }
      const boxRect = box.getBoundingClientRect();
      const ratio = (boxRect.width / boxRect.height) || 16 / 9;
      if (target.tagName === "VIDEO") target.classList.add("bs-main-video");
      for (let e = target; e && e !== box; e = e.parentElement) e.classList.add("bs-video-chain");
      for (let e = box.parentElement; e; e = e.parentElement) e.classList.add("bs-video-ancestor");
      box.classList.add("bs-video-box");
      const style = document.createElement("style");
      style.textContent = `
        html, body { overflow: hidden !important; background: #000 !important; }
        body::before { content: ""; position: fixed; inset: 0; background: #000; z-index: 2147483646; }
        .bs-video-ancestor > *:not(.bs-video-ancestor):not(.bs-video-box) { visibility: hidden !important; }
        .bs-video-ancestor { transform: none !important; filter: none !important; contain: none !important;
          will-change: auto !important; overflow: visible !important; }
        .bs-video-box { position: fixed !important; inset: 0 !important; margin: auto !important; padding: 0 !important;
          width: min(100vw, calc(100vh * ${ratio})) !important; height: min(100vh, calc(100vw / ${ratio})) !important;
          max-width: none !important; max-height: none !important;
          z-index: 2147483647 !important; background: #000 !important; }
        .bs-video-box img { object-fit: contain !important; }
        .bs-video-chain, .bs-video-box video, .bs-video-box iframe { width: 100% !important; height: 100% !important;
          max-width: none !important; max-height: none !important; }
        .bs-video-box video { object-fit: contain !important; }`;
      document.head.appendChild(style);
      window.scrollTo(0, 0);
      const video = target.tagName === "VIDEO" ? target : box.querySelector("video");
      if (video) video.addEventListener("ended", () => window.webkit.messageHandlers.video.postMessage("ended"));
      document.addEventListener("keydown", e => { if (e.key === "Escape") window.webkit.messageHandlers.video.postMessage("close"); }, true);
      \(adGuard)
      return "ok";
    })()
    """

    private static let video = "(document.querySelector('.bs-video-box video') || document.querySelector('video'))"

    /// {t: current time, d: duration, p: playing} for the player bar.
    static let state = """
    (() => { const v = \(video); return v ? JSON.stringify({t: v.currentTime || 0, d: isFinite(v.duration) ? v.duration : 0, p: !v.paused && v.readyState > 2}) : "null"; })()
    """

    /// One autoplay attempt: "playing" once a video of the page (or its ad) is
    /// really playing; otherwise presses the site's own play button, which
    /// lets its player load the video (and its ads), or else calls play().
    static let autoplay = """
    (() => {
      const videos = [...document.querySelectorAll("video")];
      if (videos.some(v => !v.paused && v.currentTime > 0)) return "playing";
      const box = document.querySelector(".bs-video-box") || document.body;
      const area = e => { const r = e.getBoundingClientRect(); return r.width * r.height; };
      const buttons = [...box.querySelectorAll("button, [role=button]")].filter(b => {
        const label = [b.getAttribute("aria-label"), b.title, String(b.className)].join(" ").toLowerCase();
        return area(b) > 0 && /play|lecture|lire|jouer|démarrer/.test(label) && !/pause|replay/.test(label);
      }).sort((a, b) => area(b) - area(a));
      if (buttons[0]) { buttons[0].click(); return "clicked"; }
      const v = box.querySelector("video") || videos[0];
      if (v) { v.play().catch(() => {}); return "play"; }
      return "none";
    })()
    """

    /// Installed with `focus`: mutes the page while an ad plays and restores the
    /// sound after. Ad players turn their sound back on when they start, so this
    /// runs in the page itself, four times a second and on every volume change.
    /// An ad is spotted by its label in the player ("Publicité 1 de 2", "Ad 1 of
    /// 2") or the classes ad players use.
    fileprivate static let adGuard = """
      if (!window.__bsAdGuard) {
        window.__bsAdGuard = true;
        const isAd = () => {
          const box = document.querySelector(".bs-video-box") || document.body;
          return /publicit|annonce|advertis|\\bad \\d|commanditaire|sponsor/i.test(box.innerText || "")
            || !!document.querySelector(".ad-showing, .ad-interrupting, [class*='ima-ad-container'] video");
        };
        const apply = () => {
          const ad = isAd();
          window.__bsAdActive = ad;
          for (const v of document.querySelectorAll("video")) {
            if (ad) {
              if (!v.dataset.bsAdMute) v.dataset.bsAdMute = v.muted ? "already" : "yes";
              if (!v.muted) v.muted = true;
            } else if (v.dataset.bsAdMute) {
              if (v.dataset.bsAdMute === "yes") v.muted = false;
              delete v.dataset.bsAdMute;
            }
          }
        };
        setInterval(apply, 250);
        for (const type of ["play", "playing", "volumechange", "loadeddata"]) {
          document.addEventListener(type, () => { if (window.__bsAdActive || isAd()) apply(); }, true);
        }
      }
    """

    /// "true" while an ad plays (and is muted).
    static let adPlaying = "String(!!window.__bsAdActive)"

    /// Whether any video of the page is really playing, ads included.
    static let anythingPlaying = "String([...document.querySelectorAll('video')].some(v => !v.paused && v.currentTime > 0))"

    static func seek(to seconds: Double) -> String {
        "(() => { const v = \(video); if (v) v.currentTime = Math.max(0, \(seconds)); })()"
    }

    static func skip(by seconds: Double) -> String {
        "(() => { const v = \(video); if (v) v.currentTime = Math.max(0, v.currentTime + \(seconds)); })()"
    }

    static func rate(_ speed: Double) -> String {
        "(() => { const v = \(video); if (v) v.playbackRate = \(speed); })()"
    }

    /// Play or pause the page's video (menu and keyboard shortcut).
    static let togglePlayback = """
    (() => {
      const video = document.querySelector(".bs-video-box video") || document.querySelector("video");
      if (!video) return "none";
      video.paused ? video.play() : video.pause();
      return "ok";
    })()
    """
}

extension VideoPage {
    /// YouTube links play in YouTube's embeddable player, in privacy mode
    /// (youtube-nocookie.com, as DuckDuckGo's Duck Player does): no YouTube page
    /// around it, no tracking cookies, and its official API drives the player bar.
    enum YouTube {
        /// watch?v=ID, youtu.be/ID, /shorts/ID, /embed/ID, /live/ID
        static func videoID(in url: URL) -> String? {
            guard let host = url.host()?.lowercased(), host.contains("youtube.com") || host == "youtu.be" else { return nil }
            let parts = url.path().split(separator: "/").map(String.init)
            let id: String?
            if host == "youtu.be" {
                id = parts.first
            } else if let index = parts.firstIndex(where: { ["shorts", "embed", "live"].contains($0) }), index + 1 < parts.count {
                id = parts[index + 1]
            } else {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            }
            guard let id, id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { return nil }
            return id
        }

        /// The page loaded in place of youtube.com: the player over the whole window.
        /// `language`: the player's interface language. Matching the listener's speech
        /// language avoids translated titles and automatic subtitles.
        static func playerPage(videoID: String, speed: Double, language: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html, body { margin: 0; height: 100%; background: #000; overflow: hidden; }
            #player { position: fixed; inset: 0; width: 100vw; height: 100vh; }</style></head>
            <body><div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
            let player, ready = false;
            function onYouTubeIframeAPIReady() {
              player = new YT.Player("player", {
                host: "https://www.youtube-nocookie.com", videoId: "\(videoID)",
                playerVars: { autoplay: 1, rel: 0, playsinline: 1, modestbranding: 1, hl: "\(language)" },
                events: {
                  onReady: e => { ready = true; e.target.setPlaybackRate(\(speed)); e.target.playVideo(); },
                  onStateChange: e => { if (e.data === YT.PlayerState.ENDED) window.webkit.messageHandlers.video.postMessage("ended"); }
                }
              });
            }
            document.addEventListener("keydown", e => { if (e.key === "Escape") window.webkit.messageHandlers.video.postMessage("close"); });
            window.__bsVideo = {
              state: () => JSON.stringify(ready ? { t: player.getCurrentTime() || 0, d: player.getDuration() || 0,
                                                   p: player.getPlayerState() === 1 } : { t: 0, d: 0, p: false }),
              toggle: () => { if (ready) player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo(); },
              seek: t => { if (ready) player.seekTo(Math.max(0, t), true); },
              skip: s => { if (ready) player.seekTo(Math.max(0, player.getCurrentTime() + s), true); },
              rate: r => { if (ready) player.setPlaybackRate(r); }
            };
            </script></body></html>
            """
        }

        static let state = "window.__bsVideo ? __bsVideo.state() : 'null'"
        static let togglePlayback = "window.__bsVideo && __bsVideo.toggle()"
        static func seek(to seconds: Double) -> String { "window.__bsVideo && __bsVideo.seek(\(seconds))" }
        static func skip(by seconds: Double) -> String { "window.__bsVideo && __bsVideo.skip(\(seconds))" }
        static func rate(_ speed: Double) -> String { "window.__bsVideo && __bsVideo.rate(\(speed))" }

        /// Title and channel, from YouTube's oEmbed endpoint.
        static func details(of url: URL) async -> (title: String, channel: String)? {
            var components = URLComponents(string: "https://www.youtube.com/oembed")!
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
            struct OEmbed: Decodable { let title: String; let author_name: String }
            guard let data = await Feeds.fetch(components.url!),
                  let info = try? JSONDecoder().decode(OEmbed.self, from: data)
            else { return nil }
            return (info.title, info.author_name)
        }

        /// When the video was published: on its watch page (oEmbed doesn't say).
        static func publishDate(videoID: String) async -> Date? {
            guard let page = URL(string: "https://www.youtube.com/watch?v=\(videoID)"),
                  let data = await Feeds.fetch(page),
                  let text = Feeds.firstMatch("\"(?:publishDate|uploadDate)\":\"([^\"]+)\"", in: String(decoding: data, as: UTF8.self))
            else { return nil }
            return Feeds.parseDate(text)
        }
    }
}
