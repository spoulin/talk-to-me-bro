import SwiftUI

/// Réglages (⌘,): optional Azure voices with the user's own key.
struct SettingsView: View {
    @State private var key = AzureConfig.key ?? ""
    @State private var region = AzureConfig.region
    @State private var isTesting = false
    private var azure = AzureVoices.shared

    var body: some View {
        Form {
            Section {
                Text("Par défaut, l'app lit avec les voix de macOS : gratuit, sans compte, sans connexion.")
                    .foregroundStyle(.secondary)
            }

            PiperSettings()

            Section("Voix Azure (optionnel)") {
                SecureField("Clé", text: $key, prompt: Text("KEY 1 de la ressource Speech"))
                TextField("Région", text: $region, prompt: Text("canadaeast"))
                HStack {
                    Button(isTesting ? "Test en cours…" : "Enregistrer et tester") {
                        AzureConfig.save(key: key, region: region)
                        isTesting = true
                        Task {
                            await azure.refresh()
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if !key.isEmpty || AzureConfig.isConfigured {
                        Button("Supprimer la clé", role: .destructive) {
                            key = ""
                            AzureConfig.save(key: "", region: region)
                            Task { await azure.refresh() }
                        }
                    }
                }
                if let status = azure.status {
                    Text(status).foregroundStyle(status.hasPrefix("Échec") ? .red : .green)
                }
                Text("La clé est rangée dans le trousseau macOS. Avec une voix Azure, le texte lu est envoyé à Microsoft. Le niveau gratuit F0 offre environ 500 000 caractères par mois.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Créer une ressource Speech dans le portail Azure",
                     destination: URL(string: "https://portal.azure.com/#create/Microsoft.CognitiveServicesSpeechServices")!)
                Link("Écouter les voix Azure",
                     destination: URL(string: "https://speech.microsoft.com/portal/voicegallery")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}

/// Piper: install, then download or remove voices.
private struct PiperSettings: View {
    private var piper = PiperService.shared

    var body: some View {
        Section("Voix Piper (locales, gratuites)") {
            Text("Voix neuronales qui tournent sur ce Mac : gratuites, sans compte, et le texte ne quitte pas l'ordinateur. Nécessite Python 3 ; environ 200 Mo pour Piper, puis 30 à 80 Mo par voix.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !piper.isInstalled {
                Button("Installer Piper") { Task { await piper.install() } }
                    .disabled(piper.busy != nil)
            } else {
                if piper.installedVoices.isEmpty {
                    Text("Aucune voix installée.").foregroundStyle(.secondary)
                }
                ForEach(piper.installedVoices) { voice in
                    HStack {
                        Text(voice.label)
                        Spacer()
                        Button("Supprimer") { piper.remove(voice) }
                    }
                }
                let available = piper.catalog.filter { entry in !piper.installedVoices.contains { $0.id == entry.id } }
                if !available.isEmpty {
                    DisclosureGroup("Voix à télécharger (\(available.count))") {
                        ForEach(available) { voice in
                            HStack {
                                Text(voice.label)
                                Spacer()
                                Text("\(voice.megabytes) Mo").foregroundStyle(.secondary)
                                Button("Télécharger") { Task { await piper.download(voice) } }
                                    .disabled(piper.busy != nil)
                            }
                        }
                    }
                }
                Button("Désinstaller Piper", role: .destructive) { piper.uninstall() }
                    .disabled(piper.busy != nil)
            }

            if let busy = piper.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(busy)
                }
            }
            if let status = piper.status {
                Text(status).foregroundStyle(status.hasPrefix("Échec") ? .red : .green)
            }
        }
        .task { if piper.isInstalled { await piper.loadCatalog() } }
    }
}
