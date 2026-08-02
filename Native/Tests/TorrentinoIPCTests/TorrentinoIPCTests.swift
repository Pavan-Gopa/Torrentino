// Layer: Unit tests (TorrentinoIPC contract v1, WP-05).
// Role: versioned envelopes, EngineCommandV1/EngineEventV1 round-trips,
// identity model, pagination, settings transaction, handshake negotiation,
// idempotency, reconciliation, reconnect policy — happy / error / edge.
// Must-not: open XPC connections or touch production Application Support.
// ADR-010: negative/fuzz for parsers; concurrency stress.

import XCTest
@testable import TorrentinoIPC

final class TorrentinoIPCTests: TestProfileCase {

    // MARK: - IPCVersion

    func testCurrentVersionIs1_0() {
        XCTAssertEqual(IPCVersion.current.major, 1)
        XCTAssertEqual(IPCVersion.current.minor, 0)
        XCTAssertEqual(IPCVersion.current.description, "1.0")
    }

    func testVersionOrderingComparable() {
        let v10 = IPCVersion(major: 1, minor: 0)
        let v11 = IPCVersion(major: 1, minor: 1)
        let v20 = IPCVersion(major: 2, minor: 0)
        let v00 = IPCVersion(major: 0, minor: 9)
        XCTAssertTrue(v10 < v11)
        XCTAssertTrue(v11 < v20)
        XCTAssertTrue(v00 < v10)
        XCTAssertFalse(v20 < v10)
        XCTAssertEqual(v10, IPCVersion.current)
    }

