// Layer: UI (UNUserNotificationCenter alerts).
// Role: delivers system notifications for torrent completion, all completed, and errors.
// Must-not: block UI thread or post duplicate alerts without state change.
// Invariants: requests authorization; respects user notification settings.

import Foundation
import UserNotifications
import TorrentinoIPC

enum NotificationTransition: Equatable {
    case torrentCompleted(TorrentRecordID, String)
    case allComplete
    case error(TorrentRecordID, String)
}

/// Pure transition state so completion/error behavior can be tested without
/// asking the system notification center for permission.
struct NotificationTransitionTracker {
    private(set) var previousStates: [TorrentRecordID: TorrentActivity] = [:]
    private(set) var completedTorrents: Set<TorrentRecordID> = []
    private var previousCompletion: [TorrentRecordID: Bool] = [:]
    private var previousHealth: [TorrentRecordID: TorrentHealth] = [:]
    private var hasSeenActiveTorrents = false

    mutating func processSnapshots(_ torrents: [TorrentSnapshot]) -> [NotificationTransition] {
        var transitions: [NotificationTransition] = []

        for torrent in torrents {
            let hadPreviousState = previousStates[torrent.id] != nil
            let previousWasComplete = previousCompletion[torrent.id] ?? false
            let isComplete = torrent.progress.fraction >= 1.0 || torrent.activity == .seeding
            previousStates[torrent.id] = torrent.activity
            previousCompletion[torrent.id] = isComplete

            if hadPreviousState,
               !previousWasComplete,
               isComplete,
               !completedTorrents.contains(torrent.id) {
                completedTorrents.insert(torrent.id)
                transitions.append(.torrentCompleted(torrent.id, torrent.displayName))
            }

            if let previousHealth = previousHealth[torrent.id],
               previousHealth == .healthy,
               torrent.health != .healthy {
                transitions.append(.error(torrent.id, torrent.displayName))
            }
            previousHealth[torrent.id] = torrent.health
        }

        let hasActiveNow = torrents.contains { $0.progress.fraction < 1.0 }
        let allFinishedNow = !torrents.isEmpty && !hasActiveNow
        if hasActiveNow {
            hasSeenActiveTorrents = true
        } else if hasSeenActiveTorrents && allFinishedNow {
            transitions.append(.allComplete)
            hasSeenActiveTorrents = false
        } else if torrents.isEmpty {
            hasSeenActiveTorrents = false
        }

        return transitions
    }
}

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var notifyOnTorrentComplete: Bool = true
    var notifyOnAllComplete: Bool = true
    var notifyOnError: Bool = true

    private var transitionTracker = NotificationTransitionTracker()

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func processSnapshots(_ torrents: [TorrentSnapshot]) {
        for transition in transitionTracker.processSnapshots(torrents) {
            switch transition {
            case .torrentCompleted(_, let name):
                if notifyOnTorrentComplete {
                    postNotification(
                        title: String(localized: "notification.complete.title"),
                        body: localizedTorrentBody(key: "notification.complete.body", name: name)
                    )
                }
            case .error(_, let name):
                if notifyOnError {
                    postNotification(
                        title: String(localized: "notification.error.title"),
                        body: localizedTorrentBody(key: "notification.error.body", name: name)
                    )
                }
            case .allComplete:
                if notifyOnAllComplete {
                    postNotification(
                        title: String(localized: "notification.all_complete.title"),
                        body: String(localized: "notification.all_complete.body")
                    )
                }
            }
        }
    }

    private func localizedTorrentBody(key: String, name: String) -> String {
        String(localized: String.LocalizationValue(key)).replacingOccurrences(of: "%{torrent}", with: name)
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
