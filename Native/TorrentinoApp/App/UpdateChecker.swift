import AppKit
import Foundation
import Sparkle

@MainActor
protocol UpdateChecking: AnyObject {
    func checkForUpdates()
}

/// Keeps the menu action independently testable without constructing Sparkle or
/// allowing a test to make a network request.
@MainActor
struct UpdateMenuAction {
    private let checker: any UpdateChecking

    init(checker: any UpdateChecking) {
        self.checker = checker
    }

    func perform() {
        checker.checkForUpdates()
    }
}

/// Manual-only Sparkle integration for the app's Check for Updates command.
///
/// Sparkle's standard controller owns its normal progress and update dialogs.
/// The controller is created lazily so a placeholder feed never initializes an
/// updater or touches the network; the placeholder path presents a local,
/// actionable alert instead. A real unreachable feed is handled by Sparkle's
/// standard user driver without crashing the app.
@MainActor
final class SparkleUpdateChecker: NSObject, UpdateChecking, SPUUpdaterDelegate {
    static let automaticallyChecksForUpdates = false
    static let automaticallyDownloadsUpdates = false
    static let sendsSystemProfile = false

    static func applyManualOnlyConfiguration(to updater: SPUUpdater) {
        updater.automaticallyChecksForUpdates = Self.automaticallyChecksForUpdates
        updater.automaticallyDownloadsUpdates = Self.automaticallyDownloadsUpdates
        updater.sendsSystemProfile = Self.sendsSystemProfile
    }

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )
    private var updaterStarted = false

    func checkForUpdates() {
        guard !UpdateFeed.isPlaceholder, UpdateFeed.isValidHTTPSGitHubURL else {
            presentUnavailableAlert()
            return
        }

        let controller = updaterController
        Self.applyManualOnlyConfiguration(to: controller.updater)

        if !updaterStarted {
            controller.startUpdater()
            updaterStarted = true
        }

        guard controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// Sparkle asks its updater delegate for the appcast URL. Keeping this
    /// callback as the only consumer of UpdateFeed prevents URL drift between
    /// Info.plist and runtime configuration.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateFeed.appcastURL?.absoluteString
    }

    private func presentUnavailableAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "updates.unavailable.title")
        alert.informativeText = String(localized: "updates.unavailable.message")
        alert.addButton(withTitle: String(localized: "updates.unavailable.ok"))
        alert.runModal()
    }
}
