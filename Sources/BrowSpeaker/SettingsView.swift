import SwiftUI

/// Réglages (⌘,): optional Piper voices.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                Text("By default, the app reads with macOS voices: free, no account, no connection.")
                    .foregroundStyle(.secondary)
            }

            PiperSettings()
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 520)
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
