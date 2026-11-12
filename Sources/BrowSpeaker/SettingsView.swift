import SwiftUI
import UniformTypeIdentifiers

/// Settings (⌘,): optional Piper voices, and the pronunciation dictionary.
struct SettingsView: View {
    var body: some View {
        TabView {
            Form {
                Section {
                    Text("By default, the app reads with macOS voices: free, no account, no connection.")
                        .foregroundStyle(.secondary)
                }

                VoiceRolesSettings()
                VoiceEffectSettings()
                PiperSettings()
            }
            .formStyle(.grouped)
            .tabItem { Label("Voices", systemImage: "person.wave.2") }

            PronunciationSettings()
                .tabItem { Label("Pronunciation", systemImage: "character.bubble") }

            SourcesSettings()
                .tabItem { Label("Sources", systemImage: "dot.radiowaves.up.forward") }

            SlideshowSettings()
                .tabItem { Label("Slideshow", systemImage: "play.rectangle.on.rectangle") }

            VideoSettings()
                .tabItem { Label("Videos", systemImage: "film") }
        }
        .frame(width: 580, height: 540)
    }
}

/// A different voice for titles, captions and quotes, so they stand out from the story.
private struct VoiceRolesSettings: View {
    @Bindable private var roles = VoiceRoles.shared
    private var piper = PiperService.shared

    var body: some View {
        Section {
            picker("Titles", selection: $roles.title)
            picker("Photo captions", selection: $roles.caption)
            picker("Quotes", selection: $roles.quote)
            Toggle("Announce captions (“Caption: …”)", isOn: $roles.announceCaptions)
        } header: {
            Text("Voices by type")
        } footer: {
            Text("The text voice is chosen in the toolbar. Changes apply from the next paragraph.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func picker(_ title: LocalizedStringKey, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("Same as text").tag(String?.none)
            Divider()
            ForEach(AVVoices.installed().main) { voice in
                Text(voice.label).tag(Optional(voice.key))
            }
            if !piper.voices.isEmpty {
                Divider()
                ForEach(piper.voices) { voice in
                    Text(voice.label).tag(Optional(voice.key))
                }
            }
        }
    }
}

/// An effect that gives the voice more body: warmth, a room, an echo…
private struct VoiceEffectSettings: View {
    @Bindable private var effects = VoiceEffects.shared

