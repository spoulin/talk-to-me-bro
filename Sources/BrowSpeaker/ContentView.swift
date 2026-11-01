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
                BrowserSurface(model: model, showsArticle: model.phase == .ready)
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

/// Shown when no article is open, and while one loads.
private struct WelcomeView: View {
    let model: BrowserModel

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            if model.phase == .loading {
                Text("Loading article…").font(.title2.weight(.semibold))
                Text(model.loadingHost).foregroundStyle(.secondary)
                ProgressView(value: model.progress).frame(width: 260)
                Button("Cancel") { model.closeArticle() }
            } else {
                Text("Talk to me Bro").font(.largeTitle.weight(.bold))
                Text("Listen to your articles, without ads or distractions.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text("In your browser, open an article and choose **Share › Read with Talk to me Bro**.")
                    } icon: { Image(systemName: "square.and.arrow.up") }
                    Label("Or drag a link into this window.", systemImage: "arrow.down.to.line")
                    Label("Or copy a link, then press ⇧⌘V.", systemImage: "doc.on.clipboard")
                }
                .font(.callout)
                .frame(maxWidth: 420, alignment: .leading)
                if !model.playlist.items.isEmpty {
                    VStack(spacing: 10) {
                        Button { model.playNextInPlaylist() } label: {
                            Label("Play Playlist", systemImage: "play.fill")
                        }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        PlaylistView(model: model)
                            .frame(height: 260)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .frame(maxWidth: 460)
                    .padding(.top, 16)
                } else if !model.history.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recently read").font(.headline)
                        ForEach(model.history.items.prefix(5)) { item in
                            Button { model.reopen(item) } label: {
                                HStack {
                                    Image(systemName: "play.circle").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).lineLimit(1)
                                        Text(item.site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 460)
                    .padding(.top, 16)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.articleTitle).font(.headline).lineLimit(1)
                    Text(model.siteName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 24) {
                    Button { model.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                        .help("Previous paragraph (←)")
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: speech.state == .speaking ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                    }
                    .help("Play / Pause (Space)")
                    Button { model.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                        .help("Next paragraph (→)")
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
                        Picker("Pauses between sentences and paragraphs", selection: $speech.pacing) {
                            ForEach(Pacing.allCases) { pacing in
                                Text(pacing.label).tag(pacing)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(speedLabel(speech.speed)).font(.body.monospacedDigit().weight(.medium))
                    }
                    .help("Speed and pauses")

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
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
                Text("Share articles while one is playing to add them here.")
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
        guard model.readerView.isHidden == showsArticle else { return }
        model.readerView.isHidden = !showsArticle
        if showsArticle { container.window?.makeFirstResponder(model.readerView) }
    }
}
