// Layer: Agent durable persistence (WP-06).
// Role: clean/unclean shutdown coordination. A clean shutdown runs a fixed
// pipeline — flush WAL (PASSIVE) -> TRUNCATE checkpoint -> truncate journal ->
// set clean_shutdown=true -> close — with a failpoint before every step and
// one during the checkpoint. The flag is written LAST, so a crash at any step
// leaves clean_shutdown=false and the next boot runs reconciliation.
// An unclean shutdown (SIGKILL, crash) simply closes the connection: the WAL
// stays on disk, SQLite replays it at next open, and the forensic trio is
// preserved untouched.
// Must-not: checkpoint or delete the WAL outside this coordinator, or set the
// clean flag before the checkpoint has completed.
// Invariants: performCleanShutdown is idempotent; every step maps failure to
// an unclean state (flag stays false, journal stays, WAL stays).

import Foundation

enum ShutdownCoordinator {
    enum Step: String, Sendable {
        case flushWAL
        case checkpoint
        case truncateJournal
        case setCleanFlag
        case close
    }

    /// The full clean-shutdown pipeline. Failpoint 8 fires before every step;
    /// failpoint 7 fires during the checkpoint. Any thrown fault aborts the
    /// pipeline with the store still marked dirty (flag not yet written).
    static func performCleanShutdown(store: PersistenceStore) async throws {
        let steps: [Step] = [.flushWAL, .checkpoint, .truncateJournal, .setCleanFlag, .close]
        for step in steps {
            try FailpointInjector.fire(.eachCleanShutdownStep)
            switch step {
            case .flushWAL:
                // Flush dirty pages into the main database without truncating.
                try await store.checkpointWAL(passive: true)
            case .checkpoint:
                // Truncate the WAL so main+WAL+SHM collapse to one clean file.
                try await store.checkpointWAL(passive: false)
            case .truncateJournal:
                // Clean session: the journal has served its purpose.
                try await store.journalTruncate()
            case .setCleanFlag:
                // LAST durable write of the session: a crash before this line
                // leaves the flag false and forces startup reconciliation.
                try await store.setCleanShutdownFlag(true)
            case .close:
                await store.rawClose()
            }
        }
    }
}
