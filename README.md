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
- `ClipSpeechEngine`: engines that produce one audio file per paragraph (Piper), fetching the next
  paragraph while the current one plays.
- **Siri** voices aren't available to third-party apps: when one is selected, the app uses another voice
  of the same language (shown as "fallback" in the menu).

The interface is in English by default and in French when the Mac is set to French
(`Resources/fr.lproj`, `ShareExtension/fr.lproj`). To add a language, add a `<lang>.lproj` folder with
the translated `Localizable.strings` (and `InfoPlist.strings` for the share extension).

The code and internal identifiers keep the original name (`BrowSpeaker`, `local.browspeaker`,
`browspeaker://`), so the display name can change without breaking sharing or "Open With".
