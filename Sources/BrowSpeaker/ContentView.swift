import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @State private var model = BrowserModel()
    @State private var isDropTargeted = false

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
            if let message = model.errorMessage {
                Text(message)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .onTapGesture { model.errorMessage = nil }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.phase == .ready {
                    Button { model.openInBrowser() } label: { Label("Ouvrir dans le navigateur", systemImage: "safari") }
                        .help("Ouvrir la page d'origine dans le navigateur")
                    Button { model.closeArticle() } label: { Label("Fermer l'article", systemImage: "xmark") }
                        .help("Fermer l'article")
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
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            if model.phase == .loading {
                Text("Chargement de l'article…").font(.title2.weight(.semibold))
                Text(model.loadingHost).foregroundStyle(.secondary)
                ProgressView(value: model.progress).frame(width: 260)
                Button("Annuler") { model.closeArticle() }
            } else {
                Text("Talk to me Bro").font(.largeTitle.weight(.bold))
                Text("Écoutez vos articles, sans pub ni distraction.")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text("Dans votre navigateur, ouvrez un article puis choisissez **Partager › Lire avec Talk to me Bro**.")
                    } icon: { Image(systemName: "square.and.arrow.up") }
                    Label("Ou glissez un lien dans cette fenêtre.", systemImage: "arrow.down.to.line")
                    Label("Ou copiez un lien, puis ⇧⌘V.", systemImage: "doc.on.clipboard")
                }
                .font(.callout)
                .frame(maxWidth: 420, alignment: .leading)
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

    private var count: Int { model.blockLengths.count }
    private var shown: Int { min(Int((scrub ?? Double(model.position)).rounded()), max(count - 1, 0)) }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Text("\(shown + 1) / \(count)")
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
                        .help("Paragraphe précédent (←)")
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: speech.state == .speaking ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                    }
                    .help("Lire / Pause (espace)")
                    Button { model.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                        .help("Paragraphe suivant (→)")
                }
                .buttonStyle(.plain)

                HStack(spacing: 16) {
                    Menu {
                        Picker("Vitesse", selection: $speech.speed) {
                            ForEach(SpeechController.speeds, id: \.self) { speed in
                                Text(speedLabel(speed)).tag(speed)
                            }
                        }
                        .pickerStyle(.inline)
                        Picker("Pauses entre phrases et paragraphes", selection: $speech.pacing) {
                            ForEach(Pacing.allCases) { pacing in
                                Text(pacing.label).tag(pacing)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(speedLabel(speech.speed)).font(.body.monospacedDigit().weight(.medium))
                    }
                    .help("Vitesse et pauses")

                    Menu {
                        VoiceChoices(speech: speech)
                    } label: {
                        Image(systemName: "person.wave.2")
                    }
                    .help("Voix : \(speech.voiceLabel)")

                    Menu {
                        Button("Agrandir le texte") { model.zoom(by: 1) }
                        Button("Réduire le texte") { model.zoom(by: -1) }
                        Button("Taille normale") { model.resetZoom() }
                    } label: {
                        Image(systemName: "textformat.size")
                    }
                    .help("Taille du texte")
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

/// The voice menu: macOS voices, then Piper voices.
private struct VoiceChoices: View {
    @Bindable var speech: SpeechController
    private var piper = PiperService.shared

    init(speech: SpeechController) {
        self.speech = speech
    }

    var body: some View {
        let voices = AVVoices.installed()
        Picker("Voix", selection: $speech.voiceKey) {
            Text("Voix du système — " + SystemSpeechEngine.systemVoiceDescription).tag(String?.none)
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
        Menu("Autres langues") {
            Picker("Autres langues", selection: $speech.voiceKey) {
                ForEach(voices.others) { voice in
                    Text(voice.label).tag(Optional(voice.key))
                }
            }
            .pickerStyle(.inline)
        }
        Divider()
        SettingsLink { Text("Voix Piper…") }
        Button("Voix macOS (Lire et énoncer)…") {
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
