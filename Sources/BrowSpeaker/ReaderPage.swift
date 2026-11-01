import Foundation

struct Article: Decodable {
    var title: String
    var byline: String
    var siteName: String
    var content: String
    var lang: String
    var words: Int?
}

/// The "Just Read"-style page: article extraction on the live page with
/// Mozilla Readability, then a clean template rendered in a separate web view.
enum ReaderPage {
    /// Runs in the browsed page (isolated world). Returns the article as JSON,
    /// falling back to the page's visible text when Readability finds nothing.
    static let extractionScript: String? = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let readability = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return """
        (function () {
        \(readability)
        try {
          var a = new Readability(document.cloneNode(true)).parse();
          if (a && a.content && a.textContent && a.textContent.trim().length > 200) {
            return JSON.stringify({
              title: a.title || document.title, byline: a.byline || "",
              siteName: a.siteName || location.hostname, content: a.content,
              lang: a.lang || document.documentElement.lang || "",
              words: a.textContent.trim().split(/\\s+/).length
            });
          }
        } catch (e) {}
        var esc = function (s) { return s.replace(/[&<>]/g, function (c) { return {"&": "&amp;", "<": "&lt;", ">": "&gt;"}[c]; }); };
        var paras = (document.body ? document.body.innerText : "").split(/\\n+/)
          .map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
        return JSON.stringify({
          title: document.title, byline: "", siteName: location.hostname,
          content: paras.map(function (p) { return "<p>" + esc(p) + "</p>"; }).join(""),
          lang: document.documentElement.lang || ""
        });
        })()
        """
    }()

    static func html(for article: Article, fontSize: Double) -> String {
        let byline = article.byline.isEmpty ? "" : "<div class=\"byline\">\(escape(article.byline))</div>"
        return """
        <!doctype html>
        <html lang="\(escape(article.lang))" style="--font-size: \(Int(fontSize))px">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(article.title))</title>
        <style>\(css)</style>
        </head>
        <body>
        <main>
        <header>
        <div class="site">\(escape(article.siteName))</div>
        <h1 class="title">\(escape(article.title))</h1>
        \(byline)
        </header>
        <article>\(article.content)</article>
        </main>
        </body>
        </html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root {
      color-scheme: light dark;
      --bg: #fbf8f1; --fg: #232323; --muted: #6e6a64; --link: #1a5fb4;
      --para: rgba(255, 196, 0, .16); --word: #ffd54f;
    }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #1d1d1f; --fg: #e3e1dc; --muted: #9a968f; --link: #78aeed;
              --para: rgba(255, 196, 0, .10); --word: #7a5f00; }
    }
    html { background: var(--bg); }
    body { margin: 0; color: var(--fg);
           font: var(--font-size, 20px)/1.65 "Charter", "Iowan Old Style", Georgia, serif;
           -webkit-font-smoothing: antialiased; }
    main { max-width: 40em; margin: 0 auto; padding: 56px 28px 160px; }
    .site { color: var(--muted); font: 600 .72em/1.4 -apple-system, sans-serif;
            text-transform: uppercase; letter-spacing: .07em; }
    h1.title { font-size: 2em; line-height: 1.18; margin: .35em 0 .3em; }
    .byline { color: var(--muted); font-style: italic; margin-bottom: 2.2em; }
    h1, h2, h3, h4 { line-height: 1.25; }
    a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 2px; }
    img, video, svg, iframe { max-width: 100%; height: auto; }
    figure { margin: 1.6em 0; }
    figcaption { color: var(--muted); font-size: .8em; }
    blockquote { margin: 1.4em 0; padding-left: 1em; border-left: 3px solid var(--muted); color: var(--muted); }
    pre, code { font: .82em/1.5 ui-monospace, Menlo, monospace; }
    pre { overflow: auto; padding: 1em; border-radius: 8px; background: rgba(127, 127, 127, .12); }
    table { border-collapse: collapse; max-width: 100%; }
    td, th { border: 1px solid rgba(127, 127, 127, .3); padding: .3em .55em; }
    .bs-speaking { background: var(--para); border-radius: 6px; box-shadow: 0 0 0 .3em var(--para); }
    ::highlight(bs-word) { background-color: var(--word); color: inherit; }
    """

    /// Injected in the reader web view (own content world; page scripts are disabled).
    /// Splits the article into speakable blocks and paints the spoken block / word.
    static let script = """
    (() => {
      const SEL = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figcaption,dt,dd,td,th";
      let blocks = null, current = null;
      const get = () => blocks || (blocks = Array.from(document.querySelectorAll("main " + SEL))
        .filter(el => !el.querySelector(SEL) && el.textContent.trim().length > 0));
      const hasHighlights = () => typeof CSS !== "undefined" && CSS.highlights && typeof Highlight !== "undefined";
      const clearWord = () => { if (hasHighlights()) CSS.highlights.delete("bs-word"); };

      function rangeFor(el, start, end) {
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        let pos = 0, started = false, node;
        while ((node = walker.nextNode())) {
          const len = node.data.length;
          if (!started && start <= pos + len) { range.setStart(node, start - pos); started = true; }
          if (started && end <= pos + len) { range.setEnd(node, end - pos); return range; }
          pos += len;
        }
        return null;
      }

      window.__bs = {
        blocks: () => get().map(el => el.textContent),
        kinds: () => get().map(el => el.matches("h1,h2,h3,h4,h5,h6") ? "title"
          : el.closest("figcaption, [class*='caption']") ? "caption"
          : el.closest("blockquote") ? "quote" : "text"),
        firstVisible() {
          const b = get();
          for (let i = 0; i < b.length; i++) if (b[i].getBoundingClientRect().bottom > 8) return i;
          return 0;
        },
        highlightBlock(i) {
          if (current) current.classList.remove("bs-speaking");
          clearWord();
          current = get()[i];
          if (!current) return;
          current.classList.add("bs-speaking");
          const r = current.getBoundingClientRect();
          if (r.top < innerHeight * 0.12 || r.bottom > innerHeight * 0.8)
            current.scrollIntoView({ block: "center", behavior: "smooth" });
        },
        highlightWord(i, start, length) {
          const el = get()[i];
          if (!el || !hasHighlights()) return;
          const range = rangeFor(el, start, start + length);
          if (range) CSS.highlights.set("bs-word", new Highlight(range));
        },
        clear() {
          if (current) current.classList.remove("bs-speaking");
          current = null;
          clearWord();
        },
        setFontSize(px) { document.documentElement.style.setProperty("--font-size", px + "px"); }
      };

      const post = message => window.webkit.messageHandlers.reader.postMessage(message);

      document.addEventListener("click", e => {
        if (e.target.closest("a")) return;
        const index = get().findIndex(el => el.contains(e.target));
        if (index >= 0) post({ type: "click", index, alt: e.altKey });
      });

      // Player keys: space plays or pauses, ← → move by paragraph.
      document.addEventListener("keydown", e => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const type = e.code === "Space" ? "toggle" : e.key === "ArrowLeft" ? "prev" : e.key === "ArrowRight" ? "next" : null;
        if (!type) return;
        e.preventDefault();
        post({ type });
      });
    })();
    """
}
