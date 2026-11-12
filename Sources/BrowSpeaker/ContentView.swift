import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @State private var model = BrowserModel()
    @State private var isDropTargeted = false
    @State private var showsHistory = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                BrowserSurface(model: model, showsArticle: model.phase == .ready && !model.isVideo,
                               showsVideo: model.phase == .ready && model.isVideo)
                if model.phase != .ready {
                    WelcomeView(model: model)
                }
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            if model.phase == .ready {
                PlayerBar(model: model, speech: model.speech)
            }
        }
        .overlay(alignment: .top) {
            if let message = model.errorMessage ?? model.notice {
                Text(message)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .onTapGesture { model.errorMessage = nil }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // The player's options live here, so the player bar only holds playback.
                if model.phase == .ready {
                    PlaylistButton(model: model)
                    SpeedMenu(model: model, speech: model.speech)
                    VolumeButton(model: model, speech: model.speech)
                    if !model.isVideo {
                        VoiceMenu(speech: model.speech)
                        TextSizeMenu(model: model)
                    }
                }
                Button { showsHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                    .help("Recently read articles")
                    .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                        HistoryView(model: model) { showsHistory = false }
                            .frame(width: 400, height: 460)
                    }
                if model.phase == .ready {
                    Button { model.openInBrowser() } label: { Label("Open in Browser", systemImage: "safari") }
                        .help("Open the original page in the browser")
                    Button { model.closeArticle() } label: { Label("Close Article", systemImage: "xmark") }
                        .help(model.isSlideshowOn ? "Back to the slideshow (Esc)" : "Back to the home page (Esc)")
                }
            }
        }
        .navigationTitle(model.phase == .ready ? model.articleTitle : "Talk to me Bro")
        .navigationSubtitle(model.phase == .ready ? model.siteName : "")
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            openDropped(providers)
        }
        .focusedSceneValue(\.browser, model)
        .onDisappear {
            model.speech.stop()
            NowPlaying.shared.forget(model)
        }
        .onOpenURL { model.handleOpenURL($0) }
        // Sources refresh at launch, then as often as chosen in Settings › Sources.
        .task {
            while !Task.isCancelled {
                await Feeds.shared.refreshIfNeeded()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // Shared links go to an existing window instead of opening a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .frame(minWidth: 640, minHeight: 480)
    }

    /// A link dragged from a browser, a `.webloc` from the Finder, or text containing a link.
    private func openDropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.handleOpenURL(url) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                guard let text else { return }
                DispatchQueue.main.async { model.open(text: text) }
            }
            return true
        }
        return false
    }
}

/// Shown when no article is open, and while one loads: a short introduction
/// on first use, then a home page with the playlist, sources and history.
private struct WelcomeView: View {
    let model: BrowserModel
    private var feeds = Feeds.shared

    init(model: BrowserModel) {
        self.model = model
    }

    var body: some View {
        if model.isSlideshowOn, model.phase == .empty {
            SlideshowView(model: model)
        } else {
            page
        }
    }

    private var page: some View {
        Group {
            if model.phase == .loading {
                VStack(spacing: 18) {
                    appIcon(112)
                    Text("Loading article…").font(.title2.weight(.semibold))
                    Text(model.loadingHost).foregroundStyle(.secondary)
                    ProgressView(value: model.progress).frame(width: 260)
                    Button("Cancel") { model.closeArticle() }
                }
            } else if model.playlist.items.isEmpty && model.history.items.isEmpty && feeds.sources.isEmpty {
                VStack(spacing: 18) {
                    appIcon(112)
                    Text("Talk to me Bro").font(.largeTitle.weight(.bold))
                    Text("Listen to your articles, without ads or distractions.")
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    instructions.frame(maxWidth: 420, alignment: .leading)
                    SettingsLink { Text("Add sites or RSS feeds…") }
                        .padding(.top, 8)
                }
            } else {
                home
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text("In your browser, open an article and choose **Share › Read with Talk to me Bro**.")
            } icon: { Image(systemName: "square.and.arrow.up") }
            Label("Or drag a link into this window.", systemImage: "arrow.down.to.line")
            Label("Or copy a link, then press ⇧⌘V.", systemImage: "doc.on.clipboard")
        }
        .font(.callout)
    }

