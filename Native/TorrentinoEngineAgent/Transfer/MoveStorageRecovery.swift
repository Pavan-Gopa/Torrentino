// Layer: EngineAgent (Transfer) — WP-10 crash recovery for moves.
// Role: evidence-based recovery of a move interrupted mid-flight (app crash,
// engine kill, power loss). Reads the durable move journal row and derives a
// recommendation from filesystem evidence + journal stage.
// Must-not: move files, decide policy, or auto-resume a half-finished move.
// Invariants: every recommendation is derived from stage + real filesystem
// evidence (lstat, no symlink traversal); resume is offered only when the
// journal says the engine move was issued AND the destination exists; guided
// recovery is the fallback for any ambiguous evidence.

import Foundation

enum MoveRecoveryRecommendation: Sendable, Equatable {
    /// Destination exists and the engine move was issued: safe to finish the
    /// move by updating the record and completing the journal row.
    case resume(recordID: String, toPath: String)
    /// Crash happened before the engine move was issued and the payload still
    /// lives at the origin: nothing to fix, journal row can be dropped.
    case rollbackNoop(recordID: String, fromPath: String)
    /// Evidence is ambiguous or the payload is missing: never guess — surface
    /// guided recovery to the user and keep the journal row for retry.
    case guided(recordID: String, fromPath: String, toPath: String, reason: String)
}

enum MoveStorageRecovery {
    static func recommendation(for entry: MoveJournalEntry) -> MoveRecoveryRecommendation {
        let recordID = entry.recordID
        let fromExists = isRealDirectory(entry.fromPath)
        let toExists = isRealDirectory(entry.toPath)

        switch entry.stage {
        case MoveJournalEntry.Stage.engineMoved.rawValue,
             MoveJournalEntry.Stage.recordUpdated.rawValue,
             MoveJournalEntry.Stage.completed.rawValue:
            // The engine move was issued (or the record was already updated).
            if toExists {
                return .resume(recordID: recordID, toPath: entry.toPath)
            }
            return .guided(
                recordID: recordID,
                fromPath: entry.fromPath,
                toPath: entry.toPath,
                reason: "engine move was issued but the destination is missing"
            )
        default:
            // stage == prepared: the engine was never asked to move anything.
            if fromExists {
                return .rollbackNoop(recordID: recordID, fromPath: entry.fromPath)
            }
            return .guided(
                recordID: recordID,
                fromPath: entry.fromPath,
                toPath: entry.toPath,
                reason: "origin payload is missing before the engine move was issued"
            )
        }
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var st = Darwin.stat()
        let status: Int32 = path.withCString { Darwin.lstat($0, &st) }
        guard status == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return (st.st_mode & S_IFLNK) != S_IFLNK
    }
}