    func testVersionBackwardCompatLogicViaEnvelope() {
        // Same major → compatible and structurally valid; higher major → fault.
        let request = { (version: IPCVersion) in
            IPCEnvelope.request(.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: 0)), version: version)
        }
        XCTAssertTrue(request(IPCVersion(major: 1, minor: 9)).isCompatibleWithCurrent)
        XCTAssertNil(request(IPCVersion(major: 1, minor: 9)).validate())

        XCTAssertTrue(request(IPCVersion(major: 1, minor: 0)).isCompatibleWithCurrent)
        XCTAssertNil(request(IPCVersion(major: 1, minor: 0)).validate())

        let nextMajor = request(IPCVersion(major: 2, minor: 0))
        XCTAssertFalse(nextMajor.isCompatibleWithCurrent)
        XCTAssertEqual(nextMajor.validate(), EnvelopeValidationError.incompatibleVersion(IPCVersion(major: 2, minor: 0)))

        let zeroMajor = request(IPCVersion(major: 0, minor: 1))
        XCTAssertFalse(zeroMajor.isCompatibleWithCurrent)
    }

    func testVersionCodableRoundTrip() throws {
        let v = IPCVersion(major: 3, minor: 7)
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(IPCVersion.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    func testVersionParsingFromAdvertisedString() {
        XCTAssertEqual(IPCVersion(parsing: "1.0"), IPCVersion.current)
        XCTAssertEqual(IPCVersion(parsing: "2.14"), IPCVersion(major: 2, minor: 14))
        XCTAssertNil(IPCVersion(parsing: "1"))
        XCTAssertNil(IPCVersion(parsing: "1.0.1"))
        XCTAssertNil(IPCVersion(parsing: "v1.0"))
        XCTAssertNil(IPCVersion(parsing: ""))
    }

    // MARK: - Identity model (plan §7.1)

    func testTorrentRecordIDRoundTripAndDescription() throws {
        let id = TorrentRecordID(rawValue: UUID())
        XCTAssertEqual(id.description, id.rawValue.uuidString)
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(TorrentRecordID.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testContentIdentityRoundTripHybrid() throws {
        let identity = ContentIdentity(
            infoHashV1: Data([0xAB, 0xCD, 0xEF]),
            infoHashV2: Data([0x01, 0x02, 0x03, 0x04])
        )
        XCTAssertTrue(identity.isKnown)
        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(ContentIdentity.self, from: data)
        XCTAssertEqual(decoded, identity)
        XCTAssertEqual(decoded.infoHashV1, Data([0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(decoded.infoHashV2, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testContentIdentityUnknownBothNil() {
        let identity = ContentIdentity(infoHashV1: nil, infoHashV2: nil)
        XCTAssertFalse(identity.isKnown)
    }

    func testAddOperationIDAndRequestIDRoundTrip() throws {
        let operation = AddOperationID()
        let request = RequestID()
        XCTAssertNotEqual(operation, AddOperationID())
        let data = try JSONEncoder().encode(operation)
        let decoded = try JSONDecoder().decode(AddOperationID.self, from: data)
        XCTAssertEqual(decoded, operation)
        let requestData = try JSONEncoder().encode(request)
        let requestDecoded = try JSONDecoder().decode(RequestID.self, from: requestData)
        XCTAssertEqual(requestDecoded, request)
    }

    func testIdempotencyKeyRoundTrip() throws {
        let key = IdempotencyKey()
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(IdempotencyKey.self, from: data)
        XCTAssertEqual(decoded, key)
    }

    // MARK: - Shared state vocabulary (plan §7.2)

    func testDesiredTorrentStateCasesFrozen() {
        XCTAssertEqual(DesiredTorrentState.allCases, [.running, .paused, .removed])
    }

    func testTorrentActivityCasesFrozen() {
        XCTAssertEqual(TorrentActivity.allCases, [
            .pendingAdd, .fetchingMetadata, .queued, .checking, .downloading,
            .seeding, .moving, .removing, .idle,
        ])
    }

    func testTorrentHealthRoundTripAllCases() throws {
        let cases: [TorrentHealth] = [
            .healthy,
            .waitingForNetwork,
            .waitingForVolume,
            .waitingForSpace,
            .permissionDenied,
            .recoverableError(.permissionDenied),
            .fatalError(.storeError),
        ]
        for health in cases {
            let data = try JSONEncoder().encode(health)
            let decoded = try JSONDecoder().decode(TorrentHealth.self, from: data)
            XCTAssertEqual(decoded, health)
        }
    }

    func testTransferProgressRatesPeerSummaryRoundTrip() throws {
        let progress = TransferProgress(fraction: 0.5, totalBytes: 1024, downloadedBytes: 512, uploadedBytes: 64)
        let rates = TransferRates(downloadBytesPerSec: 1000, uploadBytesPerSec: 500)
        let peers = PeerSummary(connected: 4, halfOpen: 2, total: 6)
        let progressData = try JSONEncoder().encode(progress)
        XCTAssertEqual(try JSONDecoder().decode(TransferProgress.self, from: progressData), progress)
        let ratesData = try JSONEncoder().encode(rates)
        XCTAssertEqual(try JSONDecoder().decode(TransferRates.self, from: ratesData), rates)
        let peersData = try JSONEncoder().encode(peers)
        XCTAssertEqual(try JSONDecoder().decode(PeerSummary.self, from: peersData), peers)
    }

    // MARK: - Snapshot (plan §7.3)

    func testTorrentSnapshotRoundTrip() throws {
        let snapshot = Sample.makeSnapshot(revision: 7)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TorrentSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(decoded.id, snapshot.id)
    }

    func testEngineSnapshotRoundTrip() throws {
        let snapshot = EngineSnapshot(
            torrents: [Sample.makeSnapshot(revision: 1), Sample.makeSnapshot(revision: 2)],
            engineRevision: 2,
            instanceID: UUID()
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(EngineSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSnapshotRevisionMonotonic() {
        XCTAssertTrue(SnapshotReconciliation.isStrictlyMonotonic([1, 2, 3, 4]))
        XCTAssertTrue(SnapshotReconciliation.isStrictlyMonotonic([0]))
        XCTAssertFalse(SnapshotReconciliation.isStrictlyMonotonic([1, 2, 2, 3]))
        XCTAssertFalse(SnapshotReconciliation.isStrictlyMonotonic([4, 3, 5]))
    }

    func testInstanceChangeRequiresFullSnapshot() {
        let instanceA = UUID()
        let instanceB = UUID()
        XCTAssertTrue(SnapshotReconciliation.needsFullSnapshot(currentInstanceID: nil, latestInstanceID: instanceA))
        XCTAssertTrue(SnapshotReconciliation.needsFullSnapshot(currentInstanceID: instanceA, latestInstanceID: instanceB))
        XCTAssertFalse(SnapshotReconciliation.needsFullSnapshot(currentInstanceID: instanceA, latestInstanceID: instanceA))
    }

    func testDroppedDeltaRequiresFullSnapshot() {
        // UI at revision 2, engine at 5 → gap > 1 → full snapshot required.
        XCTAssertTrue(SnapshotReconciliation.needsFullSnapshot(afterRevision: 2, latestEngineRevision: 5))
        XCTAssertTrue(SnapshotReconciliation.needsFullSnapshot(afterRevision: nil, latestEngineRevision: 5))
        // Contiguous → delta path.
        XCTAssertFalse(SnapshotReconciliation.needsFullSnapshot(afterRevision: 4, latestEngineRevision: 5))
    }

    func testContiguousDeltaApplicable() {
        XCTAssertTrue(SnapshotReconciliation.isDeltaApplicable(deltaRevision: 6, lastSeenRevision: 5))
        XCTAssertFalse(SnapshotReconciliation.isDeltaApplicable(deltaRevision: 6, lastSeenRevision: 4))
        XCTAssertFalse(SnapshotReconciliation.isDeltaApplicable(deltaRevision: 6, lastSeenRevision: 6))
    }

    func testFirstSnapshotAlwaysFull() {
        XCTAssertTrue(SnapshotReconciliation.needsFullSnapshot(afterRevision: nil, latestEngineRevision: 0))
    }

    // MARK: - EngineCommandV1 (plan §7.4)

    func testEngineCommandV1SurfaceComplete() {
        let expectedNames = [
            "hello", "fetchSnapshot", "fetchFiles", "fetchPeers", "fetchTrackers",
            "fetchActivity", "fetchRemovalManifestPage", "fetchCreatorManifestPage",
            "inspectAddSource", "commitAdd", "cancelAdd", "pause", "resume",
            "setFileSelection", "setLimits", "fetchSettings", "validateSettings",
            "applySettings", "testProxy", "testIncomingPort", "editTrackers",
            "reannounce", "requestRecheck", "moveStorage", "prepareRemoval",
            "commitRemoval", "cancelOperation", "inspectCreateSource",
            "commitCreate", "prepareForQuit", "restartEngineSafely", "exportDiagnostics",
        ]
        XCTAssertEqual(EngineCommandV1.allCases.map(\.name), expectedNames)
        XCTAssertEqual(EngineCommandV1.allCases.count, 32)
    }

    func testEngineCommandV1RoundTripAllCases() throws {
        for command in EngineCommandV1.allCases {
            let data = try JSONEncoder().encode(command)
            let decoded = try JSONDecoder().decode(EngineCommandV1.self, from: data)
            XCTAssertEqual(decoded, command, "round-trip failed for \(command.name)")
            XCTAssertEqual(decoded.name, command.name)
        }
    }

    func testEngineCommandUnknownDecodeFails() {
        // Synthesized Codable for associated-value enums: unknown case label fails.
        let unknown = Data(#"["launchNukes",{}]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineCommandV1.self, from: unknown))
        // Wrong payload shape for a known case fails too.
        let wrongShape = Data(#"["fetchSnapshot","not-a-payload"]"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineCommandV1.self, from: wrongShape))
    }

    func testEngineCommandV1MutatingCommandsCarryIdempotencyKey() {
        let expectedMutating = [
            "commitAdd", "cancelAdd", "pause", "resume", "setFileSelection",
            "setLimits", "applySettings", "editTrackers", "reannounce",
            "requestRecheck", "moveStorage", "prepareRemoval", "commitRemoval",
            "cancelOperation", "commitCreate", "restartEngineSafely",
        ]
        for command in EngineCommandV1.allCases {
            if expectedMutating.contains(command.name) {
                XCTAssertNotNil(command.idempotencyKey, "\(command.name) must carry an idempotency key")
                XCTAssertTrue(command.isMutating)
            } else {
                XCTAssertNil(command.idempotencyKey, "\(command.name) is a read/one-shot, no idempotency key")
                XCTAssertFalse(command.isMutating)
            }
        }
    }

    func testEngineCommandV1EveryPayloadHasRequestID() {
        for command in EngineCommandV1.allCases {
            XCTAssertEqual(command.requestID.description.count, 36)
        }
    }

    func testCommandEnvelopeRoundTrip() throws {
        let command = EngineCommandV1.pause(PauseRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: TorrentRecordID(rawValue: UUID())
        ))
        let envelope = IPCEnvelope.request(command)
        XCTAssertNil(envelope.validate())
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .request)
        XCTAssertEqual(decoded.command, command)
        XCTAssertEqual(decoded.requestID, command.requestID)
    }

    // MARK: - EngineEventV1 (plan §7.5)

    func testEngineEventV1SurfaceComplete() {
        let expectedNames = [
            "engineLifecycleChanged", "torrentAdded", "torrentDelta",
            "torrentRemoved", "operationProgress", "operationCompleted",
            "recoverableIssue", "engineHealthChanged", "snapshotRequired",
            "inspectionInvalidated", "settingsChanged",
        ]
        XCTAssertEqual(EngineEventV1.allCases.map(\.name), expectedNames)
        XCTAssertEqual(EngineEventV1.allCases.count, 11)
    }

    func testEngineEventV1RoundTripAllCases() throws {
        for event in EngineEventV1.allCases {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(EngineEventV1.self, from: data)
            XCTAssertEqual(decoded, event, "round-trip failed for \(event.name)")
        }
    }

    func testEventEnvelopeRoundTrip() throws {
        let event = EngineEventV1.settingsChanged(SettingsChangedEvent(revision: 42))
        let envelope = IPCEnvelope.event(event)
        XCTAssertNil(envelope.validate())
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .event)
        XCTAssertEqual(decoded.event, event)
        XCTAssertNil(decoded.requestID)
    }

    // MARK: - Error contract (plan §7.6)

    func testEngineFaultRoundTrip() throws {
        let fault = EngineFault(
            code: .insufficientSpace,
            severity: .warning,
            affectedRecord: TorrentRecordID(rawValue: UUID()),
            recoveryActions: ["free_disk_space", "move_storage"],
            redactedContext: "volume 50% full"
        )
        let data = try JSONEncoder().encode(fault)
        let decoded = try JSONDecoder().decode(EngineFault.self, from: data)
        XCTAssertEqual(decoded, fault)
        XCTAssertEqual(decoded.localizationKey, "fault.insufficientSpace")
    }

    func testEngineFaultLocalizationKeyStable() {
        for code in EngineErrorCode.allCases {
            let fault = EngineFault(code: code, severity: .error)
            XCTAssertEqual(fault.localizationKey, "fault.\(code.rawValue)")
        }
    }

    func testEngineFaultFactories() {
        let mismatch = EngineFault.protocolVersionMismatch(clientMajor: 1, serverMajor: 2)
        XCTAssertEqual(mismatch.code, .protocolVersionMismatch)
        XCTAssertEqual(mismatch.severity, .fatal)
        XCTAssertTrue(mismatch.redactedContext?.contains("clientMajor=1") == true)

        let oversized = EngineFault.oversizedPayload(limitBytes: IPCPayloadLimit.maxBytes)
        XCTAssertEqual(oversized.code, .oversizedPayload)

        let conflict = EngineFault.settingsRevisionConflict(current: 1, expected: 5)
        XCTAssertEqual(conflict.code, .settingsRevisionConflict)

        let record = TorrentRecordID(rawValue: UUID())
        let notFound = EngineFault.recordNotFound(recordID: record)
        XCTAssertEqual(notFound.affectedRecord, record)
    }

    // MARK: - IPCEnvelope v1

    func testEnvelopeRoundTripHappy() throws {
        let requestID = RequestID()
        let result = EngineCommandResult.success(.snapshot(EngineSnapshot(
            torrents: [Sample.makeSnapshot(revision: 1)],
            engineRevision: 1,
            instanceID: UUID()
        )))
        let envelope = IPCEnvelope.result(requestID: requestID, result: result)
        XCTAssertTrue(envelope.isCompatibleWithCurrent)
        XCTAssertNil(envelope.validate())
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.kind, .result)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.result, result)
    }

    func testEnvelopeRequestKindValidation() {
        // Request without a command is structurally invalid.
        let empty = IPCEnvelope(version: .current, kind: .request, requestID: RequestID(), command: nil, event: nil, result: nil)
        XCTAssertEqual(empty.validate(), .missingCommand)

        // Request without requestID is invalid.
        let noID = IPCEnvelope(version: .current, kind: .request, requestID: nil, command: .fetchSettings(FetchSettingsRequest(requestID: RequestID(), expectedRevision: nil)), event: nil, result: nil)
        XCTAssertEqual(noID.validate(), .missingRequestID)
    }

    func testEnvelopeEventKindValidation() {
        let event = IPCEnvelope.event(.engineHealthChanged(EngineHealthChangedEvent(healthy: true, reason: nil, engineRevision: 0)))
        XCTAssertNil(event.validate())

        // An event with a command present is structurally invalid.
        let polluted = IPCEnvelope(version: .current, kind: .event, requestID: nil, command: .pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: TorrentRecordID(rawValue: UUID()))), event: nil, result: nil)
        XCTAssertEqual(polluted.validate(), .missingEvent)

        // An event envelope carrying a command payload alongside the event is
        // a kind/payload mismatch, not just a missing event.
        let carriesCommand = IPCEnvelope(
            version: .current,
            kind: .event,
            requestID: nil,
            command: .pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: TorrentRecordID(rawValue: UUID()))),
            event: .engineHealthChanged(EngineHealthChangedEvent(healthy: true, reason: nil, engineRevision: 0)),
            result: nil
        )
        XCTAssertEqual(carriesCommand.validate(), .unexpectedPayload)
    }

    func testEnvelopeResultKindValidation() {
        let result = IPCEnvelope.result(requestID: RequestID(), result: .failure(.internalError(details: "boom")))
        XCTAssertNil(result.validate())

        let missingResult = IPCEnvelope(version: .current, kind: .result, requestID: RequestID(), command: nil, event: nil, result: nil)
        XCTAssertEqual(missingResult.validate(), .missingResult)

        let missingCorrelation = IPCEnvelope(version: .current, kind: .result, requestID: nil, command: nil, event: nil, result: .success(.ack))
        XCTAssertEqual(missingCorrelation.validate(), .missingRequestID)
    }

    func testEnvelopeRequestIDMismatch() {
        let command = EngineCommandV1.pause(PauseRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: TorrentRecordID(rawValue: UUID())
        ))
        let forged = IPCEnvelope(version: .current, kind: .request, requestID: RequestID(), command: command, event: nil, result: nil)
        XCTAssertEqual(forged.validate(), .requestIDMismatch)
        XCTAssertEqual(forged.validate()?.fault.code, .invalidPayload)
    }

    func testEnvelopeTamperedPayloadDecodeFails() {
        // Valid outer shape but garbage command payload → decode fail.
        let tampered = Data(
            #"{"version":{"major":1,"minor":0},"kind":"request","requestID":"11111111-1111-1111-1111-111111111111","command":["launchNukes",{}]}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(IPCEnvelope.self, from: tampered))
    }

    func testEnvelopeUnknownKindDecodeFails() {
        let unknownKind = Data(
            #"{"version":{"major":1,"minor":0},"kind":"teleport"}"#.utf8
        )
        XCTAssertThrowsError(try JSONDecoder().decode(IPCEnvelope.self, from: unknownKind))
    }

    func testEnvelopeGarbageJSONDecodeFails() {
        let garbage = Data("not-json-at-all".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(IPCEnvelope.self, from: garbage))
        let empty = Data()
        XCTAssertThrowsError(try JSONDecoder().decode(IPCEnvelope.self, from: empty))
    }

    func testEnvelopeOversizedPayloadRejected() {
        XCTAssertTrue(IPCPayloadLimit.validate(Data(repeating: 0, count: IPCPayloadLimit.maxBytes)))
        XCTAssertFalse(IPCPayloadLimit.validate(Data(repeating: 0, count: IPCPayloadLimit.maxBytes + 1)))
        XCTAssertFalse(IPCPayloadLimit.validate(Data(repeating: 0, count: IPCPayloadLimit.maxBytes * 4)))
        // The fault a server would return.
        let fault = EngineFault.oversizedPayload(limitBytes: IPCPayloadLimit.maxBytes)
        XCTAssertEqual(fault.code, .oversizedPayload)
        XCTAssertEqual(fault.severity, .error)
    }

    func testEnvelopeFuzzTruncatedJSON() {
        let command = EngineCommandV1.commitAdd(CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            operationID: AddOperationID(),
            desiredName: "ubuntu-24.04.iso",
            saveLocation: PersistedLocation(path: "/tmp/Downloads"),
            fileSelection: [FileSelectionItem(relativePath: "a/b.bin", priority: .normal)]
        ))
        let full = try! JSONEncoder().encode(IPCEnvelope.request(command))
        // Truncate mid-stream — decoder must fail, not crash.
        for cut in [1, 3, 8, full.count / 2, max(1, full.count - 2)] {
            let slice = full.prefix(cut)
            XCTAssertThrowsError(
                try JSONDecoder().decode(IPCEnvelope.self, from: Data(slice)),
                "expected fail at cut=\(cut)"
            )
        }
    }

    func testEnvelopeConcurrentEncodeDecodeStress() {
        let sample = IPCEnvelope.result(
            requestID: RequestID(),
            result: .success(.ack)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let counter = ConcurrentFailureCounter()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            do {
                let data = try encoder.encode(sample)
                let decoded = try decoder.decode(IPCEnvelope.self, from: data)
                if decoded != sample {
                    counter.increment()
                }
                if !decoded.isCompatibleWithCurrent || decoded.validate() != nil {
                    counter.increment()
                }
            } catch {
                counter.increment()
            }
        }
        XCTAssertEqual(counter.value, 0)
    }

    func testResultSuccessAndFailureRoundTrip() throws {
        let outcomes: [EngineCommandResult] = [
            .success(.hello(HelloResponse(
                agentVersion: "1.0.0-wp05",
                negotiatedProtocol: .current,
                instanceID: UUID(),
                engineRevision: 3
            ))),
            .success(.ack),
            .success(.commitAdd(CommitAddResult(recordID: TorrentRecordID(rawValue: UUID()), engineRevision: 4))),
            .failure(.duplicateAdd(identity: ContentIdentity(infoHashV1: Data([1]), infoHashV2: nil))),
            .failure(.settingsValidationFailed(errors: [
                SettingsValidationError(field: "downloadDirectory", message: "must not be empty"),
            ])),
        ]
        for outcome in outcomes {
            let data = try JSONEncoder().encode(outcome)
            let decoded = try JSONDecoder().decode(EngineCommandResult.self, from: data)
            XCTAssertEqual(decoded, outcome)
        }
    }

    func testSuccessPayloadAck() throws {
        let data = try JSONEncoder().encode(SuccessPayload.ack)
        let decoded = try JSONDecoder().decode(SuccessPayload.self, from: data)
        XCTAssertEqual(decoded, .ack)
    }

    // MARK: - Pagination (plan §7.4)

    func testPageCursorRoundTrip() throws {
        let cursor = PageCursor(token: Data([0x00, 0x01, 0xFF, 0x42]))
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(PageCursor.self, from: data)
        XCTAssertEqual(decoded, cursor)
        XCTAssertEqual(decoded.token, Data([0x00, 0x01, 0xFF, 0x42]))
    }

    func testFileCursorHierarchyRoundTrip() throws {
        let cursor = FileCursor(directoryStack: ["TV", "Season 1"], token: PageCursor(token: Data([9])))
        let data = try JSONEncoder().encode(cursor)
        let decoded = try JSONDecoder().decode(FileCursor.self, from: data)
        XCTAssertEqual(decoded, cursor)
        XCTAssertEqual(decoded.directoryStack, ["TV", "Season 1"])
    }

    func testPageRoundTrip() throws {
        let page = Page(items: [Sample.makeFileEntry("a.bin"), Sample.makeFileEntry("b.bin")],
                        nextCursor: PageCursor(token: Data([2])),
                        totalCount: 5,
                        revision: 3)
        let data = try JSONEncoder().encode(page)
        let decoded = try JSONDecoder().decode(Page<FileEntry>.self, from: data)
        XCTAssertEqual(decoded, page)
        XCTAssertEqual(decoded.items.count, 2)
        XCTAssertEqual(decoded.totalCount, 5)
    }

    func testPageSizeBounded() {
        XCTAssertEqual(PageSize.bounded(200), 200)
        XCTAssertEqual(PageSize.bounded(500), 200)
        XCTAssertEqual(PageSize.bounded(1), 1)
        XCTAssertEqual(PageSize.bounded(0), 1)
        XCTAssertEqual(PageSize.bounded(-3), 1)
        XCTAssertEqual(PageSize.maximum, 200)
    }

    func testPaginatedItemsRoundTrip() throws {
        let peers = Page(items: [Sample.makePeerEntry()], nextCursor: nil, totalCount: 1, revision: 0)
        let trackers = Page(items: [TrackerEntry(url: "udp://tracker.local:1337", status: .working, seeds: 3, peers: 5, message: nil)], nextCursor: nil, totalCount: 1, revision: 0)
        let activity = Page(items: [ActivityEntry(operationID: OperationID(), kind: .rechecking, fraction: 0.5, startedAt: Date(timeIntervalSince1970: 100))], nextCursor: nil, totalCount: 1, revision: 0)
        let manifest = Page(items: [RemovalManifestEntry(relativePath: "f.bin", sizeBytes: 10, kind: .file)], nextCursor: nil, totalCount: 1, revision: 0)
        XCTAssertFalse(try JSONEncoder().encode(peers).isEmpty)
        XCTAssertFalse(try JSONEncoder().encode(trackers).isEmpty)
        XCTAssertFalse(try JSONEncoder().encode(activity).isEmpty)
        XCTAssertFalse(try JSONEncoder().encode(manifest).isEmpty)
        let peersData = try JSONEncoder().encode(peers)
        XCTAssertEqual(try JSONDecoder().decode(Page<PeerEntry>.self, from: peersData), peers)
        let trackersData = try JSONEncoder().encode(trackers)
        XCTAssertEqual(try JSONDecoder().decode(Page<TrackerEntry>.self, from: trackersData), trackers)
        let activityData = try JSONEncoder().encode(activity)
        XCTAssertEqual(try JSONDecoder().decode(Page<ActivityEntry>.self, from: activityData), activity)
        let manifestData = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(Page<RemovalManifestEntry>.self, from: manifestData), manifest)
    }

    // MARK: - Settings protocol (plan §7.4)

    func testSettingsRoundTrip() throws {
        let settings = Sample.makeSettings()
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.downloadDirectory, "/tmp/Downloads")
    }

    func testSettingsValidationRules() {
        let valid = Sample.makeSettings()
        XCTAssertTrue(SettingsRules.validate(valid).isEmpty)

        let emptyDir = Sample.makeSettings(downloadDirectory: "")
        XCTAssertFalse(SettingsRules.validate(emptyDir).isEmpty)
        XCTAssertEqual(SettingsRules.validate(emptyDir).first?.field, "downloadDirectory")

        let negativeLimit = Sample.makeSettings(maxUploadBytesPerSec: -5)
        XCTAssertEqual(SettingsRules.validate(negativeLimit).first?.field, "maxUploadBytesPerSec")

        let multiple = Sample.makeSettings(downloadDirectory: "", maxDownloadBytesPerSec: -1, maxUploadBytesPerSec: -1)
        XCTAssertEqual(SettingsRules.validate(multiple).count, 3)
    }

    func testSettingsRevisionConflictFault() {
        let fault = EngineFault.settingsRevisionConflict(current: 7, expected: 11)
        XCTAssertEqual(fault.code, .settingsRevisionConflict)
        XCTAssertEqual(fault.severity, .warning)
        XCTAssertEqual(fault.localizationKey, "fault.settingsRevisionConflict")
    }

    func testSettingsTransactionApplied() {
        let candidate = Sample.makeSettings(downloadDirectory: "/tmp/NewDir")
        let box = CallBox { _ in }
        let context = SettingsTransaction.Context(
            currentRevision: 1,
            persist: { candidate, current in
                box.record(candidate)
                return current + 1
            },
            apply: { _ in .success(()) },
            rollback: { _, _ in }
        )
        let outcome = SettingsTransaction.run(candidate: candidate, expectedRevision: 1, context: context)
        XCTAssertEqual(outcome, SettingsTransaction.Outcome.applied(revision: 2))
        XCTAssertEqual(box.values.count, 1)
        let persisted = box.values.first as? EngineSettings
        XCTAssertEqual(persisted?.downloadDirectory, "/tmp/NewDir")
    }

    func testSettingsTransactionValidationFailed() {
        let candidate = Sample.makeSettings(downloadDirectory: "")
        let context = SettingsTransaction.Context(
            currentRevision: 1,
            persist: { _, _ in 2 },
            apply: { _ in .success(()) },
            rollback: { _, _ in }
        )
        let outcome = SettingsTransaction.run(candidate: candidate, expectedRevision: 1, context: context)
        guard case .validationFailed(let errors) = outcome else {
            return XCTFail("expected validationFailed, got \(outcome)")
        }
        XCTAssertEqual(errors.first?.field, "downloadDirectory")
    }

    func testSettingsTransactionRevisionConflict() {
        let candidate = Sample.makeSettings()
        let context = SettingsTransaction.Context(
            currentRevision: 1,
            persist: { _, _ in 2 },
            apply: { _ in .success(()) },
            rollback: { _, _ in }
        )
        let outcome = SettingsTransaction.run(candidate: candidate, expectedRevision: 9, context: context)
        XCTAssertEqual(outcome, SettingsTransaction.Outcome.revisionConflict(current: 1))
    }

    func testSettingsTransactionRollbackOnApplyFailure() {
        let candidate = Sample.makeSettings()
        let rollbackBox = CallBox { _ in }
        let context = SettingsTransaction.Context(
            currentRevision: 3,
            persist: { _, _ in 4 },
            apply: { _ in .failure(.internalError(details: "engine rejected")) },
            rollback: { _, newRevision in rollbackBox.record(newRevision) }
        )
        let outcome = SettingsTransaction.run(candidate: candidate, expectedRevision: 3, context: context)
        guard case .failed(let fault) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(fault.code, .internalError)
        XCTAssertEqual(rollbackBox.values.count, 1)
        XCTAssertEqual(rollbackBox.values.first as? UInt64, 4)
    }

    func testSettingsTransactionPersistFailureNoRollback() {
        let candidate = Sample.makeSettings()
        let rollbackBox = CallBox { _ in }
        let context = SettingsTransaction.Context(
            currentRevision: 3,
            persist: { _, _ in throw SettingsTestError.persistFailed },
            apply: { _ in .success(()) },
            rollback: { _, _ in rollbackBox.record(0) }
        )
        let outcome = SettingsTransaction.run(candidate: candidate, expectedRevision: 3, context: context)
        guard case .failed(let fault) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(fault.code, .storeError)
        XCTAssertEqual(rollbackBox.values.count, 0)
    }

    // MARK: - Handshake (plan §7.4, §10)

    func testHelloRequestResponseRoundTrip() throws {
        let request = Handshake.makeRequest(clientVersion: "1.0.0")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelloRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.supportedProtocolRange, IPCVersion.current...IPCVersion.current)

        let response = HelloResponse(
            agentVersion: "1.0.0-wp05",
            negotiatedProtocol: .current,
            instanceID: UUID(),
            engineRevision: 9
        )
        let responseData = try JSONEncoder().encode(response)
        let responseDecoded = try JSONDecoder().decode(HelloResponse.self, from: responseData)
        XCTAssertEqual(responseDecoded, response)
    }

    func testHandshakeNegotiatesSameVersion() {
        let range = Handshake.singleVersionRange(IPCVersion.current)
        XCTAssertEqual(
            Handshake.negotiate(clientRange: range, serverRange: range),
            .negotiated(IPCVersion.current)
        )
    }

    func testHandshakeMismatchAcrossMajors() {
        let clientRange = Handshake.singleVersionRange(IPCVersion(major: 1, minor: 0))
        let serverRange = Handshake.singleVersionRange(IPCVersion(major: 2, minor: 0))
        XCTAssertEqual(Handshake.negotiate(clientRange: clientRange, serverRange: serverRange), HandshakeResult.mismatch)
    }

    func testHandshakeNegotiatesOverlap() {
        let clientRange = IPCVersion(major: 1, minor: 0)...IPCVersion(major: 2, minor: 5)
        let serverRange = IPCVersion(major: 1, minor: 9)...IPCVersion(major: 1, minor: 9)
        XCTAssertEqual(
            Handshake.negotiate(clientRange: clientRange, serverRange: serverRange),
            .negotiated(IPCVersion(major: 1, minor: 9))
        )
    }

    func testHandshakePicksMostConservativeOverlap() {
        // Overlap is [1.5, 2.0]; the server must negotiate the smallest
        // (most conservative) version inside BOTH ranges, not the ceiling.
        let clientRange = IPCVersion(major: 1, minor: 5)...IPCVersion(major: 2, minor: 0)
        let serverRange = IPCVersion(major: 1, minor: 0)...IPCVersion(major: 2, minor: 0)
        XCTAssertEqual(
            Handshake.negotiate(clientRange: clientRange, serverRange: serverRange),
            .negotiated(IPCVersion(major: 1, minor: 5))
        )
    }

    func testHandshakeValidateResponseMismatchFault() {
        let response = HelloResponse(
            agentVersion: "agent",
            negotiatedProtocol: IPCVersion(major: 3, minor: 0),
            instanceID: UUID(),
            engineRevision: 0
        )
        let result = Handshake.validateResponse(response, clientRange: Handshake.clientSupportedRange)
        guard case .failure(let fault) = result else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(fault.code, .protocolVersionMismatch)
        XCTAssertEqual(fault.severity, .fatal)
        // Round-trips on the wire.
        let data = try! JSONEncoder().encode(fault)
        let decoded = try! JSONDecoder().decode(EngineFault.self, from: data)
        XCTAssertEqual(decoded, fault)
    }

    func testHandshakeValidateResponseHappy() {
        let response = HelloResponse(
            agentVersion: "agent",
            negotiatedProtocol: .current,
            instanceID: UUID(),
            engineRevision: 0
        )
        let result = Handshake.validateResponse(response, clientRange: Handshake.clientSupportedRange)
        guard case .success(let validated) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(validated, response)
    }

    func testVersionMismatchProducesFault() {
        // Full flow: agent advertises 2.0, client supports 1.0 → mismatch.
        let clientRequest = Handshake.makeRequest(clientVersion: "1.0.0")
        let serverAdvertised = IPCVersion(major: 2, minor: 0)
        let negotiation = Handshake.negotiate(
            clientRange: clientRequest.supportedProtocolRange,
            serverRange: Handshake.singleVersionRange(serverAdvertised)
        )
        guard case .mismatch = negotiation else {
            return XCTFail("expected mismatch")
        }
        let fault = EngineFault.protocolVersionMismatch(
            clientMajor: clientRequest.supportedProtocolRange.lowerBound.major,
            serverMajor: serverAdvertised.major
        )
        XCTAssertEqual(fault.localizationKey, "fault.protocolVersionMismatch")
    }

    // MARK: - Idempotency (plan §6.2)

    func testIdempotencyDuplicateReplaysSameResult() async {
        let tracker = IdempotencyTracker()
        let requestID = RequestID()
        let key = IdempotencyKey()
        let outcome = EngineCommandResult.success(.commitAdd(CommitAddResult(recordID: TorrentRecordID(rawValue: UUID()), engineRevision: 3)))

        await tracker.remember(commandName: "commitAdd", requestID: requestID, idempotencyKey: key, outcome: outcome)
        let replay = await tracker.replay(commandName: "commitAdd", requestID: requestID, idempotencyKey: key)
        let count = await tracker.count
        XCTAssertEqual(replay?.outcome, outcome)
        XCTAssertEqual(count, 1)
    }

    func testIdempotencyDifferentKeysDoNotReplay() async {
        let tracker = IdempotencyTracker()
        let requestID = RequestID()
        await tracker.remember(commandName: "pause", requestID: requestID, idempotencyKey: IdempotencyKey(), outcome: .success(.ack))
        let differentKeyReplay = await tracker.replay(commandName: "pause", requestID: requestID, idempotencyKey: IdempotencyKey())
        XCTAssertNil(differentKeyReplay)
        // Same key, different command → no replay either.
        let differentCommandReplay = await tracker.replay(commandName: "resume", requestID: requestID, idempotencyKey: nil)
        XCTAssertNil(differentCommandReplay)
        // Without idempotency key (read commands) replay is exact.
        await tracker.remember(commandName: "fetchSettings", requestID: requestID, idempotencyKey: nil, outcome: .success(.ack))
        let noKeyReplay = await tracker.replay(commandName: "fetchSettings", requestID: requestID, idempotencyKey: nil)
        XCTAssertNotNil(noKeyReplay)
    }

    func testIdempotencyCanonicalKeyDeterministic() {
        let requestID = RequestID()
        let key = IdempotencyKey()
        let first = IdempotencyTracker.canonicalKey(commandName: "pause", requestID: requestID, idempotencyKey: key)
        let second = IdempotencyTracker.canonicalKey(commandName: "pause", requestID: requestID, idempotencyKey: key)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(
            first,
            IdempotencyTracker.canonicalKey(commandName: "resume", requestID: requestID, idempotencyKey: key)
        )
    }

    // MARK: - Reconnect policy (plan §8.4)

    func testReconnectPolicyFirstAttemptImmediate() {
        let policy = ClientReconnectPolicy.standard
        XCTAssertEqual(policy.delayNanoseconds(forAttempt: 0), 0)
        XCTAssertEqual(policy.maxAttempts, 5)
    }

    func testReconnectPolicyBackoffMonotonic() {
        let policy = ClientReconnectPolicy.standard
        let delays = (0..<policy.maxAttempts).compactMap { policy.delayNanoseconds(forAttempt: $0) }
        XCTAssertEqual(delays.count, 5)
        for index in 1..<delays.count {
            XCTAssertGreaterThan(delays[index], delays[index - 1])
        }
    }

    func testReconnectPolicyBudgetExhausted() {
        let policy = ClientReconnectPolicy.standard
        XCTAssertNil(policy.delayNanoseconds(forAttempt: policy.maxAttempts))
        XCTAssertNil(policy.delayNanoseconds(forAttempt: 100))
        XCTAssertTrue(policy.isBudgetExhausted(afterAttempt: policy.maxAttempts))
        XCTAssertFalse(policy.isBudgetExhausted(afterAttempt: policy.maxAttempts - 1))
    }

    // MARK: - TestProfile

    func testProfileIsolation() {
        XCTAssertFalse(
            profile.rootURL.path.contains(TestProfile.productionAppSupportMarker)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.rootURL.path))
    }
}

