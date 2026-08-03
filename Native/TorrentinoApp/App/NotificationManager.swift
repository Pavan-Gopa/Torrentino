// Layer: UI (UNUserNotificationCenter alerts).
// Role: delivers system notifications for torrent completion, all completed, and errors.
// Must-not: block UI thread or post duplicate alerts without state change.
// Invariants: requests authorization; respects user notification settings.

import Foundation
import UserNotifications
import TorrentinoIPC

@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var notifyOnTorrentComplete: Bool = true
    var notifyOnAllComplete: Bool = true
    var notifyOnError: Bool = true

    private var previousStates: [TorrentRecordID: TorrentActivity] = [:]
    private var completedTorrents: Set<TorrentRecordID> = []

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func processSnapshots(_ torrents: [TorrentSnapshot]) {
        var allFinished = true
        var hasActive = false

        for torrent in torrents {
            let previous = previousStates[torrent.id]
            previousStates[torrent.id] = torrent.activity

            if torrent.progress.fraction < 1.0 {
                allFinished = false
                hasActive = true
            }

            // Check torrent completion transition
            if (previous == .downloading || previous == .fetchingMetadata),
               (torrent.activity == .seeding || torrent.progress.fraction >= 1.0),
               !completedTorrents.contains(torrent.id) {
                completedTorrents.insert(torrent.id)
                if notifyOnTorrentComplete {
                    postNotification(
                        title: String(localized: "notification.complete.title"),
                        body: String(localized: "notification.complete.body \(torrent.displayName)")
                    )
                }
            }

            // Check error status transition
            if torrent.health != .healthy, previous == .downloading {
                if notifyOnError {
                    postNotification(
                        title: String(localized: "notification.error.title"),
                        body: String(localized: "notification.error.body \(torrent.displayName)")
                    )
                }
            }
        }

        if hasActive && allFinished && notifyOnAllComplete && !torrents.isEmpty {
            postNotification(
                title: String(localized: "notification.all_complete.title"),
                body: String(localized: "notification.all_complete.body")
            )
        }
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
