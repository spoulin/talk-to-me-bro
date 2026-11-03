import Foundation

struct Article: Decodable {
    var title: String
    var byline: String
    var siteName: String
    var content: String
    var lang: String
    var words: Int?
    /// The line above the title in a heading in parts ("L'argent et le bonheur").
    var kicker: String?
    /// When the page says it was published (ISO 8601), or "".
    var published: String?
    /// The page's main picture, to show under the title, or "".
    var image: String?
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
        // A heading in parts (a kicker line, then the title) reads as one run-on
        // sentence once its text is joined: keep the parts apart.
        var norm = function (s) { return (s || "").replace(/\\s+/g, " ").trim(); };
        // The lines of a heading: by layout when there is one, else by its parts
        // (<span class="suptitle">…</span><span class="title">…</span>).
        var headingLines = function (el) {
          var lines = (el.innerText || "").split("\\n").map(norm).filter(function (s) { return s; });
          if (lines.length > 1) return lines;
          var kids = Array.prototype.filter.call(el.children, function (c) { return norm(c.textContent); });
          var loose = Array.prototype.some.call(el.childNodes, function (n) { return n.nodeType === 3 && norm(n.textContent); });
          if (kids.length > 1 && !loose && (/sup|kick|surtit|over|eyebrow|rubri|categ/i.test(kids[0].getAttribute("class") || "") ||
              /block|flex|grid/.test(getComputedStyle(kids[0]).display))) {
            return kids.map(function (c) { return norm(c.textContent); });
          }
          return [norm(el.textContent)];
        };
        // When the page says it was published: Readability's finding, its metadata,
        // else a <time> of the article.
        var published = function (text) {
          var meta = document.querySelector('meta[property="article:published_time"], meta[property="og:published_time"], ' +
            'meta[itemprop="datePublished"], meta[itemprop="uploadDate"], meta[name="pubdate"], meta[name="publish-date"]');
          text = text || (meta && meta.getAttribute("content"));
          var scripts = document.querySelectorAll('script[type="application/ld+json"]');
          for (var i = 0; i < scripts.length && !text; i++) {
            var found = /"(?:datePublished|uploadDate)"\\s*:\\s*"([^"]+)"/.exec(scripts[i].textContent);
            if (found) text = found[1];
          }
          if (!text) {
            var time = document.querySelector("article time[datetime], time[datetime]");
            text = time && time.getAttribute("datetime");
          }
          var date = new Date(text || "");
          return isNaN(date) ? "" : date.toISOString();
        };
        var splitTitle = function (title) {
          var headings = document.querySelectorAll("h1");
          for (var i = 0; i < headings.length; i++) {
            var lines = headingLines(headings[i]);
            var last = lines[lines.length - 1];
            if (lines.length > 1 && last.length > 3 && (norm(title).indexOf(last) >= 0 || norm(headings[i].textContent) === norm(title))) {
              return { kicker: lines.slice(0, -1).join(" — "), title: last };
            }
          }
          return { kicker: "", title: title };
        };
        // The page's main picture (its sharing image): often above the title, out of
        // what Readability keeps. Not when the article opens with a picture, or shows
        // that one (at another size: its file name is the same).
        var leadImage = function (content) {
          var meta = document.querySelector('meta[property="og:image"], meta[name="og:image"], ' +
            'meta[name="twitter:image"], meta[property="twitter:image"]');
          var src = meta && meta.getAttribute("content");
          try { src = src && new URL(src, location.href).href; } catch (e) { src = ""; }
          if (!src || !/^https?:/.test(src) || /logo|placeholder|default/i.test(src)) return "";
          var name = function (url) {
            var file = (url || "").split(/[?#]/)[0].split("/").pop().toLowerCase();
            return file.replace(/\\.\\w+$/, "").replace(/[-_]\\d+x\\d+$|@\\dx$|-scaled$/, "");
          };
          var doc = new DOMParser().parseFromString(content, "text/html");
          var images = doc.querySelectorAll("img");
          for (var i = 0; i < images.length; i++) {
            var sources = [images[i].getAttribute("src")].concat((images[i].getAttribute("srcset") || "").split(",")
              .map(function (s) { return s.trim().split(/\\s+/)[0]; }));
            if (sources.some(function (s) { return s && name(s) === name(src); })) return "";
          }
          var first = Array.prototype.find.call(doc.querySelectorAll("p"), function (p) { return norm(p.textContent).length > 40; });
          if (images.length && (!first || images[0].compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING)) return "";
          return src;
        };
        try {
          var a = new Readability(document.cloneNode(true)).parse();
          if (a && a.content && a.textContent && a.textContent.trim().length > 200) {
            var heading = splitTitle(a.title || document.title);
            return JSON.stringify({
              title: heading.title, kicker: heading.kicker, byline: a.byline || "",
              siteName: a.siteName || location.hostname, content: a.content,
              lang: a.lang || document.documentElement.lang || "",
              words: a.textContent.trim().split(/\\s+/).length, published: published(a.publishedTime),
              image: leadImage(a.content)
            });
          }
        } catch (e) {}
        var esc = function (s) { return s.replace(/[&<>]/g, function (c) { return {"&": "&amp;", "<": "&lt;", ">": "&gt;"}[c]; }); };
        var paras = (document.body ? document.body.innerText : "").split(/\\n+/)
          .map(function (s) { return s.trim(); }).filter(function (s) { return s.length > 0; });
        return JSON.stringify({
          title: document.title, byline: "", siteName: location.hostname,
          content: paras.map(function (p) { return "<p>" + esc(p) + "</p>"; }).join(""),
          lang: document.documentElement.lang || "", published: published(), image: leadImage("")
        });
        })()
        """
    }()

    static func html(for article: Article, fontSize: Double) -> String {
        let byline = article.byline.isEmpty ? "" : "<div class=\"byline\">\(escape(article.byline))</div>"
        let lead = article.image.flatMap { $0.isEmpty ? nil : "<figure class=\"lead\"><img src=\"\(escape($0))\" alt=\"\"></figure>" } ?? ""
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
        \(article.kicker.map { $0.isEmpty ? "" : "<p class=\"kicker\">\(escape($0))</p>" } ?? "")
        <h1 class="title">\(escape(article.title))</h1>
        \(byline)
        </header>
        \(lead)
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
    .kicker { color: var(--muted); font-size: 1.1em; margin: .9em 0 -.2em; }
    h1.title { font-size: 2em; line-height: 1.18; margin: .35em 0 .3em; }
    .byline { color: var(--muted); font-style: italic; margin-bottom: 2.2em; }
    h1, h2, h3, h4 { line-height: 1.25; }
    a { color: var(--link); text-decoration-thickness: 1px; text-underline-offset: 2px; }
    img, video, svg, iframe { max-width: 100%; height: auto; }
    figure { margin: 1.6em 0; }
    .lead { margin: 1.2em 0 2em; }
    .lead img { display: block; width: 100%; border-radius: 8px; }
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

      // The main picture can't load (the site refuses it): no empty frame.
      document.querySelectorAll(".lead img").forEach(img => {
        const drop = () => img.closest(".lead").remove();
        if (img.complete && !img.naturalWidth) drop(); else img.addEventListener("error", drop);
      });

      const post = message => window.webkit.messageHandlers.reader.postMessage(message);

      document.addEventListener("click", e => {
        if (e.target.closest("a")) return;
        const index = get().findIndex(el => el.contains(e.target));
        if (index >= 0) post({ type: "click", index, alt: e.altKey });
      });

      // Player keys: space plays or pauses, ← → move by paragraph.
      document.addEventListener("keydown", e => {
        if (e.metaKey || e.ctrlKey || e.altKey) return;
        const type = e.code === "Space" ? "toggle" : e.key === "ArrowLeft" ? "prev" : e.key === "ArrowRight" ? "next"
          : e.key === "Escape" ? "close" : null;
        if (!type) return;
        e.preventDefault();
        post({ type });
      });
    })();
    """
}
