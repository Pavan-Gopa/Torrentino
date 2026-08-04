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
                       ["dir/a.txt", "dir/nested/b.bin"])
        XCTAssertEqual(manifest.saveLocationPath, URL(fileURLWithPath: saveLocation.path).standardizedFileURL.path)

        // The manifest page serves the durable manifest (shared flags are
        // settled at prepare time and reflected in the commit outcome).
        let page = try await removalManifestPage(coordinator, token: token)
        XCTAssertEqual(page.totalCount, 4, "2 files + 2 directories")
        XCTAssertEqual(page.items.map(\.relativePath), ["dir/nested/b.bin", "dir/a.txt", "dir/nested", "dir"],
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

    // MARK: - WP-10: commit — full success path

    func testWP10CommitRemovalTrashesEveryManifestItemAndRemovesRecord() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-commit")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.trashedItems, 4, "2 files + 2 directories, all trashed")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertTrue(result.failedItems.isEmpty)

        // Every manifest path was offered to the trash provider, in order.
        let trashed = trash.recorded()
        XCTAssertEqual(trashed, [
            saveLocation.appendingPathComponent("dir/nested/b.bin").path,
            saveLocation.appendingPathComponent("dir/a.txt").path,
            saveLocation.appendingPathComponent("dir/nested").path,
            saveLocation.appendingPathComponent("dir").path,
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
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // First item in trash order fails → partial outcome with journal
        // evidence. The failed file stays on disk, so its parent directories
        // are NOT empty and refuse to be trashed (Gate 1).
        trash.fail(path: saveLocation.appendingPathComponent("dir/nested/b.bin").path)
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.trashedItems, 1, "only a.txt was trashed")
        XCTAssertEqual(result.skippedSharedItems, 0)
        XCTAssertEqual(result.failedItems.count, 3, "b.bin + dir/nested + dir (not empty)")
        XCTAssertEqual(result.failedItems.first?.relativePath, "dir/nested/b.bin")
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
        XCTAssertEqual(journal.count, 4, "journal rows survive a partial removal")
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
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        trash.failEverything()
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.trashedItems, 0)
        XCTAssertEqual(result.failedItems.count, 4, "every manifest item failed")

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
        XCTAssertEqual(journalAfterTotal.count, 4)
        XCTAssertTrue(journalAfterTotal.allSatisfy { $0.status == TrashJournalEntry.Status.failed.rawValue })
    }

    // MARK: - WP-10: shared-path protection

    func testWP10SharedPathRemovalSkipsFilesSharedWithAnotherTorrent() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, _) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-shared")

        // Torrent A: multi-file payload in the save location.
        let filesA = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        try materializePayload(saveLocation, files: filesA)
        let metainfoA = MetainfoBuilder.multiFile(files: filesA, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordA = try await addTorrentFile(coordinator, metainfo: metainfoA, saveLocation: saveLocation)

        // Torrent B: a second torrent sharing the SAME save location — its
        // payload root covers A's paths, so A's files are shared/untouchable.
        try materializePayload(saveLocation, files: [("other.bin", Int64(512))])
        let metainfoB = MetainfoBuilder.singleFile(name: "other.bin", size: 512, pieceLength: 256, piecesCount: 1)
        _ = try await addTorrentFile(coordinator, metainfo: metainfoB, saveLocation: saveLocation)

        // The manifest flags the shared files (settled at prepare time, before
        // any commit) — the commit below must skip exactly those paths.
        let token = try await prepareRemoval(coordinator, recordID: recordA, deleteFiles: true)
        _ = try await removalManifestPage(coordinator, token: token)

        // Commit: shared items are skipped (never trashed). The directories
        // still hold the shared files, so they are NOT empty and refuse to be
        // trashed (Gate 1) — the batch is partial, the record is kept, and the
        // token stays pending for guided recovery. Never a silent full delete
        // of a directory that other torrents' data lives in.
        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .failed, "nothing trashed: both dirs hold shared data")
        XCTAssertEqual(result.skippedSharedItems, 2)
        XCTAssertEqual(result.trashedItems, 0, "no file was trashed; both dirs hold shared data")
        XCTAssertEqual(result.failedItems.count, 2)
        XCTAssertTrue(result.failedItems.allSatisfy { $0.code == "not_empty" })

        let trashed = trash.recorded()
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("dir/a.txt").path))
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("dir/nested/b.bin").path))
        XCTAssertFalse(trashed.contains(saveLocation.appendingPathComponent("dir").path),
                       "a directory with shared content must never be trashed")

        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordA }, "record A kept for guided recovery")
        let settledShared = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settledShared?.status, "pending")
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

    // MARK: - WP-10 (Gate 1): manifest-scoped trash only

    func testWP10UnmanifestedSiblingSurvivesDirectoryTrash() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-sibling")
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // A file that is NOT part of the torrent lands in the manifest dir
        // before the commit (the Gate 1 scenario the review called out).
        let sibling = saveLocation.appendingPathComponent("dir/unmanifested.bin")
        try Data(repeating: 0xEE, count: 333).write(to: sibling)

        let result = try await commitRemoval(coordinator, token: token)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.trashedItems, 1, "only the manifested file was trashed")
        XCTAssertTrue(result.failedItems.contains { $0.relativePath == "dir" && $0.code == "not_empty" },
                      "the parent dir must refuse to be trashed while it holds the sibling")

        // The manifested file is gone; the unmanifested sibling survives.
        XCTAssertFalse(FileManager.default.fileExists(atPath: saveLocation.appendingPathComponent("dir/a.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path),
                      "unmanifested content inside a manifest dir must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saveLocation.appendingPathComponent("dir").path))

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
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(saveLocation, files: files)

        let metainfo = MetainfoBuilder.multiFile(files: files, pieceLength: 256, piecesCount: 1, name: "tree")
        let recordID = try await addTorrentFile(coordinator, metainfo: metainfo, saveLocation: saveLocation)
        let token = try await prepareRemoval(coordinator, recordID: recordID, deleteFiles: true)

        // Attacker swap: the payload ROOT becomes a symlink to another
        // directory between prepare and commit.
        let decoy = try profile.subdirectory("sl-swap-decoy")
        try FileManager.default.removeItem(at: saveLocation)
        try FileManager.default.createSymbolicLink(at: saveLocation, withDestinationURL: decoy)

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
        let files = [("dir/a.txt", Int64(100))]
        try materializePayload(saveLocation, files: files)

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
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        try materializePayload(saveLocation, files: files)

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
        XCTAssertEqual(resumed.trashedItems, 3, "a.txt + dir/nested + dir trashed on resume")
        XCTAssertTrue(resumed.failedItems.contains { $0.relativePath == "dir/nested/b.bin" },
                      "already-moved item surfaces as a typed failure, never silently lost")
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journal.count, 5, "1 row from the aborted attempt + 4 rows appended on resume")
    }

    func testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart() async throws {
        let engine = StubTransferEngine()
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let trash = RecordingTrashProvider(fakeTrashDirectory: profile.rootURL.appendingPathComponent("fake-trash-\(UUID().uuidString)"))
        let (coordinator, store, engineRef) = try await makeCoordinator(engine: engine, bus: bus, trashProvider: trash)
        let saveLocation = try profile.subdirectory("sl-settlefail")
        let files = [("dir/a.txt", Int64(100)), ("dir/nested/b.bin", Int64(200))]
        try materializePayload(saveLocation, files: files)

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

        XCTAssertEqual(trash.recorded().count, 4, "payload fully trashed")
        let snap = try await snapshot(coordinator)
        XCTAssertNotNil(snap.torrents.first { $0.id == recordID }, "record kept on settle failure")
        let removed = await engineRef.removedCount(for: "stub-1")
        XCTAssertEqual(removed, 0, "engine remove must not fire without a settled outcome")
        let tokenRow = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(tokenRow?.status, "pending")
        XCTAssertNil(tokenRow?.outcomeJSON)
        let journal = try await store.trashJournalEntries(token: token.rawValue)
        XCTAssertEqual(journal.count, 4)
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
        XCTAssertEqual(summaries.first?.totalItemCount, 4)
        XCTAssertEqual(summaries.first?.trashedItemCount, 4)
        XCTAssertEqual(summaries.first?.failedItemCount, 0)

        let resumed = try await commitRemoval(restarted, token: token)
        XCTAssertEqual(resumed.outcome, .completed)
        XCTAssertEqual(resumed.trashedItems, 4, "resume counts journaled rows, never re-trashes")
        XCTAssertEqual(trash.recorded().count, 4)
        let settled = try await store.removalToken(by: token.rawValue)
        XCTAssertEqual(settled?.status, "committed")
        let snapAfter = try await snapshot(restarted)
        XCTAssertNil(snapAfter.torrents.first { $0.id == recordID })
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
