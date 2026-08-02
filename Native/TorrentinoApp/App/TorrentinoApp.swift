// Layer: UI application entry (Torrentino.app).
// Role: SwiftUI lifecycle, menus, Settings shell, headless --cli hook.
// Must-not: own engine state, run an in-process engine fallback, or perform
// disk/network IO on the main actor.
// Invariants: the UI is never the source of truth; all engine access goes
// through EngineClient -> Mach XPC; degraded state is shown, never hidden.

import AppKit
import SwiftUI

@main
struct TorrentinoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless automation hook: lifecycle_test.sh / update_test.sh drive
        // the real XPC + SMAppService flows without a GUI. Returns (exit()s)
        // only when --cli is present; GUI launch is unaffected.
        CLIDispatcher.runIfRequestedAndExit()
    }

    var body: some Scene {
        WindowGroup {
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
                    // Placeholder Help — no external network in WP-03.
                }
            }
            CommandMenu(String(localized: "menu.file")) {
                Button(String(localized: "menu.file.placeholder")) {
                    // Placeholder until add-torrent UX lands in a later WP.
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// Brings the Settings scene forward. SwiftUI Settings is registered above;
    /// this bridges the ⌘, menu item to the same window.
    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if NSApp.responds(to: Selector(("showPreferencesWindow:"))) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

/// Process-wide presentation model. Deliberately MainActor: the single owner
/// of UI state; engine IO lives in the EngineClient actor.
@MainActor
enum AppContext {
    static let shared = EngineViewModel()
}
