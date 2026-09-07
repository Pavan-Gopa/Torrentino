// Layer: WP-10 safe file operations tests.
// Role: XCTest gates for durable two-phase removal (token → manifest page →
// trash commit with per-item journal, typed failures, idempotent replay),
// shared-path protection across records, and the durable storage move with
// crash recovery (resume / rollback-noop / guided — never silent auto-resume).
// Must-not: use the real Trash (injected recording/failing provider only),
// permanently delete anything, or touch production App Support (TestProfile).

import Foundation
import XCTest
import TorrentinoIPC
import TorrentinoDomain

final class WPSafeFileOperationsTests: TestProfileCase {

    // MARK: - Helpers

    private func makeCoordinator(
        engine: StubTransferEngine,
        bus: TransferEventBus,
        trashProvider: (any TrashProviding)? = nil
    ) async throws -> (TransferCoordinator, PersistenceStore, StubTransferEngine) {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let fakeTrash = profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)")
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: store,
            eventBus: bus,
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path),
            trashProvider: trashProvider ?? RecordingTrashProvider(fakeTrashDirectory: fakeTrash)
        )
        return (coordinator, store, engine)
    }

    /// Adds a torrent from in-memory metainfo data with an explicit save
    /// location, then materializes the payload files on disk exactly as the
    /// metainfo describes (relative to the save location).
    @discardableResult
    private func addTorrentFile(
        _ coordinator: TransferCoordinator,
        metainfo: Data,
        saveLocation: URL
    ) async throws -> TorrentRecordID {
        let inspection = try await inspect(coordinator, source: .torrentFileData(metainfo))
        let commit = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(
            CommitAddRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                operationID: inspection.operationID,
                saveLocation: PersistedLocation(path: saveLocation.path)
            )
        ))))
        guard case .commitAdd(let addResult) = commit else {
            throw NSError(domain: "test", code: 30, userInfo: [NSLocalizedDescriptionKey: "unexpected \(commit)"])
        }
        return addResult.recordID
    }

    private func materializePayload(_ saveLocation: URL, files: [(String, Int64)]) throws {
        for (path, size) in files {
            let url = saveLocation.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0xAB, count: Int(size)).write(to: url)
        }
    }

    private func prepareRemoval(
        _ coordinator: TransferCoordinator,
        recordID: TorrentRecordID,
        deleteFiles: Bool
    ) async throws -> RemovalToken {
        let reply = await coordinator.processCommand(encode(.prepareRemoval(
            PrepareRemovalRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                deleteFiles: deleteFiles
            )
        )))
        let payload = try resultPayload(from: reply)
        guard case .removalToken(let token) = payload else {
            throw NSError(domain: "test", code: 31, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return token
    }

    private func removalManifestPage(
        _ coordinator: TransferCoordinator,
        token: RemovalToken
    ) async throws -> Page<RemovalManifestEntry> {
        let reply = await coordinator.processCommand(encode(.fetchRemovalManifestPage(
            FetchRemovalManifestPageRequest(requestID: RequestID(), token: token, cursor: nil, pageSize: 100)
        )))
        let payload = try resultPayload(from: reply)
        guard case .removalManifestPage(let page) = payload else {
            throw NSError(domain: "test", code: 32, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return page
    }

    private func commitRemoval(
        _ coordinator: TransferCoordinator,
        token: RemovalToken
    ) async throws -> RemovalBatchResult {
        let reply = await coordinator.processCommand(encode(.commitRemoval(
            CommitRemovalRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), token: token)
        )))
        let payload = try resultPayload(from: reply)
        guard case .removalResult(let result) = payload else {
            throw NSError(domain: "test", code: 33, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return result
    }

    private func snapshot(_ coordinator: TransferCoordinator) async throws -> EngineSnapshot {
        let reply = await coordinator.processCommand(encode(.fetchSnapshot(
            FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
        )))
        let payload = try resultPayload(from: reply)
        guard case .snapshot(let snap) = payload else {
            throw NSError(domain: "test", code: 34, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return snap
    }

    private func inspect(_ coordinator: TransferCoordinator, source: AddSource) async throws -> AddSourceInspection {
        let reply = await coordinator.processCommand(encode(.inspectAddSource(
            InspectAddSourceRequest(requestID: RequestID(), source: source)
        )))
        let payload = try resultPayload(from: reply)
        guard case .addSourceInspection(let inspection) = payload else {
            throw NSError(domain: "test", code: 35, userInfo: [NSLocalizedDescriptionKey: "unexpected \(payload)"])
        }
        return inspection
    }

    private func resultPayload(from reply: Data) throws -> SuccessPayload {
        let envelope = decode(IPCEnvelope.self, from: reply)
        guard let result = envelope.result else {
            throw NSError(domain: "test", code: 36, userInfo: [NSLocalizedDescriptionKey: "no result in \(envelope)"])
        }
        switch result {
        case .success(let payload):
            return payload
        case .failure(let fault):
            throw NSError(domain: "test", code: 37, userInfo: [
                NSLocalizedDescriptionKey: "fault \(fault.code.rawValue) \(fault.redactedContext ?? "")",
            ])
        }
    }

    private func resultFault(from reply: Data) throws -> EngineFault {
        let envelope = decode(IPCEnvelope.self, from: reply)
        guard let result = envelope.result else {
            throw NSError(domain: "test", code: 38, userInfo: [NSLocalizedDescriptionKey: "no result in \(envelope)"])
        }
        guard case .failure(let fault) = result else {
            throw NSError(domain: "test", code: 39, userInfo: [NSLocalizedDescriptionKey: "expected fault, got \(result)"])
        }
        return fault
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            fatalError("decode failed: \(error)")
        }
    }

    private func encode(_ command: EngineCommandV1) -> Data {
        (try? JSONEncoder().encode(IPCEnvelope.request(command))) ?? Data()
    }

    private static func nowMilliseconds() -> Int64 {
        Int64(Date.now.timeIntervalSince1970 * 1000)
    }

    // MARK: - WP-10: durable prepare + exact manifest page

    func testWP10PrepareRemovalCreatesDurableTokenAndExactManifestPage() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-prepare")

        let metainfo = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 100), ("dir/nested/b.bin", 200)],
            pieceLength: 256, piecesCount: 1, name: "tree"
        )
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // The token row must be durable and pending, with the exact manifest.
        let tokenRecord = try await store.removalToken(by: token.rawValue)
        XCTAssertNotNil(tokenRecord)
        XCTAssertEqual(tokenRecord?.status, "pending")
        XCTAssertEqual(tokenRecord?.deleteFiles, true)
        let manifest = try JSONDecoder().decode(RemovalManifest.self, from: Data(tokenRecord!.manifestJSON.utf8))
        XCTAssertEqual(Set(manifest.entries.filter { $0.kind == .file }.map(\.relativePath)),
                       ["tree/dir/a.txt", "tree/dir/nested/b.bin"])
        XCTAssertEqual(manifest.saveLocationPath, URL(fileURLWithPath: saveLocation.path).standardizedFileURL.path)
        XCTAssertEqual(manifest.payloadRootPath, URL(fileURLWithPath: saveLocation.path).appendingPathComponent("tree").standardizedFileURL.path)
        // The manifest page serves the durable manifest (shared flags are
        // settled at prepare time and reflected in the commit outcome).
        let page = try await removalManifestPage(coordinator, token: token)
        XCTAssertEqual(page.totalCount, 5, "2 files + 3 directories")
        XCTAssertEqual(page.items.map(\.relativePath), ["tree/dir/nested/b.bin", "tree/dir/a.txt", "tree/dir/nested", "tree/dir", "tree"],
                       "files first, then directories deepest-first")
        XCTAssertNil(page.nextCursor, "single page covers the whole manifest")
        XCTAssertEqual(page.items.filter { $0.kind == .file }.count, 2)
    }

    func testWP10PrepareRemovalWithoutDeleteFilesKeepsEmptyManifest() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-nodelfiles")

        let metainfo = MetainfoBuilder.singleFile(name: "keep.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: false)
        let tokenRecord = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRecord?.deleteFiles, false)
        XCTAssertEqual(tokenRecord?.manifestJSON, "{}",
                       "record-only removal carries no payload manifest")
    }

    func testWP10KeepDataRemovalLeavesPayloadByteIdentical() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-keep-data")
        let payloadURL = saveLocation.appendingPathComponent("keep.bin")
        let before = Data(repeating: 0x6B, count: 777)
        try before.write(to: payloadURL)

        let metainfo = MetainfoBuilder.singleFile(
            name: "keep.bin",
            size: Int64(before.count),
            pieceLength: 256,
            piecesCount: 1
        )
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: false)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.trashedItems, 0, "keep-data removal must not offer payload to Trash")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: payloadURL),
            before,
            "record removal with deleteFiles=false must preserve payload bytes"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadURL.path))
        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID })
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 1)

        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed")
    }

    func testWP10PrepareRemovalPersistenceCountFailureFailsClosed() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-prepare-count-fault")
        let payload = saveLocation.appendingPathComponent("payload.bin")
        try Data(repeating: 0x6D, count: 64).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 64, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        // Closing the isolated store makes removalTokenCount throw while the
        // coordinator still has the record in memory. Admission must not treat
        // that read failure as an empty token table.
        try await store.close(clean: false)
        let reply = await coordinator.processCommand(encode(.prepareRemoval(
            PrepareRemovalRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                deleteFiles: true
            )
        )))
        let fault = try resultFault(from: reply)
        XCTAssertEqual(fault.code, .storeError)
        XCTAssertEqual(fault.affectedRecord, recordID)

        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 0)
        await store.rawClose()
    }

    func testWP10FetchPendingRemovalsPersistenceFailureDoesNotFabricateProgress() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-pending-read-fault")
        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 1, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        _ = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // A closed store makes the pending-removal read fail. The command must
        // return a typed persistence fault, never an empty pending list with
        // fabricated zero progress.
        try await store.close(clean: false)
        let reply = await coordinator.processCommand(encode(.fetchPendingRemovals(
            FetchPendingRemovalsRequest(requestID: RequestID())
        )))
        let fault = try resultFault(from: reply)
        XCTAssertEqual(fault.code, .storeError)
        XCTAssertNil(fault.affectedRecord, "the pending-token read failed before a record could be identified")
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        await store.rawClose()
    }

    // MARK: - WP-10: commit — full success path

    func testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-commit")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        let payloadDir = saveLocation.appendingPathComponent("tree")
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.trashedItems, 5, "2 files + 3 directories, all trashed")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertTrue(result.failedItems.isEmpty)

        // Every manifest path was offered to the trash provider, in order.
        let trashed = trash.recorded()
        XCTAssertEqual(trashed, [
            saveLocation.appendingPathComponent("tree/dir/nested/b.bin").path,
            saveLocation.appendingPathComponent("tree/dir/a.txt").path,
            saveLocation.appendingPathComponent("tree/dir/nested").path,
            saveLocation.appendingPathComponent("tree/dir").path,
            saveLocation.appendingPathComponent("tree").path,
        ])

        // Engine remove was issued for the engine-owned torrent (never delete
        // files on the engine side — the trash already did).
        let removedCount = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removedCount, 1)

        // Record is gone from the snapshot.
        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record must be removed after full success")

        // Durable cleanup: token settled committed, journal evidence cleared.
        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed")
        let journalAfterSuccess = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertTrue(journalAfterSuccess.isEmpty, "journal cleared after success")
        let moveJournalAfterSuccess = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(moveJournalAfterSuccess)
    }

    // MARK: - WP-10: commit — partial failure keeps record + journal, resumable replay

    func testWP10CommitRemovalPartialFailureKeepsRecordAndJournalWithResumableReplay() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-partial")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        let payloadDir = saveLocation.appendingPathComponent("tree")
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // First item in trash order fails → partial outcome with journal
        // evidence. The failed file stays on disk, so its parent directories
        // are NOT empty and refuse to be trashed (Gate 1).
        trash.fail(path: saveLocation.appendingPathComponent("tree/dir/nested/b.bin").path)
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.trashedItems, 1, "only a.txt was trashed")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertEqual(result.failedItems.count, 4, "b.bin + tree/dir/nested + tree/dir + tree (not empty)")
        XCTAssertEqual(result.failedItems.first?.relativePath, "tree/dir/nested/b.bin")
        XCTAssertEqual(result.failedItems.first?.code, "trash_failed")

        // The record is KEPT — never removed on partial success.
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID }, "record survives a partial removal")
        let removedAfterPartial = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removedAfterPartial, 0, "engine remove must not fire on partial")

        // Gate 4: the token STAYS pending (no outcomeJSON, no cancellation) so
        // an explicit re-commit can resume; the per-item journal rows remain
        // as recovery evidence.
        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "pending")
        XCTAssertNil(settled?.outcomeJSON, "partial batches never settle an outcome")
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journal.count, 5, "journal rows survive a partial removal")
        XCTAssertEqual(journal.first?.status, TrashJournalEntry.Status.failed.rawValue)
        XCTAssertEqual(journal.first?.failureCode, "trash_failed")
        XCTAssertEqual(journal[1].status, TrashJournalEntry.Status.trashed.rawValue)

        // Resumable replay: committing the SAME token resumes from the durable
        // journal — already-trashed items are never touched again, the still
        // failing item fails again (identical result).
        let replay = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(replay, result, "resumed replay returns the identical batch result")
        XCTAssertEqual(trash.recorded().count, 1, "replay must not trash again")
    }

    func testWP10CommitRemovalTotalFailureKeepsRecordAndJournal() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-total")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        let payloadDir = saveLocation.appendingPathComponent("tree")
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        trash.failEverything()
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.trashedItems, 0)
        XCTAssertEqual(result.failedItems.count, 5, "every manifest item failed")

        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        let removedAfterTotal = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removedAfterTotal, 0)
        // Gate 4: a fully failed batch stays pending and resumable (never
        // settled cancelled — nothing was settled at all).
        let settledAfterTotal = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settledAfterTotal?.status, "pending")
        XCTAssertNil(settledAfterTotal?.outcomeJSON)
        let journalAfterTotal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journalAfterTotal.count, 5)
        XCTAssertTrue(journalAfterTotal.allSatisfy { $0.status == TrashJournalEntry.Status.failed.rawValue })
    }

    // MARK: - WP-10: shared-path protection

    func testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-shared")

        // Torrent A: multi-file payload in saveLocation/tree.
        let filesA = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        let payloadDirA = saveLocation.appendingPathComponent("tree")
        try materializePayload(payloadDirA, files: filesA)
        let metainfoA = MetainfoBuilder.multiFile(files: filesA, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordA = try await addTorrentFile(coordinator, metainfo: metainfoA, saveLocation: saveLocation)

        // Torrent B: a second torrent that genuinely shares A's payload files under the same tree — its
        // metainfo covers A's paths under the same tree directory, so A's files are shared/untouchable.
        let filesB = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200)), ("other.bin", Int64(512))]
        try materializePayload(payloadDirA, files: [("other.bin", Int64(512))])
        let metainfoB = MetainfoBuilder.multiFile(files: filesB, pieceLength: 256, piecesCount: 1, name: "tree")
        _ = try await addTorrentFile(coordinator, metainfo: metainfoB, saveLocation: saveLocation)

        // The manifest flags the shared files (settled at prepare time, before
        // any commit) — the commit below must skip exactly those paths.
        let token = try await prepareRemoval(coordinator, recordID: recordA, deleteFiles: true)
        _ = try await removalManifestPage(coordinator, token: token)

        // Commit: shared items are skipped (never trashed). Files and directories
        // covered by another torrent are preserved intact on disk.
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "all items skipped as shared; removal completes cleanly")
        XCTAssertEqual(result.skippedSharedItems, 5, "2 files + 3 directories skipped as shared")
        XCTAssertEqual(result.trashedItems, 0, "no file was trashed")
        XCTAssertTrue(result.failedItems.isEmpty)

        let trashed = trash.recorded()
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("tree/dir/a.txt").path))
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("tree/dir/nested/b.bin").path))
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("tree/dir").path),
                       "a directory with shared content must never be trashed")
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("tree").path))
        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordA }, "record A removed after clean skip")
        let settledShared = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settledShared?.status, "committed")
    }

    // MARK: - WP-26: reliable removal regressions (completed, partial, absent, growing, quiescence)

    func testWP26SameSaveLocationWithoutSharedFilesTrashesAllPayloadsAndKeepsOtherTorrent() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-sameloc")

        // Torrent A: multi-file payload in the save location under treeA (e.g. Downloads/treeA/dirA/...).
        let filesA = [("dirA/a.txt", Int64(100)), ("dirA/nested/b.bin", Int64(200))]
        let payloadDirA = saveLocation.appendingPathComponent("treeA")
        try materializePayload(payloadDirA, files: filesA)
        let metainfoA = MetainfoBuilder.multiFile(files: filesA, pieceLength: 256, piecesCount: 1, name: "treeA")
        let recordA = try await addTorrentFile(coordinator, metainfo: metainfoA, saveLocation: saveLocation)

        // Torrent B: unrelated torrent sharing the SAME save location (e.g. Downloads/other.bin).
        let filesB = [("other.bin", Int64(512))]
        try materializePayload(saveLocation, files: filesB)
        let metainfoB = MetainfoBuilder.singleFile(name: "other.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordB = try await addTorrentFile(coordinator, metainfo: metainfoB, saveLocation: saveLocation)

        // Remove Torrent A with deleteFiles = true:
        // Because B's files do not intersect A's files, A's files must NOT be skipped as shared.
        let token = try await prepareRemoval(coordinator, recordID: recordA, deleteFiles: true)
        let manifestPage = try await removalManifestPage(coordinator, token: token)
        XCTAssertEqual(manifestPage.totalCount, 5)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "Torrent A removal must complete successfully")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertEqual(result.trashedItems, 5, "2 files + 3 directories trashed")
        XCTAssertTrue(result.failedItems.isEmpty)

        let trashed = trash.recorded()
        XCTAssertTrue(trashed.contains(saveLocation.appendingPathComponent("treeA/dirA/a.txt").path))
        XCTAssertTrue(trashed.contains(saveLocation.appendingPathComponent("treeA/dirA/nested/b.bin").path))
        XCTAssertTrue(trashed.contains(saveLocation.appendingPathComponent("treeA/dirA/nested").path))
        XCTAssertTrue(trashed.contains(saveLocation.appendingPathComponent("treeA/dirA").path))
        XCTAssertTrue(trashed.contains(saveLocation.appendingPathComponent("treeA").path))
        // Torrent B payload is completely untouched!
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("other.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveLocation.appendingPathComponent("other.bin").path))

        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordA }, "Torrent A record is removed")
        XCTAssertNotNil(snap.torrents.first { $0.id == recordB }, "Torrent B record survives untouched")
    }

    func testWP26PartialPayloadRemovalTrashesSmallerFileWithoutSizeMismatch() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-partial")

        // Metainfo expects 1000 bytes, but only 350 bytes exist on disk (partial download).
        let file = saveLocation.appendingPathComponent("partial.bin")
        try Data(repeating: 0x55, count: 350).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "partial.bin", size: 1000, pieceLength: 256, piecesCount: 4)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "partial file removal must complete without size mismatch")
        XCTAssertEqual(result.trashedItems, 1)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertTrue(trash.recorded().contains(file.path))
    }

    func testWP26AbsentUndownloadedPayloadDoesNotBlockRemoval() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-absent")

        let payloadDir = saveLocation.appendingPathComponent("tree")
        let fileA = payloadDir.appendingPathComponent("dir/present.txt")
        try FileManager.default.createDirectory(at: payloadDir.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 100).write(to: fileA)

        let files = [("dir/present.txt", Int64(100)), ("dir/absent.bin", Int64(200))]
        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 2, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "absent file must not block batch completion")
        XCTAssertEqual(result.trashedItems, 4, "present file + absent file (handled 0-byte) + 2 empty dirs")
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertTrue(trash.recorded().contains(fileA.path))
        XCTAssertTrue(trash.recorded().contains(payloadDir.path))
    }

    func testWP26FileGrowingBetweenPrepareAndCommitIsSafelyTrashed() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-growing")

        let file = saveLocation.appendingPathComponent("growing.bin")
        try Data(repeating: 0x33, count: 100).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "growing.bin", size: 1000, pieceLength: 256, piecesCount: 4)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // File grows between prepare and commit (e.g. engine was downloading before commit).
        // Same file descriptor/inode, size increases from 100 to 250 (still <= 1000).
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x33, count: 150))
        try handle.close()

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "growing file must be safely trashed")
        XCTAssertEqual(result.trashedItems, 1)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertTrue(trash.recorded().contains(file.path))
    }

    func testWP26FileAppearingBetweenPrepareAndCommitIsSafelyTrashed() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-appearing")

        // File does NOT exist at prepare time.
        let file = saveLocation.appendingPathComponent("appearing.bin")
        let metainfo = MetainfoBuilder.singleFile(name: "appearing.bin", size: 500, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // File appears between prepare and commit (created by engine before commit).
        try Data(repeating: 0x77, count: 200).write(to: file)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "file appearing before commit must be safely trashed")
        XCTAssertEqual(result.trashedItems, 1)
        XCTAssertTrue(result.failedItems.isEmpty)
        XCTAssertTrue(trash.recorded().contains(file.path))
    }

    func testWP26MultiFilePayloadUnderNameDirectoryIsFullRemovedAndNotFalselySucceeded() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-multifile-namedir")

        // Files on disk planted at save/name/file (the real libtorrent layout, e.g. Movies/<name>/...).
        let torrentName = "SeriesName"
        let files = [("season1/ep1.mkv", Int64(500)), ("season1/ep2.mkv", Int64(700))]
        let payloadDir = saveLocation.appendingPathComponent(torrentName)
        try materializePayload(payloadDir, files: files)

        let file1Path = payloadDir.appendingPathComponent("season1/ep1.mkv").path
        let file2Path = payloadDir.appendingPathComponent("season1/ep2.mkv").path
        let seasonDir = payloadDir.appendingPathComponent("season1").path

        XCTAssertTrue(FileManager.default.fileExists(atPath: file1Path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2Path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadDir.path))

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 5, name: torrentName)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Manifest must reflect the name directory prefix in its relative paths and payloadRoot
        let tokenRecord = try await store.removalToken(by: token.rawValue)
        let manifest = try JSONDecoder().decode(RemovalManifest.self, from: Data(tokenRecord!.manifestJSON.utf8))
        XCTAssertEqual(manifest.payloadRootPath, payloadDir.standardizedFileURL.path)
        XCTAssertEqual(Set(manifest.entries.filter { $0.kind == .file }.map(\.relativePath)),
                       ["SeriesName/season1/ep1.mkv", "SeriesName/season1/ep2.mkv"])

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.trashedItems, 4, "2 files + season1 dir + SeriesName dir")
        XCTAssertEqual(result.failedItems.count, 0)

        // CRITICAL REGRESSION: files and name directory MUST be trashed from disk.
        // On old join-without-name, files remained at save/name/file while success was falsely reported.
        XCTAssertFalse(FileManager.default.fileExists(atPath: file1Path), "ep1.mkv must be trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2Path), "ep2.mkv must be trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: seasonDir), "season1 dir must be trashed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadDir.path), "empty SeriesName directory must be trashed")

        let trashed = trash.recorded()
        XCTAssertTrue(trashed.contains(file1Path))
        XCTAssertTrue(trashed.contains(file2Path))
        XCTAssertTrue(trashed.contains(seasonDir))
        XCTAssertTrue(trashed.contains(payloadDir.path))

        // Save location (e.g. Movies) MUST NOT be deleted!
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveLocation.path), "saveLocation itself must never be trashed")
    }

    func testWP26RemovalManifestRejectsEscapingOrMultiComponentTorrentName() throws {
        let saveLocation = try profile.subdirectory("sl-name-validation")

        let escapingNames = ["../escape", "a/b", "/absolute", "", ".", "..", "foo/bar/baz"]
        for badName in escapingNames {
            let metainfo = MetainfoBuilder.multiFile(files: [("a.txt", 100)], pieceLength: 256, piecesCount: 1, name: badName)
            let record = TransferRecord(
                id: TorrentRecordID(rawValue: UUID()),
                contentIdentity: ContentIdentity(infoHashV1: nil, infoHashV2: nil),
                displayName: badName,
                desiredState: .paused,
                activity: .idle,
                health: .healthy,
                totalBytes: 100,
                downloadedBytes: 0,
                uploadedBytes: 0,
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                peersConnected: 0,
                seedsTotal: 0,
                engineID: nil,
                metainfoData: metainfo,
                trackerTiers: [],
                fileSelection: [],
                saveLocation: PersistedLocation(path: saveLocation.path),
                addedAt: 0,
                revision: 0
            )

            // Direct builder build rejects escaping/invalid names fail-closed
            XCTAssertThrowsError(try RemovalManifestBuilder.build(record: record, otherPayloadFiles: [], otherPayloadRoots: [])) { error in
                XCTAssertTrue(error is RemovalManifestError)
            }
            XCTAssertEqual(RemovalManifestBuilder.payloadFiles(of: record), [])
            XCTAssertNil(RemovalManifestBuilder.payloadRoot(of: record))
        }
    }

    func testWP26EngineQuiescedBeforePayloadMutation() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, _, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-quiesce")

        let file = saveLocation.appendingPathComponent("payload.bin")
        try Data(repeating: 0x11, count: 100).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 100, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)
        let initialPaused = await engineRef.pausedCount(for: "stub-1")
        XCTAssertEqual(initialPaused, 0)

        // Resuming the torrent while a removal token is pending must be rejected outright
        let resumeAttempt = await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        let resumeFault = try resultFault(from: resumeAttempt)
        XCTAssertEqual(resumeFault.code, .invalidRequest)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed)
        let pausedCount = await engineRef.pausedCount(for: "stub-1")
        XCTAssertEqual(pausedCount, 1, "engine must be paused for quiescence before mutation")
        let removedCount = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removedCount, 1, "engine must be removed after successful completion")
    }

    /// WP-26 fail-closed serialization: a concurrent command interleaved
    /// while `commitRemoval` is suspended must never leave a surviving
    /// engine writer for the removed record. Real routing makes this
    /// reachable: the XPC lane runs every client command as an independent
    /// Task on the same coordinator actor, so a `restartEngineSafely` (or a
    /// resume whose pending-removal guard was passed before prepare) can run
    /// inside the commit's suspension windows. The reproduction drives the
    /// exact window deterministically through actor reentrancy: the commit's
    /// quiesce-pause hook issues `restartEngineSafely`, which invalidates
    /// every engine handle (engineID → nil) and then pumps — and the pump
    /// re-adds the record, whose desiredState is STILL .running (the commit
    /// has not yet persisted or applied the paused state), as a fresh
    /// UNPAUSED engine writer. The commit then resumes with its stale
    /// captured record: it trashes the payload, and the final engine remove
    /// uses the STALE engineID, never touching the re-added writer. A
    /// completed batch must instead leave no un-quiesced writer — an
    /// unpaused writer re-creates the payload root after the Trash.
    func testWP26RestartReaddDuringCommitRemovalNeverLeavesSurvivingWriter() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-restart-readd")

        let file = saveLocation.appendingPathComponent("concurrent.bin")
        try Data(repeating: 0x66, count: 512).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "concurrent.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // The commit's quiesce pause (engine.pause await) suspends the
        // coordinator actor — the exact interleaving point a concurrent
        // client command occupies in real routing. Issue the restart from
        // inside that window: it clears the record's engineID and its pump
        // re-adds the still-running record as a new unpaused writer while
        // the commit holds its stale captured record.
        let restartCommand = encode(.restartEngineSafely(RestartEngineSafelyRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey()
        )))
        let hookProbe = HookFiredProbe()
        let engineReference = engineRef
        await engineReference.setPauseHook {
            await hookProbe.markFired()
            _ = await coordinator.processCommand(restartCommand)
        }
        defer { Task { await engineReference.setPauseHook(nil) } }

        let result = try await commitRemoval(coordinator, token: token)
        let hookFired = await hookProbe.fired
        XCTAssertTrue(hookFired, "the pause-hook reentrancy window must actually run inside commitRemoval")

        let addCount = await engineRef.addCallCount()
        let pausedStub2 = await engineRef.pausedCount(for: "stub-2")
        let removedStub2 = await engineRef.removedCount(for: "stub-2")

        if result.outcome == .completed {
            // The batch settled while a concurrent restart re-added the
            // record's engine handle. A completed removal must leave NO
            // surviving writer: every handle added during the race must
            // have been quiesced (paused or removed) before settling.
            let snap = try await snapshot(coordinator)
            XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record removed after completed batch")
            XCTAssertEqual(trash.recorded().filter { $0 == file.path }.count, 1, "payload trashed exactly once")
            let settled = try await store.removalToken(by: token.rawValue)
            XCTAssertEqual(settled?.status, "committed")
            XCTAssertTrue(
                addCount == 1 || pausedStub2 > 0 || removedStub2 > 0,
                "re-added engine writer stub-2 survived the completed removal batch un-quiesced (addCalls=\(addCount), paused=\(pausedStub2), removed=\(removedStub2)); an unpaused surviving writer re-creates the payload root after the Trash"
            )
        } else {
            // Fail-closed outcome: the token stays pending for an explicit
            // retry — never a settled batch with a live writer.
            let pending = try await store.removalToken(by: token.rawValue)
            XCTAssertEqual(pending?.status, "pending", "failed batch must stay pending for retry")
            XCTAssertNil(pending?.outcomeJSON)
        }
    }

    /// WP-26: An older in-flight admission (add or resume) holding actor suspension points
    /// must establish mutual exclusion BEFORE any filesystem mutation: commitRemoval attempted
    /// during active admission is refused fail-closed with .engineBusy without mutating payload
    /// or settling the token. After admission completes, retry commitRemoval completes successfully.
    func testWP26InFlightAdmissionBlocksCommitRemovalUntilComplete() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let fakeTrashDir = profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)")
        let trash = RecordingTrashProvider(fakeTrashDirectory: fakeTrashDir)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-inflight-admission")

        let file = saveLocation.appendingPathComponent("payload.bin")
        let payloadData = Data(repeating: 0xAB, count: 512)
        try payloadData.write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        // Pause the torrent first so we can drive a deterministic in-flight resume
        let pauseReply = await coordinator.processCommand(encode(.pause(
            PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        _ = try resultPayload(from: pauseReply)

        let hookFiredProbe = HookFiredProbe()
        let hookCompletedProbe = HookFiredProbe()
        let coordinatorRef = coordinator
        let filePath = file.path
        let storeRef = store
        let tokenCell = TokenRefCell()
        let prepareCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.prepareRemoval(
            PrepareRemovalRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                deleteFiles: true
            )
        )))) ?? Data()

        // Set resume hook: when admit() reaches engine.resume(), coordinator suspends.
        // During that suspension window, prepareRemoval and commitRemoval are attempted.
        await engineRef.setResumeHook {
            await hookFiredProbe.markFired()

            // Prepare removal while admission is suspended in engine.resume
            let prepReply = await coordinatorRef.processCommand(prepareCommand)
            let prepEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: prepReply)
            guard case .success(let prepPayload) = prepEnvelope?.result,
                  case .removalToken(let token) = prepPayload else {
                XCTFail("prepareRemoval failed in hook: \(String(describing: prepEnvelope?.result))")
                return
            }
            await tokenCell.setToken(token)

            let commitCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.commitRemoval(
                CommitRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    token: token
                )
            )))) ?? Data()
            let reply = await coordinatorRef.processCommand(commitCommand)
            let commitEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: reply)
            guard case .failure(let fault) = commitEnvelope?.result else {
                XCTFail("expected failure with .engineBusy, got \(String(describing: commitEnvelope?.result))")
                return
            }
            XCTAssertEqual(fault.code, .engineBusy, "commitRemoval during in-flight admission must fail with .engineBusy")
            // Invariant: BEFORE filesystem mutation, payload is untouched
            XCTAssertTrue(FileManager.default.fileExists(atPath: filePath), "payload must not be deleted or moved during in-flight admission")
            let contentOnDisk = try? Data(contentsOf: URL(fileURLWithPath: filePath))
            XCTAssertEqual(contentOnDisk, payloadData, "payload content must remain identical on disk")

            // Trash provider has 0 recorded items
            XCTAssertEqual(trash.recorded().count, 0, "trash provider must have 0 recorded items")

            // Token in store remains 'pending' and unsettled
            let tokenRecord = try? await storeRef.removalToken(by: token.rawValue)
            XCTAssertEqual(tokenRecord?.status, "pending", "removal token must stay pending in store")
            XCTAssertNil(tokenRecord?.outcomeJSON, "removal token outcomeJSON must remain nil")

            await hookCompletedProbe.markFired()
        }
        defer { Task { await engineRef.setResumeHook(nil) } }

        // Trigger resume: will enter admit(), call engine.resume(), and fire the hook
        let resumeReply = await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        _ = try resultPayload(from: resumeReply)

        let hookFired = await hookFiredProbe.fired
        XCTAssertTrue(hookFired, "resume hook must have executed during in-flight admission")
        let hookCompleted = await hookCompletedProbe.fired
        XCTAssertTrue(hookCompleted, "hook assertions must have passed")

        guard let token = await tokenCell.token else {
            XCTFail("removal token was not captured")
            return
        }

        // After admission finishes, retry commitRemoval. It MUST now succeed!
        let retryResult = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(retryResult.outcome, .completed, "retry commitRemoval after admission completed must succeed")
        XCTAssertEqual(retryResult.trashedItems, 1, "payload item must be trashed on retry")

        // Invariant: Observable post-completion filesystem and token state
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "payload must be trashed after completed removal")
        XCTAssertEqual(trash.recorded().filter { $0 == file.path }.count, 1, "payload recorded in trash exactly once")

        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed", "token settled as committed")
        XCTAssertNotNil(settled?.outcomeJSON, "settled token has outcomeJSON")

        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record removed from coordinator snapshot")
    }

    /// WP-26: An in-flight engine.add admission suspending the coordinator must refuse
    /// commitRemoval with .engineBusy before mutating payload or settling. After add finishes,
    /// retrying commitRemoval succeeds.
    func testWP26InFlightAddBlocksCommitRemovalUntilComplete() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let fakeTrashDir = profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)")
        let trash = RecordingTrashProvider(fakeTrashDirectory: fakeTrashDir)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-inflight-add")

        let file = saveLocation.appendingPathComponent("payload-add.bin")
        let payloadData = Data(repeating: 0xCD, count: 512)
        try payloadData.write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "payload-add.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let hookFiredProbe = HookFiredProbe()
        let hookCompletedProbe = HookFiredProbe()
        let coordinatorRef = coordinator
        let filePath = file.path
        let storeRef = store
        let tokenCell = TokenRefCell()

        let prepareCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.prepareRemoval(
            PrepareRemovalRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                deleteFiles: true
            )
        )))) ?? Data()

        // Set add hook: when pumpOnce re-adds the torrent after restart, admit() calls engine.add().
        // While suspended in engine.add, attempt commitRemoval.
        await engineRef.setAddHook {
            await hookFiredProbe.markFired()

            let prepReply = await coordinatorRef.processCommand(prepareCommand)
            let prepEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: prepReply)
            guard case .success(let prepPayload) = prepEnvelope?.result,
                  case .removalToken(let token) = prepPayload else {
                XCTFail("prepareRemoval failed in add hook: \(String(describing: prepEnvelope?.result))")
                return
            }
            await tokenCell.setToken(token)

            let commitCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.commitRemoval(
                CommitRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    token: token
                )
            )))) ?? Data()
            let reply = await coordinatorRef.processCommand(commitCommand)
            let commitEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: reply)
            guard case .failure(let fault) = commitEnvelope?.result else {
                XCTFail("expected failure with .engineBusy during in-flight add, got \(String(describing: commitEnvelope?.result))")
                return
            }
            XCTAssertEqual(fault.code, .engineBusy, "commitRemoval during in-flight add must fail with .engineBusy")

            // Invariant: BEFORE filesystem mutation, payload is untouched
            XCTAssertTrue(FileManager.default.fileExists(atPath: filePath), "payload must not be deleted or moved during in-flight add")
            let contentOnDisk = try? Data(contentsOf: URL(fileURLWithPath: filePath))
            XCTAssertEqual(contentOnDisk, payloadData, "payload content must remain identical on disk")

            // Trash provider has 0 recorded items
            XCTAssertEqual(trash.recorded().count, 0, "trash provider must have 0 recorded items")

            // Token in store remains 'pending' and unsettled
            let tokenRecord = try? await storeRef.removalToken(by: token.rawValue)
            XCTAssertEqual(tokenRecord?.status, "pending", "removal token must stay pending in store")
            XCTAssertNil(tokenRecord?.outcomeJSON, "removal token outcomeJSON must remain nil")

            await hookCompletedProbe.markFired()
        }
        defer { Task { await engineRef.setAddHook(nil) } }

        // Restart engine to trigger pump re-add via engine.add
        let restartCommand = encode(.restartEngineSafely(RestartEngineSafelyRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey()
        )))
        let restartReply = await coordinator.processCommand(restartCommand)
        _ = try resultPayload(from: restartReply)

        let hookFired = await hookFiredProbe.fired
        XCTAssertTrue(hookFired, "add hook must have executed during in-flight add")
        let hookCompleted = await hookCompletedProbe.fired
        XCTAssertTrue(hookCompleted, "add hook assertions must have passed")

        guard let token = await tokenCell.token else {
            XCTFail("removal token was not captured")
            return
        }

        // Retry commitRemoval after add completed: MUST succeed
        let retryResult = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(retryResult.outcome, .completed, "retry commitRemoval after add completed must succeed")
        XCTAssertEqual(retryResult.trashedItems, 1, "payload item must be trashed on retry")

        // Observable post-completion filesystem and token state
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "payload must be trashed after completed removal")
        XCTAssertEqual(trash.recorded().filter { $0 == file.path }.count, 1, "payload recorded in trash exactly once")

        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed", "token settled as committed")
        XCTAssertNotNil(settled?.outcomeJSON, "settled token has outcomeJSON")

        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record removed from coordinator snapshot")
    }

    /// WP-26: The persistence await window in handleCommitRemoval (await moveJournal)
    /// must establish mutual exclusion BEFORE any suspension point: activeCommitRemovals is
    /// captured before await moveJournal, so an admission attempt (e.g. resume) during moveJournal
    /// is refused fail-closed with .engineBusy before mutating payload or admitting a writer.
    func testWP26MoveJournalAwaitWindowBlocksAdmission() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let fakeTrashDir = profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)")
        let trash = RecordingTrashProvider(fakeTrashDirectory: fakeTrashDir)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-movejournal-window")

        let file = saveLocation.appendingPathComponent("payload-movejournal.bin")
        let payloadData = Data(repeating: 0xEE, count: 512)
        try payloadData.write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "payload-movejournal.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let pauseReply = await coordinator.processCommand(encode(.pause(
            PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        _ = try resultPayload(from: pauseReply)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        let hookFiredProbe = HookFiredProbe()
        let hookCompletedProbe = HookFiredProbe()
        let coordinatorRef = coordinator
        let filePath = file.path
        let storeRef = store

        await coordinator.setMoveJournalAwaitHook {
            await hookFiredProbe.markFired()

            let resumeCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.resume(
                ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
            )))) ?? Data()
            let resumeReply = await coordinatorRef.processCommand(resumeCommand)
            let resumeEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: resumeReply)
            guard case .failure(let fault) = resumeEnvelope?.result else {
                XCTFail("expected resume failure with .engineBusy during in-flight moveJournal, got \(String(describing: resumeEnvelope?.result))")
                return
            }
            XCTAssertEqual(fault.code, .engineBusy, "resume during in-flight moveJournal must fail with .engineBusy")

            // Invariant: BEFORE filesystem mutation, payload is untouched
            XCTAssertTrue(FileManager.default.fileExists(atPath: filePath), "payload must not be deleted or moved during in-flight moveJournal")
            let contentOnDisk = try? Data(contentsOf: URL(fileURLWithPath: filePath))
            XCTAssertEqual(contentOnDisk, payloadData, "payload content must remain identical on disk")

            // Trash provider has 0 recorded items
            XCTAssertEqual(trash.recorded().count, 0, "trash provider must have 0 recorded items")

            // Token in store remains 'pending' and unsettled
            let tokenRecord = try? await storeRef.removalToken(by: token.rawValue)
            XCTAssertEqual(tokenRecord?.status, "pending", "removal token must stay pending in store")
            XCTAssertNil(tokenRecord?.outcomeJSON, "removal token outcomeJSON must remain nil")

            await hookCompletedProbe.markFired()
        }
        defer { Task { await coordinator.setMoveJournalAwaitHook(nil) } }

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed, "commitRemoval must complete successfully")
        XCTAssertEqual(result.trashedItems, 1, "payload item must be trashed")

        let hookFired = await hookFiredProbe.fired
        XCTAssertTrue(hookFired, "moveJournal hook must have executed during commitRemoval")
        let hookCompleted = await hookCompletedProbe.fired
        XCTAssertTrue(hookCompleted, "moveJournal hook assertions must have passed")

        // Observable post-completion filesystem and token state
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "payload must be trashed after completed removal")
        XCTAssertEqual(trash.recorded().filter { $0 == file.path }.count, 1, "payload recorded in trash exactly once")

        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed", "token settled as committed")
        XCTAssertNotNil(settled?.outcomeJSON, "settled token has outcomeJSON")

        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record removed from coordinator snapshot")
    }

    /// WP-26: The persistence await window in admit() must establish mutual exclusion BEFORE
    /// any suspension point: activeAdmissions is incremented before any await, so a concurrent
    /// commitRemoval attempted during admit's persistence await is refused with .engineBusy.
    func testWP26AdmitRemovalTokenAwaitWindowBlocksCommitRemoval() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let fakeTrashDir = profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)")
        let trash = RecordingTrashProvider(fakeTrashDirectory: fakeTrashDir)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-admit-window")

        let file = saveLocation.appendingPathComponent("payload-admit-window.bin")
        let payloadData = Data(repeating: 0xBA, count: 512)
        try payloadData.write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "payload-admit-window.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let pauseReply = await coordinator.processCommand(encode(.pause(
            PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        _ = try resultPayload(from: pauseReply)

        let hookFiredProbe = HookFiredProbe()
        let hookCompletedProbe = HookFiredProbe()
        let coordinatorRef = coordinator
        let filePath = file.path
        let storeRef = store
        let tokenCell = TokenRefCell()

        await coordinator.setRemovalTokenAwaitHook {
            await hookFiredProbe.markFired()

            // Prepare and attempt commitRemoval while admit() is suspended in its await window
            let prepareCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.prepareRemoval(
                PrepareRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    recordID: recordID,
                    deleteFiles: true
                )
            )))) ?? Data()
            let prepReply = await coordinatorRef.processCommand(prepareCommand)
            let prepEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: prepReply)
            guard case .success(let prepPayload) = prepEnvelope?.result,
                  case .removalToken(let token) = prepPayload else {
                XCTFail("prepareRemoval failed in admit hook: \(String(describing: prepEnvelope?.result))")
                return
            }
            await tokenCell.setToken(token)

            let commitCommand = (try? JSONEncoder().encode(IPCEnvelope.request(.commitRemoval(
                CommitRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    token: token
                )
            )))) ?? Data()
            let commitReply = await coordinatorRef.processCommand(commitCommand)
            let commitEnvelope = try? JSONDecoder().decode(IPCEnvelope.self, from: commitReply)
            guard case .failure(let fault) = commitEnvelope?.result else {
                XCTFail("expected failure with .engineBusy during in-flight admit await window, got \(String(describing: commitEnvelope?.result))")
                return
            }
            XCTAssertEqual(fault.code, .engineBusy, "commitRemoval during in-flight admit await window must fail with .engineBusy")

            // Invariant: BEFORE filesystem mutation, payload is untouched
            XCTAssertTrue(FileManager.default.fileExists(atPath: filePath), "payload must not be deleted or moved during in-flight admit")
            let contentOnDisk = try? Data(contentsOf: URL(fileURLWithPath: filePath))
            XCTAssertEqual(contentOnDisk, payloadData, "payload content must remain identical on disk")

            // Trash provider has 0 recorded items
            XCTAssertEqual(trash.recorded().count, 0, "trash provider must have 0 recorded items")

            // Token in store remains 'pending' and unsettled
            let tokenRecord = try? await storeRef.removalToken(by: token.rawValue)
            XCTAssertEqual(tokenRecord?.status, "pending", "removal token must stay pending in store")
            XCTAssertNil(tokenRecord?.outcomeJSON, "removal token outcomeJSON must remain nil")

            await hookCompletedProbe.markFired()
        }
        defer { Task { await coordinator.setRemovalTokenAwaitHook(nil) } }

        // Trigger resume: enters admit(), increments activeAdmissions, fires removalTokenAwaitHook
        let resumeReply = await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID)
        )))
        _ = try? resultPayload(from: resumeReply)

        let hookFired = await hookFiredProbe.fired
        XCTAssertTrue(hookFired, "admit await hook must have executed during admit")
        let hookCompleted = await hookCompletedProbe.fired
        XCTAssertTrue(hookCompleted, "admit await hook assertions must have passed")

        guard let token = await tokenCell.token else {
            XCTFail("removal token was not captured")
            return
        }

        // After admission completes, retry commitRemoval. It MUST now succeed!
        let retryResult = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(retryResult.outcome, .completed, "retry commitRemoval after admission completed must succeed")
        XCTAssertEqual(retryResult.trashedItems, 1, "payload item must be trashed on retry")

        // Observable post-completion filesystem and token state
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "payload must be trashed after completed removal")
        XCTAssertEqual(trash.recorded().filter { $0 == file.path }.count, 1, "payload recorded in trash exactly once")

        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed", "token settled as committed")
        XCTAssertNotNil(settled?.outcomeJSON, "settled token has outcomeJSON")

        let snap = try await snapshot(coordinator)
        XCTAssertNil(snap.torrents.first { $0.id == recordID }, "record removed from coordinator snapshot")
    }

    func testWP26FailedEngineStartPreventsTrashAndPreservesRetry() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-failstart")

        let file = saveLocation.appendingPathComponent("important.bin")
        try Data(repeating: 0x99, count: 512).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "important.bin", size: 512, pieceLength: 256, piecesCount: 2)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Inject engine start failure
        await engineRef.setFailStart(true)

        // Commit removal must fail-closed: return an engine fault, NOT trash any files!
        let failReply = await coordinator.processCommand(encode(.commitRemoval(
            CommitRemovalRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), token: token)
        )))
        let failFault = try resultFault(from: failReply)
        XCTAssertEqual(failFault.code, .engineNotReady)

        // Verification: payload was NOT trashed, remains intact on disk
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "payload must not be trashed when engine fails to start")
        XCTAssertEqual(trash.recorded().count, 0, "no files moved to trash")

        // Removal token remains pending in persistent store
        let pendingToken = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(pendingToken?.status, "pending", "token must remain pending for retry")

        // Heal engine start
        await engineRef.setFailStart(false)
        try await engineRef.start(configuration: nil)
        // Retry commit with the same token must now succeed and trash the payload
        let retryResult = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(retryResult.outcome, .completed, "retry after engine healed must complete")
        XCTAssertEqual(retryResult.trashedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "payload now trashed")

        let settledToken = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settledToken?.status, "committed", "token settled as committed")
    }

    func testWP26EnginePauseFailurePreventsTrashAndPreservesRetry() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-wp26-failpause")

        let file = saveLocation.appendingPathComponent("guarded.bin")
        try Data(repeating: 0x88, count: 256).write(to: file)
        let metainfo = MetainfoBuilder.singleFile(name: "guarded.bin", size: 256, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)

        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Inject pause timeout / failure
        await engineRef.failNextPause(with: EngineFault.engineNotReady(details: "quiescence timed out"))

        // Commit removal must fail-closed: return fault, NOT trash files
        let failReply = await coordinator.processCommand(encode(.commitRemoval(
            CommitRemovalRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), token: token)
        )))
        let failFault = try resultFault(from: failReply)
        XCTAssertEqual(failFault.code, .engineNotReady)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "payload must not be trashed when pause fails")
        XCTAssertEqual(trash.recorded().count, 0)
        let pendingToken = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(pendingToken?.status, "pending", "token stays pending for retry")

        // Retry succeeds
        let retryResult = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(retryResult.outcome, .completed)
        XCTAssertEqual(retryResult.trashedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testWP26UnavailableRootAndPermissionDeniedRefuseRemoval() throws {
        let root = try profile.subdirectory("sl-wp26-errors")
        let nonExistentRoot = "/tmp/nonexistent-root-\(UUID().uuidString)"

        // Unavailable root
        let rootIssue = FileSafetyValidator.verifyChain(root: nonExistentRoot, absolutePath: "\(nonExistentRoot)/file.bin")
        XCTAssertEqual(rootIssue, .unavailableRoot(nonExistentRoot))

        let manifest = RemovalManifest(
            saveLocationPath: nonExistentRoot,
            payloadRootPath: nonExistentRoot,
            entries: [
                RemovalManifestItem(
                    relativePath: "file.bin",
                    sizeBytes: 100,
                    kind: .file,
                    isShared: false,
                    fileIdentity: nil
                )
            ]
        )
        let trashService = TrashService()
        let trashOutcome = trashService.trash(entry: manifest.entries[0], manifest: manifest)
        XCTAssertEqual(trashOutcome, TrashOutcome.failed(TrashItemFailure(
            code: "unavailable_root",
            message: "payload root unavailable at \(nonExistentRoot)"
        )), "unavailable root must be reported as failure, never as trashed")

        // Permission denied
        let restrictedDir = root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: restrictedDir, withIntermediateDirectories: true)
        let restrictedFile = restrictedDir.appendingPathComponent("secret.bin")
        try Data([0x01]).write(to: restrictedFile)

        // Make restrictedDir unreadable / unsearchable
        Darwin.chmod(restrictedDir.path, 0o000)
        defer { Darwin.chmod(restrictedDir.path, 0o755) }

        let permIssue = FileSafetyValidator.verifyChain(root: root.path, absolutePath: restrictedFile.path)
        XCTAssertEqual(permIssue, .permissionDenied(restrictedFile.path))

        let restrictedManifest = RemovalManifest(
            saveLocationPath: root.path,
            payloadRootPath: root.path,
            entries: [
                RemovalManifestItem(
                    relativePath: "restricted/secret.bin",
                    sizeBytes: 1,
                    kind: .file,
                    isShared: false,
                    fileIdentity: nil
                )
            ]
        )
        let permOutcome = trashService.trash(entry: restrictedManifest.entries[0], manifest: restrictedManifest)
        XCTAssertEqual(permOutcome, TrashOutcome.failed(TrashItemFailure(
            code: "permission_denied",
            message: "permission denied at \(restrictedFile.path)"
        )), "permission error must be reported as failure, never as trashed")
    }

    // MARK: - WP-10: FileSafetyValidator (symlink / TOCTOU / size)

    func testWP10SafetyValidatorRefusesSymlinksMissingItemsAndSizeChanges() throws {
        let root = try profile.subdirectory("sl-safety")
        let dir = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("payload.bin")
        try Data(repeating: 0x11, count: 64).write(to: file)

        // Healthy chain verifies clean.
        XCTAssertNil(FileSafetyValidator.verifyChain(root: root.path, absolutePath: file.path))
        XCTAssertNil(FileSafetyValidator.verifyFileIdentity(absolutePath: file.path, expectedSize: 64))
        XCTAssertNil(FileSafetyValidator.verifyDirectoryIdentity(absolutePath: dir.path))

        // A symlink in the middle of the chain is refused (lstat, no follow).
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertEqual(
            FileSafetyValidator.verifyChain(root: root.path, absolutePath: link.appendingPathComponent("x").path),
            .symlink(link.path),
            "a symlinked directory must be refused before any mutation"
        )

        // Symlink leaf refused for both files and directories.
        XCTAssertEqual(FileSafetyValidator.verifyFileIdentity(absolutePath: link.path, expectedSize: 64), .symlink(link.path))
        XCTAssertEqual(FileSafetyValidator.verifyDirectoryIdentity(absolutePath: link.path), .symlink(link.path))

        // Missing leaf.
        XCTAssertEqual(
            FileSafetyValidator.verifyFileIdentity(absolutePath: dir.appendingPathComponent("gone.bin").path, expectedSize: 1),
            .missing
        )

        // Size mismatch (item changed since prepare) refuses the mutation.
        XCTAssertEqual(
            FileSafetyValidator.verifyFileIdentity(absolutePath: file.path, expectedSize: 63),
            .sizeMismatch(expected: 63, actual: 64)
        )

        // A path escaping the root is refused outright.
        XCTAssertEqual(FileSafetyValidator.verifyChain(root: root.path, absolutePath: "/etc/hosts"), .symlink("/etc/hosts"))
    }

    // MARK: - WP-10: durable storage move

    func testWP10MoveStorageUpdatesSaveLocationDurablyAndRechecks() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-move-from")
        let to = try profile.subdirectory("sl-move-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x22, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Move through the engine; the destination directory is created by the
        // coordinator, the journal row is dropped on success, and a force
        // recheck validates the moved payload.
        let reply = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        let payloadResult = try resultPayload(from: reply)
        guard case .ack = payloadResult else {
            return XCTFail("unexpected \(payloadResult)")
        }

        let snap = try await snapshot(coordinator)
        let entry = snap.torrents.first { $0.id == recordID }
        XCTAssertEqual(entry?.saveLocation.path, URL(fileURLWithPath: to.path).standardizedFileURL.path,
                       "record save location must be durably updated")

        let moveCalls = await engineRef.moveCalls()
        XCTAssertEqual(moveCalls.count, 1)
        XCTAssertEqual(moveCalls.first?.torrentID, "stub-1")
        XCTAssertEqual(moveCalls.first?.destinationPath, to.path)
        let recheckCount = await engineRef.recheckCount(for: "stub-1")
        XCTAssertEqual(recheckCount, 1, "force recheck after move")

        let journalAfterMove = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfterMove, "journal row dropped on success")

        // A second move to the same destination is rejected as a no-op.
        let again = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        XCTAssertThrowsError(try resultPayload(from: again))
    }

    func testWP10MoveStorageEngineFailureLeavesJournalForRecovery() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-move-fail-from")
        let to = try profile.subdirectory("sl-move-fail-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x33, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        await engineRef.setFailMoveStorage(true)
        let reply = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        XCTAssertThrowsError(try resultPayload(from: reply))

        // The journal row stays at 'prepared'/'failed' — evidence for recovery.
        let row = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNotNil(row, "failed move must leave a journal row")
        XCTAssertEqual(row?.status, MoveJournalEntry.Status.failed.rawValue)

        // Record and save location unchanged.
        let snap = try await snapshot(coordinator)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path)
    }

    func testWP10MoveStorageAdmissionReadFailureAbortsBeforeMove() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-move-admission-fault-from")
        let to = try profile.subdirectory("sl-move-admission-fault-to")
        try Data(repeating: 0x34, count: 128).write(to: from.appendingPathComponent("payload.bin"))

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 128, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // The journal admission lookup is unreadable, so the coordinator must
        // fail closed instead of treating the missing result as no in-flight move.
        try await store.close(clean: false)
        let reply = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        let fault = try resultFault(from: reply)
        XCTAssertEqual(fault.code, .storeError)
        XCTAssertEqual(fault.affectedRecord, recordID)
        let admissionMoveCalls = await engineRef.moveCalls()
        XCTAssertTrue(admissionMoveCalls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent("payload.bin").path))
        let snap = try await snapshot(coordinator)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path)
        await store.rawClose()
    }

    func testWP10MoveStorageRecheckFailureLeavesJournalForRecovery() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-move-recheck-fault-from")
        let to = try profile.subdirectory("sl-move-recheck-fault-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x35, count: 128).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 128, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)
        await engineRef.setFailRecheck(true)

        let reply = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        let fault = try resultFault(from: reply)
        XCTAssertEqual(fault.code, .engineBusy)

        let row = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertEqual(row?.stage, MoveJournalEntry.Stage.engineMoved.rawValue)
        XCTAssertEqual(row?.status, MoveJournalEntry.Status.pending.rawValue)
        let snapBeforeRecovery = try await snapshot(coordinator)
        XCTAssertEqual(snapBeforeRecovery.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: to.path).standardizedFileURL.path)
        let recheckCount = await engineRef.recheckCount(for: "stub-1")
        XCTAssertEqual(recheckCount, 0)

        // The stub failed before moving bytes; supply the evidence that a real
        // engine could have left behind, then verify recovery converges.
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: payload, to: to.appendingPathComponent("payload.bin"))
        try await store.close(clean: false)
        await store.rawClose()

        let reopened = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await reopened.open()
        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: reopened,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()
        let journalAfterRecovery = try await reopened.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfterRecovery)
        let recovered = try await snapshot(restarted)
        XCTAssertEqual(recovered.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: to.path).standardizedFileURL.path)
    }

    func testWP10MoveStorageJournalDeletionFailureLeavesRowForRecovery() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-move-delete-fault-from")
        let to = try profile.subdirectory("sl-move-delete-fault-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x36, count: 128).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 128, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)
        await engineRef.setRecheckHook { [store, from, to] in
            // Make the test stub's successful engine move observable at the
            // exact boundary before coordinator journal cleanup.
            try? FileManager.default.moveItem(
                at: from.appendingPathComponent("payload.bin"),
                to: to.appendingPathComponent("payload.bin")
            )
            try? await store.close(clean: false)
        }

        let reply = await coordinator.processCommand(encode(.moveStorage(MoveStorageRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            destination: PersistedLocation(path: to.path)
        ))))
        let fault = try resultFault(from: reply)
        XCTAssertEqual(fault.code, .storeError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent("payload.bin").path))
        let moveCalls = await engineRef.moveCalls()
        XCTAssertEqual(moveCalls.count, 1)
        let recheckCount = await engineRef.recheckCount(for: "stub-1")
        XCTAssertEqual(recheckCount, 1)

        // The closed store is reopened like a new agent process. The journal
        // row must survive the failed drop and the next recovery pass must
        // remove only that durable evidence, without another engine move.
        await store.rawClose()
        let reopened = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await reopened.open()
        let journalBeforeRecovery = try await reopened.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNotNil(journalBeforeRecovery)
        let restartedEngine = StubTransferEngine()
        let restarted = TransferCoordinator(
            engine: restartedEngine,
            persistence: reopened,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()
        let journalAfterRecovery = try await reopened.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfterRecovery)
        let restartedMoveCalls = await restartedEngine.moveCalls()
        XCTAssertTrue(restartedMoveCalls.isEmpty)
        let recovered = try await snapshot(restarted)
        XCTAssertEqual(recovered.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: to.path).standardizedFileURL.path)
    }

    // MARK: - WP-10: move crash recovery (evidence-based, no silent auto-resume)

    func testWP10MoveRecoveryResumesInterruptedMove() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-recover-from")
        let to = try profile.subdirectory("sl-recover-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x44, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Simulate a crash AFTER the engine moved the payload: journal row at
        // stage engine_moved, the payload REALLY sits at the destination,
        // record not yet updated.
        let seq = try await store.moveJournalCreate(
            recordID: recordID.rawValue.uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"payload.bin\"]",
            startedAt: Self.nowMilliseconds()
        )
        try await store.moveJournalUpdate(
            seq: seq,
            stage: MoveJournalEntry.Stage.engineMoved.rawValue,
            status: MoveJournalEntry.Status.pending.rawValue,
            failureReason: nil,
            updatedAt: Self.nowMilliseconds()
        )
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: from.appendingPathComponent("payload.bin"),
            to: to.appendingPathComponent("payload.bin")
        )

        // Restart: a fresh coordinator over the same store recovers the move.
        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()

        let snap = try await snapshot(restarted)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: to.path).standardizedFileURL.path,
                       "interrupted move resumes to the destination")
        let journalAfterResume = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfterResume, "resumed journal row dropped")
    }

    func testWP10MoveRecoveryRollsBackNeverStartedMove() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-rollback-from")
        let to = try profile.subdirectory("sl-rollback-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x55, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Crash BEFORE the engine move was issued: stage prepared, origin
        // intact, destination never created → rollback-noop.
        _ = try await store.moveJournalCreate(
            recordID: recordID.rawValue.uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"payload.bin\"]",
            startedAt: Self.nowMilliseconds()
        )

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()

        let snap = try await snapshot(restarted)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path,
                       "never-started move keeps the origin save location")
        let journalAfterRollback = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfterRollback, "never-started move journal row is dropped (noop)")
    }

    func testWP10MoveRecoveryGuidedKeepsJournalWhenEvidenceAmbiguous() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-guided-from")
        // The destination is deliberately NEVER created on disk: the engine
        // move was issued (per the journal) but no evidence exists at the
        // destination → guided recovery.
        let to = profile.rootURL.appendingPathComponent("sl-guided-missing")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0x66, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Crash AFTER the engine move was issued but the destination is MISSING
        // on disk: ambiguous evidence — guided recovery, journal row kept.
        let seq = try await store.moveJournalCreate(
            recordID: recordID.rawValue.uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"payload.bin\"]",
            startedAt: Self.nowMilliseconds()
        )
        try await store.moveJournalUpdate(
            seq: seq,
            stage: MoveJournalEntry.Stage.engineMoved.rawValue,
            status: MoveJournalEntry.Status.pending.rawValue,
            failureReason: nil,
            updatedAt: Self.nowMilliseconds()
        )

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()

        // No silent decision: journal row stays for the user to resolve.
        let journalAfterGuided = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNotNil(journalAfterGuided, "ambiguous move evidence must remain for guided recovery")
        let snap = try await snapshot(restarted)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path,
                       "guided recovery never rewrites the record")
    }

    func testWP10MoveRecoverySymlinkPayloadEvidenceStaysGuided() throws {
        let from = try profile.subdirectory("sl-symlink-evidence-from")
        let to = profile.rootURL.appendingPathComponent("sl-symlink-evidence-to")
        let decoy = try profile.subdirectory("sl-symlink-evidence-decoy")
        try Data(repeating: 0x68, count: 64).write(to: from.appendingPathComponent("payload.bin"))
        try FileManager.default.createSymbolicLink(at: to, withDestinationURL: decoy)

        let entry = MoveJournalEntry(
            seq: 1,
            recordID: UUID().uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"payload.bin\"]",
            stage: MoveJournalEntry.Stage.engineMoved.rawValue,
            status: MoveJournalEntry.Status.pending.rawValue,
            startedAt: Self.nowMilliseconds(),
            updatedAt: Self.nowMilliseconds(),
            failureReason: nil
        )

        guard case .guided(_, _, _, let reason) = MoveStorageRecovery.recommendation(for: entry) else {
            return XCTFail("symlink destination evidence must never produce resume")
        }
        XCTAssertTrue(reason.contains("lacks the payload"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: from.appendingPathComponent("payload.bin").path))
    }

    // MARK: - WP-10 (Gate 1): manifest-scoped trash only

    func testWP10UnmanifestedSiblingSurvivesDirectoryTrash() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-sibling")
        let payloadDir = saveLocation.appendingPathComponent("tree")
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // A file that is NOT part of the torrent lands in the manifest dir
        // before the commit (the Gate 1 scenario the review called out).
        let sibling = payloadDir.appendingPathComponent("dir/unmanifested.bin")
        try Data(repeating: 0xEE, count: 333).write(to: sibling)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.trashedItems, 1, "only the manifested file was trashed")
        XCTAssertTrue(result.failedItems.contains { $0.relativePath == "tree/dir" && $0.code == "not_empty" },
                      "the parent dir must refuse to be trashed while it holds the sibling")
        XCTAssertTrue(result.failedItems.contains { $0.relativePath == "tree" && $0.code == "not_empty" })

        // The manifested file is gone; the unmanifested sibling survives.
        XCTAssertFalse(FileManager.default.fileExists(atPath: payloadDir.appendingPathComponent("dir/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path),
                      "unmanifested content inside a manifest dir must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadDir.appendingPathComponent("dir").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadDir.path))
        // Record kept, token pending for guided recovery.
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 0)
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
    }

    // MARK: - WP-10 (Gate 7): TOCTOU / identity refusal before any mutation

    func testWP10AncestorSymlinkSwapRefusedBeforeAnyMutation() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-swap")
        let payloadDir = saveLocation.appendingPathComponent("tree")
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Attacker swap: the payload ROOT becomes a symlink to another
        // directory between prepare and commit.
        let decoy = try profile.subdirectory("sl-swap-decoy")
        try FileManager.default.removeItem(at: payloadDir)
        try FileManager.default.createSymbolicLink(at: payloadDir, withDestinationURL: decoy)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(trash.recorded().count, 0, "no mutation may reach the provider")
        XCTAssertTrue(result.failedItems.allSatisfy { $0.code == "unsafe_symlink" },
                      "every item must refuse on the swapped chain: \(result.failedItems)")
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
    }

    func testWP10SameSizeReplacementRefusedByIdentity() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-replace")
        let files = [("a.bin", Int64(100))]
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.singleFile(name: "a.bin", size: 100, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Same-size replacement: different inode, identical byte count — the
        // classic TOCTOU swap a size-only check cannot catch.
        let file = saveLocation.appendingPathComponent("a.bin")
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x77, count: 100).write(to: file)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(trash.recorded().count, 0, "replacement must never be trashed")
        XCTAssertEqual(result.failedItems.first?.code, "identity_changed")
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
    }

    func testWP10HardlinkSwapRefusedByIdentity() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-hardlink")
        let files = [("a.bin", Int64(100))]
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.singleFile(name: "a.bin", size: 100, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // A second hardlink to the same inode: the link count changes, which
        // proves the file is referenced elsewhere — refuse before mutation.
        let file = saveLocation.appendingPathComponent("a.bin")
        try FileManager.default.linkItem(
            at: file,
            to: saveLocation.appendingPathComponent("elsewhere.bin")
        )

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(trash.recorded().count, 0, "hardlinked file must never be trashed")
        XCTAssertEqual(result.failedItems.first?.code, "identity_changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
    }

    // MARK: - WP-10 (Gate 8): journal failures are fail-closed

    func testWP10JournalAppendFailureAbortsBatchBeforeAnyMutation() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-appendfail")
        let payloadDir = saveLocation.appendingPathComponent("tree")
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        FailpointInjector.arm(.beforeTrashJournalAppend) { _ in
            throw PersistenceError.injectedFailpoint(FailpointID.beforeTrashJournalAppend)
        }
        do {
            _ = try await commitRemoval(coordinator, token: token)
            XCTFail("journal append failure must abort the batch")
        } catch {}
        FailpointInjector.disarmAll()

        XCTAssertEqual(trash.recorded().count, 0, "no mutation may proceed without a durable journal row")
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertTrue(journal.isEmpty)
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 0)
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
    }

    func testWP10JournalUpdateFailureAbortsFailClosedAndResumes() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-updatefail")
        let payloadDir = saveLocation.appendingPathComponent("tree")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        try materializePayload(payloadDir, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Crash after the FIRST item was trashed but before its journal row
        // could be marked: the batch aborts with a typed failure.
        let throwOnce = ThrowFirst(n: 1)
        FailpointInjector.arm(.beforeTrashJournalUpdate) { _ in
            try throwOnce.fire()
        }
        do {
            _ = try await commitRemoval(coordinator, token: token)
            XCTFail("journal update failure must abort the batch")
        } catch {}
        FailpointInjector.disarmAll()

        // Fail-closed: the durable state says exactly "one item trashed, row
        // pending" — never a removed record without a settled outcome.
        XCTAssertEqual(trash.recorded().count, 1)
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")

        // Resume: the pending row's item was already moved, so it reports a
        // trash failure; the remaining items are processed and journaled, and
        // the now-empty directories trash normally.
        let resumed = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(resumed.outcome, .partial)
        XCTAssertEqual(resumed.trashedItems, 4, "a.txt + tree/dir/nested + tree/dir + tree trashed on resume")
        XCTAssertTrue(resumed.failedItems.contains { $0.relativePath == "tree/dir/nested/b.bin" },
                      "already-moved item surfaces as a typed failure, never silently lost")
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journal.count, 6, "1 row from the aborted attempt + 5 rows appended on resume")
    }

    func testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-settlefail")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        let payloadDir = saveLocation.appendingPathComponent("tree")
        try materializePayload(payloadDir, files: files)
        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Crash at the settle boundary: payload fully trashed, outcome never
        // durably settled.
        FailpointInjector.arm(.beforeRemovalTokenSettle) { _ in
            throw PersistenceError.injectedFailpoint(FailpointID.beforeRemovalTokenSettle)
        }
        do {
            _ = try await commitRemoval(coordinator, token: token)
            XCTFail("settlement failure must abort fail-closed")
        } catch {}
        FailpointInjector.disarmAll()

        XCTAssertEqual(trash.recorded().count, 5, "payload fully trashed")
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID }, "record kept on settle failure")
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 0, "engine remove must not fire without a settled outcome")
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
        XCTAssertNil(tokenRow?.outcomeJSON)
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journal.count, 5)
        XCTAssertTrue(journal.allSatisfy { $0.status == TrashJournalEntry.Status.trashed.rawValue })

        // Restart: the pending token is restored and ENUMERABLE by the UI
        // (Gate 4/9 fetchPendingRemovals), then an explicit resume finishes.
        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path),
            trashProvider: trash
        )
        await restarted.restoreFromPersistence()

        let pendingReply = await restarted.processCommand(encode(.fetchPendingRemovals(
            FetchPendingRemovalsRequest(requestID: RequestID())
        )))
        let pendingPayload = try resultPayload(from: pendingReply)
        guard case .pendingRemovals(let summaries) = pendingPayload else {
            return XCTFail("unexpected \(pendingPayload)")
        }
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.token, token)
        XCTAssertEqual(summaries.first?.recordID, recordID)
        XCTAssertEqual(summaries.first?.deleteFiles, true)
        XCTAssertEqual(summaries.first?.totalItemCount, 5)
        XCTAssertEqual(summaries.first?.trashedItemCount, 5)
        XCTAssertEqual(summaries.first?.failedItemCount, 0)

        let resumed = try await commitRemoval(restarted, token: token)
        XCTAssertEqual(resumed.outcome, .completed)
        XCTAssertEqual(resumed.trashedItems, 5, "resume counts journaled rows, never re-trashes")
        XCTAssertEqual(trash.recorded().count, 5)
        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed")
        let snapAfter = try await snapshot(restarted)
        XCTAssertNil(snapAfter.torrents.first { $0.id == recordID })
    }

    func testWP10PendingRemovalRestoreDoesNotAutoResume() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-no-auto-resume")
        let payload = saveLocation.appendingPathComponent("payload.bin")
        try Data(repeating: 0x7C, count: 128).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 128, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)
        trash.fail(path: payload.path)

        let first = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(first.outcome, .failed)
        XCTAssertTrue(trash.recorded().isEmpty)

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path),
            trashProvider: trash
        )
        await restarted.restoreFromPersistence()

        XCTAssertTrue(trash.recorded().isEmpty, "restore must not auto-resume a pending removal")
        let snap = try await snapshot(restarted)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID })
        let pendingReply = await restarted.processCommand(encode(.fetchPendingRemovals(
            FetchPendingRemovalsRequest(requestID: RequestID())
        )))
        let pendingPayload = try resultPayload(from: pendingReply)
        guard case .pendingRemovals(let summaries) = pendingPayload else {
            return XCTFail("unexpected \(pendingPayload)")
        }
        XCTAssertEqual(summaries.map(\.token), [token])
        XCTAssertEqual(summaries.first?.failedItemCount, 1)
    }

    func testWP10CommittedOutcomeReplayRepairsRecordAfterSettlementCrash() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let saveLocation = try profile.subdirectory("sl-settled-repair")
        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 1, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: false)

        // Simulate a crash after durable settle and before record cleanup.
        let settledOutcome = RemovalBatchResult(
            recordID: recordID,
            token: token,
            outcome: .completed,
            trashedItems: 0,
            skippedSharedItems: 0,
            failedItems: []
        )
        let outcomeJSON = String(
            data: try JSONEncoder().encode(settledOutcome),
            encoding: .utf8
        )!
        try await store.settleRemovalToken(
            token: token.rawValue,
            status: "committed",
            outcomeJSON: outcomeJSON,
            at: Self.nowMilliseconds()
        )

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()
        let snapBeforeReplay = try await snapshot(restarted)
        XCTAssertNotNil(snapBeforeReplay.torrents.first { $0.id == recordID })

        let replay = try await commitRemoval(restarted, token: token)
        XCTAssertEqual(replay, settledOutcome, "replay must return the durable outcome byte-for-byte")
        let snapAfterReplay = try await snapshot(restarted)
        XCTAssertNil(
            snapAfterReplay.torrents.first { $0.id == recordID },
            "settled replay must converge by removing the leftover record"
        )
        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed")
    }

    // MARK: - WP-10 (Gate 5): move recovery requires payload evidence

    func testWP10MoveRecoveryDestinationWithoutPayloadIsNotResume() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-evidence-from")
        let to = try profile.subdirectory("sl-evidence-to")
        let payload = from.appendingPathComponent("payload.bin")
        try Data(repeating: 0xAA, count: 512).write(to: payload)

        let metainfo = MetainfoBuilder.singleFile(name: "payload.bin", size: 512, pieceLength: 256, piecesCount: 1)
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Crash AFTER the engine move was issued, but the destination holds NO
        // payload (empty dir left by an interrupted move). Directory existence
        // is NOT evidence: recovery must not adopt an empty destination.
        let seq = try await store.moveJournalCreate(
            recordID: recordID.rawValue.uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"payload.bin\"]",
            startedAt: Self.nowMilliseconds()
        )
        try await store.moveJournalUpdate(
            seq: seq,
            stage: MoveJournalEntry.Stage.engineMoved.rawValue,
            status: MoveJournalEntry.Status.pending.rawValue,
            failureReason: nil,
            updatedAt: Self.nowMilliseconds()
        )
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()

        let snap = try await snapshot(restarted)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path,
                       "an empty destination must never be adopted as success")
        let journalAfter = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNil(journalAfter, "origin intact + empty destination is a rollback-noop")
    }

    func testWP10MoveRecoverySplitPayloadStaysGuided() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus)
        let from = try profile.subdirectory("sl-split-from")
        let to = try profile.subdirectory("sl-split-to")
        let files = [("a.bin", Int64(100)), ("b.bin", Int64(200))]
        try materializePayload(from, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "pair")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: from)

        // Split crash: ONE file reached the destination, the other stayed at
        // the origin. Neither side holds the full payload — evidence is
        // ambiguous, so recovery stays guided and touches nothing.
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: from.appendingPathComponent("a.bin"),
            to: to.appendingPathComponent("a.bin")
        )
        let seq = try await store.moveJournalCreate(
            recordID: recordID.rawValue.uuidString,
            fromPath: from.path,
            toPath: to.path,
            fileListJSON: "[\"a.bin\",\"b.bin\"]",
            startedAt: Self.nowMilliseconds()
        )
        try await store.moveJournalUpdate(
            seq: seq,
            stage: MoveJournalEntry.Stage.engineMoved.rawValue,
            status: MoveJournalEntry.Status.pending.rawValue,
            failureReason: nil,
            updatedAt: Self.nowMilliseconds()
        )

        let restarted = TransferCoordinator(
            engine: StubTransferEngine(),
            persistence: store,
            eventBus: TransferEventBus(flushIntervalMilliseconds: 0),
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        await restarted.restoreFromPersistence()

        let journalAfterSplit = try await store.moveJournal(recordID: recordID.rawValue.uuidString)
        XCTAssertNotNil(journalAfterSplit,
                        "split payload evidence must stay for guided recovery")
        let snap = try await snapshot(restarted)
        XCTAssertEqual(snap.torrents.first { $0.id == recordID }?.saveLocation.path,
                       URL(fileURLWithPath: from.path).standardizedFileURL.path,
                       "guided recovery never rewrites the record")
    }
}

