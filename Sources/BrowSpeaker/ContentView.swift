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
                        .help("Close Article")
                }
            }
        }
        .navigationTitle(model.phase == .ready ? model.articleTitle : "Talk to me Bro")
        .navigationSubtitle(model.phase == .ready ? model.siteName : "")
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isDropTargeted) { providers in
            openDropped(providers)
        }
        .focusedSceneValue(\.browser, model)
        .onDisappear { model.speech.stop() }
        .onOpenURL { model.handleOpenURL($0) }
        // Sources refresh at launch, then every 30 minutes.
        .task {
            while !Task.isCancelled {
                await Feeds.shared.refreshIfNeeded()
                try? await Task.sleep(for: .seconds(300))
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

    init(model: BrowserModel) {
        self.model = model
    }

    private static func isVideo(_ url: URL) -> Bool {
        VideoPage.looksLikeVideo(url) || VideoPage.YouTube.videoID(in: url) != nil
    }

    private var items: [FeedItem] {
        let latest = feeds.latest
        switch tab {
        case .all: return Array(latest.prefix(24))
        case .articles: return Array(latest.filter { !Self.isVideo($0.url) }.prefix(24))
        case .videos: return Array(latest.filter { Self.isVideo($0.url) }.prefix(24))
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

    var body: some View {
        let items = self.items
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Show", selection: $tab) {
                    Text("All").tag(Tab.all)
                    Text("Articles").tag(Tab.articles)
                    Text("Videos").tag(Tab.videos)
                    Group {
                        if model.playlist.items.isEmpty { Text("Playlist") } else { Text("Playlist (\(model.playlist.items.count))") }
                    }
                    .tag(Tab.playlist)
                    Text("History").tag(Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if feeds.isRefreshing { ProgressView().controlSize(.small) }
                Spacer()
                if tab == .playlist {
                    Button { model.playNextInPlaylist() } label: { Label("Play Playlist", systemImage: "play.fill") }
                        .disabled(model.playlist.items.isEmpty)
                } else {
                    Picker("Display", selection: $style) {
                        Image(systemName: "square.grid.2x2").help("Cards").tag("cards")
                        Image(systemName: "list.bullet").help("List").tag("list")
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
                    Button { Task { await feeds.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh")
                        .disabled(feeds.isRefreshing)
                    Button {
                        model.listenToAll(items.filter { !model.hasRead($0.url) }.map(\.url))
                    } label: { Label("Listen to All", systemImage: "text.badge.plus") }
                        .help("Add the unread articles to the playlist and start listening")
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
                Text(tab == .history ? "Articles you listen to will appear here." : "No articles yet.")
                    .foregroundStyle(.secondary)
            } else if style == "cards" {
                cards(items)
            } else {
                ForEach(items) { item in
                    HStack {
                        ArticleRow(title: item.title, detail: detail(of: item), isRead: tab != .history && model.hasRead(item.url),
                                   isVideo: Self.isVideo(item.url)) {
                            model.play(item.url)
                        }
                        Button { model.addToPlaylist(item.url) } label: { Image(systemName: "plus.circle") }
                            .buttonStyle(.borderless)
                            .help("Add to Playlist")
                    }
                    .contextMenu { menu(for: item) }
                }
            }
        }
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
        ArticleCard(item: item, detail: detail(of: item), isRead: tab != .history && model.hasRead(item.url),
                    imageHeight: imageHeight, titleFont: titleFont,
                    play: { model.play(item.url) }, add: { model.addToPlaylist(item.url) })
            .contextMenu { menu(for: item) }
    }

    @ViewBuilder
    private func menu(for item: FeedItem) -> some View {
        Button("Add to Playlist") { model.addToPlaylist(item.url) }
        Button("Open in Browser") { NSWorkspace.shared.open(item.url) }
        if tab == .history {
            Divider()
            Button("Remove from History", role: .destructive) { model.history.remove(item.sourceID) }
        }
    }

    private func detail(of item: FeedItem) -> String {
        guard let date = item.date else { return item.sourceTitle }
        return "\(item.sourceTitle) · \(date.formatted(.relative(presentation: .named)))"
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
        .opacity(isRead ? 0.65 : 1)
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

/// Bottom bar: progress by paragraph, playback controls, and reading options.
private struct PlayerBar: View {
    let model: BrowserModel
    @Bindable var speech: SpeechController
    /// The paragraph under the slider while it is being dragged.
    @State private var scrub: Double?
    @State private var showsPlaylist = false

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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.articleTitle).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(model.siteName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if model.isVideo && model.videoAd {
                            Label("Ad · muted", systemImage: "speaker.slash.fill")
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
                    Button { model.closeArticle() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                        .help("Next article in the playlist")
                        .disabled(model.playlist.items.isEmpty)
                }
                .buttonStyle(.plain)

                HStack(spacing: 16) {
                    Button { showsPlaylist.toggle() } label: {
                        Image(systemName: "list.bullet")
                            .overlay(alignment: .topTrailing) {
                                if !model.playlist.items.isEmpty {
                                    Text(verbatim: "\(model.playlist.items.count)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .background(Capsule().fill(Color.accentColor))
                                        .offset(x: 10, y: -8)
                                }
                            }
                    }
                    .buttonStyle(.borderless)
                    .help("Playlist")
                    .popover(isPresented: $showsPlaylist, arrowEdge: .top) {
                        PlaylistView(model: model).frame(width: 380, height: 420)
                    }

                    Menu {
                        Picker("Speed", selection: $speech.speed) {
                            ForEach(SpeechController.speeds, id: \.self) { speed in
                                Text(speedLabel(speed)).tag(speed)
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
                        Text(speedLabel(speech.speed)).font(.body.monospacedDigit().weight(.medium))
                    }
                    .help("Speed and pauses")

                    if !model.isVideo {
                        Menu {
                            VoiceChoices(speech: speech)
                        } label: {
                            Image(systemName: "person.wave.2")
                        }
                        .help("Voice: \(speech.voiceLabel)")

                        Menu {
                            Button("Bigger Text") { model.zoom(by: 1) }
                            Button("Smaller Text") { model.zoom(by: -1) }
                            Button("Actual Size") { model.resetZoom() }
                        } label: {
                            Image(systemName: "textformat.size")
                        }
                        .help("Text size")
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
    }

    private func speedLabel(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
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
                        Button("Add to Playlist") { model.addToPlaylist(item.url) }
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
