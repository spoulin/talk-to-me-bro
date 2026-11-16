import AppKit
import SwiftUI
import WebKit

/// The mini player: a small window that floats over every app, on every desktop (and over apps in
/// full screen), without making Talk to me Bro the active app. A video moves into it and keeps
/// playing; an article shows the paragraph being read, the word highlighted, scrolling as it goes.
/// ⇧⌘M or the toolbar opens it and hides the app, as ⌘H would, or going to another app when that is
/// chosen in Settings. Escape, ⤢, a double-click or coming back to the app brings everything back to
/// the window; right-click for its options.
@MainActor @Observable
final class MiniPlayer {
    static let shared = MiniPlayer()

    enum Mode: String { case text, video }

    private(set) var isShown = false
    private(set) var mode: Mode = .text
    /// The window whose article or video plays in it.
    @ObservationIgnored private(set) weak var model: BrowserModel?

    var switchesAutomatically = UserDefaults.standard.bool(forKey: "miniAuto") {
        didSet { UserDefaults.standard.set(switchesAutomatically, forKey: "miniAuto") }
    }
    /// 0.2…1.
    var opacity = UserDefaults.standard.object(forKey: "miniOpacity") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(opacity, forKey: "miniOpacity")
            panel?.alphaValue = opacity
        }
    }

    @ObservationIgnored private var panel: MiniPanel?
    @ObservationIgnored private var textHost: NSView?
    @ObservationIgnored private var videoHost: HoverView?
    @ObservationIgnored private var videoBar: NSView?
    /// Where the page view lives in the main window, to put it back.
    @ObservationIgnored private var webHome: NSView?
    /// Opened because the user went to another app: it goes away when they come back.
    @ObservationIgnored private var automatic = false
    /// Opened by hand, so the app hid itself: coming back to it brings everything back to the window.
    @ObservationIgnored private var hidApp = false
    @ObservationIgnored private var delegate: PanelDelegate?
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    /// Moves made by the app itself: not snapped, not saved.
    @ObservationIgnored private var placing = false
    @ObservationIgnored private var generation = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MiniPlayer.shared.appWentAway() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MiniPlayer.shared.appCameBack() }
        }
    }

    func isShowing(_ model: BrowserModel) -> Bool { isShown && self.model === model }

    func toggle(_ model: BrowserModel) {
        isShowing(model) ? backToWindow() : show(model, automatic: false)
    }

    func show(_ model: BrowserModel, automatic: Bool) {
        guard model.phase == .ready else { return }
        if isShown, self.model !== model { backToWindow(activating: false) }
        self.model = model
        self.automatic = automatic
        let panel = self.panel ?? makePanel()
        let wasShown = isShown
        isShown = true
        sync(placing: !wasShown)
        watch()
        panel.alphaValue = opacity
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        // Opened by hand: the app steps aside like ⌘H, so its big window isn't left in the way and the
        // app used before comes back to the front. The mini player stays (canHide is false).
        if !automatic {
            hidApp = true
            NSApp.hide(nil)
        }
    }

    /// ⤢, Escape, a double-click or ⇧⌘M: back in the window, still playing.
    func backToWindow(activating: Bool = true) {
        guard isShown else { return }
        let window = model?.readerView.window
        savePlace()
        returnWebView()
        panel?.orderOut(nil)
        isShown = false
        automatic = false
        hidApp = false
        generation += 1
        if activating, let window {
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// ✕: pauses, and puts the video back in the window without leaving the current app.
    func close() {
        if let model, Self.isPlaying(model) { model.togglePlayPause() }
        backToWindow(activating: false)
    }

    /// The window was closed: nothing left to show.
    func windowClosed(_ model: BrowserModel) {
        guard isShowing(model) else { return }
        panel?.orderOut(nil)
        isShown = false
        hidApp = false
        generation += 1
    }

    static func isPlaying(_ model: BrowserModel) -> Bool {
        model.isVideo ? model.videoPlaying : model.speech.state == .speaking
    }

    // MARK: Going to another app and back

    private func appWentAway() {
        guard switchesAutomatically, !isShown, let model = NowPlaying.shared.current,
              model.phase == .ready, Self.isPlaying(model) else { return }
        show(model, automatic: true)
    }

    /// Back in the app (the Dock, ⌘Tab, a click on its window): the mini player was only for while
    /// the user was elsewhere.
    private func appCameBack() {
        guard isShown, automatic || hidApp else { return }
        // Unhidden by the user: put the window that was playing in front of the others.
        backToWindow(activating: hidApp)
    }

    // MARK: Following the window

    /// Text or video, as the window's state changes (next article, video ended, back home).
    private func watch() {
        generation += 1
        let current = generation
        guard let model else { return }
        withObservationTracking {
            _ = model.phase
            _ = model.isVideo
            _ = model.videoAspect
        } onChange: {
            Task { @MainActor in
                let mini = MiniPlayer.shared
                guard mini.generation == current, mini.isShown else { return }
                mini.sync(placing: false)
                mini.watch()
            }
        }
    }

    private func sync(placing first: Bool) {
        guard let model, let panel else { return }
        // Back on the home page: nothing left to play.
        if model.phase == .empty { return backToWindow(activating: false) }
        // While the next one loads, the page view shows the raw page: the text side says "Loading…".
        let wanted: Mode = model.phase == .ready && model.isVideo ? .video : .text
        if wanted != mode || first {
            if !first { savePlace() }
            mode = wanted
            textHost?.isHidden = mode != .text
            videoHost?.isHidden = mode != .video
            if mode == .video {
                adoptWebView()
                panel.minSize = NSSize(width: 220, height: 124)
            } else {
                returnWebView()
                panel.contentResizeIncrements = NSSize(width: 1, height: 1) // drops the video's proportions
                panel.minSize = NSSize(width: 260, height: 110)
            }
            place()
        } else if mode == .video {
            keepProportions()
        }
    }

    // MARK: The page view

    private func adoptWebView() {
        guard let model, let host = videoHost else { return }
        let web = model.webView
        guard web.superview !== host else { return }
        webHome = web.superview
        web.removeFromSuperview()
        host.addSubview(web, positioned: .below, relativeTo: videoBar)
        pin(web, in: host)
    }

    private func returnWebView() {
        guard let model, let home = webHome else { return }
        let web = model.webView
        guard web.superview !== home else { return }
        web.removeFromSuperview()
        if model.readerView.superview === home {
            home.addSubview(web, positioned: .below, relativeTo: model.readerView)
        } else {
            home.addSubview(web)
        }
        pin(web, in: home)
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: Place and size: remembered for text and video apart, snapped to the screen's edges

    private var aspect: Double { max(0.4, min(3.5, model?.videoAspect ?? 16 / 9)) }

    private func place() {
        guard let panel else { return }
        var frame = UserDefaults.standard.string(forKey: "miniFrame.\(mode.rawValue)").map(NSRectFromString)
        if let f = frame, !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { frame = nil }
        let screen = model?.readerView.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var f = frame ?? {
            let size = mode == .video ? NSSize(width: 480, height: 270) : NSSize(width: 440, height: 170)
            let vf = screen.visibleFrame
            return NSRect(x: vf.maxX - size.width - 20, y: vf.minY + 20, width: size.width, height: size.height)
        }()
        if mode == .video {
            panel.contentAspectRatio = NSSize(width: aspect, height: 1)
            let height = (f.width / aspect).rounded()
            f.origin.y += f.height - height
            f.size.height = height
        }
        placing = true
        panel.setFrame(f, display: true)
        placing = false
    }

    private func keepProportions() {
        guard let panel, mode == .video else { return }
        panel.contentAspectRatio = NSSize(width: aspect, height: 1)
        var f = panel.frame
        let height = (f.width / aspect).rounded()
        guard abs(height - f.height) > 1 else { return }
        f.origin.y += f.height - height
        f.size.height = height
        placing = true
        panel.setFrame(f, display: true, animate: true)
        placing = false
    }

    private func savePlace() {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "miniFrame.\(mode.rawValue)")
    }

    /// Once a move or a resize ends: close to an edge, it sticks to it.
    fileprivate func moved() {
        guard !placing else { return }
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            guard !Task.isCancelled else { return }
            snap()
            savePlace()
        }
    }

    private func snap() {
        guard let panel, let vf = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let margin = 12.0, reach = 40.0
        var f = panel.frame
        if abs(f.minX - vf.minX) < reach { f.origin.x = vf.minX + margin }
        else if abs(vf.maxX - f.maxX) < reach { f.origin.x = vf.maxX - f.width - margin }
        if abs(f.minY - vf.minY) < reach { f.origin.y = vf.minY + margin }
        else if abs(vf.maxY - f.maxY) < reach { f.origin.y = vf.maxY - f.height - margin }
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        guard f != panel.frame else { return }
        placing = true
        panel.setFrame(f, display: true, animate: true)
        placing = false
    }

    // MARK: Dragging the video

    @ObservationIgnored private var dragTimer: Timer?

    /// The page saw a drag on the video: the window follows the pointer while the button is down.
    func pageDragStarted(_ model: BrowserModel) {
        guard isShowing(model), mode == .video, let panel else { return }
        let start = NSEvent.mouseLocation
        let offset = NSPoint(x: start.x - panel.frame.minX, y: start.y - panel.frame.minY)
        dragTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let mini = MiniPlayer.shared
                guard NSEvent.pressedMouseButtons & 1 != 0, let panel = mini.panel, panel.isVisible else { return mini.pageDragEnded() }
                let p = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(x: p.x - offset.x, y: p.y - offset.y))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    func pageDragEnded() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    // MARK: Keys and options

    /// Text: Space plays or pauses, ← → move by paragraph. A video's keys stay the site's.
    private func handle(_ event: NSEvent) -> Bool {
        guard mode == .text, let model, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 49: model.togglePlayPause()
        case 123: model.previous()
        case 124: model.next()
        default: return false
        }
        return true
    }

    private func optionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionItem(String(localized: "Back to Window")) { MiniPlayer.shared.backToWindow() })
        menu.addItem(ActionItem(String(localized: "Close")) { MiniPlayer.shared.close() })
        menu.addItem(.separator())
        let opacityItem = NSMenuItem(title: String(localized: "Opacity"), action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for level in [1.0, 0.8, 0.6, 0.4] {
            let item = ActionItem(level.formatted(.percent)) { MiniPlayer.shared.opacity = level }
            item.state = abs(opacity - level) < 0.01 ? .on : .off
            levels.addItem(item)
        }
        opacityItem.submenu = levels
        menu.addItem(opacityItem)
        menu.addItem(.separator())
        let automatic = ActionItem(String(localized: "Switch to the Mini Player When I Go to Another App")) {
            MiniPlayer.shared.switchesAutomatically.toggle()
        }
        automatic.state = switchesAutomatically ? .on : .off
        menu.addItem(automatic)
        return menu
    }

    // MARK: The window

    private func makePanel() -> MiniPanel {
        let panel = MiniPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
                              styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        // ⌘H hides the app's windows, not this one.
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.onEscape = { MiniPlayer.shared.backToWindow() }
        panel.onKey = { MiniPlayer.shared.handle($0) }
        panel.options = { MiniPlayer.shared.optionsMenu() }

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        let text = NSHostingView(rootView: MiniTextView(mini: self))
        let video = HoverView()
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor.black.cgColor
        for view in [text, video] as [NSView] {
            effect.addSubview(view)
            pin(view, in: effect)
        }
        let bar = NSHostingView(rootView: MiniVideoBar(mini: self))
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        video.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            bar.topAnchor.constraint(equalTo: video.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
        ])
        // The bar shows while the mouse is over the video.
        video.onHover = { [weak bar] inside in bar?.isHidden = !inside }

        let delegate = PanelDelegate()
        panel.delegate = delegate
        self.delegate = delegate
        self.panel = panel
        textHost = text
        videoHost = video
        videoBar = bar
        return panel
    }
}

