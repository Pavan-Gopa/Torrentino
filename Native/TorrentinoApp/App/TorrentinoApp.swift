// Layer: UI application entry (Torrentino.app).
// Role: SwiftUI lifecycle, native menus, Settings shell, headless --cli hook.
// Must-not: own engine state, run an in-process engine fallback, or perform disk/network IO on the main actor.
// Invariants: UI is never source of truth; commands pass through EngineClient; degraded state is shown.

import AppKit
import SwiftUI

@main
struct TorrentinoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        CLIDispatcher.runIfRequestedAndExit()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(AppContext.shared)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .defaultSize(width: 900, height: 560)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "app.about")) {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button(String(localized: "app.settings")) {
                    openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(String(localized: "menu.help")) {
                    // Help documentation
                }
            }
            CommandMenu(String(localized: "menu.file")) {
                Button(String(localized: "menu.file.add_torrent")) {
                    AppContext.transfers.showAddSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(String(localized: "menu.file.add_url")) {
                    AppContext.transfers.showAddSheet = true
                }
                 .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu(String(localized: "menu.edit")) {
                Button(String(localized: "menu.edit.find")) {
                    AppContext.transfers.focusSearch()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu(String(localized: "menu.torrent")) {
                Button(String(localized: "torrents.action.pause")) {
                    AppContext.transfers.pauseSelected()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!AppContext.transfers.canPauseSelected)

                Button(String(localized: "torrents.action.resume")) {
                    AppContext.transfers.resumeSelected()
                }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(!AppContext.transfers.canResumeSelected)

                Button(String(localized: "torrents.action.remove")) {
                    AppContext.transfers.removeSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(AppContext.transfers.selection.isEmpty)

                Divider()

                Button(String(localized: "menu.torrent.reveal")) {
                    AppContext.transfers.revealSelected()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(AppContext.transfers.selectedTorrent == nil)

                Button(String(localized: "menu.torrent.inspector")) {
                    AppContext.transfers.toggleInspector()
                }
                 .keyboardShortcut("i", modifiers: .command)
            }
            CommandMenu(String(localized: "menu.view")) {
                Button(String(localized: "menu.view.toggle_inspector")) {
                    AppContext.transfers.toggleInspector()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if NSApp.responds(to: Selector(("showPreferencesWindow:"))) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "magnet" {
            Task { @MainActor in
                await AppContext.transfers.addMagnet(url.absoluteString, startPaused: false)
            }
        } else if url.isFileURL && url.pathExtension.lowercased() == "torrent" {
            Task { @MainActor in
                await AppContext.transfers.addTorrentFile(url, startPaused: false)
            }
        }
    }
}

@MainActor
enum AppContext {
    static let engineClient = EngineClient()
    static let shared = EngineViewModel(client: engineClient)
    static let transfers = TorrentListViewModel(client: engineClient)
}
