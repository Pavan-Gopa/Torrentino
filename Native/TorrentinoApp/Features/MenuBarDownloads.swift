// Layer: UI model (WP-27 status-item downloads).
// Role: pure in-memory rules for the status-item menu: which rows show, which
// finished downloads raise the green dot, and when that dot clears.
// Must-not: touch AppKit, the engine, IPC, or disk; persist attention or pauses
// across launches.
// Invariants: rows are never capped; a pause shows only for a torrent this run
// saw active; green clears only in menuWillOpen(); a finished row shows once.

import Foundation
import TorrentinoIPC

struct MenuBarDownloads {
    enum Badge: Equatable {
        case clear
        /// A running download is in progress.
        case downloading
        /// An unacknowledged completion. Wins over `downloading`.
        case finished
    }

    struct Row: Equatable {
        enum Kind: Equatable {
            case finished
            case active
            case paused
        }

        enum Caption: Equatable {
            case finished
            case percent(Int)
            /// The activity's `torrents.status.*` text.
            case status
            case paused
            case pausedPercent(Int)
        }

        let id: TorrentRecordID
        let kind: Kind
        let snapshot: TorrentSnapshot

        /// Bar position in 0...1. A finished row is always full.
        var fraction: Double {
            kind == .finished ? 1 : MenuBarDownloads.clamped(snapshot.progress.fraction)
        }

        var caption: Caption {
            switch kind {
            case .finished:
                return .finished
            case .active:
                let showsPercent = snapshot.activity == .downloading && snapshot.progress.totalBytes > 0
                return showsPercent ? .percent(wholePercent) : .status
            case .paused:
                let hasKnownBytes = snapshot.progress.totalBytes > 0 && snapshot.progress.downloadedBytes > 0
                return hasKnownBytes ? .pausedPercent(wholePercent) : .paused
            }
        }

        private var wholePercent: Int {
            Int(fraction * 100)
        }
    }

    private(set) var isMenuOpen = false
    private var latest: [TorrentRecordID: TorrentSnapshot] = [:]
    /// Ids this run saw in the Downloads filter. Only these can show as paused.
    private var seenActive: Set<TorrentRecordID> = []
    /// Ids this run saw downloading, fetching metadata, or queued below 100%.
    /// Only these can finish green, so a relaunch never reads as a finish.
    private var witnessed: Set<TorrentRecordID> = []
    private var tracker = NotificationTransitionTracker()
    /// Completions the menu has not acknowledged, each with its snapshot at completion.
    private var unacknowledged: [TorrentRecordID: TorrentSnapshot] = [:]
    /// Finished rows of the open menu. Empty while the menu is closed.
    private var shownFinished: [TorrentRecordID: TorrentSnapshot] = [:]

    var badge: Badge {
        if !unacknowledged.isEmpty { return .finished }
        let isRunning = latest.values.contains { Self.isActive($0) && $0.desiredState == .running }
        return isRunning ? .downloading : .clear
    }

    mutating func apply(_ torrents: [TorrentSnapshot]) {
        let completed = tracker.processSnapshots(torrents).compactMap { transition -> TorrentRecordID? in
            guard case .torrentCompleted(let id, _) = transition else { return nil }
            return id
        }
        // An empty emission is an engine gap, not a removal: only this-run pauses outlive it, so the
        // «На паузе» row stays. A later non-empty snapshot that omits an id is its removal.
        if torrents.isEmpty {
            latest = latest.filter { isPausedRow($0.value) }
        } else {
            latest = Dictionary(torrents.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            seenActive.formIntersection(latest.keys)
        }
        for torrent in torrents {
            if Self.isFinished(torrent) {
                seenActive.remove(torrent.id)
            } else if Self.isActive(torrent) {
                seenActive.insert(torrent.id)
            }
            if Self.isWitness(torrent) {
                witnessed.insert(torrent.id)
            }
        }
        for id in completed where witnessed.contains(id) {
            guard let snapshot = latest[id] else { continue }
            if isMenuOpen {
                shownFinished[id] = snapshot
            } else {
                unacknowledged[id] = snapshot
            }
        }
    }

    /// Acknowledges every completion, freezes the rows it shows, and clears green.
    /// Returns the row ids in display order: finished, then active, then paused.
    mutating func menuWillOpen() -> [TorrentRecordID] {
        isMenuOpen = true
        shownFinished = unacknowledged
        unacknowledged.removeAll()
        let finished = shownFinished.values.sorted(by: Self.isBefore)
        let active = latest.values
            .filter { Self.isActive($0) && shownFinished[$0.id] == nil }
            .sorted(by: Self.isBefore)
        let paused = latest.values
            .filter { isPausedRow($0) && shownFinished[$0.id] == nil }
            .sorted(by: Self.isBefore)
        return (finished + active + paused).map(\.id)
    }

    mutating func menuDidClose() {
        isMenuOpen = false
        shownFinished.removeAll()
    }

    /// The current row for an id. nil means it can no longer show, and the open menu disables it in place.
    func row(for id: TorrentRecordID) -> Row? {
        if let captured = shownFinished[id] {
            return Row(id: id, kind: .finished, snapshot: captured)
        }
        guard let torrent = latest[id] else { return nil }
        if Self.isActive(torrent) {
            return Row(id: id, kind: .active, snapshot: torrent)
        }
        if isPausedRow(torrent) {
            return Row(id: id, kind: .paused, snapshot: torrent)
        }
        return nil
    }

    private func isPausedRow(_ torrent: TorrentSnapshot) -> Bool {
        torrent.desiredState == .paused
            && seenActive.contains(torrent.id)
            && !Self.isFinished(torrent)
            && torrent.activity != .removing
            && torrent.activity != .moving
    }

    /// Exactly the Downloads table's filter, so the menu and the table agree.
    private static func isActive(_ torrent: TorrentSnapshot) -> Bool {
        TorrentListFilter.downloading.matches(torrent)
    }

    private static func isFinished(_ torrent: TorrentSnapshot) -> Bool {
        torrent.activity == .seeding || torrent.progress.fraction >= 1
    }

    private static func isWitness(_ torrent: TorrentSnapshot) -> Bool {
        torrent.progress.fraction < 1
            && [TorrentActivity.downloading, .fetchingMetadata, .queued].contains(torrent.activity)
    }

    private static func isBefore(_ lhs: TorrentSnapshot, _ rhs: TorrentSnapshot) -> Bool {
        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    /// NaN is 0; everything else is clamped to 0...1.
    static func clamped(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}