/// Becomes key without activating the app, so Escape and the text keys reach it, and so the first
/// click already works; a right-click anywhere (the video included) opens the mini player's options.
final class MiniPanel: NSPanel {
    var onEscape: () -> Void = {}
    var onKey: (NSEvent) -> Bool = { _ in false }
    var options: () -> NSMenu = { NSMenu() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape() }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown:
            if let view = contentView { NSMenu.popUpContextMenu(options(), with: event, for: view) }
            return
        case .leftMouseDown:
            // Key first, so the click (and a drag starting with it) reaches the page and the buttons
            // instead of only making the window key.
            if !isKeyWindow { makeKey() }
        case .keyDown:
            if event.keyCode == 53 { return onEscape() }
            if onKey(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { MainActor.assumeIsolated { MiniPlayer.shared.moved() } }
    func windowDidResize(_ notification: Notification) { MainActor.assumeIsolated { MiniPlayer.shared.moved() } }
}

/// Reports the mouse coming in and going out, even over the page view that covers it.
final class HoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

private final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}

// MARK: - Contents

/// Moves the window when dragged; a double-click brings everything back to the main window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { return MiniPlayer.shared.backToWindow() }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Over the video, while the mouse is on it: the title, ⤢ and ✕. The bar also moves the window.
struct MiniVideoBar: View {
    let mini: MiniPlayer