    private func appIcon(_ size: CGFloat) -> some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: size, height: size)
    }

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 14) {
                    appIcon(56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Talk to me Bro").font(.title2.weight(.bold))
                        Text("Share an article from your browser, drag a link here, or pick one below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if feeds.sources.isEmpty && !model.playlist.items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Playlist").font(.title3.weight(.semibold))
                            Spacer()
                            Button { model.playNextInPlaylist() } label: { Label("Play Playlist", systemImage: "play.fill") }
                                .keyboardShortcut(.defaultAction)
                        }
                        PlaylistView(model: model)
                            .frame(height: 220)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                if feeds.sources.isEmpty {
                    HStack {
                        Text("Add sites or RSS feeds to see their latest articles here.")
                            .foregroundStyle(.secondary)
                        SettingsLink { Text("Add Sources…") }
                    }
                } else {
                    ToReadSection(model: model)
                }

                if feeds.sources.isEmpty && !model.history.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recently read").font(.title3.weight(.semibold))
                        ForEach(model.history.items.prefix(5)) { item in
                            ArticleRow(title: item.title, detail: item.site, isRead: false) { model.reopen(item) }
                        }
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// The latest articles of the user's sources, filtered by tab (all, articles,
/// videos) as magazine cards or a list; and the history in its own tab.
private struct ToReadSection: View {
    enum Tab: String, CaseIterable, Identifiable {
        case all, articles, videos, playlist, history
        var id: Self { self }
    }

    let model: BrowserModel
    private var feeds = Feeds.shared
    @AppStorage("toReadStyle") private var style = "cards"
    @AppStorage("homeTab") private var tab = Tab.all
    /// "Listen to All" order: newest first (as on screen) or oldest first (chronological).
    @AppStorage("listenOrder") private var oldestFirst = false
    @AppStorage("hideRead") private var hidesRead = false

    init(model: BrowserModel) {
        self.model = model
    }

    static func isVideo(_ url: URL) -> Bool {
        VideoPage.looksLikeVideo(url) || VideoPage.YouTube.videoID(in: url) != nil
    }

    private var items: [FeedItem] {
        switch tab {
        case .all, .articles, .videos: return Self.feedItems(tab, hidingRead: hidesRead, model: model)
        case .playlist: return []
        case .history:
            // History entries as cards, with the picture of the same article in the sources when known.
            let images = Dictionary(feeds.items.compactMap { item in item.image.map { (BrowserModel.readKey(item.url), $0) } },
                                    uniquingKeysWith: { a, _ in a })
            return model.history.items.map {
                FeedItem(url: $0.url, title: $0.title, date: $0.date, sourceID: $0.id, sourceTitle: $0.site,
                         image: images[BrowserModel.readKey($0.url)])
            }
        }
    }

    private func tabGlyph(_ symbol: String, _ name: LocalizedStringKey) -> some View {
        Image(systemName: symbol).help(name).accessibilityLabel(name)
    }

    /// "8:42", with the day when it wasn't today.
    private static func time(of date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                             : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// "8:42", or only the day when it wasn't today ("1 Nov"): short enough for a button.
    private static func shortTime(of date: Date) -> String {
        Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
                                             : date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A feed tab's articles: the 24 newest; once read articles are hidden, the 24
    /// newest unread. The slideshow shows the same.
    static func feedItems(_ tab: Tab, hidingRead: Bool, model: BrowserModel) -> [FeedItem] {
        let latest = Feeds.shared.latest
        let items = switch tab {
        case .articles: latest.filter { !isVideo($0.url) }
        case .videos: latest.filter { isVideo($0.url) }
        default: latest
        }
        return Array((hidingRead ? items.filter { !model.hasRead($0.url) } : items).prefix(24))
    }

    var body: some View {
        // Drawn again each minute, so the "5 minutes ago" keep up while the window sits open.
        TimelineView(.everyMinute) { _ in
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 12) {
            // The tabs as glyphs but All (their names in the help), so the bar fits on one row,
            // no wider than the cards. The playlist's shows its count instead, when it has
            // any: a segment shows a text or a picture, not both.
            HStack {
                Picker("Show", selection: $tab) {
                    Text("All").tag(Tab.all)
                    tabGlyph("newspaper", "Articles").tag(Tab.articles)
                    tabGlyph("play.rectangle", "Videos").tag(Tab.videos)
                    Group {
                        if model.playlist.items.isEmpty {
                            tabGlyph("list.bullet", "Playlist")
                        } else {
                            Text(verbatim: "\(model.playlist.items.count)")
                                .help("Playlist")
                                .accessibilityLabel("Playlist")
                                .accessibilityValue(Text(verbatim: "\(model.playlist.items.count)"))
                        }
                    }
                    .tag(Tab.playlist)
                    tabGlyph("clock.arrow.circlepath", "History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab == .playlist {
                    Button { model.playNextInPlaylist() } label: { Label("Play Playlist", systemImage: "play.fill") }
                        .disabled(model.playlist.items.isEmpty)
                } else {
                    Picker("Display", selection: $style) {
                        Image(systemName: "square.grid.2x2").help("Cards").tag("cards")
                        Image(systemName: "rectangle.grid.1x2").help("List").tag("list")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                if tab == .playlist {
                    EmptyView()
                } else if tab == .history {
                    Button("Clear") { model.history.clear() }
                        .disabled(items.isEmpty)
                } else {
                    Button {
                        model.slideURL = nil
                        model.slideIndex = 0
                        model.isSlideshowOn = true
                    } label: {
                        Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Slideshow: the articles one at a time")
                    .disabled(items.isEmpty)
                    // A plain button like ↻: only the eye changes (crossed out while read articles are hidden).
                    Button { hidesRead.toggle() } label: {
                        Label("Hide Read", systemImage: hidesRead ? "eye.slash" : "eye")
                    }
                    .labelStyle(.iconOnly)
                    .help(hidesRead ? "Show read articles" : "Hide read articles")
                    // ↻ shows when it last refreshed, and turns into a spinner while it refreshes.
                    Button { Task { await feeds.refreshAll() } } label: {
                        HStack(spacing: 4) {
                            if feeds.isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            if let date = feeds.lastRefresh { Text(verbatim: Self.shortTime(of: date)).monospacedDigit() }
                        }
                    }
                    // Not disabled while refreshing (a click then does nothing): the spinner stays easy to see.
                    .help(feeds.lastRefresh.map { Text("Refreshed at \(Self.time(of: $0)). Click to refresh now.") } ?? Text("Refresh"))
                    // Picking an order also starts listening in it, and becomes the button's order.
                    Menu {
                        Button { listenToAll(items, oldestFirst: false) } label: {
                            if oldestFirst { Text("Newest First") } else { Label("Newest First", systemImage: "checkmark") }
                        }
                        Button { listenToAll(items, oldestFirst: true) } label: {
                            if oldestFirst { Label("Oldest First", systemImage: "checkmark") } else { Text("Oldest First") }
                        }
                    } label: {
                        Label("Listen to All", systemImage: "text.badge.plus")
                    } primaryAction: {
                        listenToAll(items, oldestFirst: oldestFirst)
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help(oldestFirst ? "Add the unread articles to the playlist, oldest first, and start listening"
                                      : "Add the unread articles to the playlist, newest first, and start listening")
                    .disabled(items.allSatisfy { model.hasRead($0.url) })
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Manage sources")
                }
            }
            if tab == .playlist {
                // The playlist's own list: drag to reorder, Delete to remove, double-click to play.
                PlaylistView(model: model)
                    .frame(height: min(max(CGFloat(model.playlist.items.count) * 54 + 60, 140), 560))
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            } else if items.isEmpty {
                Text(tab == .history ? "Articles you listen to will appear here." : hidesRead ? "No unread articles." : "No articles yet.")
                    .foregroundStyle(.secondary)
            } else if style == "cards" {
                cards(items)
            } else {
                ForEach(items) { item in
                    HStack {
                        ArticleRow(title: item.title, detail: Self.detail(of: item), isRead: tab != .history && model.hasRead(item.url),
                                   isVideo: Self.isVideo(item.url)) {
                            model.play(item.url)
                        }
                        Button { model.addToPlaylist(item.url, title: item.title, site: item.sourceTitle) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless)
                            .help("Add to Playlist")
                    }
                    .contextMenu { menu(for: item) }
                }
            }
        }
    }

    private func listenToAll(_ items: [FeedItem], oldestFirst: Bool) {
        self.oldestFirst = oldestFirst
        let unread = items.filter { !model.hasRead($0.url) }
        model.listenToAll(oldestFirst ? unread.reversed() : unread)
    }

    /// The newest unread article with a picture as a large card, then a grid.
    @ViewBuilder
    private func cards(_ items: [FeedItem]) -> some View {
        let hero = tab == .history ? nil : items.first { $0.image != nil && !model.hasRead($0.url) }
        if let hero {
            card(hero, imageHeight: 260, titleFont: .title2.weight(.bold))
        }
        // A plain grid, laid out once: a lazy grid of cards of different heights
        // could keep re-measuring them and freeze the app.
        let rest = items.filter { $0.id != hero?.id }
        let columns = 3
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 20) {
            ForEach(Array(stride(from: 0, to: rest.count, by: columns)), id: \.self) { start in
                GridRow(alignment: .top) {
                    ForEach(rest[start..<min(start + columns, rest.count)]) { item in
                        card(item, imageHeight: 120, titleFont: .headline)
                    }
                    // Keep the last row's cards the same width as the others.
                    ForEach(0..<(columns - min(columns, rest.count - start)), id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    private func card(_ item: FeedItem, imageHeight: CGFloat, titleFont: Font) -> some View {
        ArticleCard(item: item, detail: Self.detail(of: item), isRead: tab != .history && model.hasRead(item.url),
                    imageHeight: imageHeight, titleFont: titleFont,
                    play: { model.play(item.url) }, add: { model.addToPlaylist(item.url, title: item.title, site: item.sourceTitle) })
            .contextMenu { menu(for: item) }
    }

    @ViewBuilder
    private func menu(for item: FeedItem) -> some View {
        Button("Add to Playlist") { model.addToPlaylist(item.url, title: item.title, site: item.sourceTitle) }
        Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
        if tab == .history {
            Divider()
            Button("Remove from History", role: .destructive) { model.history.remove(item.sourceID) }
        }
    }

    static func detail(of item: FeedItem) -> String {
        guard let date = item.date else { return item.sourceTitle }
        return "\(item.sourceTitle) · \(date.formatted(.relative(presentation: .named)))"
    }
}

/// The slideshow's choices, also in Settings › Slideshow.
enum Slideshow {
    static let durations = [5, 8, 10, 15, 20, 30, 60]

    /// How one article gives way to the next.
    enum Transition: String, CaseIterable, Identifiable {
        case fade, black, slide, zoom, blur, wipe, random

        var id: Self { self }

        var label: String {
            switch self {
            case .fade: String(localized: "Crossfade")
            case .black: String(localized: "Fade through black")
            case .slide: String(localized: "Slide")
            case .zoom: String(localized: "Zoom")
            case .blur: String(localized: "Blur")
            case .wipe: String(localized: "Wipe")
            case .random: String(localized: "Random")
            }
        }

        /// For `random`, one of the others each time.
        var resolved: Transition {
            self == .random ? Self.allCases.filter { $0 != .random }.randomElement() ?? .fade : self
        }

        var animation: Animation {
            switch self {
            case .slide: .easeInOut(duration: 0.7)
            case .black: .easeInOut(duration: 1)
            default: .easeInOut(duration: 0.9)
            }
        }
    }
}

/// The move under way, read by the slides as they come and go. A leaving slide keeps
/// the transition it came with, not the latest one: so one transition for all, which
/// looks here for the effect and the direction.
private final class SlideMotion {
    var effect = Slideshow.Transition.fade
    var forward = true
}

/// A slide coming (0 → 1) or leaving (1 → 0), as the move under way wants. The
/// same modifiers whatever the effect, so a slide keeps its content when it changes.
private struct SlideEffect: ViewModifier, Animatable {
    let motion: SlideMotion
    /// 1: in place; 0: not in yet, or gone.
    var shown: Double
    let leaving: Bool

    var animatableData: Double {
        get { shown }
        set { shown = newValue }
    }

    static func transition(_ motion: SlideMotion) -> AnyTransition {
        .asymmetric(insertion: .modifier(active: Self(motion: motion, shown: 0, leaving: false),
                                         identity: Self(motion: motion, shown: 1, leaving: false)),
                    removal: .modifier(active: Self(motion: motion, shown: 0, leaving: true),
                                       identity: Self(motion: motion, shown: 1, leaving: true)))
    }

    func body(content: Content) -> some View {
        let effect = motion.effect, away = 1 - shown
        // Forward, the next one comes from the right and the old one leaves to the left.
        let side: Double = (leaving ? -1 : 1) * (motion.forward ? 1 : -1)
        let opacity: Double = switch effect {
        // Out to black, then in: half the time each.
        case .black: max(0, 2 * shown - 1)
        // The new one is uncovered over the old one, which leaves once covered.
        case .wipe: leaving ? (shown > 0 ? 1 : 0) : 1
        default: shown
        }
        // As if going through: the old one grows as it fades, the new one grows into place.
        let scale = effect == .zoom ? (leaving ? 1 + 0.08 * away : 1 - 0.08 * away) : 1
        let shift = effect == .slide ? side * away : 0
        let uncovered = effect == .wipe && !leaving ? shown : 1
        content
            .scaleEffect(scale)
            .blur(radius: effect == .blur ? 40 * away : 0)
            .visualEffect { view, geometry in view.offset(x: geometry.size.width * shift) }
            .mask {
                Rectangle().scaleEffect(x: max(uncovered, 0.001), y: 1, anchor: motion.forward ? .leading : .trailing)
            }
            .opacity(opacity)
    }
}

/// The home page's articles one at a time, picture and title, a few seconds each,
/// round and round while the sources refresh. A click listens to the article,
/// whose end comes back here.
private struct SlideshowView: View {
    let model: BrowserModel
    private var feeds = Feeds.shared
    @AppStorage("homeTab") private var tab = ToReadSection.Tab.all
    @AppStorage("hideRead") private var hidesRead = false
    @AppStorage("slideshowSeconds") private var seconds = 10
    @AppStorage("slideshowTransition") private var style = Slideshow.Transition.fade
    @AppStorage("slideshowKenBurns") private var kenBurns = false
    @AppStorage("slideshowTitleAfter") private var titleAfter = false
    @State private var motion = SlideMotion()
    @State private var isPaused = false
    /// When the slide appeared, for the progress line.
    @State private var shownAt = Date()
    /// Counts the moves, so the timer starts again even when the slide stays the same.
    @State private var moves = 0
    /// Each new slide above the one it replaces: a slide being removed from a stack
    /// is otherwise drawn below the others, and its transition isn't seen.
    @State private var layer = 0.0
    @State private var showsControls = false
    @State private var isOverControls = false
    @State private var hidingControls: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(model: BrowserModel) {
        self.model = model
    }

    private var items: [FeedItem] {
        ToReadSection.feedItems([.articles, .videos].contains(tab) ? tab : .all, hidingRead: hidesRead, model: model)
    }

    /// Where the slide's article is now, or where it was once the sources dropped it.
    private func index(in items: [FeedItem]) -> Int {
        items.firstIndex { $0.url == model.slideURL } ?? min(model.slideIndex, items.count - 1)
    }

    private func move(by step: Int) {
        let items = self.items
        guard !items.isEmpty else { return }
        let i = (index(in: items) + step + items.count) % items.count
        let effect = style.resolved
        motion.effect = effect
        motion.forward = step >= 0
        moves += 1
        withAnimation(effect.animation) {
            layer += 1
            model.slideURL = items[i].url
            model.slideIndex = i
        }
    }

    private func open(_ item: FeedItem) {
        // Back from the article: the next one.
        move(by: 1)
        model.playFromSlideshow(item.url)
    }

    var body: some View {
        let items = self.items
        let i = items.isEmpty ? 0 : index(in: items)
        ZStack {
            if items.isEmpty {
                Text(hidesRead ? "No unread articles." : "No articles yet.").foregroundStyle(.white.opacity(0.6))
            } else {
                let item = items[i]
                // The picture zooms slowly until the slide is gone, transition included.
                Slide(item: item, isRead: model.hasRead(item.url),
                      zoomSeconds: kenBurns ? Double(seconds) + 2 : nil, titleAfter: titleAfter)
                    .contentShape(Rectangle())
                    .onTapGesture { open(item) }
                    .help("Click to listen")
                    .id(item.url)
                    .transition(SlideEffect.transition(motion))
                    .zIndex(layer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .clipped()
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if showsControls || isPaused || items.isEmpty {
                    controls(number: i + 1, of: items.count)
                        .onHover { isOverControls = $0 }
                        .transition(.opacity)
                }
                progress
            }
        }
        // Each slide for `seconds`, then the next one.
        .task(id: "\(moves) \(model.slideURL?.absoluteString ?? "") \(isPaused) \(seconds) \(items.isEmpty)") {
            shownAt = Date()
            guard !isPaused, !items.isEmpty else { return }
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { move(by: 1) }
        }
        // The next picture, loaded ahead.
        .task(id: items.isEmpty ? nil : items[(i + 1) % items.count].image) {
            if !items.isEmpty, let next = items[(i + 1) % items.count].image {
                _ = try? await URLSession.shared.data(from: next)
            }
        }
        // The controls show while the mouse moves, then hide with the pointer.
        .onContinuousHover { phase in
            switch phase {
            case .active: revealControls()
            case .ended: withAnimation { showsControls = false }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .onKeyPress(.space) { isPaused.toggle(); return .handled }
        .onKeyPress(.return) {
            if !items.isEmpty { open(items[i]) }
            return .handled
        }
        .onKeyPress(.escape) { model.isSlideshowOn = false; return .handled }
    }

    private func revealControls() {
        withAnimation { showsControls = true }
        hidingControls?.cancel()
        hidingControls = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !isOverControls else { return }
            withAnimation { showsControls = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func controls(number: Int, of count: Int) -> some View {
        HStack(spacing: 18) {
            if count > 0 {
                Text(verbatim: "\(number) / \(count)").monospacedDigit().foregroundStyle(.white.opacity(0.7))
                Button { move(by: -1) } label: { Image(systemName: "backward.fill") }
                    .help("Previous (←)")
                Button { isPaused.toggle() } label: { Image(systemName: isPaused ? "play.fill" : "pause.fill") }
                    .help(isPaused ? "Resume (Space)" : "Pause (Space)")
                Button { move(by: 1) } label: { Image(systemName: "forward.fill") }
                    .help("Next (→)")
                Menu {
                    ForEach(Slideshow.durations, id: \.self) { n in
                        Button { seconds = n } label: {
                            if n == seconds { Label("\(n) seconds", systemImage: "checkmark") } else { Text("\(n) seconds") }
                        }
                    }
                } label: {
                    Label("\(seconds) s", systemImage: "timer")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("Time per article")
            }
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Full Screen")
            Button { model.isSlideshowOn = false } label: { Image(systemName: "xmark") }
                .help("Close the slideshow (Esc)")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 16)
    }

    /// A thin line across the bottom, filling up until the next slide.
    private var progress: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: isPaused)) { context in
            GeometryReader { geometry in
                let fraction = isPaused ? 0 : min(context.date.timeIntervalSince(shownAt) / Double(seconds), 1)
                Rectangle().fill(.white.opacity(0.35)).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

/// One article of the slideshow: the picture, whole, over a blurred copy of itself
/// that fills the window whatever its shape; the title and source right below, the
/// two centered.
private struct Slide: View {
    let item: FeedItem
    let isRead: Bool
    /// Ken Burns: the picture zooms in slowly for this long, from when it shows.
    let zoomSeconds: Double?
    /// The title rises a moment after the picture.
    let titleAfter: Bool
    @State private var showsTitle = false

    var body: some View {
        AsyncImage(url: item.image) { phase in
            ZStack {
                if let image = phase.image {
                    Color.clear
                        .overlay { image.resizable().scaledToFill().blur(radius: 60).opacity(0.45) }
                        .clipped()
                }
                VStack(spacing: 28) {
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .modifier(SlowZoom(seconds: zoomSeconds))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.5), radius: 30)
                    } else {
                        // While the picture loads, or without one: its place, so the title doesn't jump.
                        RoundedRectangle(cornerRadius: 14)
                            .fill(.white.opacity(0.06))
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay {
                                if item.image == nil {
                                    Text(item.sourceTitle).font(.largeTitle.weight(.semibold)).foregroundStyle(.white.opacity(0.35))
                                }
                            }
                    }
                    VStack(spacing: 10) {
                        Text(item.title)
                            .font(.system(size: 34, weight: .bold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            if ToReadSection.isVideo(item.url) { Image(systemName: "play.rectangle") }
                            Text(ToReadSection.detail(of: item))
                            if isRead { Label("Read", systemImage: "checkmark") }
                        }
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.65))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: 900)
                    .opacity(titleAfter && !showsTitle ? 0 : 1)
                    .offset(y: titleAfter && !showsTitle ? 18 : 0)
                    // The title first: the picture takes the room left.
                    .layoutPriority(1)
                }
                .padding(.horizontal, 48)
                .padding(.top, 40)
                .padding(.bottom, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // After the transition's start, even a fade through black.
            if titleAfter { withAnimation(.easeOut(duration: 0.7).delay(0.8)) { showsTitle = true } }
        }
    }
}

/// Ken Burns: zooms in slowly toward a corner (another one each time), from when
/// the picture shows.
private struct SlowZoom: ViewModifier {
    let seconds: Double?
    @State private var zoomed = false
    @State private var anchor = [UnitPoint.topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .center].randomElement() ?? .center

    func body(content: Content) -> some View {
        content
            .scaleEffect(zoomed ? 1.15 : 1, anchor: anchor)
            .onAppear {
                if let seconds { withAnimation(.linear(duration: seconds)) { zoomed = true } }
            }
    }
}

/// A magazine card: picture, title, source and date. Click to listen, ➕ for the playlist.
private struct ArticleCard: View {
    let item: FeedItem
    let detail: String
    let isRead: Bool
    let imageHeight: CGFloat
    let titleFont: Font
    let play: () -> Void
    let add: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            picture
                .frame(height: imageHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .saturation(isRead ? 0.15 : 1)
                .opacity(isRead ? 0.4 : 1)
                // Video posts: a round mark at the bottom right, matching the ➕ at the top right.
                .overlay(alignment: .bottomTrailing) {
                    if VideoPage.looksLikeVideo(item.url) || VideoPage.YouTube.videoID(in: item.url) != nil {
                        Image(systemName: "video.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.7))
                            .padding(8)
                            .help("Video")
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isRead {
                        Label("Read", systemImage: "checkmark")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .overlay {
                    if isHovered {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white, .black.opacity(0.35))
                    }
                }
            Text(item.title)
                .font(titleFont)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isRead ? .secondary : .primary)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .opacity(isRead ? 0.85 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: play)
        .onHover { isHovered = $0 }
        .overlay(alignment: .topTrailing) {
            Button(action: add) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white, Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add to Playlist")
            .padding(8)
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image = item.image {
            AsyncImage(url: image) { phase in
                if let loaded = phase.image {
                    loaded.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text(item.sourceTitle).font(.callout.weight(.semibold)).foregroundStyle(.secondary).padding()
        }
    }
}

/// A clickable article line: title and a detail line; dimmed once read.
private struct ArticleRow: View {
    let title: String
    let detail: String
    let isRead: Bool
    var isVideo = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isRead ? "checkmark.circle" : isVideo ? "play.rectangle" : "play.circle").foregroundStyle(isRead ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).foregroundStyle(isRead ? .secondary : .primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bottom bar: progress, playback controls, and what plays next.
private struct PlayerBar: View {
    let model: BrowserModel
    @Bindable var speech: SpeechController
    /// The paragraph under the slider while it is being dragged.
    @State private var scrub: Double?

    private var count: Int { model.blockLengths.count }
    private var shown: Int { min(Int((scrub ?? Double(model.position)).rounded()), max(count - 1, 0)) }

    var body: some View {
        VStack(spacing: 8) {
            if model.isVideo {
                videoProgress
            } else {
                paragraphProgress
            }
            controls
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: speech.speed) { model.applyVideoSpeed() }
    }

    /// Video: elapsed time, position, time left.
    private var videoProgress: some View {
        let shownTime = scrub ?? model.videoTime
        return HStack(spacing: 10) {
            Text(verbatim: Self.clock(shownTime)).frame(width: 70, alignment: .leading)
            Slider(value: Binding(get: { scrub ?? model.videoTime }, set: { scrub = $0 }),
                   in: 0...max(model.videoDuration, 1)) { editing in
                if !editing, let scrub {
                    model.videoSeek(to: scrub)
                    self.scrub = nil
                }
            }
            .controlSize(.small)
            .disabled(model.videoDuration <= 0)
            Text(verbatim: model.videoDuration > 0 ? "−" + Self.clock(model.videoDuration - shownTime) : "")
                .frame(width: 70, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private static func clock(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private var isPlaying: Bool { model.isVideo ? model.videoPlaying : speech.state == .speaking }

    /// Reading: paragraph number, position, time left.
    private var paragraphProgress: some View {
            HStack(spacing: 10) {
                Text(verbatim: "\(shown + 1) / \(count)")
                    .frame(width: 70, alignment: .leading)
                Slider(value: Binding(get: { scrub ?? Double(model.position) }, set: { scrub = $0 }),
                       in: 0...Double(max(count - 1, 1))) { editing in
                    if !editing, let scrub {
                        model.seek(to: Int(scrub.rounded()))
                        self.scrub = nil
                    }
                }
                .controlSize(.small)
                .disabled(count < 2)
                Text(model.timeLeftLabel(from: shown))
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var controls: some View {
            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.articleTitle).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(model.siteName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let date = model.articleDate {
                            Text(verbatim: "· " + min(date, .now).formatted(.relative(presentation: .named)))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .fixedSize()
                                .help(date.formatted(date: .long, time: .shortened))
                        }
                        if model.isVideo && model.videoAd {
                            let music = AdMusic.shared.isPlaying
                            Label(music ? LocalizedStringKey("Ad · music") : LocalizedStringKey("Ad · muted"),
                                  systemImage: music ? "music.note" : "speaker.slash.fill")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.25), in: Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 24) {
                    Button { model.previous() } label: {
                        Image(systemName: model.isVideo ? "gobackward.15" : "backward.fill").font(.title2)
                    }
                    .help(model.isVideo ? "Back 15 seconds" : "Previous paragraph (←)")
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                    }
                    .help("Play / Pause (Space)")
                    Button { model.next() } label: {
                        Image(systemName: model.isVideo ? "goforward.15" : "forward.fill").font(.title2)
                    }
                    .help(model.isVideo ? "Forward 15 seconds" : "Next paragraph (→)")
                    Button { model.nextArticle() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                        .help("Next article in the playlist")
                        .disabled(model.playlist.items.isEmpty)
                }
                .buttonStyle(.plain)

                // What plays next, facing what plays now: the controls stay centered.
                // Not for an article opened from the slideshow: its end goes back there.
                Group {
                    if !model.startedFromSlideshow, let next = model.playlist.items.first {
                        Button { model.nextArticle() } label: {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(next.displayTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text("Up Next · \(next.displaySite)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Play it now")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
    }

}

/// The playlist, in a popover from the toolbar.
private struct PlaylistButton: View {
    let model: BrowserModel
    @State private var shows = false

    var body: some View {
        Button { shows.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                if !model.playlist.items.isEmpty {
                    Text(verbatim: "\(model.playlist.items.count)").font(.callout.monospacedDigit().weight(.semibold))
                }
            }
        }
        .help("Playlist")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            PlaylistView(model: model).frame(width: 380, height: 420)
        }
    }
}

/// Speed, and the pauses between sentences when reading.
private struct SpeedMenu: View {
    let model: BrowserModel
    @Bindable var speech: SpeechController

    var body: some View {
        Menu {
            Picker("Speed", selection: $speech.speed) {
                ForEach(SpeechController.speeds, id: \.self) { speed in
                    Text(Self.label(speed)).tag(speed)
                }
            }
            .pickerStyle(.inline)
            if !model.isVideo {
                Picker("Pauses between sentences and paragraphs", selection: $speech.pacing) {
                    ForEach(Pacing.allCases) { pacing in
                        Text(pacing.label).tag(pacing)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Text(Self.label(speech.speed)).font(.body.monospacedDigit().weight(.medium))
        }
        .menuIndicator(.hidden)
        .help("Speed and pauses")
    }

    private static func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// The volume of what plays. Reading and videos each keep their own, so going
/// from a video to an article doesn't call for the Mac's volume keys.
private struct VolumeButton: View {
    @Bindable var model: BrowserModel
    @Bindable var speech: SpeechController
    @Bindable private var music = AdMusic.shared
    @State private var shows = false

    var body: some View {
        let volume = model.isVideo ? $model.videoVolume : $speech.volume
        Button { shows.toggle() } label: {
            Label("Volume", systemImage: Self.icon(volume.wrappedValue))
        }
        .help(model.isVideo ? "Video volume" : "Reading volume")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.isVideo ? "Video volume" : "Reading volume").font(.headline)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Text("Reading and videos each keep their own volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isVideo && music.hasSource {
                    Divider().padding(.vertical, 4)
                    Text("Music during ads").font(.headline)
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $music.volume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .frame(width: 280)
        }
    }

    private static func icon(_ volume: Double) -> String {
        switch volume {
        case 0: "speaker.slash"
        case ..<0.34: "speaker.wave.1"
        case ..<0.67: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }
}

private struct VoiceMenu: View {
    let speech: SpeechController

    var body: some View {
        Menu {
            VoiceChoices(speech: speech)
        } label: {
            Label("Voice", systemImage: "person.wave.2")
        }
        .menuIndicator(.hidden)
        .help("Voice: \(speech.voiceLabel)")
    }
}

private struct TextSizeMenu: View {
    let model: BrowserModel

    var body: some View {
        Menu {
            Button("Bigger Text") { model.zoom(by: 1) }
            Button("Smaller Text") { model.zoom(by: -1) }
            Button("Actual Size") { model.resetZoom() }
        } label: {
            Label("Text size", systemImage: "textformat.size")
        }
        .menuIndicator(.hidden)
        .help("Text size")
    }
}

/// The articles waiting after the current one: reorder by dragging, remove
/// with Delete or the context menu, double-click to play one now.
private struct PlaylistView: View {
    let model: BrowserModel
    @State private var selection = Set<UUID>()

    var body: some View {
        let playlist = model.playlist
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Button("Clear") {
                    playlist.clear()
                    selection = []
                }
                .disabled(playlist.items.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if playlist.items.isEmpty {
                Text("Add articles with ➕, or share them while one is playing.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(playlist.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayTitle).lineLimit(2)
                            Text(item.displaySite).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.playNow(item.id) })
                        .contextMenu {
                            Button("Play Now") { model.playNow(item.id) }
                            Button("Remove", role: .destructive) { playlist.remove([item.id]) }
                        }
                    }
                    .onMove { playlist.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { playlist.remove(atOffsets: $0) }
                }
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    playlist.remove(selection)
                    selection = []
                }
            }
        }
    }
}

/// The last articles read: click one to read it again.
private struct HistoryView: View {
    let model: BrowserModel
    var onOpen: () -> Void = {}

    var body: some View {
        let history = model.history
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recently read").font(.headline)
                Spacer()
                Button("Clear") { history.clear() }
                    .disabled(history.items.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if history.items.isEmpty {
                Text("Articles you listen to will appear here.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(history.items) { item in
                    Button {
                        model.reopen(item)
                        onOpen()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(2)
                            Text("\(item.site) · \(item.date.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Add to Playlist") { model.addToPlaylist(item.url, title: item.title, site: item.site) }
                        Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
                        Divider()
                        Button("Remove from History", role: .destructive) { history.remove(item.id) }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// The voice menu: macOS voices, then Piper voices.
private struct VoiceChoices: View {
    @Bindable var speech: SpeechController
    private var piper = PiperService.shared

    init(speech: SpeechController) {
        self.speech = speech
    }

    var body: some View {
        let voices = AVVoices.installed()
        Picker("Voice", selection: $speech.voiceKey) {
            Text("System voice — \(SystemSpeechEngine.systemVoiceDescription)").tag(String?.none)
            Divider()
            ForEach(voices.main) { voice in
                Text(voice.label).tag(Optional(voice.key))
            }
            if !piper.voices.isEmpty {
                Divider()
                ForEach(piper.voices) { voice in
                    Text(voice.label).tag(Optional(voice.key))
                }
            }
        }
        .pickerStyle(.inline)
        Menu("Other Languages") {
            Picker("Other Languages", selection: $speech.voiceKey) {
                ForEach(voices.others) { voice in
                    Text(voice.label).tag(Optional(voice.key))
                }
            }
            .pickerStyle(.inline)
        }
        Divider()
        SettingsLink { Text("Piper Voices…") }
        Button("macOS Voices (Read & Speak)…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
        }
    }
}

/// Hosts the hidden page loader under the article view. The loader stays in a
/// window so pages load and run as if visible; the welcome screen covers it.
private struct BrowserSurface: NSViewRepresentable {
    let model: BrowserModel
    let showsArticle: Bool
    let showsVideo: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        for view in [model.webView, model.readerView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        model.readerView.isHidden = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if showsVideo, context.coordinator.focusedVideo == false {
            container.window?.makeFirstResponder(model.webView)
        }
        context.coordinator.focusedVideo = showsVideo
        guard model.readerView.isHidden == showsArticle else { return }
        model.readerView.isHidden = !showsArticle
        if showsArticle { container.window?.makeFirstResponder(model.readerView) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var focusedVideo = false
    }
}
