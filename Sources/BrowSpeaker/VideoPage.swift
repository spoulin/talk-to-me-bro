import Foundation

/// Video pages ("articles" that are only a video): instead of reading the few
/// words around it, the original page is shown with its player isolated and
/// stretched over the window. The site's own player is used as is.
enum VideoPage {
    /// Address segments that mark a video page, e.g. ici.radio-canada.ca/info/videos/…
    static func looksLikeVideo(_ url: URL) -> Bool {
        url.path().lowercased().split(separator: "/").contains { ["video", "videos", "vidéo", "vidéos", "watch"].contains($0.removingPercentEncoding ?? String($0)) }
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
