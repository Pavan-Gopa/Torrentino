// Layer: Agent durable persistence (WP-10 safe file operations).
// Role: durable per-item Trash journal, durable two-phase removal tokens, and
// the same/cross-volume move journal. These tables are the crash-safety layer
// for remove/move: every payload mutation is journaled BEFORE it happens, and
// the coordinator (not this file) decides recovery from the journal state.
// Must-not: touch payload files, decide recovery policy, or auto-resume any
// half-finished operation (recovery is evidence-based and user-guided).
// Invariants: a removal token row exists before any trash item row; a trash
// item row exists before that item is moved; a move journal row exists before
// the engine is asked to move storage; rows of a completed operation are
// deleted only after the record is gone or the move is durably committed.

import Foundation
import TorrentinoIPC

// MARK: - Value types (all Sendable)

/// Durable two-phase removal token (WP-10). `manifestJSON` holds the exact
/// manifest the token was minted for; recovery and page fetches read it back
/// instead of trusting a client-supplied path.
struct RemovalTokenRecord: Sendable, Equatable {
    enum Status: String, Sendable {
        case pending
        case committed
        case cancelled
    }

    let token: String
    let recordID: String
    let deleteFiles: Bool
    let manifestJSON: String
    let sharedPathsJSON: String
    let status: String
    let createdAt: Int64
    let completedAt: Int64?
    let outcomeJSON: String?
}

/// One row of the per-item Trash journal. `status` is one of
/// pending / trashed / skipped_shared / failed; `failureCode` is a stable
/// classifier (symlink, sizeMismatch, io, permission, missing, notEmpty).
struct TrashJournalEntry: Sendable, Equatable {
    enum Status: String, Sendable {
        case pending
        case trashed
        case skippedShared = "skipped_shared"
        case failed
    }

    let seq: Int64
    let token: String
    let relativePath: String
    let absolutePath: String
    let kind: String
    let sizeBytes: Int64
    let status: String
    let failureCode: String?
    let failureMessage: String?
    let updatedAt: Int64
}

/// Durable outcome of a removal batch, written in the SAME update that marks
/// the token committed/cancelled, so a replayed commit (same token + key)
/// returns the identical RemovalBatchResult (WP-10 idempotency).
struct RemovalTokenOutcomeRecord: Sendable, Equatable {
    let status: String
    let outcomeJSON: String
}

/// One row of the move journal. `stage` is prepared -> engine_moved ->
/// record_updated -> completed; `status` is pending / completed / cancelled /
/// guided / failed. Recovery reads stage + status + fileListJSON.
struct MoveJournalEntry: Sendable, Equatable {
    enum Stage: String, Sendable {
        case prepared
        case engineMoved = "engine_moved"
        case recordUpdated = "record_updated"
        case completed
    }

    enum Status: String, Sendable {
        case pending
        case completed
        case cancelled
        case guided
        case failed
    }

    let seq: Int64
    let recordID: String
    let fromPath: String
    let toPath: String
    let fileListJSON: String
    let stage: String
    let status: String
    let startedAt: Int64
    let updatedAt: Int64
    let failureReason: String?
}

// MARK: - Store extension (schema v2)

extension PersistenceStore {
    // MARK: Removal tokens

    func createRemovalToken(
        token: String,
        recordID: String,
        deleteFiles: Bool,
        manifestJSON: String,
        sharedPathsJSON: String,
        createdAt: Int64
    ) throws {
        try requireOpen()
        let statement = try prepare("""
            INSERT OR REPLACE INTO removal_tokens
            (token, record_id, delete_files, manifest_json, shared_paths_json, status, created_at, completed_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?, NULL)
            """)
        try statement.bindText(token, index: 1)
        try statement.bindText(recordID, index: 2)
        try statement.bindInt64(deleteFiles ? 1 : 0, index: 3)
        try statement.bindText(manifestJSON, index: 4)
        try statement.bindText(sharedPathsJSON, index: 5)
        try statement.bindInt64(createdAt, index: 6)
        _ = try statement.step()
    }

    func removalToken(by token: String) throws -> RemovalTokenRecord? {
        try requireOpen()
        let statement = try prepare("""
            SELECT token, record_id, delete_files, manifest_json, shared_paths_json, status, created_at, completed_at, outcome_json
            FROM removal_tokens WHERE token = ?
            """)
        try statement.bindText(token, index: 1)
        guard try statement.step() == .row else { return nil }
        return readRemovalToken(statement)
    }

    func pendingRemovalTokens() throws -> [RemovalTokenRecord] {
        try requireOpen()
        let statement = try prepare("""
            SELECT token, record_id, delete_files, manifest_json, shared_paths_json, status, created_at, completed_at, outcome_json
            FROM removal_tokens WHERE status = 'pending'
            """)
        var result: [RemovalTokenRecord] = []
        while try statement.step() == .row {
            result.append(readRemovalToken(statement))
        }
        return result
    }

