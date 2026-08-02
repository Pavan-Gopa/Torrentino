// Layer: Agent durable persistence (WP-06).
// Role: append-only journal of recent commands (last `limit` = 1000 rows).
// Every state-mutating operation journals a 'pending' entry BEFORE touching
// payloads and flips it to 'committed' inside the same SQLite transaction as
// the payload row. On unclean startup the reconciler replays entries that are
// still 'pending' (conservatively marking torrents for recheck) and flags them
// 'replayed'; a clean shutdown truncates the journal entirely.
// Must-not: journal payloads themselves (only command + torrent reference), or
// grow without bound (trim keeps the newest `limit` rows after each append).
// Invariants: entry statuses are pending -> committed (normal) or pending ->
// replayed (after crash reconciliation); timestamp is unix-epoch milliseconds.

import Foundation

enum OperationJournal {
    /// Newest entries kept; older rows are trimmed after each append.
    static let limit = 1000

    /// Appends a pending entry. Returns the journal seq for markCommitted.
    static func append(store: PersistenceStore, command: String, torrentID: String?) async throws -> Int64 {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        return try await store.journalAppend(command: command, torrentID: torrentID, timestamp: timestamp)
    }

    /// Marks an entry as durably committed (the store calls the equivalent
    /// primitive inside its transaction, so it commits atomically with the
    /// payload row; this façade exists for reconciler/test use).
    static func markCommitted(store: PersistenceStore, seq: Int64) async throws {
        try await store.journalMarkCommitted(seq: seq)
    }

    /// Entries that never reached 'committed' — the replay candidates.
    static func pending(store: PersistenceStore) async throws -> [JournalEntry] {
        try await store.journalPendingEntries()
    }

    static func allEntries(store: PersistenceStore) async throws -> [JournalEntry] {
        try await store.journalAllEntries()
    }

    static func count(store: PersistenceStore) async throws -> Int64 {
        try await store.journalCount()
    }

    /// Marks a replayed entry so it is never re-replayed in a later session.
    static func markReplayed(store: PersistenceStore, seq: Int64) async throws {
        try await store.journalMarkReplayed(seq: seq)
    }

    /// Empties the journal (clean shutdown only).
    static func truncate(store: PersistenceStore) async throws {
        try await store.journalTruncate()
    }

    /// Keeps the newest `limit` entries.
    static func trim(store: PersistenceStore) async throws {
        try await store.journalTrim(limit: limit)
    }
}
