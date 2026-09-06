// Layer: Agent integration tests (WP-23 Add pipeline: confirm-before-download).
// Role: validate mandatory saveLocation, admission priorities vector, durable file selection,
// restore ordering, corrupt payload fallback, and truthful progress without synthesis.

import Foundation
import XCTest
import TorrentinoIPC
@testable import TorrentinoEngineAgent

final class WP23AddPipelineAgentTests: TestProfileCase {

    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []

        func record(_ call: String) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(call)
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    private func makeCoordinator(
        engine: TransferEngine = StubTransferEngine(),
        bus: TransferEventBus = TransferEventBus(flushIntervalMilliseconds: 0),
        store: PersistenceStore? = nil
    ) async throws -> (TransferCoordinator, PersistenceStore) {
        let actualStore: PersistenceStore
        if let store {
            actualStore = store
        } else {
            let s = PersistenceStore(dataDirectory: profile.rootURL)
            _ = try await s.open()
            actualStore = s
        }
        let coordinator = TransferCoordinator(
            engine: engine,
            persistence: actualStore,
            eventBus: bus,
            agentVersion: "test",
            defaultSaveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        return (coordinator, actualStore)
    }

    private func inspect(
        _ coordinator: TransferCoordinator,
        source: AddSource
    ) async throws -> AddSourceInspection {
        let request = InspectAddSourceRequest(requestID: RequestID(), source: source)
        let reply = await coordinator.processCommand(encode(.inspectAddSource(request)))
        let payload = try resultPayload(from: reply)
        guard case .addSourceInspection(let inspection) = payload else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "expected inspectAddSource result"])
        }
        return inspection
    }

    private func encode(_ command: EngineCommandV1) -> Data {
        (try? JSONEncoder().encode(IPCEnvelope.request(command))) ?? Data()
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            fatalError("decode failed: \(error)")
        }
    }

    private func resultPayload(from data: Data) throws -> SuccessPayload {
        let envelope = decode(IPCEnvelope.self, from: data)
        guard let result = envelope.result else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "no result in envelope"])
        }
        switch result {
        case .success(let payload):
            return payload
        case .failure(let fault):
            throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "fault \(fault.code.rawValue) \(fault.redactedContext ?? "")"])
        }
    }

    // MARK: - WP23 Tests

    /// 1. commitAdd without saveLocation -> typed fault invalidPayload("saveLocation is required")
    func testWP23CommitWithoutSaveLocationFailsTyped() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.singleFile(name: "mandatory.bin", size: 1024, pieceLength: 256, piecesCount: 1)
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))

        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: nil
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        let envelope = decode(IPCEnvelope.self, from: reply)

        guard let result = envelope.result, case .failure(let fault) = result else {
            return XCTFail("expected failure when saveLocation is nil, got success")
        }
        XCTAssertEqual(fault.code, EngineErrorCode.invalidPayload)
        XCTAssertTrue(fault.redactedContext?.contains("saveLocation is required") == true, "fault context should state saveLocation is required")
    }

    /// 2. commitAdd with saveLocation + selection -> spec carries full metainfo-ordered priorities vector (engine spy asserts vector and add called exactly once)
    func testWP23CommitWithSelectionAppliesPrioritiesVectorAtAdd() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 100), ("dir/b.bin", 200), ("dir/c.dat", 300)],
            pieceLength: 256,
            piecesCount: 1,
            name: "multi"
        )
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))

        let selection: [FileSelectionItem] = [
            FileSelectionItem(relativePath: "dir/a.txt", priority: .normal),
            FileSelectionItem(relativePath: "dir/b.bin", priority: .skip),
            FileSelectionItem(relativePath: "dir/c.dat", priority: .normal),
        ]

        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: selection
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        guard case .commitAdd = try resultPayload(from: reply) else {
            return XCTFail("expected commitAdd success")
        }

        // Assert engine spy received spec with exact priorities vector: skip=0, normal=4
        let addCalls = await engine.addCallCount()
        XCTAssertEqual(addCalls, 1, "engine.add must be called exactly once")

        let spec = await engine.lastAddSpecification()
        XCTAssertNotNil(spec, "lastAddSpecification must exist")
        XCTAssertEqual(spec?.filePriorities, [4, 0, 4], "priorities vector must match metainfo order: [4, 0, 4]")
    }

    /// Commit with empty selection -> spec priorities vector all zeros, effectiveTotalBytes is 0
    func testWP23CommitWithEmptySelectionProducesAllZerosVectorAndZeroBytes() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 100), ("dir/b.bin", 200), ("dir/c.dat", 300)],
            pieceLength: 256,
            piecesCount: 1,
            name: "empty-selection"
        )
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))

        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: []
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        guard case .commitAdd(let addResult) = try resultPayload(from: reply) else {
            return XCTFail("expected commitAdd success")
        }

        let spec = await engine.lastAddSpecification()
        XCTAssertNotNil(spec, "lastAddSpecification must exist")
        XCTAssertEqual(spec?.filePriorities, [0, 0, 0], "empty selection must produce vector with all zeros")

        let record = await coordinator.record(for: addResult.recordID)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.totalBytes, 0, "effective total bytes must be 0 for empty selection")
    }

    /// Unmapped file defaults to 0 (default-deny)
    func testWP23CommitWithUnmappedFileDefaultsToZero() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 100), ("dir/b.bin", 200), ("dir/c.dat", 300)],
            pieceLength: 256,
            piecesCount: 1,
            name: "unmapped-test"
        )
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))

        // Only dir/a.txt is normal, dir/b.bin is skip; dir/c.dat is unmapped (not in array)
        let selection: [FileSelectionItem] = [
            FileSelectionItem(relativePath: "dir/a.txt", priority: .normal),
            FileSelectionItem(relativePath: "dir/b.bin", priority: .skip),
        ]

        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: selection
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        guard case .commitAdd(let addResult) = try resultPayload(from: reply) else {
            return XCTFail("expected commitAdd success")
        }

        let spec = await engine.lastAddSpecification()
        XCTAssertNotNil(spec, "lastAddSpecification must exist")
        XCTAssertEqual(spec?.filePriorities, [4, 0, 0], "unmapped file dir/c.dat must default to priority 0")

        let record = await coordinator.record(for: addResult.recordID)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.totalBytes, 100, "effective total bytes must only count normal priority files")
    }

    /// Commit with one checked file downloads exactly that file (vector has 4 only at its index)
    func testWP23CommitWithOneCheckedFileDownloadsExactlyThatFile() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/a.txt", 100), ("dir/b.bin", 200), ("dir/c.dat", 300)],
            pieceLength: 256,
            piecesCount: 1,
            name: "single-checked"
        )
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))

        // User checked ONLY dir/b.bin. All other files are not in selection (or skip)
        let selection: [FileSelectionItem] = [
            FileSelectionItem(relativePath: "dir/b.bin", priority: .normal),
        ]

        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: selection
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(commit)))
        guard case .commitAdd(let addResult) = try resultPayload(from: reply) else {
            return XCTFail("expected commitAdd success")
        }

        let spec = await engine.lastAddSpecification()
        XCTAssertNotNil(spec, "lastAddSpecification must exist")
        XCTAssertEqual(spec?.filePriorities, [0, 4, 0], "priorities vector must have 4 only at dir/b.bin index")

        let record = await coordinator.record(for: addResult.recordID)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.totalBytes, 200, "effective total bytes must equal exactly the checked file's size")
    }

    /// 3. setFileSelection durable round-trip: write -> new coordinator instance restoreFromPersistence -> record.fileSelection equals stored
    func testWP23SetFileSelectionDurableRoundTrip() async throws {
        let engine = StubTransferEngine()
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let (coordinator1, _) = try await makeCoordinator(engine: engine, store: store)

        let torrent = MetainfoBuilder.multiFile(
            files: [("dir/1.bin", 100), ("dir/2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "persist"
        )
        let inspection = try await inspect(coordinator1, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path)
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator1.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        let updatedSelection: [FileSelectionItem] = [
            FileSelectionItem(relativePath: "dir/1.bin", priority: .skip),
            FileSelectionItem(relativePath: "dir/2.bin", priority: .normal),
        ]
        let setReply = await coordinator1.processCommand(encode(.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: addResult.recordID,
                selection: updatedSelection,
                expectedRevision: 0
            )
        )))
        XCTAssertEqual(try resultPayload(from: setReply), SuccessPayload.ack)

        // Drop coordinator1 and create coordinator2 sharing the same store.
        let engine2 = StubTransferEngine()
        let (coordinator2, _) = try await makeCoordinator(engine: engine2, store: store)
        await coordinator2.restoreFromPersistence()

        let restoredRecord = await coordinator2.record(for: addResult.recordID)
        XCTAssertNotNil(restoredRecord, "restored record must exist in coordinator2")
        let storedSelection = updatedSelection.map { RecordFileSelection(relativePath: $0.relativePath, priority: $0.priority) }
        XCTAssertEqual(Set(restoredRecord?.fileSelection ?? []), Set(storedSelection), "persisted file selection must match stored selection")
    }

    /// 4. corrupt selection payload -> restore falls back to legacy default (all normal, spec filePriorities omitted), record still rebuilt
    func testWP23CorruptSelectionPayloadFallsBackTolerantly() async throws {
        let engine = StubTransferEngine()
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let (coordinator1, _) = try await makeCoordinator(engine: engine, store: store)

        let torrent = MetainfoBuilder.multiFile(
            files: [("corrupt1.bin", 100), ("corrupt2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "corrupt"
        )
        let inspection = try await inspect(coordinator1, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: [
                FileSelectionItem(relativePath: "corrupt1.bin", priority: .normal),
                FileSelectionItem(relativePath: "corrupt2.bin", priority: .skip),
            ],
            startPaused: false
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator1.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        // Corrupt the file selection session value in SQLite
        let key = "torrent_file_selection.\(addResult.recordID.rawValue.uuidString)"
        let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33])
        try await store.setSessionValue(key: key, data: garbage)

        // Restore in new coordinator
        let engine2 = StubTransferEngine()
        let (coordinator2, _) = try await makeCoordinator(engine: engine2, store: store)
        await coordinator2.restoreFromPersistence()
        await coordinator2.pumpOnce()

        let snapshotReply = await coordinator2.processCommand(encode(.fetchSnapshot(
            FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil)
        )))
        guard case .snapshot(let snapshot) = try resultPayload(from: snapshotReply) else {
            return XCTFail("fetchSnapshot failed")
        }
        guard let restoredSnapshot = snapshot.torrents.first(where: { $0.id == addResult.recordID }) else {
            return XCTFail("record must be rebuilt even when file selection payload is corrupt")
        }
        XCTAssertEqual(restoredSnapshot.id, addResult.recordID)
        // R1 / R3: rebuilt record's effective behavior is the chosen legacy default (all-normal), NOT skip-all
        XCTAssertEqual(restoredSnapshot.progress.totalBytes, 300, "corrupt selection must fall back to all-normal full size, not 0")

        let restoredRecord = await coordinator2.record(for: addResult.recordID)
        XCTAssertNotNil(restoredRecord)
        XCTAssertEqual(restoredRecord?.totalBytes, 300)
        XCTAssertEqual(restoredRecord?.fileSelection, [], "fileSelection projection must match chosen encoding []")
        // Assert engine2 received add spec with filePriorities omitted (nil)
        let lastSpec = await engine2.lastAddSpecification()
        XCTAssertNotNil(lastSpec)
        XCTAssertNil(lastSpec?.filePriorities, "re-add spec must omit filePriorities (nil) for corrupt/legacy fallback")
    }

    /// 5. real restore test: coordinator 1 commits with explicit selection; coordinator 2 restores from persistence
    /// Assert engine.add spec carries exact stored priorities vector, and NO resume is called on the re-add path.
    func testWP23RestoredRunningRecordAppliesPrioritiesBeforeResume() async throws {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let engine1 = StubTransferEngine()
        let (coordinator1, _) = try await makeCoordinator(engine: engine1, store: store)

        let torrent = MetainfoBuilder.multiFile(
            files: [("file1.bin", 100), ("file2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "order-test"
        )
        let inspection = try await inspect(coordinator1, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: [
                FileSelectionItem(relativePath: "file1.bin", priority: .skip),
                FileSelectionItem(relativePath: "file2.bin", priority: .normal),
            ],
            startPaused: false
        )
        guard case .commitAdd(_) = try resultPayload(from: await coordinator1.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        // Coordinator 2 restores the running record from the same persistence store.
        let engine2 = StubTransferEngine()
        let callLog = CallLog()
        await engine2.setFileSelectionHook {
            callLog.record("setFileSelection")
        }
        await engine2.setResumeHook {
            callLog.record("resume")
        }

        let (coordinator2, _) = try await makeCoordinator(engine: engine2, store: store)
        await coordinator2.restoreFromPersistence()
        await coordinator2.pumpOnce()

        // Assert re-add specification carried exact stored priorities vector [0, 4]
        let spec = await engine2.lastAddSpecification()
        XCTAssertNotNil(spec, "re-add specification must exist")
        XCTAssertEqual(spec?.filePriorities, [0, 4], "engine.add spec must carry exact stored priorities vector")
        XCTAssertEqual(spec?.paused, false, "restored running record must be re-added unpaused")

        // Assert NO resume was called on the restore re-add path
        let calls = callLog.snapshot()
        XCTAssertFalse(calls.contains("resume"), "no resume call expected on the restore re-add path: \(calls)")
    }

    /// 5b. live-handle resume path: paused live handle receives setFileSelection BEFORE resume
    func testWP23LiveHandleResumedAppliesPrioritiesBeforeResume() async throws {
        let engine = StubTransferEngine()
        let callLog = CallLog()
        await engine.setFileSelectionHook {
            callLog.record("setFileSelection")
        }
        await engine.setResumeHook {
            callLog.record("resume")
        }

        let (coordinator, _) = try await makeCoordinator(engine: engine)

        let torrent = MetainfoBuilder.multiFile(
            files: [("file1.bin", 100), ("file2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "live-order-test"
        )
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: [
                FileSelectionItem(relativePath: "file1.bin", priority: .skip),
                FileSelectionItem(relativePath: "file2.bin", priority: .normal),
            ],
            startPaused: true
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        // Now resume the already-admitted live handle (engineID is non-nil).
        _ = try resultPayload(from: await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID)
        ))))

        let calls = callLog.snapshot()
        guard let fileIdx = calls.firstIndex(of: "setFileSelection"),
              let resumeIdx = calls.firstIndex(of: "resume") else {
            return XCTFail("expected both setFileSelection and resume in call log, got: \(calls)")
        }
        XCTAssertLessThan(fileIdx, resumeIdx, "setFileSelection must be called BEFORE resume on live handle")
    }

    /// 5c. legacy record without stored selection row restores all-normal and downloads (spec filePriorities nil/absent)
    func testWP23LegacyRecordWithoutSelectionRowRestoresAllNormal() async throws {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let engine1 = StubTransferEngine()
        let (coordinator1, _) = try await makeCoordinator(engine: engine1, store: store)

        let torrent = MetainfoBuilder.multiFile(
            files: [("leg1.bin", 100), ("leg2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "legacy-test"
        )
        let inspection = try await inspect(coordinator1, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            startPaused: false
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator1.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        // Simulate legacy record by removing the selection session value row
        let key = "torrent_file_selection.\(addResult.recordID.rawValue.uuidString)"
        try await store.removeSessionValue(key: key)
        let checkAbsent = try await store.torrentFileSelection(torrentID: addResult.recordID.rawValue.uuidString)
        XCTAssertNil(checkAbsent, "selection row must be absent to simulate legacy record")

        // Restore with coordinator 2
        let engine2 = StubTransferEngine()
        let (coordinator2, _) = try await makeCoordinator(engine: engine2, store: store)
        await coordinator2.restoreFromPersistence()
        await coordinator2.pumpOnce()

        let record = await coordinator2.record(for: addResult.recordID)
        XCTAssertNotNil(record, "legacy record must restore successfully")
        XCTAssertEqual(record?.totalBytes, 300, "legacy record must count all files (full size)")
        XCTAssertEqual(record?.fileSelection, [], "legacy record projection is []")

        let spec = await engine2.lastAddSpecification()
        XCTAssertNotNil(spec, "re-add spec must exist")
        XCTAssertNil(spec?.filePriorities, "legacy record must omit filePriorities (nil -> engine all-normal default)")
        XCTAssertEqual(spec?.paused, false, "legacy running record must be re-added unpaused")
        XCTAssertEqual(record?.desiredState, .running, "legacy running record must have desiredState .running")
        XCTAssertEqual(record?.activity, .checking, "restored running record starts in checking bootstrap activity")
    }

    /// 5d. commit persists a distinguishable explicit row even when selection is empty (R1c)
    func testWP23CommitPersistsDistinguishableExplicitRowEvenWhenSelectionIsEmpty() async throws {
        let store = PersistenceStore(dataDirectory: profile.rootURL)
        _ = try await store.open()
        let engine1 = StubTransferEngine()
        let (coordinator1, _) = try await makeCoordinator(engine: engine1, store: store)

        let torrent = MetainfoBuilder.multiFile(
            files: [("empty1.bin", 100), ("empty2.bin", 200)],
            pieceLength: 256,
            piecesCount: 1,
            name: "empty-persist"
        )
        let inspection = try await inspect(coordinator1, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: profile.rootURL.path),
            fileSelection: [],
            startPaused: false
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator1.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }

        // R1c: the store MUST contain a distinguishable explicit row
        let stored = try await store.torrentFileSelection(torrentID: addResult.recordID.rawValue.uuidString)
        XCTAssertNotNil(stored, "a distinguishable row must be persisted even when selection is empty")
        XCTAssertEqual(stored?.count, 2, "stored selection should map all files in metainfo")
        XCTAssertTrue(stored?.allSatisfy({ $0.priority == .skip }) == true, "all files should be explicitly marked as skip")

        // When restored in coordinator 2, it restores with strict default-deny (all-skip), NOT legacy all-normal
        let engine2 = StubTransferEngine()
        let (coordinator2, _) = try await makeCoordinator(engine: engine2, store: store)
        await coordinator2.restoreFromPersistence()
        await coordinator2.pumpOnce()

        let restored = await coordinator2.record(for: addResult.recordID)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.totalBytes, 0, "explicit empty selection must restore with 0 totalBytes")
        let spec = await engine2.lastAddSpecification()
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.filePriorities, [0, 0], "explicit empty selection must re-add with all-zero vector, not nil")
    }

    /// 7. duplicate commit with a different save location -> typed volumeUnavailable fault (moveStorage recovery), no second engine.add
    func testWP23CommitDuplicateWithDifferentSaveLocationFailsVolumeUnavailable() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)
        let dirA = try profile.subdirectory("wp23-diverge-a")
        let dirB = try profile.subdirectory("wp23-diverge-b")

        let torrent = MetainfoBuilder.singleFile(name: "dup-loc.bin", size: 1024, pieceLength: 256, piecesCount: 1)
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))
        let first = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: dirA.path)
        )
        guard case .commitAdd(let firstResult) = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(first)))) else {
            return XCTFail("first commitAdd failed")
        }
        let firstAddCalls = await engine.addCallCount()
        XCTAssertEqual(firstAddCalls, 1)

        let inspection2 = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))
        let second = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection2.operationID,
            saveLocation: PersistedLocation(path: dirB.path)
        )
        let reply = await coordinator.processCommand(encode(.commitAdd(second)))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: reply).result else {
            return XCTFail("duplicate commit with a different save location must fail, got success")
        }
        XCTAssertEqual(fault.code, EngineErrorCode.volumeUnavailable)
        XCTAssertEqual(fault.affectedRecord, firstResult.recordID)
        let dupAddCalls = await engine.addCallCount()
        XCTAssertEqual(dupAddCalls, 1, "diverged duplicate must not silently re-add elsewhere")
    }

    /// 7b. live handle whose engine save_path diverges from the record -> resume fails typed volumeUnavailable, health waitingForVolume, no re-add
    func testWP23LiveHandleSavePathDivergenceFailsResumeWithVolumeUnavailable() async throws {
        let engine = StubTransferEngine()
        let (coordinator, _) = try await makeCoordinator(engine: engine)
        let dirA = try profile.subdirectory("wp23-livediverge-a")
        let dirB = try profile.subdirectory("wp23-livediverge-b")

        let torrent = MetainfoBuilder.singleFile(name: "live-diverge.bin", size: 1024, pieceLength: 256, piecesCount: 1)
        let inspection = try await inspect(coordinator, source: AddSource.torrentFileData(torrent))
        let commit = CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: inspection.operationID,
            saveLocation: PersistedLocation(path: dirA.path),
            startPaused: true
        )
        guard case .commitAdd(let addResult) = try resultPayload(from: await coordinator.processCommand(encode(.commitAdd(commit)))) else {
            return XCTFail("commitAdd failed")
        }
        let pausedAddCalls = await engine.addCallCount()
        XCTAssertEqual(pausedAddCalls, 1)

        // The live handle now reports a save_path that diverges from the record.
        await engine.setStatuses([TransferTorrentStatus(
            engineID: "stub-1",
            progressFraction: 0,
            downloadedBytes: 0,
            uploadedBytes: 0,
            downloadBytesPerSec: 0,
            uploadBytesPerSec: 0,
            peersConnected: 0,
            seedsTotal: 0,
            activity: .idle,
            health: .healthy,
            etaSeconds: nil,
            metadataName: nil,
            totalBytes: 1024,
            savePath: dirB.path
        )])
        await coordinator.pumpOnce()

        let reply = await coordinator.processCommand(encode(.resume(
            ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: addResult.recordID)
        )))
        guard case .failure(let fault) = decode(IPCEnvelope.self, from: reply).result else {
            return XCTFail("resume with diverged live save_path must fail, got success")
        }
        XCTAssertEqual(fault.code, EngineErrorCode.volumeUnavailable)
        let record = await coordinator.record(for: addResult.recordID)
        XCTAssertEqual(record?.health, .waitingForVolume)
        let finalAddCalls = await engine.addCallCount()
        XCTAssertEqual(finalAddCalls, 1, "diverged live handle must not be silently re-added elsewhere")
    }

    /// 6. applying(status:) honesty: no synthesized total, isCompleted false while downloadRate > 0, true only at seeding with downloaded >= total
    func testWP23TruthfulProgressHonesty() {
        let record = TransferRecord(
            id: TorrentRecordID(rawValue: UUID()),
            contentIdentity: ContentIdentity(infoHashV1: Data(repeating: 0xaa, count: 20), infoHashV2: nil),
            displayName: "Test",
            desiredState: .running,
            activity: .downloading,
            health: TorrentHealth.healthy,
            totalBytes: 500,
            downloadedBytes: 100,
            uploadedBytes: 0,
            downloadBytesPerSec: 50,
            uploadBytesPerSec: 0,
            peersConnected: 2,
            seedsTotal: 1,
            engineID: "e1",
            metainfoData: nil,
            trackerTiers: [],
            fileSelection: [],
            saveLocation: PersistedLocation(path: "/tmp"),
            addedAt: 1234567890,
            revision: 1
        )

        // A. No synthesized total: metainfo absent, status.totalBytes == -1
        let statusSentinel = TransferTorrentStatus(
            engineID: "e1",
            progressFraction: 0.5,
            downloadedBytes: 250,
            uploadedBytes: 0,
            downloadBytesPerSec: 100,
            uploadBytesPerSec: 0,
            peersConnected: 1,
            seedsTotal: 1,
            activity: .downloading,
            health: TorrentHealth.healthy,
            etaSeconds: nil,
            metadataName: nil,
            totalBytes: -1
        )
        let updatedA = record.applying(statusSentinel, health: .healthy)
        // totalBytes must stay 500, NOT synthesized as 250 / 0.5
        XCTAssertEqual(updatedA.totalBytes, 500, "totalBytes must NOT be synthesized from downloaded / fraction")
        XCTAssertEqual(updatedA.downloadedBytes, 250)

        // B. isCompleted is FALSE while activity is .downloading (even if downloaded >= total)
        let statusDownloadingFull = TransferTorrentStatus(
            engineID: "e1",
            progressFraction: 1.0,
            downloadedBytes: 500,
            uploadedBytes: 0,
            downloadBytesPerSec: 200,
            uploadBytesPerSec: 0,
            peersConnected: 3,
            seedsTotal: 2,
            activity: .downloading,
            health: TorrentHealth.healthy,
            etaSeconds: nil,
            metadataName: nil,
            totalBytes: 500
        )
        let updatedB = record.applying(statusDownloadingFull, health: .healthy)
        XCTAssertEqual(updatedB.downloadedBytes, 500)
        XCTAssertEqual(updatedB.totalBytes, 500)
        XCTAssertFalse(updatedB.isCompleted, "isCompleted must be false while torrent is actively downloading")

        // C. isCompleted is TRUE only when activity == .seeding or .idle with downloaded >= total
        let statusSeeding = TransferTorrentStatus(
            engineID: "e1",
            progressFraction: 1.0,
            downloadedBytes: 500,
            uploadedBytes: 50,
            downloadBytesPerSec: 0,
            uploadBytesPerSec: 10,
            peersConnected: 2,
            seedsTotal: 1,
            activity: .seeding,
            health: TorrentHealth.healthy,
            etaSeconds: nil,
            metadataName: nil,
            totalBytes: 500
        )
        let updatedC = record.applying(statusSeeding, health: .healthy)
        XCTAssertTrue(updatedC.isCompleted, "isCompleted must be true when activity is .seeding and downloaded >= total")

        // D. Sentinel for downloadedBytes (< 0) keeps previous downloadedBytes
        let statusDownloadedSentinel = TransferTorrentStatus(
            engineID: "e1",
            progressFraction: 0.8,
            downloadedBytes: -1,
            uploadedBytes: 0,
            downloadBytesPerSec: 0,
            uploadBytesPerSec: 0,
            peersConnected: 0,
            seedsTotal: 0,
            activity: .idle,
            health: TorrentHealth.healthy,
            etaSeconds: nil,
            metadataName: nil,
            totalBytes: 500
        )
        let updatedD = record.applying(statusDownloadedSentinel, health: .healthy)
        XCTAssertEqual(updatedD.downloadedBytes, 100, "sentinel downloadedBytes must preserve previous value")
    }
}
