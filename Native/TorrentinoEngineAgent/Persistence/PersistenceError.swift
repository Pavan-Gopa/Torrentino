// Layer: Agent durable persistence (WP-06).
// Role: shared error vocabulary for the persistence stack. One type so the
// store, journal, reconciler, quarantine manager and shutdown coordinator can
// throw interoperable errors without cross-file type gossip.
// Must-not: carry non-Sendable payloads, or absorb NSError bridging (all
// paths stay pure Swift Foundation/CryptoKit/SQLite).
// Invariants: every case is Sendable and CustomStringConvertible; every error
// is recoverable — the store degrades, it never aborts the agent process.

import Foundation

enum PersistenceError: Error, CustomStringConvertible, Sendable {
    /// The store was opened twice, or an operation ran before open()/after close().
    case notOpen
    /// The store is already open.
    case alreadyOpen
    /// The store was opened on a DB whose schema is NEWER than this binary.
    case downgradeBlocked(found: Int, supported: Int)
    /// A checksummed payload no longer matches its SHA-256 (torn write, bit rot).
    case checksumMismatch(kind: String, torrentID: String?, generation: UInt64)
    /// A torrent record referenced by an operation does not exist.
    case unknownTorrent(id: String)
    /// The SQLite engine refused a statement (busy, constraint, corrupt, ...).
    case sqlite(String)
    /// The database failed integrity checking and could not be salvaged.
    case corruptDatabase(reason: String)
    /// A failpoint armed by the test harness fired and injected a fault.
    case injectedFailpoint(FailpointID)
    /// Filesystem refused an operation on the sidecar / database files.
    case ioFailure(reason: String)
    /// The persistence boundary observed that its backing volume is absent.
    /// Keeping this typed prevents the coordinator from presenting a detached
    /// volume as a generic storage failure.
    case volumeUnavailable(volumeIdentifier: String?)
    /// Another writer already owns the data directory lock.
    case alreadyLocked(url: String)

    var description: String {
        switch self {
        case .notOpen:
            return "persistence store is not open"
        case .alreadyOpen:
            return "persistence store is already open"
        case .downgradeBlocked(let found, let supported):
            return "database schema v\(found) is newer than supported v\(supported); downgrade blocked"
        case .checksumMismatch(let kind, let torrentID, let generation):
            let owner = torrentID.map { " torrent=\($0)" } ?? ""
            return "checksum mismatch kind=\(kind)\(owner) generation=\(generation)"
        case .unknownTorrent(let id):
            return "unknown torrent record \(id)"
        case .sqlite(let message):
            return "sqlite error: \(message)"
        case .corruptDatabase(let reason):
            return "corrupt database: \(reason)"
        case .injectedFailpoint(let id):
            return "injected failpoint \(id.rawValue)"
        case .ioFailure(let reason):
            return "persistence IO failure: \(reason)"
        case .volumeUnavailable(let volumeIdentifier):
            return "persistence volume unavailable: \(volumeIdentifier ?? "unknown")"
        case .alreadyLocked(let url):
            return "data directory is already locked by another writer: \(url)"
        }
    }
}
