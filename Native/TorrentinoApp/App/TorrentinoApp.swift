// Layer: UI application entry (Torrentino.app).
// Role: SwiftUI lifecycle, native menus, Settings shell, headless --cli hook.
// Must-not: own engine state, run an in-process engine fallback, or perform disk/network IO on the main actor.
// Invariants: UI is never source of truth; commands pass through EngineClient; degraded state is shown.

import AppKit
import SwiftUI

@MainActor
@main
struct TorrentinoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateMenuAction: UpdateMenuAction

    init() {
        self.updateMenuAction = UpdateMenuAction(checker: SparkleUpdateChecker())
        CLIDispatcher.runIfRequestedAndExit()
    }

    init(updateChecker: any UpdateChecking) {
        self.updateMenuAction = UpdateMenuAction(checker: updateChecker)
        CLIDispatcher.runIfRequestedAndExit()
    }

    var body: some Scene {
        Window("Torrentino", id: "main") {
            ContentView()
                .environmentObject(AppContext.shared)
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

                Divider()

                Button(String(localized: "menu.file.create_torrent")) {
                    AppContext.transfers.showCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .option])

                Divider()

                Button(String(localized: "app.check_updates")) {
                    updateMenuAction.perform()
                }
                .keyboardShortcut("u", modifiers: .command)
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

}

@MainActor
enum AppContext {
    static let engineClient = EngineClient()
    static let shared = EngineViewModel(client: engineClient)
    static let transfers = TorrentListViewModel(client: engineClient)
}
enum AppLogo {
    /// Brand mark from the app's asset catalog. A fresh instance per call, because
    /// callers (status item) set `size` on the returned image.
    static var image: NSImage {
        guard let logo = NSImage(named: "AppLogo") else {
            return NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return logo.copy() as? NSImage ?? logo
    }
}