    var body: some View {
        HStack(spacing: 6) {
            Text(mini.model?.articleTitle ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 8)
            MiniWindowButtons(mini: mini)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
        .background(LinearGradient(colors: [.black.opacity(0.8), .black.opacity(0)], startPoint: .top, endPoint: .bottom))
    }
}

struct MiniWindowButtons: View {
    let mini: MiniPlayer

    var body: some View {
        HStack(spacing: 2) {
            MiniIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Back to Window (Esc)") { mini.backToWindow() }
            MiniIconButton(symbol: "xmark", help: "Close (pauses)") { mini.close() }
        }
    }
}

struct MiniIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var size: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size * 2.2, height: size * 2.2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.9))
        .help(help)
    }
}

/// The article: its title and place, then the paragraph being read, the word highlighted, scrolling
/// as the reading goes on. The playback buttons show while the mouse is over it.
struct MiniTextView: View {
    let mini: MiniPlayer
    @State private var hovering = false

    var body: some View {
        if let model = mini.model {
            content(model)
        } else {
            Color.clear
        }
    }

    private func content(_ model: BrowserModel) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(model.phase == .loading ? String(localized: "Loading…") : model.articleTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if hovering {
                        MiniWindowButtons(mini: mini)
                    } else if model.phase == .ready, !model.blockLengths.isEmpty {
                        Text(verbatim: "\(model.position + 1) / \(model.blockLengths.count)")
                            .font(.system(size: 10).monospacedDigit())
                    }
                }
                .foregroundStyle(.white.opacity(0.6))
                .frame(height: 22)
                Teleprompter(text: model.phase == .ready ? model.blockText(model.position) ?? "" : model.loadingHost,
                             word: model.phase == .ready ? model.spokenWord : nil,
                             fontSize: min(34, max(15, geometry.size.width / 19)))
                // The lines going out of sight fade instead of being cut.
                .mask(LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .black, location: 0.08),
                                             .init(color: .black, location: 0.78), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.top, 6).padding(.bottom, 10)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if hovering, model.phase == .ready {
                    MiniControls(model: model, speech: model.speech)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
            }
        }
        .background(WindowDragArea())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