// MARK: - Actor-safe hook firing probe (pause-hook reentrancy tests)

private actor HookFiredProbe {
    private(set) var fired = false

    func markFired() {
        fired = true
    }
}

private actor TokenRefCell {
    private(set) var token: RemovalToken?

    func setToken(_ token: RemovalToken) {
        self.token = token
    }
}

// MARK: - Deterministic throw-once helper (Gate 8 journal-update tests)

private final class ThrowFirst: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(n: Int) {
        remaining = n
    }

    func fire() throws {
        lock.lock()
        defer { lock.unlock() }
        if remaining > 0 {
            remaining -= 1
            throw PersistenceError.injectedFailpoint(FailpointID.beforeTrashJournalUpdate)
        }
    }
}

// MARK: - Recording / failing trash provider (no real Trash in tests)

/// Records trashed paths AND physically moves the item into a scratch
/// directory, so directory-emptiness semantics (Gate 1) behave exactly like
/// the real Finder Trash: children leave first, then the directory is empty
/// and trashable; unmanifested/shared siblings keep it non-empty and safe.
private final class RecordingTrashProvider: TrashProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let fakeTrashDirectory: URL
    private var trashedPaths: [String] = []
    private var failedPaths: Set<String> = []
    private var failAll = false

    init(fakeTrashDirectory: URL) {
        self.fakeTrashDirectory = fakeTrashDirectory
    }

    func moveToTrash(at absolutePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if failAll || failedPaths.contains(absolutePath) {
            throw NSError(
                domain: "RecordingTrashProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "injected trash failure"]
            )
        }
        try FileManager.default.createDirectory(
            at: fakeTrashDirectory,
            withIntermediateDirectories: true
        )
        let source = URL(fileURLWithPath: absolutePath)
        var destination = fakeTrashDirectory.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            destination = fakeTrashDirectory.appendingPathComponent(
                ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            )
            counter += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
        trashedPaths.append(absolutePath)
    }

    func fail(path: String) {
        lock.lock()
        defer { lock.unlock() }
        failedPaths.insert(path)
    }

    func failEverything() {
        lock.lock()
        defer { lock.unlock() }
        failAll = true
    }

    func recorded() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return trashedPaths
    }
}
