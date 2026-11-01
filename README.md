<img src="Resources/AppIcon.png" width="128" alt="">

# Talk to me Bro

**English** · [Français](README.fr.md)

An article player for macOS: send it an article from your browser, it shows the text without ads or
clutter (like "Just Read") and **reads it aloud**, with a macOS voice or a local Piper voice.

## Build

```bash
scripts/build-app.sh
open "build/Talk to me Bro.app"
```

Requires macOS 14+ and Xcode / Swift 6. To install, copy `build/Talk to me Bro.app` to `/Applications`.

## Usage

To open an article:
- in your browser, **Share › Read with Talk to me Bro**;
- or drag a link into the window;
- or copy a link, then press ⇧⌘V.

Playback starts on its own. The bottom bar shows the progress (click or drag to jump to a paragraph),
the time left, the playback controls, speed and pauses, voice, and text size.

| Action | Shortcut |
| --- | --- |
| Play / Pause | Space (in the article) or ⌥⌘P |
| Previous / next paragraph | ← / → (in the article) or ⌥⌘← / ⌥⌘→ |
| Stop | ⌥⌘. |
| Listen to the copied link | ⇧⌘V |
| Open the original page in the browser | ⇧⌘O |
| Text size | ⌘+ / ⌘- / ⌘0 |

- While reading, click a paragraph to jump to it; ⌥-click always starts reading from it.
- Links in the article open in your usual browser.
- **Pauses** (speed menu): None, Short, Medium (default) or Long, after each paragraph and, shorter,
  after each sentence, so the flow is less monotonous.

## Playlist

- Share (or drag, or ⇧⌘V) an article while another is playing or paused: it goes to the **playlist**
  instead of interrupting ("Added to playlist").
- When an article has been read to the end, the next one in the playlist starts by itself and is removed
  from the list. ⏭ (or ⌥⌘↓, or closing the article) skips to the next one.
- The playlist button in the player bar (with the number of waiting articles) opens the list: drag to
  reorder, Delete or right-click to remove, *Clear* to empty it, double-click to play one now.
- The playlist is kept when the app quits; the welcome screen offers to resume it.

## Sources

**Settings › Sources**: paste the address of a site (e.g. `example.com/news`) or of an RSS/Atom feed.
For a site, the app looks for the feed the page announces, then tries the usual feed addresses
(`…/rss`, `/feed`, `/rss.xml`…), and otherwise loads the page (JavaScript included) and keeps its article
links ("approximate" mode, no dates).

The home screen then shows **To Read**: the latest articles of all sources, newest first, as magazine
cards (the newest one large) or as a list (⊞ / ☰). Pictures come from the feed, from the page, or from
each article's sharing image (`og:image`). Already read articles are dimmed and marked "Read"; an article
listed by several sources appears once. Click to listen, ➕ to add to the playlist, *Listen to All* to queue the unread ones.
Sources refresh at launch and every 30 minutes (↻ to refresh now).

## Video pages

Some "articles" are only a video (e.g. `ici.radio-canada.ca/info/videos/…`). When an opened page has a
video address, or very little text around a large video, the app switches to **video mode**: the original
page is shown with its player isolated, centered at its proportions over the window, and everything else
hidden. The site's own player is used (play, volume, full screen). When the video ends, the next article
of the playlist starts. Video pages carry a "Video" badge in To Read.

## History

The history button (🕘) in the toolbar lists the last 50 articles read; click one to read it again.
Right-click to add it to the playlist, open it in the browser, or remove it. The welcome screen shows the
last five.

## Pronunciation

**Settings › Pronunciation**: a dictionary of words to read differently, e.g. `soccer` → `soqueur`.

- Matching ignores case and only replaces whole words; the highlight stays on the original word.
- `[pause]` (0.6 s) or `[pause 1.5]` (seconds) in "Phonetic spelling" adds a silence, e.g. `—` → `[pause 0.4]`.
- Built-in pauses: "…" and "...", and before and after parentheses and brackets. Note numbers like
  `[12]` are not read. A dictionary entry for the same characters takes precedence.
- ▶︎ plays the word through the dictionary with the current voice.

## Voices by type

