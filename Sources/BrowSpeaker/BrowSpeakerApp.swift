import SwiftUI

@main
struct BrowSpeakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands { BrowserCommands() }

        Settings {
            SettingsView()
        }
    }
}

struct BrowserFocusedKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browser: BrowserModel? {
        get { self[BrowserFocusedKey.self] }
        set { self[BrowserFocusedKey.self] = newValue }
    }
}

struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var model

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Écouter le lien copié") { model?.openFromPasteboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Ouvrir dans le navigateur") { model?.openInBrowser() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model?.phase != .ready)
            Button("Fermer l'article") { model?.closeArticle() }
                .disabled(model?.phase != .ready)
        }

        CommandGroup(after: .toolbar) {
            Button("Agrandir le texte") { model?.zoom(by: 1) }
                .keyboardShortcut("+")
            Button("Réduire le texte") { model?.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Taille normale") { model?.resetZoom() }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Lecture") {
            Button(model?.speech.state == .speaking ? "Pause" : "Lire") {
                model?.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Arrêter") { model?.speech.stop() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button("Paragraphe précédent") { model?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Paragraphe suivant") { model?.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
    }
}
