// Layer: Agent durable persistence (WP-06).
// Role: quarantine + controlled recovery. Corrupt records are moved into the
// quarantine table (payload preserved for forensics) and their torrent is
// marked for recheck; a corrupt database triggers salvage + rebuild with the
// forensic trio (main + WAL + SHM) preserved as one group. The agent never
// crashes on corrupt data — it degrades and keeps serving.
// Must-not: delete corrupt evidence, or rebuild while the old connection is
// still alive (the store closes it first).
// Invariants: every corruption is recorded with timestamp/reason/generation;
// a rebuilt database starts with clean_shutdown=false and all salvaged
// torrents marked for recheck; quarantine is queryable for diagnostics.

import Foundation

enum QuarantineManager {
    /// Moves a corrupt record to quarantine and marks the owner for recheck.
    static func quarantineCorruptRecord(store: PersistenceStore, kind: GenerationKind,
                                        torrentID: String?, generation: UInt64,
                                        reason: String) async throws {
        try await store.quarantineCorruptRecord(kind: kind, torrentID: torrentID,
                                                generation: generation, reason: reason)
    }

    /// Marks a torrent for recheck (conservative recovery for half-applied
    /// operations and corrupted resume data).
    static func markTorrentForRecheck(store: PersistenceStore, torrentID: String) async throws {
        try await store.markTorrentForRecheck(torrentID: torrentID)
    }

    static func records(store: PersistenceStore) async throws -> [QuarantineRecord] {
        try await store.quarantineRecords()
    }

    static func count(store: PersistenceStore) async throws -> Int {
        try await store.quarantineCount()
    }

    static func clear(store: PersistenceStore, seq: Int64) async throws {
        try await store.clearQuarantine(seq: seq)
    }

    /// Controlled recovery entry point for a corrupt database. The store
    /// closes the connection, preserves the forensic trio, salvages readable
    /// torrent/metainfo rows, writes a fresh database and reopens it.
    static func rebuildDatabase(store: PersistenceStore, reason: String) async throws -> RebuildReport {
        try await store.recoverFromCorruptDatabase(reason: reason)
    }
}