// MARK: - Sample fixtures

private enum Sample {
    static func makeSnapshot(revision: UInt64) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentRecordID(rawValue: UUID()),
            contentIdentity: ContentIdentity(infoHashV1: Data([1, 2, 3]), infoHashV2: nil),
            displayName: "ubuntu-24.04-desktop-amd64.iso",
            desiredState: .running,
            activity: .downloading,
            health: .healthy,
            progress: TransferProgress(fraction: 0.5, totalBytes: 6_000_000_000, downloadedBytes: 3_000_000_000, uploadedBytes: 0),
            rates: TransferRates(downloadBytesPerSec: 1_200_000, uploadBytesPerSec: 0),
            peers: PeerSummary(connected: 8, halfOpen: 2, total: 10),
            saveLocation: PersistedLocation(path: "/tmp/Downloads"),
            revision: revision
        )
    }

    static func makeFileEntry(_ name: String) -> FileEntry {
        FileEntry(
            relativePath: "files/\(name)",
            name: name,
            sizeBytes: 1024,
            kind: .file,
            selection: .normal
        )
    }

    static func makePeerEntry() -> PeerEntry {
        PeerEntry(
            peerID: "peer-1",
            ipAddress: "192.0.2.10",
            port: 6881,
            clientName: "qBittorrent/5.0",
            downloadBytesPerSec: 2048,
            uploadBytesPerSec: 512,
            progress: 0.25,
            isSeed: false
        )
    }

    static func makeSettings(
        downloadDirectory: String = "/tmp/Downloads",
        maxDownloadBytesPerSec: Int64 = 0,
        maxUploadBytesPerSec: Int64 = 0
    ) -> EngineSettings {
        EngineSettings(
            downloadDirectory: downloadDirectory,
            maxDownloadBytesPerSec: maxDownloadBytesPerSec,
            maxUploadBytesPerSec: maxUploadBytesPerSec,
            listenPort: 51413,
            dhtEnabled: true,
            lsdEnabled: true,
            upnpEnabled: true,
            natPmpEnabled: true,
            encryptionEnabled: true
        )
    }
}

private enum SettingsTestError: Error {
    case persistFailed
}

/// Thread-safe box for capturing values from @Sendable transaction closures.
private final class CallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Any] = []
    private let recordHandler: @Sendable (Any) -> Void

    init(recordHandler: @escaping @Sendable (Any) -> Void) {
        self.recordHandler = recordHandler
    }

    func record(_ value: Any) {
        lock.lock()
        storage.append(value)
        lock.unlock()
        recordHandler(value)
    }

    var values: [Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Thread-safe failure tally for concurrentPerform stress tests (Swift 6 Sendable).
private final class ConcurrentFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
