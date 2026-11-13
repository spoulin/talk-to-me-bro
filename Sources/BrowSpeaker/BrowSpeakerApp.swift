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
        // About Talk to me Bro (just above) shows the version; new versions are GitHub releases.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/spoulin/talk-to-me-bro/releases/latest")!)
            }
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("Listen to Copied Link") { model?.openFromPasteboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Open in Browser") { model?.openInBrowser() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model?.phase != .ready)
            Button("Close Article") { model?.closeArticle() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model?.phase != .ready)
        }

        CommandGroup(after: .toolbar) {
            Button("Bigger Text") { model?.zoom(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model?.zoom(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model?.resetZoom() }
                .keyboardShortcut("0")
            Divider()
        }

        CommandMenu("Playback") {
            Button(model?.speech.state == .speaking ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) {
                model?.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Stop") { model?.speech.stop() }
                .keyboardShortcut(".", modifiers: [.command, .option])
            Divider()
            Button("Previous Paragraph") { model?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Paragraph") { model?.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Next Article") { model?.nextArticle() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model?.playlist.items.isEmpty ?? true)
        }
    }
}
