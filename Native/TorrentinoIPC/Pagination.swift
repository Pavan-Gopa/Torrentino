// Layer: IPC (pagination, plan §7.4 bounded reads).
// Role: opaque cursor tokens + bounded pages for file tree / peers / trackers
// / activity / manifests. The full file tree of a torrent with tens of
// thousands of files must never ride a single XPC payload.
// Must-not: let a requested page size exceed PageSize.maximum.
// Invariants: cursors are opaque Data (server-side interpretation only);
// Page<T> items are immutable; nextCursor == nil means "last page".

import Foundation

/// Bounding policy for every paginated read (plan §7.4).
public enum PageSize {
    /// Hard cap: a single page never exceeds this many rows.
    public static let maximum = 200

    /// Clamps any requested page size into 1...maximum.
    public static func bounded(_ requested: Int) -> Int {
        min(max(requested, 1), maximum)
    }
}

/// Opaque pagination token. The agent owns the encoding; the UI treats it as
/// an opaque round-trip value (zero-copy replay in fetch* commands).
public struct PageCursor: Codable, Sendable, Equatable, Hashable {
    public let token: Data

    public init(token: Data) {
        self.token = token
    }
}

/// Hierarchical file paging: directoryStack names the folder being drilled
/// into (e.g. ["TV", "Season 1"]), token continues the flat page inside it.
public struct FileCursor: Codable, Sendable, Equatable, Hashable {
    public let directoryStack: [String]
    public let token: PageCursor?

    public init(directoryStack: [String] = [], token: PageCursor? = nil) {
        self.directoryStack = directoryStack
        self.token = token
    }
}

/// One page of any paginated read. revision lets the UI discard stale pages
/// after a torrent revision bump.
public struct Page<T: Codable & Sendable>: Codable, Sendable, Equatable where T: Equatable {
    public let items: [T]
    public let nextCursor: PageCursor?
    public let totalCount: Int
    public let revision: UInt64

    public init(items: [T], nextCursor: PageCursor?, totalCount: Int, revision: UInt64) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
        self.revision = revision
    }
}

public enum FileKind: String, Codable, Sendable, Equatable, CaseIterable {
    case file
    case directory
}

/// One row of a file tree page (hierarchical paging, plan §7.4).
public struct FileEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let name: String
    public let sizeBytes: Int64
    public let kind: FileKind
    public let selection: FileSelectionPriority

    public init(relativePath: String, name: String, sizeBytes: Int64, kind: FileKind, selection: FileSelectionPriority) {
        self.relativePath = relativePath
        self.name = name
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.selection = selection
    }
}

/// One row of a peers page. Identified by the opaque peerID token, not by an
/// index, because peer sets churn continuously.
public struct PeerEntry: Codable, Sendable, Equatable {
    public let peerID: String
    public let ipAddress: String
    public let port: UInt16
    public let clientName: String?
    public let downloadBytesPerSec: Int64
    public let uploadBytesPerSec: Int64
    public let progress: Double
    public let isSeed: Bool

    public init(
        peerID: String,
        ipAddress: String,
        port: UInt16,
        clientName: String?,
        downloadBytesPerSec: Int64,
        uploadBytesPerSec: Int64,
        progress: Double,
        isSeed: Bool
    ) {
        self.peerID = peerID
        self.ipAddress = ipAddress
        self.port = port
        self.clientName = clientName
        self.downloadBytesPerSec = downloadBytesPerSec
        self.uploadBytesPerSec = uploadBytesPerSec
        self.progress = progress
        self.isSeed = isSeed
    }
}

public enum TrackerStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case working
    case notWorking
    case updating
    case disabled
}

/// One row of a trackers page.
public struct TrackerEntry: Codable, Sendable, Equatable {
    public let url: String
    public let status: TrackerStatus
    public let seeds: Int
    public let peers: Int
    public let message: String?

    public init(url: String, status: TrackerStatus, seeds: Int, peers: Int, message: String?) {
        self.url = url
        self.status = status
        self.seeds = seeds
        self.peers = peers
        self.message = message
    }
}

public enum ActivityKind: String, Codable, Sendable, Equatable, CaseIterable {
    case metadataFetch
    case checking
    case moving
    case removing
    case creating
    case rechecking
}

/// One row of the activity feed.
public struct ActivityEntry: Codable, Sendable, Equatable {
    public let operationID: OperationID
    public let kind: ActivityKind
    public let fraction: Double
    public let startedAt: Date

    public init(operationID: OperationID, kind: ActivityKind, fraction: Double, startedAt: Date) {
        self.operationID = operationID
        self.kind = kind
        self.fraction = fraction
        self.startedAt = startedAt
    }
}

/// One row of a removal manifest (prepareRemoval result preview).
public struct RemovalManifestEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sizeBytes: Int64
    public let kind: FileKind

    public init(relativePath: String, sizeBytes: Int64, kind: FileKind) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

/// One row of a creator manifest (inspectCreateSource result preview).
public struct CreatorManifestEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sizeBytes: Int64
    public let kind: FileKind

    public init(relativePath: String, sizeBytes: Int64, kind: FileKind) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}
