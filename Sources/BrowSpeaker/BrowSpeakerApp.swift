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
            Button("Ouvrir l'adresse…") { model?.addressFocusRequest += 1 }
                .keyboardShortcut("l")
        }

        CommandGroup(after: .toolbar) {
            Button(model?.isReaderMode == true ? "Quitter le mode lecture" : "Mode lecture") {
                model?.toggleReader()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Recharger la page") { model?.webView.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("Agrandir") { model?.zoom(by: 1) }
                .keyboardShortcut("+")
            Button("Réduire") { model?.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Taille réelle") { model?.resetZoom() }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Historique") {
            Button("Précédent") { model?.webView.goBack() }
                .keyboardShortcut("[")
            Button("Suivant") { model?.webView.goForward() }
                .keyboardShortcut("]")
        }

        CommandMenu("Lecture") {
            Button(model?.speech.state == .speaking ? "Pause" : "Lire à voix haute") {
                model?.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Arrêter") { model?.speech.stop() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button("Paragraphe précédent") { model?.speech.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Paragraphe suivant") { model?.speech.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }
    }
}