    func removalTokenCount() throws -> Int {
        try requireOpen()
        let statement = try prepare("SELECT COUNT(*) FROM removal_tokens")
        guard try statement.step() == .row else { return 0 }
        return Int(statement.columnInt64(0))
    }

    func markRemovalTokenCommitted(token: String, at completedAt: Int64) throws {
        try requireOpen()
        let statement = try prepare("UPDATE removal_tokens SET status = 'committed', completed_at = ? WHERE token = ?")
        try statement.bindInt64(completedAt, index: 1)
        try statement.bindText(token, index: 2)
        _ = try statement.step()
    }

    func markRemovalTokenCancelled(token: String, at completedAt: Int64) throws {
        try requireOpen()
        let statement = try prepare("UPDATE removal_tokens SET status = 'cancelled', completed_at = ? WHERE token = ?")
        try statement.bindInt64(completedAt, index: 1)
        try statement.bindText(token, index: 2)
        _ = try statement.step()
    }

    /// Atomically writes the batch outcome together with the final status, so
    /// an idempotent replay can reconstruct the exact RemovalBatchResult.
    /// WP-10 (Gate 8): the settle is fail-closed — a throwing failpoint aborts
    /// the commit so no payload mutation proceeds without durable evidence.
    func settleRemovalToken(token: String, status: String, outcomeJSON: String, at completedAt: Int64) throws {
        try requireOpen()
        try FailpointInjector.fire(.beforeRemovalTokenSettle)
        let statement = try prepare("""
            UPDATE removal_tokens SET status = ?, outcome_json = ?, completed_at = ? WHERE token = ?
            """)
        try statement.bindText(status, index: 1)
        try statement.bindText(outcomeJSON, index: 2)
        try statement.bindInt64(completedAt, index: 3)
        try statement.bindText(token, index: 4)
        _ = try statement.step()
    }

    /// Bounded pruning of settled tokens (newest first), so committed rows
    /// kept for crash-safe replay never grow without bound.
    func pruneSettledRemovalTokens(keepNewest: Int) throws {
        try requireOpen()
        let statement = try prepare("""
            DELETE FROM removal_tokens
            WHERE status != 'pending'
              AND token NOT IN (
                SELECT token FROM removal_tokens
                WHERE status != 'pending'
                ORDER BY completed_at DESC
                LIMIT ?
              )
            """)
        try statement.bindInt64(Int64(max(0, keepNewest)), index: 1)
        _ = try statement.step()
    }