**Settings › Voices › Voices by type**: a different voice for titles, photo captions and quotes ("Same
as text" by default), mixing macOS and Piper voices freely. *Announce captions* says "Caption:" (in the
article's language) before a caption, once for several captions in a row.

Changes to the dictionary and to the voices by type apply from the next paragraph, without cutting the
current one.

## Voices

Two engines, chosen from the voice menu in the player bar; everything stays on the Mac:

| Engine | Quality | Cost / account | Privacy |
| --- | --- | --- | --- |
| **macOS** (default) | Standard to Premium, depending on downloaded voices | Free, nothing to install | Local |
| **Piper** (optional) | Neural, better than the basic voices | Free, no account | Local |

If Piper fails, reading continues with the macOS voice. To add an online voice service (Azure, OpenAI,
ElevenLabs…), write another `ClipSynthesizer`, modeled on `PiperSynthesizer` (a complete Azure engine
is in the first commit of the git history).

## Piper voices (optional, local)

[Piper](https://github.com/OHF-Voice/piper1-gpl) provides neural voices that run on the Mac.

1. **Settings** (⌘,) → *Install Piper* (about 200 MB; requires Python 3.9+, for example
   `brew install python` or python.org).
2. *Voices to download* → choose a voice (30 to 80 MB).
3. The voice appears in the voice menu of the player bar.

- Everything is installed in `~/Library/Application Support/local.browspeaker/piper` (a separate Python
  environment, the voices, and a `piper.log` log); *Uninstall Piper* deletes that folder.
- A small local Piper server (127.0.0.1) keeps the voice loaded while reading; it stops with the app.
- The voice list follows the system speech language. In French, Piper only has voices from France.
- The highlighted word is estimated (Piper doesn't report word timings); the paragraph is exact.

## Share to Talk to me Bro

From any app (Safari, Chrome, Mail, Notes…), choose **Share › Read with Talk to me Bro**: the app opens
(or comes to the front if it's running), loads the page, shows the article and starts reading. It works
with a link, or with text that contains a link (that's what Dia sends: the address as text, without
`https://`).

- If the option doesn't appear: *System Settings › General › Login Items & Extensions › Sharing*
  (or *Share › Edit Extensions…*), then check "Read with Talk to me Bro".
- After moving the app (for example to `/Applications`), open it once so macOS registers the extension
  again.
- Under the hood, the extension opens `browspeaker://read?url=<encoded address>`. You can use this link
  elsewhere too (Shortcuts, scripts, `open "browspeaker://read?url=…"`).

## Open With Talk to me Bro

Right-click › **Open With › Talk to me Bro** in the Finder, on:

- a `.webloc` bookmark (a link dragged from a browser to the desktop);
- a Windows `.url` shortcut;
- an `.html` file.

The app also declares itself as a browser (`http`/`https`): it can be picked in
*System Settings › Desktop & Dock › Default web browser* or in a browser picker, and it answers
`open -a "Talk to me Bro" https://…`. In every case, the article opens in the existing window and
reading starts.

## How it works

- `BrowserModel`: a hidden `WKWebView` loads the page, a second one shows the clean article.
- The article is extracted with [Mozilla Readability](https://github.com/mozilla/readability)
  (`Resources/Readability.js`, v0.5.0, Apache 2.0 license), run in a JavaScript world isolated from the page.
- The article view disables the page's JavaScript; only Talk to me Bro's own script runs there.
- `SpeechController`: playback state, choice of voice and engine (`SpeechEngine`).
- `SystemSpeechEngine`: `AVSpeechSynthesizer` with the system voice (`NSSpeechSynthesizer.defaultVoice`),
  read again at each playback.
- `SpeechScript`: splits paragraphs into segments (sentences, pauses) and applies the pronunciation
  dictionary, keeping a map back to the article text for highlighting.
- `ClipSpeechEngine`: engines that produce one audio file per segment (Piper), fetching the next
  ones while the current one plays.
- **Siri** voices aren't available to third-party apps: when one is selected, the app uses another voice
  of the same language (shown as "fallback" in the menu).

The interface is in English by default and in French when the Mac is set to French
(`Resources/fr.lproj`, `ShareExtension/fr.lproj`). To add a language, add a `<lang>.lproj` folder with
the translated `Localizable.strings` (and `InfoPlist.strings` for the share extension).

The code and internal identifiers keep the original name (`BrowSpeaker`, `local.browspeaker`,
`browspeaker://`), so the display name can change without breaking sharing or "Open With".
