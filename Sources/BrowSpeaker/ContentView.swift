import SwiftUI
import WebKit

struct ContentView: View {
    @State private var model = BrowserModel()
    @FocusState private var addressFocused: Bool

    var body: some View {
        @Bindable var model = model
        BrowserSurface(model: model, isReaderMode: model.isReaderMode)
            .overlay(alignment: .top) {
                if model.isLoading && !model.isReaderMode {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            .overlay(alignment: .bottom) {
                if let message = model.errorMessage {
                    Text(message)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 18)
                        .onTapGesture { model.errorMessage = nil }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { model.webView.goBack() } label: { Label("Précédent", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack)
                    Button { model.webView.goForward() } label: { Label("Suivant", systemImage: "chevron.right") }
                        .disabled(!model.canGoForward)
                }
                ToolbarItem(placement: .principal) {
                    TextField("Rechercher ou saisir une adresse", text: $model.addressText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280, idealWidth: 560, maxWidth: 720)
                        .focused($addressFocused)
                        .onSubmit {
                            model.submitAddress()
                            addressFocused = false
                        }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { model.toggleReader() } label: {
                        Label("Mode lecture", systemImage: model.isReaderMode ? "doc.plaintext.fill" : "doc.plaintext")
                    }
                    .help("Mode lecture (⇧⌘R)")
                    .disabled(model.isExtracting)

                    SpeechControls(model: model, speech: model.speech)
                }
            }
            .navigationTitle(model.title.isEmpty ? "Talk to me Bro" : model.title)
            .focusedSceneValue(\.browser, model)
            .onChange(of: model.addressFocusRequest) { addressFocused = true }
            .onDisappear { model.speech.stop() }
            .onOpenURL { model.handleOpenURL($0) }
            .task { await AzureVoices.shared.loadIfNeeded() }
            // Shared links go to an existing window instead of opening a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .frame(minWidth: 760, minHeight: 500)
    }
}

private struct SpeechControls: View {
    let model: BrowserModel
    @Bindable var speech: SpeechController

    var body: some View {
        Button { speech.previous() } label: { Label("Paragraphe précédent", systemImage: "backward.fill") }
            .disabled(speech.state == .idle)
        Button { model.togglePlayPause() } label: {
            Label(speech.state == .speaking ? "Pause" : "Lire à voix haute",
                  systemImage: speech.state == .speaking ? "pause.fill" : "play.fill")
        }
        .help("Lire à voix haute / Pause (⌥⌘P)")
        Button { speech.next() } label: { Label("Paragraphe suivant", systemImage: "forward.fill") }
            .disabled(speech.state == .idle)
        Button { speech.stop() } label: { Label("Arrêter", systemImage: "stop.fill") }
            .disabled(speech.state == .idle)

        Menu {
            Picker("Vitesse", selection: $speech.speed) {
                ForEach(SpeechController.speeds, id: \.self) { speed in
                    Text(speed.formatted(.number.precision(.fractionLength(0...2))) + " ×").tag(speed)
                }
            }
            .pickerStyle(.inline)
            Divider()
            VoicePicker(speech: speech)
            Button("Gérer les voix (Lire et énoncer)…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
            }
            Divider()
            Button("Agrandir le texte") { model.zoom(by: 1) }
            Button("Réduire le texte") { model.zoom(by: -1) }
        } label: {
            Label("Options de lecture", systemImage: "textformat.size")
        }
    }
}

private struct VoicePicker: View {
    @Bindable var speech: SpeechController
    private var azure = AzureVoices.shared
    private var piper = PiperService.shared

    init(speech: SpeechController) {
        self.speech = speech
    }

    var body: some View {
        let voices = AVVoices.installed()
        Menu("Voix : " + speech.voiceLabel) {
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
                if !azure.voices.isEmpty {
                    Divider()
                    ForEach(azure.voices) { voice in
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
            SettingsLink { Text("Autres voix (Piper, Azure)…") }
        }
    }
}

/// Hosts both web views and shows one or the other, so neither is recreated
/// when toggling reader mode.
private struct BrowserSurface: NSViewRepresentable {
    let model: BrowserModel
    let isReaderMode: Bool

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
        guard model.readerView.isHidden == isReaderMode else { return }
        model.readerView.isHidden = !isReaderMode
        model.webView.isHidden = isReaderMode
        container.window?.makeFirstResponder(isReaderMode ? model.readerView : model.webView)
    }
}