    func deleteRemovalToken(token: String) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM removal_tokens WHERE token = ?")
        try statement.bindText(token, index: 1)
        _ = try statement.step()
    }

    // MARK: Trash journal

    func trashJournalAppend(
        token: String,
        relativePath: String,
        absolutePath: String,
        kind: String,
        sizeBytes: Int64,
        updatedAt: Int64
    ) throws -> Int64 {
        try requireOpen()
        try FailpointInjector.fire(.beforeTrashJournalAppend)
        let statement = try prepare("""
            INSERT INTO trash_journal (token, relative_path, absolute_path, kind, size_bytes, status, updated_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)
            """)
        try statement.bindText(token, index: 1)
        try statement.bindText(relativePath, index: 2)
        try statement.bindText(absolutePath, index: 3)
        try statement.bindText(kind, index: 4)
        try statement.bindInt64(sizeBytes, index: 5)
        try statement.bindInt64(updatedAt, index: 6)
        _ = try statement.step()
        let lookup = try prepare("""
            SELECT seq FROM trash_journal
            WHERE token = ? AND relative_path = ?
            ORDER BY seq DESC LIMIT 1
            """)
        try lookup.bindText(token, index: 1)
        try lookup.bindText(relativePath, index: 2)
        guard try lookup.step() == .row else { return -1 }
        return lookup.columnInt64(0)
    }

    func trashJournalEntries(token: String) throws -> [TrashJournalEntry] {
        try requireOpen()
        let statement = try prepare("""
            SELECT seq, token, relative_path, absolute_path, kind, size_bytes, status, failure_code, failure_message, updated_at
            FROM trash_journal WHERE token = ? ORDER BY seq
            """)
        try statement.bindText(token, index: 1)
        var result: [TrashJournalEntry] = []
        while try statement.step() == .row {
            result.append(TrashJournalEntry(
                seq: statement.columnInt64(0),
                token: statement.columnText(1) ?? "",
                relativePath: statement.columnText(2) ?? "",
                absolutePath: statement.columnText(3) ?? "",
                kind: statement.columnText(4) ?? "file",
                sizeBytes: statement.columnInt64(5),
                status: statement.columnText(6) ?? "pending",
                failureCode: statement.columnText(7),
                failureMessage: statement.columnText(8),
                updatedAt: statement.columnInt64(9)
            ))
        }
        return result
    }

    func trashJournalUpdate(
        seq: Int64,
        status: String,
        failureCode: String?,
        failureMessage: String?,
        updatedAt: Int64
    ) throws {
        try requireOpen()
        try FailpointInjector.fire(.beforeTrashJournalUpdate)
        let statement = try prepare("""
            UPDATE trash_journal SET status = ?, failure_code = ?, failure_message = ?, updated_at = ?
            WHERE seq = ?
            """)
        try statement.bindText(status, index: 1)
        try statement.bindText(failureCode, index: 2)
        try statement.bindText(failureMessage, index: 3)
        try statement.bindInt64(updatedAt, index: 4)
        try statement.bindInt64(seq, index: 5)
        _ = try statement.step()
    }

    func deleteTrashJournal(token: String) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM trash_journal WHERE token = ?")
        try statement.bindText(token, index: 1)
        _ = try statement.step()
    }

    // MARK: Move journal

    func moveJournalCreate(
        recordID: String,
        fromPath: String,
        toPath: String,
        fileListJSON: String,
        startedAt: Int64
    ) throws -> Int64 {
        try requireOpen()
        let statement = try prepare("""
            INSERT OR REPLACE INTO move_journal
            (record_id, from_path, to_path, file_list_json, stage, status, started_at, updated_at, failure_reason)
            VALUES (?, ?, ?, ?, 'prepared', 'pending', ?, ?, NULL)
            """)
        try statement.bindText(recordID, index: 1)
        try statement.bindText(fromPath, index: 2)
        try statement.bindText(toPath, index: 3)
        try statement.bindText(fileListJSON, index: 4)
        try statement.bindInt64(startedAt, index: 5)
        try statement.bindInt64(startedAt, index: 6)
        _ = try statement.step()
        let lookup = try prepare("""
            SELECT seq FROM move_journal
            WHERE record_id = ?
            ORDER BY seq DESC LIMIT 1
            """)
        try lookup.bindText(recordID, index: 1)
        guard try lookup.step() == .row else { return -1 }
        return lookup.columnInt64(0)
    }

    func moveJournal(recordID: String) throws -> MoveJournalEntry? {
        try requireOpen()
        let statement = try prepare("""
            SELECT seq, record_id, from_path, to_path, file_list_json, stage, status, started_at, updated_at, failure_reason
            FROM move_journal WHERE record_id = ? ORDER BY seq DESC LIMIT 1
            """)
        try statement.bindText(recordID, index: 1)
        guard try statement.step() == .row else { return nil }
        return readMoveJournal(statement)
    }

    func moveJournalUpdate(
        seq: Int64,
        stage: String,
        status: String,
        failureReason: String?,
        updatedAt: Int64
    ) throws {
        try requireOpen()
        let statement = try prepare("""
            UPDATE move_journal SET stage = ?, status = ?, failure_reason = ?, updated_at = ? WHERE seq = ?
            """)
        try statement.bindText(stage, index: 1)
        try statement.bindText(status, index: 2)
        try statement.bindText(failureReason, index: 3)
        try statement.bindInt64(updatedAt, index: 4)
        try statement.bindInt64(seq, index: 5)
        _ = try statement.step()
    }

    func pendingMoveJournals() throws -> [MoveJournalEntry] {
        try requireOpen()
        let statement = try prepare("""
            SELECT seq, record_id, from_path, to_path, file_list_json, stage, status, started_at, updated_at, failure_reason
            FROM move_journal WHERE status = 'pending'
            """)
        var result: [MoveJournalEntry] = []
        while try statement.step() == .row {
            result.append(readMoveJournal(statement))
        }
        return result
    }

    func deleteMoveJournal(recordID: String) throws {
        try requireOpen()
        let statement = try prepare("DELETE FROM move_journal WHERE record_id = ?")
        try statement.bindText(recordID, index: 1)
        _ = try statement.step()
    }

    // MARK: Readers

    private func readRemovalToken(_ statement: SQLiteStatement) -> RemovalTokenRecord {
        let completedAtValue = statement.columnInt64(7)
        return RemovalTokenRecord(
            token: statement.columnText(0) ?? "",
            recordID: statement.columnText(1) ?? "",
            deleteFiles: statement.columnInt64(2) != 0,
            manifestJSON: statement.columnText(3) ?? "",
            sharedPathsJSON: statement.columnText(4) ?? "[]",
            status: statement.columnText(5) ?? "pending",
            createdAt: statement.columnInt64(6),
            completedAt: completedAtValue == 0 ? nil : completedAtValue,
            outcomeJSON: statement.columnText(8)
        )
    }

    private func readMoveJournal(_ statement: SQLiteStatement) -> MoveJournalEntry {
        MoveJournalEntry(
            seq: statement.columnInt64(0),
            recordID: statement.columnText(1) ?? "",
            fromPath: statement.columnText(2) ?? "",
            toPath: statement.columnText(3) ?? "",
            fileListJSON: statement.columnText(4) ?? "[]",
            stage: statement.columnText(5) ?? "prepared",
            status: statement.columnText(6) ?? "pending",
            startedAt: statement.columnInt64(7),
            updatedAt: statement.columnInt64(8),
            failureReason: statement.columnText(9)
        )
    }
}
