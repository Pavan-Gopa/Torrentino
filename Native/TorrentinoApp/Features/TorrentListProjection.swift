// Layer: UI list projection.
// Role: pure filtering and sorting shared by the production table and tests.

import Foundation
import TorrentinoIPC

/// Stable filter vocabulary shared by the table projection and its
/// performance tests. It contains no UI state or engine mutation.
enum TorrentListFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case downloading
    case seeding
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "torrents.filter.all")
        case .downloading: return String(localized: "torrents.filter.downloading")
        case .seeding: return String(localized: "torrents.filter.seeding")
        case .paused: return String(localized: "torrents.filter.paused")
        }
    }

    var icon: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .paused: return "pause.circle"
        }
    }

    func matches(_ torrent: TorrentSnapshot) -> Bool {
        switch self {
        case .all: return true
        case .downloading:
            return torrent.desiredState != .paused
                && [.downloading, .fetchingMetadata, .checking, .queued].contains(torrent.activity)
        case .seeding: return torrent.activity == .seeding
        case .paused: return torrent.desiredState == .paused
        }
    }
}

/// The production table projection path is kept pure so 100-500 row behavior
/// can be measured without constructing a second fake view or touching XPC.
enum TorrentListProjection {
    static func project(
        _ torrents: [TorrentSnapshot],
        query: String = "",
        filter: TorrentListFilter = .all,
        sortOrder: [KeyPathComparator<TorrentSnapshot>] = [KeyPathComparator(\.displayName)]
    ) -> [TorrentSnapshot] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = torrents.filter { torrent in
            filter.matches(torrent)
                && (normalizedQuery.isEmpty || torrent.displayName.localizedCaseInsensitiveContains(normalizedQuery))
        }
        result.sort(using: sortOrder)
        return result
    }
}