private struct MiniControls: View {
    let model: BrowserModel
    let speech: SpeechController

    var body: some View {
        HStack(spacing: 4) {
            MiniIconButton(symbol: "backward.fill", help: "Previous paragraph (←)", size: 13) { model.previous() }
            MiniIconButton(symbol: speech.state == .speaking ? "pause.fill" : "play.fill", help: "Play / Pause (Space)", size: 16) {
                model.togglePlayPause()
            }
            MiniIconButton(symbol: "forward.fill", help: "Next paragraph (→)", size: 13) { model.next() }
            if !model.playlist.items.isEmpty {
                MiniIconButton(symbol: "forward.end.fill", help: "Next article in the playlist", size: 13) { model.nextArticle() }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// The paragraph in large type, the spoken word highlighted, its line kept in the upper third.
struct Teleprompter: NSViewRepresentable {
    let text: String
    let word: NSRange?
    let fontSize: CGFloat

    func makeNSView(context: Context) -> TeleprompterView { TeleprompterView() }

    func updateNSView(_ view: TeleprompterView, context: Context) {
        view.show(text, word: word, fontSize: fontSize)
    }
}

final class TeleprompterView: NSView {
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var shownText = ""
    private var shownSize: CGFloat = 0
    private var shownWord: NSRange?

    private static let highlight = NSColor(srgbRed: 1, green: 0.78, blue: 0.2, alpha: 0.42)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        scroll.documentView = textView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // The whole text area moves the window: clicks don't select or scroll.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func scrollWheel(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { return MiniPlayer.shared.backToWindow() }
        window?.performDrag(with: event)
    }

    func show(_ text: String, word: NSRange?, fontSize: CGFloat) {
        guard let storage = textView.textStorage else { return }
        if text != shownText || fontSize != shownSize {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.18
            let font = NSFont(name: "Charter-Roman", size: fontSize) ?? .systemFont(ofSize: fontSize)
            storage.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: paragraph,
            ]))
            let newParagraph = text != shownText
            shownText = text
            shownSize = fontSize
            shownWord = nil
            if newParagraph {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; animator().alphaValue = 1 }
            }
        }
        guard word != shownWord else { return }
        let length = (text as NSString).length
        if let old = shownWord, NSMaxRange(old) <= length { storage.removeAttribute(.backgroundColor, range: old) }
        shownWord = word
        guard let word, word.length > 0, NSMaxRange(word) <= length,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        storage.addAttribute(.backgroundColor, value: Self.highlight, range: word)
        // Keep the word's line in the upper third.
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
        let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let visible = scroll.contentView.bounds.height
        let total = layout.usedRect(for: container).height
        let target = max(0, min(line.minY - visible * 0.3, total - visible))
        guard abs(target - scroll.contentView.bounds.origin.y) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// In the main window while the video plays in the mini player.
struct MiniPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Playing in the mini player").font(.title3.weight(.semibold))
            Button("Back to Window") { MiniPlayer.shared.backToWindow() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