    var body: some View {
        Section {
            Picker("Effect", selection: $effects.effect) {
                ForEach(VoiceEffect.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Amount") {
                Slider(value: $effects.amount, in: 0...1)
            }
            .disabled(effects.effect == .none)
        } header: {
            Text("Voice effect")
        } footer: {
            Text("Gives the voice more body. Piper voices only; changes are heard right away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The home page's slideshow: how long each article stays, and how it gives way to the next.
private struct SlideshowSettings: View {
    @AppStorage("slideshowSeconds") private var seconds = 10
    @AppStorage("slideshowTransition") private var transition = Slideshow.Transition.fade
    @AppStorage("slideshowKenBurns") private var kenBurns = false
    @AppStorage("slideshowTitleAfter") private var titleAfter = false

    var body: some View {
        Form {
            Section {
                Picker("Time per article", selection: $seconds) {
                    ForEach(Slideshow.durations, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Transition", selection: $transition) {
                    ForEach(Slideshow.Transition.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Random takes another transition for each article.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Slow zoom on the pictures (Ken Burns effect)", isOn: $kenBurns)
                Toggle("Show the title just after the picture", isOn: $titleAfter)
            }
        }
        .formStyle(.grouped)
    }
}

/// Music during ads, on video pages: a radio, a stream, a file or a folder, with its volume and fades.
private struct VideoSettings: View {
    @Bindable private var music = AdMusic.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Source", text: $music.source, prompt: Text(verbatim: "https://somafm.com/illstreet.pls"))
                    Button("Choose…", action: choose)
                    Button("Listen") { music.preview() }
                        .disabled(!music.hasSource)
                }
                if let problem = music.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Volume of the music") {
                    Slider(value: $music.volume, in: 0...1)
                }
                Picker("Fades (music, and the video coming back)", selection: $music.fadeSeconds) {
                    Text("No fade").tag(0.0)
                    ForEach([0.5, 1, 2, 3], id: \.self) { Text(verbatim: "\($0.formatted()) s").tag($0) }
                }
            } header: {
                Text("Music during ads")
            } footer: {
                Text("While a video page plays an ad without sound, this plays instead: a radio (a .pls or .m3u link, or its stream address), an audio file or a folder of music. Leave it empty for silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .folder]
        panel.message = String(localized: "An audio file, or a folder of music")
        if panel.runModal() == .OK, let url = panel.url { music.source = url.path(percentEncoded: false) }
    }
}

/// Sites and RSS feeds whose latest articles are listed on the home screen.
private struct SourcesSettings: View {
    @Bindable private var feeds = Feeds.shared
    @State private var address = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste the address of a site (e.g. example.com/news) or of an RSS feed. For a site, the app looks for its feed, or else takes the article links from the page.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Site or RSS feed address", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || feeds.isAdding)
                if feeds.isAdding { ProgressView().controlSize(.small) }
            }
            if let error = feeds.addError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            List {
                ForEach(feeds.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(source.mode == .feed ? LocalizedStringKey("RSS feed")
                                                          : LocalizedStringKey("Links from the page (approximate)"))
                                Text(verbatim: "· \(source.url.host() ?? "")")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let error = source.lastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Button { feeds.remove(source) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if feeds.sources.isEmpty {
                    Text("No sources yet.").foregroundStyle(.secondary)
                }
            }

            Picker("Refresh sources", selection: $feeds.refreshMinutes) {
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
                Text("Every hour").tag(60)
                Text("Every 2 hours").tag(120)
                Text("At launch only").tag(0)
            }
            .fixedSize()
        }
        .padding()
    }

    private func add() {
        let text = address
        Task {
            await feeds.add(text)
            if feeds.addError == nil { address = "" }
        }
    }
}

/// Words read differently, e.g. "soccer" → "soqueur", and pauses with [pause].
private struct PronunciationSettings: View {
    @Bindable private var dictionary = Pronunciations.shared
    @State private var selection = Set<UUID>()
    /// The row being edited: clicking in a text field doesn't select its row.
    @FocusState private var focused: UUID?
    @State private var lastFocused: UUID?
    /// Plays a word through the dictionary with the current voice.
    @State private var preview: SpeechController?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words to read differently. Write them as they should sound; add [pause] or [pause 1.5] (seconds) for a silence. “…” already makes a pause.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach($dictionary.entries) { $entry in
                    HStack {
                        TextField("Original text", text: $entry.word, prompt: Text("Original text"))
                            .focused($focused, equals: entry.id)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Phonetic spelling", text: $entry.replacement, prompt: Text("Phonetic spelling"))
                            .focused($focused, equals: entry.id)
                        Button { listen(to: entry) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help("Listen with the current voice")
                            .disabled(entry.word.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button { remove([entry.id]) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                    }
                    .textFieldStyle(.roundedBorder)
                    .tag(entry.id)
                }
                .onDelete { dictionary.entries.remove(atOffsets: $0) }
            }
            .onDeleteCommand(perform: removeSelected)
            .onChange(of: focused) { if let focused { lastFocused = focused } }
            .overlay {
                if dictionary.entries.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(action: add) { Image(systemName: "plus") }
                    .help("Add a word")
                Button(action: removeSelected) { Image(systemName: "minus") }
                    .help("Remove the selected words")
                    .disabled(selection.isEmpty && lastFocused == nil)
                Spacer()
                Text("Changes apply from the next paragraph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func add() {
        let entry = PronunciationEntry()
        dictionary.entries.append(entry)
        focused = entry.id
    }

    /// The selected rows, or else the row being edited.
    private func removeSelected() {
        remove(selection.isEmpty ? Set([lastFocused].compactMap { $0 }) : selection)
    }

    private func remove(_ ids: Set<UUID>) {
        dictionary.entries.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        if let lastFocused, ids.contains(lastFocused) { self.lastFocused = nil }
    }

    /// Reads the word itself, so what you hear is the dictionary rule at work.
    private func listen(to entry: PronunciationEntry) {
        preview?.stop()
        let controller = SpeechController()
        preview = controller
        controller.speak([entry.word], from: 0)
    }
}

/// Piper: install, then download or remove voices.
private struct PiperSettings: View {
    private var piper = PiperService.shared

    var body: some View {
        Section("Piper Voices (local, free)") {
            Text("Neural voices that run on this Mac: free, no account, and the text never leaves the computer. Requires Python 3; about 200 MB for Piper, then 30 to 80 MB per voice.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !piper.isInstalled {
                Button("Install Piper") { Task { await piper.install() } }
                    .disabled(piper.busy != nil)
            } else {
                if piper.installedVoices.isEmpty {
                    Text("No voice installed.").foregroundStyle(.secondary)
                }
                ForEach(piper.installedVoices) { voice in
                    HStack {
                        Text(voice.label)
                        Spacer()
                        Button("Remove") { piper.remove(voice) }
                    }
                }
                let available = piper.catalog.filter { entry in !piper.installedVoices.contains { $0.id == entry.id } }
                if !available.isEmpty {
                    DisclosureGroup("Voices to download (\(available.count))") {
                        ForEach(available) { voice in
                            HStack {
                                Text(voice.label)
                                Spacer()
                                Text("\(voice.megabytes) MB").foregroundStyle(.secondary)
                                Button("Download") { Task { await piper.download(voice) } }
                                    .disabled(piper.busy != nil)
                            }
                        }
                    }
                }
                Button("Uninstall Piper", role: .destructive) { piper.uninstall() }
                    .disabled(piper.busy != nil)
            }

            if let busy = piper.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(busy)
                }
            }
            if let status = piper.status {
                Text(status).foregroundStyle(piper.statusIsError ? .red : .green)
            }
        }
        .task { if piper.isInstalled { await piper.loadCatalog() } }
    }
}
