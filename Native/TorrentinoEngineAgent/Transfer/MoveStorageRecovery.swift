// Layer: EngineAgent (Transfer) — WP-10 crash recovery for moves.
// Role: evidence-based recovery of a move interrupted mid-flight (app crash,
// engine kill, power loss). Reads the durable move journal row and derives a
// recommendation from journal stage + REAL payload evidence: the journal's
// fileListJSON is decoded and every listed file must exist as a real file at
// the origin (rollback) or destination (resume). Directory existence alone is
// NEVER evidence — an empty destination directory or a half-moved payload
// yields guided recovery, never resume.
// Must-not: move files, decide policy, or auto-resume a half-finished move.
// Invariants: every recommendation is derived from stage + fileListJSON
// evidence (lstat, no symlink traversal); resume is offered only when the
// journal says the engine move was issued AND every listed payload file exists
// at the destination; rollback only when the origin still holds every listed
// file; guided recovery is the fallback for any ambiguous or missing evidence.

import Foundation

enum MoveRecoveryRecommendation: Sendable, Equatable {
    /// The engine move was issued AND every payload file exists at the
    /// destination: safe to finish the move by updating the record and
    /// completing the journal row.
    case resume(recordID: String, toPath: String)
    /// Crash happened before the engine move took effect and the full payload
    /// still lives at the origin: nothing to fix, journal row can be dropped.
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
        // Gate 5: decode the payload list — recovery must never guess from
        // directory presence alone. nil = the list is missing/undecodable,
        // which is itself ambiguous evidence (guided).
        let payloadFiles = decodePayloadFiles(entry.fileListJSON)
        let fromHasPayload: Bool? = payloadFiles.map { allFilesPresent($0, under: entry.fromPath) }
        let toHasPayload: Bool? = payloadFiles.map { allFilesPresent($0, under: entry.toPath) }

        switch entry.stage {
        case MoveJournalEntry.Stage.engineMoved.rawValue,
             MoveJournalEntry.Stage.recordUpdated.rawValue,
             MoveJournalEntry.Stage.completed.rawValue:
            // The engine move was issued (or the record was already updated).
            if toExists, toHasPayload == true {
                return .resume(recordID: recordID, toPath: entry.toPath)
            }
            if toExists, toHasPayload == false, fromHasPayload == true {
                // Destination exists but never received the payload and the
                // origin still holds it: the move did not take effect. The
                // record still points at the origin, so dropping the journal
                // is a consistent no-op — NOT adopting an empty destination.
                return .rollbackNoop(recordID: recordID, fromPath: entry.fromPath)
            }
            return .guided(
                recordID: recordID,
                fromPath: entry.fromPath,
                toPath: entry.toPath,
                reason: "engine move was issued but the destination lacks the payload"
            )
        default:
            // stage == prepared: the engine was never asked to move anything.
            if fromExists, fromHasPayload == true {
                return .rollbackNoop(recordID: recordID, fromPath: entry.fromPath)
            }
            if toExists, toHasPayload == true {
                // Crash window: the engine moved the payload but the journal
                // stage update never happened. The payload evidence wins.
                return .resume(recordID: recordID, toPath: entry.toPath)
            }
            return .guided(
                recordID: recordID,
                fromPath: entry.fromPath,
                toPath: entry.toPath,
                reason: "payload evidence is missing or partial before the engine move was recorded"
            )
        }
    }

    /// Decodes the journal's `fileListJSON` (a JSON array of relative paths).
    /// Returns nil when the payload is missing or undecodable — evidence that
    /// must never be treated as "all files present".
    private static func decodePayloadFiles(_ fileListJSON: String) -> [String]? {
        guard !fileListJSON.isEmpty else { return nil }
        guard let data = fileListJSON.data(using: .utf8) else { return nil }
        let paths = try? JSONDecoder().decode([String].self, from: data)
        guard let paths, !paths.isEmpty else { return nil }
        return paths
    }

    /// True only when EVERY listed relative path exists under `dir` as a real
    /// regular file (lstat, no symlinks). An empty list is never evidence.
    private static func allFilesPresent(_ relativePaths: [String], under dir: String) -> Bool {
        for relative in relativePaths {
            let joined = (dir as NSString).appendingPathComponent(relative)
            guard let result = lstatForRecovery(joined), result.isFile, !result.isSymlink else {
                return false
            }
        }
        return true
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        guard let result = lstatForRecovery(path) else { return false }
        return result.isDirectory && !result.isSymlink
    }

    private struct RecoveryLStat: Sendable {
        let isSymlink: Bool
        let isDirectory: Bool
        let isFile: Bool
    }

    private static func lstatForRecovery(_ path: String) -> RecoveryLStat? {
        var st = Darwin.stat()
        guard path.withCString({ Darwin.lstat($0, &st) }) == 0 else { return nil }
        let mode = st.st_mode
        return RecoveryLStat(
            isSymlink: (mode & S_IFMT) == S_IFLNK,
            isDirectory: (mode & S_IFMT) == S_IFDIR,
            isFile: (mode & S_IFMT) == S_IFREG
        )
    }
}
