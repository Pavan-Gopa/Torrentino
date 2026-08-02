// Layer: UI application entry (Torrentino.app).
// Role: SwiftUI lifecycle + headless --cli test hook for lifecycle automation.
// Must-not: own engine state, run an in-process engine fallback, or perform
// disk/network IO on the main actor.
// Invariants: the UI is never the source of truth; all engine access goes
// through EngineClient -> Mach XPC; degraded state is shown, never hidden.

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
        WindowGroup("Torrentino — Engine Lifecycle") {
            ContentView()
                .environmentObject(AppContext.shared)
        }
        .defaultSize(width: 760, height: 520)
    }
}

/// Process-wide presentation model. Deliberately MainActor: the single owner
/// of UI state; engine IO lives in the EngineClient actor.
@MainActor
enum AppContext {
    static let shared = EngineViewModel()
}
