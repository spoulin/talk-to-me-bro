import SwiftUI

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
                PiperSettings()
            }
            .formStyle(.grouped)
            .tabItem { Label("Voices", systemImage: "person.wave.2") }

            PronunciationSettings()
                .tabItem { Label("Pronunciation", systemImage: "character.bubble") }
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
            Text("The text voice is chosen in the player bar. Changes apply from the next paragraph.")
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

/// Words read differently, e.g. "soccer" → "soqueur", and pauses with [pause].
private struct PronunciationSettings: View {
    @Bindable private var dictionary = Pronunciations.shared
    @State private var selection = Set<UUID>()
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
                        TextField("Word", text: $entry.word, prompt: Text(verbatim: "soccer"))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Read as", text: $entry.replacement, prompt: Text(verbatim: "soqueur"))
                        Button { listen(to: entry) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help("Listen with the current voice")
                            .disabled(entry.word.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                    .tag(entry.id)
                }
                .onDelete { dictionary.entries.remove(atOffsets: $0) }
            }
            .onDeleteCommand(perform: removeSelected)
            .overlay {
                if dictionary.entries.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button { dictionary.entries.append(PronunciationEntry()) } label: { Image(systemName: "plus") }
                    .help("Add a word")
                Button(action: removeSelected) { Image(systemName: "minus") }
                    .help("Remove the selected words")
                    .disabled(selection.isEmpty)
                Spacer()
                Text("Changes apply from the next paragraph.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private func removeSelected() {
        dictionary.entries.removeAll { selection.contains($0.id) }
        selection = []
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
