// Layer: Agent durable persistence (WP-06).
// Role: startup reconciliation. Runs inside PersistenceStore.open() before the
// store is marked ready. If the previous shutdown was unclean (or this is a
// crash-followed boot), SQLite's WAL replay already ran at open; this pass
// then verifies every checksummed record, sweeps orphan sidecars, and replays
// pending journal entries. Corrupt records are quarantined — never fatal.
// Must-not: mutate the database outside the quarantine/journal rules, or run
// while another session is live (the advisory lock guarantees single writer).
// Invariants: a clean_shutdown=true flag skips the heavy pass but still
// verifies checksums; a corrupt database surfaces as .corruptDatabase so the
// store can enter controlled recovery; every corruption is recorded in the
// quarantine table with its payload preserved.

import Foundation

enum StartupReconciler {
    /// Performs the startup pass and returns a report for the open() result.
    static func reconcile(store: PersistenceStore) async throws -> StartupReport {
        let cleanFlag = try await store.cleanShutdownFlag()

        // SQLite WAL replay happened automatically during open. Verify the
        // resulting database before trusting any record.
        let integrity = try await store.integrityCheck()
        guard integrity.ok else {
            throw PersistenceError.corruptDatabase(reason: integrity.detail)
        }

        // Checksum verification: a payload that fails SHA-256 is quarantined
        // (payload preserved) and its torrent is marked for recheck.
        var failures: [RecordCorruption] = []
        failures += try await store.verifyChecksums(kind: .resume)
        failures += try await store.verifyChecksums(kind: .metainfo)
        failures += try await store.verifySessionChecksums()
        for failure in failures {
            try await store.quarantineCorruptRecord(kind: failure.kind, torrentID: failure.torrentID,
                                                    generation: failure.generation, reason: failure.reason)
        }

        // Orphan sidecars: durable payloads whose SQLite commit never happened
        // (or whose generation was superseded). They must not resurrect a
        // write that never committed — sweep them.
        var removedSidecars = 0
        for kind in [GenerationKind.resume, .metainfo] {
            for orphan in try await store.orphanSidecars(kind: kind) {
                try await store.removeOrphanSidecar(kind: kind, file: orphan.file)
                removedSidecars += 1
            }
        }

        // Journal replay: 'pending' entries are operations interrupted by the
        // crash. Their effect may be partially applied; the conservative
        // recovery is to mark the referenced torrent for recheck, then flag
        // the entry 'replayed' so a later session never replays it twice.
        var replayed = 0
        if !cleanFlag {
            for entry in try await OperationJournal.pending(store: store) {
                if let torrentID = entry.torrentID,
                   try await store.torrent(withID: torrentID) != nil {
                    try await store.markTorrentForRecheck(torrentID: torrentID)
                }
                try await OperationJournal.markReplayed(store: store, seq: entry.seq)
                replayed += 1
            }
        }

        // A live session begins with clean_shutdown=false: the flag becomes
        // true only at the very end of a fully completed clean shutdown.
        try await store.setCleanShutdownFlag(false)

        let checksumsVerified = ((try? await store.recordCount(kind: .resume)) ?? 0)
            + ((try? await store.recordCount(kind: .metainfo)) ?? 0)
            + ((try? await store.sessionStateCount()) ?? 0)
        return StartupReport(
            cleanShutdown: cleanFlag,
            integrityOK: true,
            checksumsVerified: checksumsVerified,
            checksumFailures: failures.count,
            quarantined: failures.count,
            journalReplayed: replayed,
            orphanSidecarsRemoved: removedSidecars,
            degraded: false,
            rebuilt: false,
            message: cleanFlag
                ? "clean shutdown; verified=\(checksumsVerified) quarantined=\(failures.count)"
                : "unclean shutdown; WAL replayed; verified=\(checksumsVerified) "
                    + "quarantined=\(failures.count) journalReplayed=\(replayed) sidecarsRemoved=\(removedSidecars)"
        )
    }
}
