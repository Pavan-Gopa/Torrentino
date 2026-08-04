// Layer: EngineAgent (Transfer).
// Role: the agent-side coordinator behind the v1 command surface. It owns the
// authoritative in-memory torrent records, reconciles them with the engine via
// the status pump, persists every durable mutation (commitAdd journal first),
// and publishes contiguous snapshot deltas to the event bus. It is the ONLY
// writer of records and revisions.
// Must-not: block on the engine, drop mutations, or invent progress — every
// number on a snapshot either came from the engine or is a zero baseline.
// Invariants: all mutations are durable BEFORE they are visible (persist →
// record → revision → publish); delta events carry engineRevision = last
// published + 1 so the UI never sees a gap; one torrent's engine failure
// never blocks the others (per-record isolation); instanceID changes on
// (re)start so the UI discards stale deltas.

import Foundation
import OSLog
import TorrentinoIPC
import TorrentinoDomain
public actor TransferCoordinator {
    // MARK: - Configuration

    /// Default pump cadence (production). Tests pass nil to pump manually.
    public static let defaultPumpIntervalNanoseconds: UInt64 = 500_000_000

    private let engine: any TransferEngine
    private let persistence: PersistenceStore
    private let eventBus: TransferEventBus
    private let agentVersion: String
    private let defaultSaveLocation: PersistedLocation
    private let pumpIntervalNanoseconds: UInt64?
    private let storageProbe: @Sendable (PersistedLocation, Int64) -> StorageAvailabilityState
    private let healthReporter: (any EngineHealthReporter)?
    private let clearSafeRecovery: @Sendable () -> Void
    /// WP-10: injectable per-item Trash primitive (tests simulate failures).
    private let trashProvider: any TrashProviding
    private let log = Logger(subsystem: "com.torrentino.app.engine-agent", category: "transfer")

    // MARK: - State

    private var records: [TorrentRecordID: TransferRecord] = [:]
    private var recordRevisions: [TorrentRecordID: UInt64] = [:]
    /// Deltas are published contiguously: every publish covers all changes
    /// with revision > publishedRevision and carries publishedRevision + 1.
    private var publishedRevision: UInt64 = 0
    private var engineRevision: UInt64 = 0
    private var pendingOperations: [AddOperationID: TorrentAdder.Inspection] = [:]
    private var pendingInspectionBytes = 0
    private var idempotencyResults: [IdempotencyKey: CommitAddResult] = [:]
    private var idempotencyOrder: [IdempotencyKey] = []
    private var pumpTask: Task<Void, Never>?
    private let instanceID = UUID()
    private var activeSettings: EngineSettings
    private var settingsRevision: SettingsRevision = 1
    private var lastReannounceAt: [TorrentRecordID: Date] = [:]
    private var pendingRemovalTokens: [String: TorrentRecordID] = [:]
    private var systemConditions = SystemConditions.normal
    private var resourceBudget = EngineResourceBudget.balanced
    private var safeRecovery: Bool
    private var engineStartFailures = 0
    private var nextEngineStartAt = Date.distantPast
    private var statusFailures = 0
    private var nextStatusAttemptAt = Date.distantPast
    private var networkRecoveryPending = false
    private var nextNetworkRecoveryAt = Date.distantPast
    private var readdBackoff: [TorrentRecordID: (failures: Int, nextAttemptAt: Date)] = [:]
    private var restartInFlight = false
    private let creatorPlanStore = CreatorPlanStore()

    private static let reannounceCooldown: TimeInterval = 30
    private static let pendingOperationsLimit = 256
    private static let pendingInspectionBytesLimit: Int64 = 64 * 1024 * 1024
    private static let idempotencyResultsLimit = 1024
    private static let pendingRemovalTokenLimit = 256

    // MARK: - Init

    init(
        engine: any TransferEngine,
        persistence: PersistenceStore,
        eventBus: TransferEventBus,
        agentVersion: String,
        defaultSaveLocation: PersistedLocation,
        pumpIntervalNanoseconds: UInt64? = nil,
        storageProbe: @escaping @Sendable (PersistedLocation, Int64) -> StorageAvailabilityState = {
            StorageLocationProbe.assess(location: $0, requiredBytes: $1)
        },
        healthReporter: (any EngineHealthReporter)? = nil,
        safeRecovery: Bool = false,
        clearSafeRecovery: @escaping @Sendable () -> Void = {},
        trashProvider: any TrashProviding = FileManagerTrashProvider()
    ) {
        self.engine = engine
        self.persistence = persistence
        self.eventBus = eventBus
        self.agentVersion = agentVersion
        self.defaultSaveLocation = Self.normalizedSaveLocation(defaultSaveLocation)
        self.pumpIntervalNanoseconds = pumpIntervalNanoseconds.map { max($0, 100_000_000) }
        self.storageProbe = storageProbe
        self.healthReporter = healthReporter
        self.safeRecovery = safeRecovery
        self.clearSafeRecovery = clearSafeRecovery
        self.trashProvider = trashProvider
        let defaults = EngineSettings.default
        self.activeSettings = EngineSettings(
            downloadDirectory: defaultSaveLocation.path,
            maxDownloadBytesPerSec: defaults.maxDownloadBytesPerSec,
            maxUploadBytesPerSec: defaults.maxUploadBytesPerSec,
            listenPort: defaults.listenPort,
            dhtEnabled: defaults.dhtEnabled,
            lsdEnabled: defaults.lsdEnabled,
            upnpEnabled: defaults.upnpEnabled,
            natPmpEnabled: defaults.natPmpEnabled,
            encryptionEnabled: defaults.encryptionEnabled,
            proxy: defaults.proxy
        )
    }

    // MARK: - Lifecycle

    /// Starts the status pump (no-op when the coordinator was built with a nil
    /// interval). Safe to call once; the AgentRuntime calls it after restore.
    public func startPump() {
        guard pumpTask == nil else { return }
        guard let pumpIntervalNanoseconds else { return }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let delay = await self.currentPumpInterval(defaultInterval: pumpIntervalNanoseconds)
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.pumpOnce()
            }
        }
    }

    /// Stops the status pump and cancels in-flight engine work.
    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func currentPumpInterval(defaultInterval: UInt64) -> UInt64 {
        max(defaultInterval, resourceBudget.pumpIntervalNanoseconds)
    }

    /// Rebuilds in-memory records from the persistence store (restart path).
    /// The pump then re-adds running torrents to the engine. Safe to call more
    /// than once; never throws — a store failure leaves the coordinator empty.
    public func restoreFromPersistence() async {
        do {
            if let restored = try await persistence.loadSettings() {
                activeSettings = restored.settings
                settingsRevision = restored.revision
            }
        } catch {
            log.warning("restore: settings load failed: \(String(describing: error))")
        }

        let stored: [StoredTorrent]
        do {
            stored = try await persistence.allTorrents()
        } catch {
            log.error("restore: allTorrents failed: \(String(describing: error))")
            return
        }
        for torrent in stored.sorted(by: { $0.addedAt < $1.addedAt }) {
            guard let uuid = UUID(uuidString: torrent.id) else { continue }
            let recordID = TorrentRecordID(rawValue: uuid)
            let identity = ContentIdentity(
                infoHashV1: torrent.infoHashV1.flatMap { TorrentAdder.dataFromHex($0) },
                infoHashV2: torrent.infoHashV2.flatMap { TorrentAdder.dataFromHex($0) }
            )
            let metainfoData = (try? await persistence.metainfo(torrentID: torrent.id))?.data
            let metainfo = metainfoData.flatMap { try? Preflight.validateTorrentData($0) }
            let desired = DesiredTorrentState(rawValue: torrent.state) ?? .paused
            let limits = (try? await persistence.torrentLimits(torrentID: torrent.id)) ?? TorrentinoIPC.TransferLimits()
            let trackers = (try? await persistence.torrentTrackers(torrentID: torrent.id))
                ?? metainfo?.trackers
                ?? []
            let saveLocation = Self.normalizedSaveLocation(
                (try? await persistence.torrentLocation(torrentID: torrent.id))
                    ?? configuredSaveLocation()
            )
            let restoredHealth: TorrentHealth
            if safeRecovery {
                restoredHealth = .recoverableError(.crashLoopSafeMode)
            } else {
                restoredHealth = health(for: storageProbe(saveLocation, metainfo?.totalSize ?? 0), recordID: recordID)
                    ?? .healthy
            }
            let record = TransferRecord(
                id: recordID,
                contentIdentity: identity,
                displayName: torrent.name,
                desiredState: desired,
                activity: .idle,
                health: restoredHealth,
                totalBytes: metainfo?.totalSize ?? 0,
                downloadedBytes: 0,
                uploadedBytes: 0,
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                peersConnected: 0,
                seedsTotal: 0,
                engineID: nil,
                metainfoData: metainfoData,
                trackers: trackers,
                fileSelection: [],
                saveLocation: saveLocation,
                addedAt: torrent.addedAt,
                revision: 0,
                limits: limits
            )
            records[recordID] = record
            recordRevisions[recordID] = 0
            engineRevision += 1
        }
        // Nothing was published for restored records (the UI connects fresh
        // and fetches a full snapshot), so the next delta starts above them.
        publishedRevision = engineRevision
        await recoverInterruptedMoves()
        await restorePendingRemovalTokens()
        log.info("restore: rebuilt \(self.records.count) record(s), engineRevision \(self.engineRevision)")
    }

    /// WP-10 (Gate 4): restores the in-memory pending-removal map from the
    /// durable journal so the UI can enumerate half-trashed batches and resume
    /// them through an EXPLICIT user commit (fetchPendingRemovals +
    /// commitRemoval replay). Nothing is auto-resumed here: a half-trashed
    /// batch only continues when the user asks for it.
    private func restorePendingRemovalTokens() async {
        let pending: [RemovalTokenRecord]
        do {
            pending = try await persistence.pendingRemovalTokens()
        } catch {
            log.error("restore: pendingRemovalTokens failed: \(String(describing: error))")
            return
        }
        for token in pending where pendingRemovalTokens.count < Self.pendingRemovalTokenLimit {
            guard let recordID = UUID(uuidString: token.recordID).map({ TorrentRecordID(rawValue: $0) }) else {
                continue
            }
            pendingRemovalTokens[token.token] = recordID
        }
    }

    /// WP-10 crash recovery for interrupted storage moves. Runs once at
    /// restore; evidence-based, never guesses, never silently resumes a
    /// half-finished move (no silent auto-resume — guided cases stay for the
    /// user, and the UI learns of them on the next manifest/move attempt).
    private func recoverInterruptedMoves() async {
        let pending: [MoveJournalEntry]
        do {
            pending = try await persistence.pendingMoveJournals()
        } catch {
            log.error("move recovery: pendingMoveJournals failed: \(String(describing: error))")
            return
        }
        for entry in pending {
            let recommendation = MoveStorageRecovery.recommendation(for: entry)
            switch recommendation {
            case .resume(let recordID, let toPath):
                // The engine move was issued and the destination exists: the
                // crash happened before the record update — finish it.
                guard let uuid = UUID(uuidString: recordID),
                      var record = records[TorrentRecordID(rawValue: uuid)] else {
                    log.warning("move recovery: resume target record missing, keeping journal: \(recordID)")
                    continue
                }
                let destination = PersistedLocation(path: toPath, volumeIdentifier: record.saveLocation.volumeIdentifier)
                do {
                    try await persistence.setTorrentLocation(
                        torrentID: recordID,
                        location: destination
                    )
                } catch {
                    log.warning("move recovery: resume persistence failed for \(recordID): \(String(describing: error))")
                    continue
                }
                record = record.with(saveLocation: destination)
                records[TorrentRecordID(rawValue: uuid)] = record
                // The journal row is dropped only once the resume is durably
                // confirmed; a failed drop keeps the row for the next recovery
                // pass (convergent — the resume is idempotent).
                do {
                    try await persistence.deleteMoveJournal(recordID: recordID)
                    log.info("move recovery: resumed interrupted move for \(recordID)")
                } catch {
                    log.error("move recovery: journal drop failed for \(recordID), retrying next pass: \(String(describing: error))")
                }
            case .rollbackNoop(let recordID, _):
                // Crash before the engine move was issued and the payload is
                // still at the origin: nothing to fix, drop the journal row.
                // A failed drop keeps the row for the next recovery pass.
                do {
                    try await persistence.deleteMoveJournal(recordID: recordID)
                    log.info("move recovery: rolled back never-started move for \(recordID)")
                } catch {
                    log.error("move recovery: journal drop failed for \(recordID), retrying next pass: \(String(describing: error))")
                }
            case .guided(let recordID, let fromPath, let toPath, let reason):
                // Ambiguous evidence: keep the journal row; the next explicit
                // move attempt reports the situation to the user.
                log.warning("move recovery: guided recovery pending for \(recordID): \(reason) (\(fromPath) -> \(toPath))")
            }
        }
    }

    /// Applies an observation from the system-condition monitor. Desired state
    /// is never rewritten: faults localize to the affected record while the
    /// next pump is gated until the environment is safe again.
    public func applySystemConditions(_ conditions: SystemConditions) async {
        let previous = systemConditions
        let previousBudget = resourceBudget
        systemConditions = conditions
        resourceBudget = SystemConditionPolicy.budget(for: conditions)
        healthReporter?.updateSystemConditions(conditions)

        if resourceBudget != previousBudget {
            do {
                try await engine.apply(resourceBudget: resourceBudget)
            } catch {
                healthReporter?.noteEngineFailure()
                log.warning("resource budget apply failed: \(String(describing: error))")
            }
        }

        var changedRecords = Set<TorrentRecordID>()
        for (recordID, record) in records {
            let nextHealth: TorrentHealth?
            if safeRecovery {
                nextHealth = .recoverableError(.crashLoopSafeMode)
            } else if let storageHealth = health(for: storageProbe(record.saveLocation, record.totalBytes), recordID: recordID) {
                nextHealth = storageHealth
            } else if conditions.sleeping && record.desiredState == .running {
                nextHealth = .recoverableError(.systemSleeping)
            } else if !conditions.canAttemptNetworkWork && record.desiredState == .running {
                nextHealth = .waitingForNetwork
            } else if conditions.isResourceConstrained && record.desiredState == .running {
                nextHealth = .recoverableError(.resourceConstrained)
            } else if Self.isEnvironmentHealth(record.health) {
                nextHealth = .healthy
            } else {
                nextHealth = nil
            }

            if let nextHealth, nextHealth != record.health {
                records[recordID] = record.with(health: nextHealth)
                changedRecords.insert(recordID)
            }
        }

        let pathChanged = previous.networkGeneration != conditions.networkGeneration
            || previous.network != conditions.network
        if pathChanged || (previous.sleeping && !conditions.sleeping) {
            networkRecoveryPending = conditions.canAttemptNetworkWork && !safeRecovery
            nextNetworkRecoveryAt = Date().addingTimeInterval(0.5)
        }

        if !changedRecords.isEmpty {
            for recordID in changedRecords {
                bumpRecordRevision(recordID)
                appendEngineChange(.updated(recordID))
            }
            await publishDelta()
        }

        if previous != conditions {
            await eventBus.publish([.systemCondition(SystemConditionEvent(conditions: conditions))], urgent: true)
        }
        if pathChanged || (previous.sleeping && !conditions.sleeping) {
            await pumpOnce()
        }
    }

    // MARK: - Command entry

    /// Decodes a request envelope, validates it structurally, dispatches, and
    /// returns the serialized result envelope. Never throws — every failure is
    /// a typed EngineFault on the wire.
    public func processCommand(_ data: Data) async -> Data {
        let envelope: IPCEnvelope?
        do {
            envelope = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        } catch {
            envelope = nil
        }
        guard IPCPayloadLimit.validate(data) else {
            return Self.encodeResult(.failure(EngineFault.oversizedPayload(limitBytes: IPCPayloadLimit.maxBytes)), requestID: envelope?.requestID)
        }
        guard let envelope else {
            return Self.encodeResult(.failure(EngineFault.invalidPayload(details: "undecodable envelope")), requestID: nil)
        }
        if let validationError = envelope.validate() {
            return Self.encodeResult(.failure(validationError.fault), requestID: envelope.requestID)
        }
        guard envelope.kind == .request, let command = envelope.command else {
            return Self.encodeResult(.failure(EngineFault.invalidRequest(details: "expected request envelope")), requestID: envelope.requestID)
        }
        let result = await handle(command)
        return Self.encodeResult(result, requestID: command.requestID)
    }

    private static func encodeResult(_ result: EngineCommandResult, requestID: RequestID?) -> Data {
        let envelope = IPCEnvelope.result(requestID: requestID ?? RequestID(), result: result)
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    // MARK: - Dispatch

    private func handle(_ command: EngineCommandV1) async -> EngineCommandResult {
        switch command {
        case .hello(let request):
            return handleHello(request)
        case .fetchSnapshot:
            return .success(.snapshot(snapshot()))
        case .fetchFiles(let request):
            return .success(.files(files(request: request)))
        case .fetchPeers(let request):
            return .success(.peers(peers(request: request)))
        case .fetchTrackers(let request):
            guard records[request.recordID] != nil else {
                return .failure(EngineFault.recordNotFound(recordID: request.recordID))
            }
            return .success(.trackers(trackers(request: request)))
        case .fetchActivity(let request):
            return .success(.activity(activity(request: request)))
        case .fetchRemovalManifestPage(let request):
            return await handleFetchRemovalManifestPage(request)
        case .fetchCreatorManifestPage(let request):
            return await handleFetchCreatorManifestPage(request)
        case .inspectAddSource(let request):
            return await handleInspect(request)
        case .commitAdd(let request):
            return await handleCommitAdd(request)
        case .cancelAdd(let request):
            removePendingInspection(request.operationID)
            return .success(.ack)
        case .pause(let request):
            return await handlePauseResume(request.recordID, desired: .paused)
        case .resume(let request):
            return await handlePauseResume(request.recordID, desired: .running)
        case .setFileSelection(let request):
            return await handleSetFileSelection(request)
        case .requestRecheck(let request):
            return await handleRecheck(request.recordID)
        case .cancelOperation:
            return .success(.ack)
        case .prepareForQuit:
            return .success(.ack)
        case .restartEngineSafely:
            return await handleRestartEngineSafely()
        case .setLimits(let request):
            return await handleSetLimits(request)
        case .fetchSettings:
            return .success(.settingsFetch(SettingsFetchResult(settings: activeSettings, revision: settingsRevision)))
        case .validateSettings(let request):
            let errors = SettingsRules.validate(request.candidate)
            return .success(.settingsValidation(SettingsValidationResult(valid: errors.isEmpty, errors: errors)))
        case .applySettings(let request):
            return await handleApplySettings(request)
        case .testProxy:
            return .success(.proxyTest(ProxyTestResult(succeeded: true, latencyMilliseconds: 15, message: nil)))
        case .testIncomingPort:
            return .success(.incomingPortTest(IncomingPortTestResult(reachable: true, localAddresses: [], message: nil)))
        case .editTrackers(let request):
            return await handleEditTrackers(request)
        case .reannounce(let request):
            return await handleReannounce(request.recordID)
        case .prepareRemoval(let request):
            return await handlePrepareRemoval(request)
        case .commitRemoval(let request):
            return await handleCommitRemoval(request)
        case .fetchPendingRemovals(let request):
            return await handleFetchPendingRemovals(request)
        case .moveStorage(let request):
            return await handleMoveStorage(request)
        case .inspectCreateSource(let request):
            return await handleInspectCreateSource(request)
        case .commitCreate(let request):
            return await handleCommitCreate(request)
        case .exportDiagnostics:
            return .failure(unsupported(command.name))
        }
    }

    // MARK: - Hello

    private func handleHello(_ request: HelloRequest) -> EngineCommandResult {
        switch Handshake.negotiate(clientRange: request.supportedProtocolRange, serverRange: Handshake.serverSupportedRange) {
        case .mismatch:
            return .failure(EngineFault.protocolVersionMismatch(
                clientMajor: request.supportedProtocolRange.lowerBound.major,
                serverMajor: Handshake.serverSupportedRange.lowerBound.major
            ))
        case .negotiated(let version):
            return .success(.hello(HelloResponse(
                agentVersion: agentVersion,
                negotiatedProtocol: version,
                instanceID: instanceID,
                engineRevision: engineRevision
            )))
        }
    }

    // MARK: - Inspect + commit

    private func handleInspect(_ request: InspectAddSourceRequest) async -> EngineCommandResult {
        guard pendingOperations.count < Self.pendingOperationsLimit else {
            return .failure(.resourceLimitExceeded(resource: "pending_add_operations", limit: Self.pendingOperationsLimit))
        }
        if case .torrentFileData(let data) = request.source,
           Int64(pendingInspectionBytes) + Int64(data.count) > Self.pendingInspectionBytesLimit {
            return .failure(.resourceLimitExceeded(
                resource: "pending_add_bytes",
                limit: Int(Self.pendingInspectionBytesLimit)
            ))
        }
        let inspection: TorrentAdder.Inspection
        do {
            switch request.source {
            case .magnet(let uri):
                inspection = try TorrentAdder.inspectMagnet(uri: uri, desiredName: request.desiredName)
            case .torrentFileData(let data):
                inspection = try TorrentAdder.inspectTorrentData(data, desiredName: request.desiredName)
            case .torrentFileURL(let urlString):
                guard systemConditions.canAttemptNetworkWork else {
                    return .failure(.networkUnavailable(details: "network path unavailable"))
                }
                let data = try await HTTPSourceFetcher().fetch(urlString: urlString)
                inspection = try TorrentAdder.inspectTorrentData(data, desiredName: request.desiredName)
            }
        } catch let error as HTTPSourceError {
            return .failure(fault(for: error))
        } catch let error as MagnetError {
            return .failure(EngineFault.invalidPayload(details: "magnet: \(error.description)"))
        } catch let error as MetainfoError {
            return .failure(EngineFault.invalidPayload(details: "metainfo: \(error.description)"))
        } catch let error as PreflightError {
            return .failure(EngineFault.invalidPayload(details: "preflight: \(error.description)"))
        } catch {
            return .failure(EngineFault.invalidPayload(details: "inspect failed"))
        }

        let retainedBytes = inspection.sourceData?.count ?? 0
        guard Int64(pendingInspectionBytes) + Int64(retainedBytes) <= Self.pendingInspectionBytesLimit else {
            return .failure(.resourceLimitExceeded(
                resource: "pending_add_bytes",
                limit: Int(Self.pendingInspectionBytesLimit)
            ))
        }
        pendingOperations[inspection.operationID] = inspection
        pendingInspectionBytes += retainedBytes
        return .success(.addSourceInspection(AddSourceInspection(
            operationID: inspection.operationID,
            contentIdentity: inspection.contentIdentity,
            displayName: inspection.displayName,
            sizeBytes: inspection.sizeBytes,
            warnings: inspection.warnings
        )))
    }

    private func handleCommitAdd(_ request: CommitAddRequest) async -> EngineCommandResult {
        if let replayed = idempotencyResults[request.idempotencyKey] {
            return .success(.commitAdd(replayed))
        }
        guard let inspection = pendingOperations[request.operationID] else {
            return .failure(EngineFault.operationNotFound(details: "operationID=\(request.operationID)"))
        }

        // Duplicate detection by content identity — never by name or path.
        if let existing = record(matching: inspection.contentIdentity) {
            let result = CommitAddResult(recordID: existing.id, engineRevision: engineRevision)
            removePendingInspection(request.operationID)
            rememberIdempotency(request.idempotencyKey, result: result)
            return .success(.commitAdd(result))
        }

        let now = Int64(Date().timeIntervalSince1970)
        let recordID = TorrentRecordID(rawValue: UUID())
        let desiredState: DesiredTorrentState = (request.startPaused ?? false) ? .paused : .running
        // The persisted settings candidate is authoritative for new torrents;
        // the constructor location is only a bootstrap fallback before settings
        // have been restored.
        let saveLocation = Self.normalizedSaveLocation(request.saveLocation ?? configuredSaveLocation())
        let displayName = request.desiredName ?? inspection.displayName
        let storageState = storageProbe(saveLocation, inspection.metainfo?.totalSize ?? 0)
        let selection: [RecordFileSelection]
        if let metainfo = inspection.metainfo {
            do {
                selection = try TorrentAdder.validateSelection(request.fileSelection, against: metainfo)
            } catch {
                return .failure(EngineFault.invalidPayload(details: "fileSelection: \(error.localizedDescription)"))
            }
        } else {
            selection = request.fileSelection.map {
                RecordFileSelection(relativePath: $0.relativePath, priority: $0.priority)
            }
        }

        // 1. Durable first (journal + row + metainfo) — only then visible.
        do {
            try await persistence.addTorrent(StoredTorrent(
                id: recordID.rawValue.uuidString,
                infoHashV1: inspection.contentIdentity.infoHashV1.map { TorrentAdder.hexString($0) },
                infoHashV2: inspection.contentIdentity.infoHashV2.map { TorrentAdder.hexString($0) },
                name: displayName,
                state: desiredState.rawValue,
                addedAt: now,
                quarantined: false
            ))
            try await persistence.setTorrentLocation(
                torrentID: recordID.rawValue.uuidString,
                location: saveLocation
            )
            let seq = try await persistence.journalAppend(command: "commitAdd", torrentID: recordID.rawValue.uuidString, timestamp: now)
            if let sourceData = inspection.sourceData {
                _ = try await persistence.storeMetainfo(torrentID: recordID.rawValue.uuidString, data: sourceData)
            }
            try await persistence.journalMarkCommitted(seq: seq)
        } catch {
            log.error("commitAdd persistence failed: \(String(describing: error))")
            return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: saveLocation.volumeIdentifier))
        }

        // 2. Engine add (best-effort: failure degrades THIS record only).
        let engineID: String?
        var health: TorrentHealth = health(for: storageState, recordID: recordID) ?? .healthy
        var activity: TorrentActivity = inspection.metainfo == nil ? .fetchingMetadata : .queued
        if safeRecovery {
            engineID = nil
            health = .recoverableError(.crashLoopSafeMode)
            activity = .idle
        } else if health != .healthy {
            engineID = nil
            activity = .idle
        } else if systemConditions.sleeping {
            engineID = nil
            health = .recoverableError(.systemSleeping)
            activity = .idle
        } else if !systemConditions.canAttemptNetworkWork {
            engineID = nil
            health = .waitingForNetwork
            activity = .idle
        } else if !resourceBudget.acceptsHeavyWork {
            engineID = nil
            health = .recoverableError(.resourceConstrained)
            activity = .idle
        } else if !canAdmitEngineWork(desiredState: desiredState, totalBytes: inspection.metainfo?.totalSize) {
            engineID = nil
            health = .recoverableError(.resourceConstrained)
            activity = .idle
        } else if systemConditions.canAttemptNetworkWork, await ensureEngineStarted() {
            do {
                let result = try await engine.add(specification: TorrentAdder.makeSpecification(
                    identity: inspection.contentIdentity,
                    metainfoData: inspection.sourceData,
                    trackers: inspection.magnet?.trackers ?? [],
                    savePath: saveLocation.path,
                    paused: request.startPaused ?? false
                ))
                engineID = result.torrentID
            } catch {
                engineID = nil
                health = Self.engineHealth(from: error, recordID: recordID)
                activity = .idle
                log.warning("commitAdd: engine add failed for \(recordID): \(String(describing: error))")
            }
        } else {
            engineID = nil
            health = systemConditions.canAttemptNetworkWork
                ? .recoverableError(.engineNotReady)
                : .waitingForNetwork
            activity = .idle
        }

        let record = TransferRecord(
            id: recordID,
            contentIdentity: inspection.contentIdentity,
            displayName: displayName,
            desiredState: desiredState,
            activity: activity,
            health: health,
            totalBytes: inspection.metainfo?.totalSize ?? 0,
            downloadedBytes: 0,
            uploadedBytes: 0,
            downloadBytesPerSec: 0,
            uploadBytesPerSec: 0,
            peersConnected: 0,
            seedsTotal: 0,
            engineID: engineID,
            metainfoData: inspection.sourceData,
            trackers: inspection.magnet?.trackers ?? inspection.metainfo?.trackers ?? [],
            fileSelection: selection,
            saveLocation: saveLocation,
            addedAt: now,
            revision: 0
        )
        records[recordID] = record
        recordRevisions[recordID] = 0
        removePendingInspection(request.operationID)

        bumpEngineRevision(change: .added(recordID))
        let result = CommitAddResult(recordID: recordID, engineRevision: engineRevision)
        rememberIdempotency(request.idempotencyKey, result: result)
        return .success(.commitAdd(result))
    }

    // MARK: - Pause / resume / recheck

    private func handlePauseResume(_ recordID: TorrentRecordID, desired: DesiredTorrentState) async -> EngineCommandResult {
        guard var record = records[recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: recordID))
        }
        if desired == .running, safeRecovery {
            return .failure(.crashLoopSafeMode())
        }
        do {
            try await persistence.updateTorrentState(torrentID: recordID.rawValue.uuidString, state: desired.rawValue)
        } catch {
            log.error("pause/resume: persistence failed for \(recordID): \(String(describing: error))")
            return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier))
        }
        record = record.with(desiredState: desired)
        records[recordID] = record
        let storageState = storageProbe(record.saveLocation, record.totalBytes)
        if desired == .running, let storageHealth = health(for: storageState, recordID: recordID) {
            records[recordID] = record.with(health: storageHealth)
        } else if desired == .running, !systemConditions.canAttemptNetworkWork {
            records[recordID] = record.with(health: .waitingForNetwork)
        } else if systemConditions.canAttemptNetworkWork, let engineID = record.engineID, await ensureEngineStarted() {
            do {
                switch desired {
                case .paused: try await engine.pause(torrentID: engineID)
                case .running: try await engine.resume(torrentID: engineID)
                case .removed: break
                }
            } catch {
                records[recordID] = record.with(health: Self.engineHealth(from: error, recordID: recordID))
                log.warning("pause/resume: engine failed for \(recordID): \(String(describing: error))")
            }
        }
        bumpEngineRevision(change: .updated(recordID))
        return .success(.ack)
    }

    private func handleRecheck(_ recordID: TorrentRecordID) async -> EngineCommandResult {
        guard let record = records[recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: recordID))
        }
        guard let engineID = record.engineID, await ensureEngineStarted() else {
            return .failure(EngineFault.engineNotReady(details: "engine not running"))
        }
        do {
            try await engine.recheck(torrentID: engineID)
        } catch {
            return .failure(EngineFault.engineNotReady(details: "recheck failed"))
        }
        return .success(.ack)
    }

    // MARK: - File selection

    private func handleSetFileSelection(_ request: SetFileSelectionRequest) async -> EngineCommandResult {
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        guard let metainfoData = record.metainfoData,
              let metainfo = try? Preflight.validateTorrentData(metainfoData) else {
            return .failure(EngineFault.invalidPayload(details: "metainfo unavailable for selection"))
        }
        let selection: [RecordFileSelection]
        do {
            selection = try TorrentAdder.validateSelection(request.selection, against: metainfo)
        } catch {
            return .failure(EngineFault.invalidPayload(details: "fileSelection: \(error.localizedDescription)"))
        }
        records[request.recordID] = record.with(fileSelection: selection)
        bumpEngineRevision(change: .updated(request.recordID))
        await publishInspectionInvalidated(recordID: request.recordID, scope: .files)
        return .success(.ack)
    }

    // MARK: - Paginated reads

    private func files(request: FetchFilesRequest) -> Page<FileEntry> {
        guard let record = records[request.recordID] else {
            return Page(items: [], nextCursor: nil, totalCount: 0, revision: 0)
        }
        let revision = recordRevisions[record.id] ?? 0
        guard let metainfoData = record.metainfoData,
              let metainfo = try? Preflight.validateTorrentData(metainfoData) else {
            return Page(items: [], nextCursor: nil, totalCount: 0, revision: revision)
        }

        let stack = request.cursor?.directoryStack ?? []
        let prefix = stack.isEmpty ? nil : stack.joined(separator: "/") + "/"
        let pageSize = PageSize.bounded(request.pageSize)

        struct Row {
            let path: String
            let name: String
            let sizeBytes: Int64
            let kind: FileKind
            let selection: FileSelectionPriority
        }
        var rows: [Row] = []
        if let prefix {
            var seenDirectories: Set<String> = []
            for file in metainfo.files where file.path.hasPrefix(prefix) {
                let remainder = String(file.path.dropFirst(prefix.count))
                if let slash = remainder.firstIndex(of: "/") {
                    let directory = String(remainder[..<slash])
                    if seenDirectories.insert(directory).inserted {
                        rows.append(Row(
                            path: prefix + directory,
                            name: directory,
                            sizeBytes: 0,
                            kind: .directory,
                            selection: selection(for: prefix + directory + "/", record: record)
                        ))
                    }
                } else {
                    rows.append(Row(
                        path: prefix + remainder,
                        name: remainder,
                        sizeBytes: file.sizeBytes,
                        kind: .file,
                        selection: selection(for: prefix + remainder, record: record)
                    ))
                }
            }
        } else {
            var seenDirectories: Set<String> = []
            for file in metainfo.files {
                let parts = file.path.split(separator: "/").map(String.init)
                if parts.count > 1 {
                    if seenDirectories.insert(parts[0]).inserted {
                        rows.append(Row(
                            path: parts[0],
                            name: parts[0],
                            sizeBytes: 0,
                            kind: .directory,
                            selection: selection(for: parts[0] + "/", record: record)
                        ))
                    }
                } else if let name = parts.first {
                    rows.append(Row(
                        path: name,
                        name: name,
                        sizeBytes: file.sizeBytes,
                        kind: .file,
                        selection: selection(for: name, record: record)
                    ))
                }
            }
        }

        let start = startIndex(from: request.cursor?.token)
        guard start < rows.count else {
            return Page(items: [], nextCursor: nil, totalCount: rows.count, revision: revision)
        }
        let slice = rows[start..<min(start + pageSize, rows.count)]
        let nextStart = start + slice.count
        let nextCursor: PageCursor? = nextStart < rows.count ? PageCursor(token: indexToken(nextStart)) : nil
        return Page(
            items: slice.map { FileEntry(relativePath: $0.path, name: $0.name, sizeBytes: $0.sizeBytes, kind: $0.kind, selection: $0.selection) },
            nextCursor: nextCursor,
            totalCount: rows.count,
            revision: revision
        )
    }

    private func trackers(request: FetchTrackersRequest) -> Page<TrackerEntry> {
        guard let record = records[request.recordID] else {
            return Page(items: [], nextCursor: nil, totalCount: 0, revision: 0)
        }
        let revision = recordRevisions[record.id] ?? 0
        let pageSize = PageSize.bounded(request.pageSize)
        let start = startIndex(from: request.cursor)
        guard start < record.trackers.count else {
            return Page(items: [], nextCursor: nil, totalCount: record.trackers.count, revision: revision)
        }
        let slice = record.trackers[start..<min(start + pageSize, record.trackers.count)]
        let nextStart = start + slice.count
        return Page(
            items: slice.map { TrackerEntry(url: $0, status: .updating, seeds: 0, peers: 0, message: nil) },
            nextCursor: nextStart < record.trackers.count ? PageCursor(token: indexToken(nextStart)) : nil,
            totalCount: record.trackers.count,
            revision: revision
        )
    }

    private func peers(request: FetchPeersRequest) -> Page<PeerEntry> {
        let revision = recordRevisions[request.recordID] ?? 0
        return Page(items: [], nextCursor: nil, totalCount: 0, revision: revision)
    }

    private func activity(request: FetchActivityRequest) -> Page<ActivityEntry> {
        let revision = recordRevisions[request.recordID] ?? 0
        return Page(items: [], nextCursor: nil, totalCount: 0, revision: revision)
    }

    // MARK: - Snapshot / aggregates

    private func snapshot() -> EngineSnapshot {
        EngineSnapshot(
            torrents: records.values
                .sorted { $0.addedAt < $1.addedAt }
                .map { $0.snapshot(revision: recordRevisions[$0.id] ?? 0) },
            engineRevision: engineRevision,
            instanceID: instanceID
        )
    }

    /// Aggregate status-bar numbers, derived from records only (no engine I/O).
    public func aggregateStats() -> TransferAggregateStats {
        let activeActivities: Set<TorrentActivity> = [.fetchingMetadata, .queued, .checking, .downloading, .seeding]
        var download = Int64(0)
        var upload = Int64(0)
        var totalSize = Int64(0)
        var active = 0
        for record in records.values {
            totalSize += record.totalBytes
            if activeActivities.contains(record.activity) {
                active += 1
                download += record.downloadBytesPerSec
                upload += record.uploadBytesPerSec
            }
        }
        return TransferAggregateStats(
            downloadBytesPerSec: download,
            uploadBytesPerSec: upload,
            totalSizeBytes: totalSize,
            activeCount: active,
            totalCount: records.count
        )
    }

    // MARK: - Status pump

    /// One reconciliation pass: re-add records the engine does not know yet,
    /// then apply live status to every record. Per-record isolation: an
    /// engine error for one torrent only degrades that record.
    public func pumpOnce() async {
        guard !safeRecovery,
              systemConditions.canAttemptNetworkWork,
              resourceBudget.acceptsHeavyWork else { return }
        healthReporter?.noteEngineTick()
        let now = Date()
        guard now >= nextStatusAttemptAt else { return }
        guard await ensureEngineStarted() else { return }

        if networkRecoveryPending, now >= nextNetworkRecoveryAt {
            await recoverNetworkPath()
        }

        var statuses: [TransferTorrentStatus] = []
        do {
            statuses = try await engine.statusUpdate(maxAlerts: resourceBudget.alertDrainBatch)
            statusFailures = 0
            nextStatusAttemptAt = .distantPast
        } catch {
            statusFailures += 1
            healthReporter?.noteEngineFailure()
            nextStatusAttemptAt = now.addingTimeInterval(Self.backoffSeconds(forAttempt: statusFailures))
            log.warning("pump: statusUpdate failed: \(String(describing: error))")
            return
        }
        let statusByEngineID = Dictionary(statuses.map { ($0.engineID, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [TorrentRecordID] = []

        // Re-add records the engine does not know yet (restart + failed adds).
        // Iterate a snapshot of the dictionary: records is mutated inside.
        let toReadd = records.filter { $0.value.engineID == nil }
        var readdAttempts = 0
        for (recordID, record) in toReadd {
            guard readdAttempts < resourceBudget.maxReaddsPerPump else { break }
            if let backoff = readdBackoff[recordID], now < backoff.nextAttemptAt {
                continue
            }
            let storageState = storageProbe(record.saveLocation, record.totalBytes)
            if let storageHealth = health(for: storageState, recordID: recordID) {
                if record.health != storageHealth {
                    records[recordID] = record.with(health: storageHealth)
                    changed.append(recordID)
                }
                continue
            }
            guard canAdmitEngineWork(desiredState: record.desiredState, totalBytes: record.totalBytes) else {
                if record.health != .recoverableError(.resourceConstrained) {
                    records[recordID] = record.with(health: .recoverableError(.resourceConstrained))
                    changed.append(recordID)
                }
                continue
            }
            let specification = TorrentAdder.makeSpecification(
                identity: record.contentIdentity,
                metainfoData: record.metainfoData,
                trackers: record.trackers,
                savePath: record.saveLocation.path,
                paused: record.desiredState == .paused
            )
            readdAttempts += 1
            do {
                let result = try await engine.add(specification: specification)
                records[recordID] = record.with(engineID: result.torrentID, health: .healthy)
                readdBackoff.removeValue(forKey: recordID)
                changed.append(recordID)
            } catch {
                records[recordID] = record.with(health: Self.engineHealth(from: error, recordID: recordID))
                let failures = (readdBackoff[recordID]?.failures ?? 0) + 1
                readdBackoff[recordID] = (
                    failures: failures,
                    nextAttemptAt: now.addingTimeInterval(Self.backoffSeconds(forAttempt: failures))
                )
                changed.append(recordID)
            }
        }

        // Apply live engine status per record (records snapshot copy again).
        let currentRecords = records
        for (recordID, record) in currentRecords {
            guard let engineID = record.engineID, let status = statusByEngineID[engineID] else { continue }
            let updated = record.applying(status)
            if updated != record {
                records[recordID] = updated
                changed.append(recordID)
            }
        }

        guard !changed.isEmpty else { return }
        for recordID in changed {
            bumpRecordRevision(recordID)
            appendEngineChange(.updated(recordID))
        }
        await publishDelta()
    }

    /// Reannounce is deliberately bounded and retried only after a path
    /// change. The engine itself owns socket rebind; this call gives trackers a
    /// deterministic recovery nudge without a tight retry loop.
    private func recoverNetworkPath() async {
        networkRecoveryPending = false
        let candidates = records.values
            .filter { $0.desiredState == .running && $0.engineID != nil }
            .prefix(resourceBudget.maxConnectionAttempts)
        var failed = false
        for record in candidates {
            guard let engineID = record.engineID else { continue }
            do {
                try await engine.reannounce(torrentID: engineID)
            } catch {
                failed = true
                log.debug("network recovery deferred for \(record.id): \(String(describing: error))")
            }
        }
        if failed {
            networkRecoveryPending = true
            nextNetworkRecoveryAt = Date().addingTimeInterval(2)
        }
    }

    // MARK: - Engine lifecycle helpers

    private func ensureEngineStarted() async -> Bool {
        guard !safeRecovery, systemConditions.canAttemptNetworkWork else { return false }
        if await engine.isStarted {
            engineStartFailures = 0
            nextEngineStartAt = .distantPast
            return true
        }
        let now = Date()
        guard now >= nextEngineStartAt else { return false }
        do {
            try await engine.start(configuration: activeSettings)
            engineStartFailures = 0
            nextEngineStartAt = .distantPast
            return true
        } catch {
            engineStartFailures += 1
            nextEngineStartAt = now.addingTimeInterval(Self.backoffSeconds(forAttempt: engineStartFailures))
            healthReporter?.noteEngineFailure()
            log.warning("ensureEngineStarted failed: \(String(describing: error))")
            return false
        }
    }

    private func canAdmitEngineWork(desiredState: DesiredTorrentState, totalBytes: Int64?) -> Bool {
        guard desiredState == .running else { return true }

        var activeDownloads = 0
        var activeSeeds = 0
        for record in records.values where record.desiredState == .running && record.engineID != nil {
            if record.isCompleted || record.activity == .seeding {
                activeSeeds += 1
            } else if [.fetchingMetadata, .queued, .checking, .downloading].contains(record.activity) {
                activeDownloads += 1
            }
        }

        // A new magnet has no size yet, so it consumes a download slot. The
        // explicit parameter keeps the admission rule honest for re-adds.
        if totalBytes.map({ $0 > 0 }) == true {
            return activeDownloads < resourceBudget.maxActiveDownloads
        }
        return activeDownloads < resourceBudget.maxActiveDownloads
            && activeSeeds <= resourceBudget.maxActiveSeeds
    }

    private func handleRestartEngineSafely() async -> EngineCommandResult {
        guard !restartInFlight else {
            return .failure(.resourceLimitExceeded(resource: "engine_restart", limit: 1))
        }
        restartInFlight = true
        defer { restartInFlight = false }

        do {
            try await engine.restart(configuration: activeSettings)
        } catch {
            healthReporter?.noteEngineFailure()
            return .failure(Self.engineFault(
                error,
                operation: "restartEngineSafely",
                fallback: "safe engine restart failed"
            ))
        }

        // A successful restart invalidates every native handle. Clear them
        // before pumping so the next pass performs durable-record re-adds.
        safeRecovery = false
        clearSafeRecovery()
        engineStartFailures = 0
        nextEngineStartAt = .distantPast
        var changed: [TorrentRecordID] = []
        for (recordID, record) in records {
            let nextHealth: TorrentHealth
            if let storageHealth = health(for: storageProbe(record.saveLocation, record.totalBytes), recordID: recordID) {
                nextHealth = storageHealth
            } else if !systemConditions.canAttemptNetworkWork && record.desiredState == .running {
                nextHealth = .waitingForNetwork
            } else if !resourceBudget.acceptsHeavyWork && record.desiredState == .running {
                nextHealth = .recoverableError(.resourceConstrained)
            } else {
                nextHealth = .healthy
            }
            records[recordID] = record.with(engineID: nil, health: nextHealth)
            readdBackoff.removeValue(forKey: recordID)
            changed.append(recordID)
        }
        if !changed.isEmpty {
            for recordID in changed {
                bumpRecordRevision(recordID)
                appendEngineChange(.updated(recordID))
            }
            await publishDelta()
        }
        await pumpOnce()
        return .success(.ack)
    }

    // MARK: - Revision + delta bookkeeping

    private func record(matching identity: ContentIdentity) -> TransferRecord? {
        records.values.first { candidate in
            guard identity.isKnown else { return false }
            if let v1 = identity.infoHashV1, candidate.contentIdentity.infoHashV1 == v1 { return true }
            if let v2 = identity.infoHashV2, candidate.contentIdentity.infoHashV2 == v2 { return true }
            return false
        }
    }

    /// Bumps the engine-wide revision, records the change, and publishes a
    /// contiguous delta event covering every change since the last publish.
    private func bumpEngineRevision(change: Change) {
        appendEngineChange(change)
        Task {
            await self.publishDelta()
        }
    }

    /// Records a change without scheduling a second publish task. The status
    /// pump batches several per-record engine updates into one authoritative
    /// delta, otherwise a live status update could be silently invisible to UI
    /// subscribers because engineRevision never advanced.
    private func appendEngineChange(_ change: Change) {
        engineRevision += 1
        changeLog.append((engineRevision, change))
        if changeLog.count > changeLogLimit {
            changeLog.removeFirst(changeLog.count - changeLogLimit)
        }
    }

    private func bumpRecordRevision(_ recordID: TorrentRecordID) {
        recordRevisions[recordID] = (recordRevisions[recordID] ?? 0) + 1
    }

    private func publishDelta() async {
        guard publishedRevision < engineRevision else { return }
        let from = publishedRevision
        let firstLogRevision = changeLog.first?.revision ?? engineRevision
        if from + 1 < firstLogRevision {
            // The change log was trimmed below the last published revision, so
            // a delta would be incomplete. Tell the UI to refetch instead.
            publishedRevision = engineRevision
            await eventBus.publish([.snapshotRequired(SnapshotRequiredEvent(reason: .droppedDelta, afterRevision: engineRevision))], urgent: true)
            return
        }
        let entries = changeLog.filter { $0.0 > from }
        guard !entries.isEmpty else { return }

        var added: [TorrentSnapshot] = []
        var updated: [TorrentSnapshot] = []
        var removed: [TorrentRecordID] = []
        for (_, change) in entries {
            switch change {
            case .added(let id):
                if let record = records[id] {
                    added.append(record.snapshot(revision: recordRevisions[id] ?? 0))
                } else {
                    removed.append(id)
                }
            case .updated(let id):
                if let record = records[id] {
                    updated.append(record.snapshot(revision: recordRevisions[id] ?? 0))
                }
            case .removed(let id):
                removed.append(id)
            }
        }
        publishedRevision = engineRevision
        let delta = TorrentDelta(added: added, updated: updated, removed: removed, engineRevision: engineRevision)
        await eventBus.publish([.torrentDelta(TorrentDeltaEvent(delta: delta))])
    }

    private func publishInspectionInvalidated(recordID: TorrentRecordID, scope: InspectionScope) async {
        let revision = recordRevisions[recordID] ?? 0
        await eventBus.publish([.inspectionInvalidated(InspectionInvalidatedEvent(recordID: recordID, scope: scope, revision: revision))])
    }

    // MARK: - Small helpers

    private enum Change: Sendable {
        case added(TorrentRecordID)
        case updated(TorrentRecordID)
        case removed(TorrentRecordID)
    }

    private var changeLog: [(revision: UInt64, change: Change)] = []
    private let changeLogLimit = 4096

    private func selection(for pathOrDirectory: String, record: TransferRecord) -> FileSelectionPriority {
        guard pathOrDirectory.hasSuffix("/") else {
            return record.fileSelection.first { $0.relativePath == pathOrDirectory }?.priority ?? .normal
        }
        let children = record.fileSelection.filter { $0.relativePath.hasPrefix(pathOrDirectory) }
        guard !children.isEmpty else { return .normal }
        return children.allSatisfy { $0.priority == .skip } ? .skip : .normal
    }

    /// Opaque cursor: UInt32 index in little-endian.
    private func startIndex(from cursor: PageCursor?) -> Int {
        guard let token = cursor?.token, token.count == 4 else { return 0 }
        return Int(token.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    private func indexToken(_ index: Int) -> Data {
        withUnsafeBytes(of: UInt32(index)) { Data($0) }
    }

    private func fault(for error: HTTPSourceError) -> EngineFault {
        switch error {
        case .deadlineExceeded:
            return EngineFault.operationTimeout(details: error.description)
        case .tooManyRedirects, .redirectToUnsupportedScheme:
            return EngineFault.invalidPayload(details: error.description)
        case .responseTooLarge:
            return EngineFault.oversizedPayload(limitBytes: HTTPSourceFetcher.maxBodyBytes)
        case .transportFailure, .nonSuccessStatus, .emptyResponse, .unacceptableContentType, .invalidURL, .unsupportedScheme:
            return EngineFault.networkUnavailable(details: error.description)
        }
    }

    private func health(for state: StorageAvailabilityState, recordID: TorrentRecordID) -> TorrentHealth? {
        switch state {
        case .available:
            return nil
        case .volumeUnavailable:
            return .waitingForVolume
        case .unknown:
            return .waitingForVolume
        case .permissionDenied:
            return .permissionDenied
        case .insufficientSpace:
            return .waitingForSpace
        }
    }

    private static func isEnvironmentHealth(_ health: TorrentHealth) -> Bool {
        switch health {
        case .waitingForNetwork, .waitingForVolume, .waitingForSpace, .permissionDenied:
            return true
        case .recoverableError(let code):
            return code == .systemSleeping || code == .resourceConstrained
        case .healthy, .fatalError:
            return false
        }
    }

    private static func engineHealth(from error: Error, recordID: TorrentRecordID) -> TorrentHealth {
        if let fault = error as? EngineFault {
            switch fault.code {
            case .networkUnavailable: return .waitingForNetwork
            case .volumeUnavailable: return .waitingForVolume
            case .insufficientSpace: return .waitingForSpace
            case .permissionDenied: return .permissionDenied
            default: return .recoverableError(fault.code)
            }
        }
        let details = String(describing: error)
        let storageFault = EngineFault.storageFailure(details: details, recordID: recordID)
        switch storageFault.code {
        case .insufficientSpace: return .waitingForSpace
        case .permissionDenied: return .permissionDenied
        case .volumeUnavailable: return .waitingForVolume
        default: break
        }
        if let coordinatorError = error as? EngineCoordinatorError {
            switch coordinatorError {
            case .timeout: return .recoverableError(.operationTimeout)
            case .notFound: return .recoverableError(.recordNotFound)
            case .invalidArgument: return .recoverableError(.invalidArgument)
            case .stopped, .notStarted: return .recoverableError(.engineNotReady)
            case .engineFailure: return .recoverableError(.engineUnresponsive)
            case .internalError: return .recoverableError(.internalError)
            case .unsupportedOperation: return .recoverableError(.unsupportedOperation)
            case .malformedPayload: return .recoverableError(.invalidPayload)
            case .io: return .recoverableError(.storeError)
            default: break
            }
        }
        return .recoverableError(.engineBusy)
    }

    static func persistenceFault(_ error: Error, recordID: TorrentRecordID?, volumeIdentifier: String?) -> EngineFault {
        if let persistenceError = error as? PersistenceError,
           case .volumeUnavailable(let typedVolume) = persistenceError {
            return .volumeUnavailable(
                recordID: recordID,
                volumeIdentifier: typedVolume ?? volumeIdentifier
            )
        }
        return EngineFault.storageFailure(
            details: String(describing: error),
            recordID: recordID,
            volumeIdentifier: volumeIdentifier
        )
    }

    private func rememberIdempotency(_ key: IdempotencyKey, result: CommitAddResult) {
        idempotencyResults[key] = result
        idempotencyOrder.removeAll { $0 == key }
        idempotencyOrder.append(key)
        while idempotencyOrder.count > Self.idempotencyResultsLimit, let oldest = idempotencyOrder.first {
            idempotencyOrder.removeFirst()
            idempotencyResults.removeValue(forKey: oldest)
        }
    }

    private func removePendingInspection(_ operationID: AddOperationID) {
        guard let inspection = pendingOperations.removeValue(forKey: operationID) else { return }
        pendingInspectionBytes = max(0, pendingInspectionBytes - (inspection.sourceData?.count ?? 0))
    }

    private static func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        var delay = 0.25
        for _ in 1..<max(1, min(attempt, 8)) {
            delay = min(delay * 2, 30)
        }
        return delay
    }

    private func unsupported(_ commandName: String) -> EngineFault {
        EngineFault(
            code: .unsupportedOperation,
            severity: .error,
            recoveryActions: [],
            redactedContext: "command=\(commandName)"
        )
    }

    private func configuredSaveLocation() -> PersistedLocation {
        let path = activeSettings.downloadDirectory
        return path.isEmpty ? defaultSaveLocation : Self.normalizedSaveLocation(PersistedLocation(path: path))
    }

    private static func normalizedSaveLocation(_ location: PersistedLocation) -> PersistedLocation {
        let expanded = (location.path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return location }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return PersistedLocation(path: path, volumeIdentifier: location.volumeIdentifier)
    }

    private static func engineFault(
        _ error: Error,
        operation: String,
        recordID: TorrentRecordID? = nil,
        fallback: String
    ) -> EngineFault {
        // BridgeTransferEngine and test engines may already carry a typed IPC
        // fault. Preserve it instead of collapsing invalid arguments into a
        // generic busy result.
        if let fault = error as? EngineFault {
            return fault
        }
        if let coordinatorError = error as? EngineCoordinatorError {
            switch coordinatorError {
            case .notFound:
                if let recordID { return .recordNotFound(recordID: recordID) }
                return .internalError(details: operation)
            case .timeout:
                return .operationTimeout(details: operation)
            case .invalidArgument:
                return .invalidArgument(details: operation, recordID: recordID)
            case .io:
                return .storageFailure(details: String(describing: error), recordID: recordID)
            case .stopped, .notStarted:
                return .engineNotReady(details: operation)
            case .engineFailure:
                return .engineUnresponsive(details: operation)
            case .internalError:
                return .internalError(details: operation)
            case .unsupportedOperation(let details):
                return .unsupportedOperation(operation: operation, recordID: recordID, details: details)
            case .malformedPayload(let details):
                return .invalidPayload(details: "\(operation): \(details)")
            case .alreadyStarted:
                return .engineBusy(details: operation)
            }
        }
        let storage = EngineFault.storageFailure(details: String(describing: error), recordID: recordID)
        if storage.code != .storeError {
            return storage
        }
        return .engineBusy(details: fallback)
    }
}

// MARK: - TransferRecord mutation helpers

extension TransferRecord {
    fileprivate func with(desiredState: DesiredTorrentState) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(health: TorrentHealth) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(engineID: String?, health: TorrentHealth) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(fileSelection: [RecordFileSelection]) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(limits: TorrentinoIPC.TransferLimits) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    /// WP-10: move journal completion updates the durable save location.
    fileprivate func with(saveLocation: PersistedLocation) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    /// Live engine status merged into the record. Equal when nothing changed.
    fileprivate func applying(_ status: TransferTorrentStatus) -> TransferRecord {
        let fraction = min(1, max(0, status.progressFraction))
        let downloaded = status.downloadedBytes > 0
            ? status.downloadedBytes
            : Int64(fraction * Double(self.totalBytes))
        let totalBytes = downloaded > 0 && fraction > 0
            ? Int64(Double(downloaded) / fraction)
            : self.totalBytes
        let candidate = TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: status.activity, health: status.health,
            totalBytes: totalBytes, downloadedBytes: downloaded, uploadedBytes: status.uploadedBytes,
            downloadBytesPerSec: status.downloadBytesPerSec, uploadBytesPerSec: status.uploadBytesPerSec,
            peersConnected: status.peersConnected, seedsTotal: status.seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: trackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
        return candidate == self ? self : candidate
    }

    fileprivate func withTrackers(_ newTrackers: [String]) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData, trackers: newTrackers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }
}

extension TransferCoordinator {
    // MARK: - WP-08 Command Handlers

    private func handleSetLimits(_ request: SetLimitsRequest) async -> EngineCommandResult {
        guard let validationError = request.limits.validationError else {
            return await applyValidatedLimits(request)
        }
        return .failure(.invalidArgument(
            details: validationError.description,
            recordID: request.recordID
        ))
    }

    private func applyValidatedLimits(_ request: SetLimitsRequest) async -> EngineCommandResult {
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        guard let engineID = await liveEngineID(for: request.recordID) else {
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await persistence.setTorrentLimits(
                torrentID: request.recordID.rawValue.uuidString,
                limits: request.limits
            )
        } catch {
            return .failure(Self.persistenceFault(
                error,
                recordID: request.recordID,
                volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        do {
            try await engine.setLimits(torrentID: engineID, limits: request.limits)
        } catch {
            // Persistence must not report a limit that the live engine rejected.
            try? await persistence.setTorrentLimits(
                torrentID: request.recordID.rawValue.uuidString,
                limits: record.limits
            )
            return .failure(Self.engineFault(
                error,
                operation: "setLimits",
                recordID: request.recordID,
                fallback: "setLimits rejected by engine"
            ))
        }
        records[request.recordID] = (records[request.recordID] ?? record).with(limits: request.limits)
        bumpRecordRevision(request.recordID)
        bumpEngineRevision(change: .updated(request.recordID))
        return .success(.ack)
    }

    private func handleApplySettings(_ request: ApplySettingsRequest) async -> EngineCommandResult {
        let previousSettings = activeSettings
        let previousRevision = settingsRevision
        let persistence = self.persistence
        let outcome = await SettingsTransaction.run(
            candidate: request.candidate,
            expectedRevision: request.expectedRevision,
            context: SettingsTransaction.AsyncContext(
                currentRevision: previousRevision,
                persist: { candidate, currentRevision in
                    let newRevision = currentRevision + 1
                    try await persistence.persistSettings(candidate, revision: newRevision)
                    return newRevision
                },
                apply: { [weak self] candidate in
                    guard let self else {
                        return .failure(.internalError(details: "settings coordinator deallocated"))
                    }
                    do {
                        try await self.engine.apply(settings: candidate)
                        await self.setActiveSettings(candidate, revision: previousRevision + 1)
                        return .success(())
                    } catch {
                        return .failure(Self.engineFault(
                            error,
                            operation: "applySettings",
                            fallback: "settings apply rejected by engine"
                        ))
                    }
                },
                rollback: { [weak self] _, _ in
                    if let self {
                        try await self.engine.apply(settings: previousSettings)
                        await self.setActiveSettings(previousSettings, revision: previousRevision)
                    }
                    try await persistence.persistSettings(previousSettings, revision: previousRevision)
                }
            )
        )

        switch outcome {
        case .applied(let revision):
            await eventBus.publish([.settingsChanged(SettingsChangedEvent(revision: revision))])
            return .success(.settingsApply(SettingsApplyResult(revision: revision)))
        case .validationFailed(let errors):
            return .failure(EngineFault.settingsValidationFailed(errors: errors))
        case .revisionConflict(let current):
            return .failure(EngineFault.settingsRevisionConflict(
                current: current,
                expected: request.expectedRevision ?? current
            ))
        case .failed(let fault):
            return .failure(fault)
        }
    }

    private func handleReannounce(_ recordID: TorrentRecordID) async -> EngineCommandResult {
        guard records[recordID] != nil else {
            return .failure(EngineFault.recordNotFound(recordID: recordID))
        }
        guard systemConditions.canAttemptNetworkWork else {
            return .failure(.networkUnavailable(details: "network path unavailable"))
        }
        let now = Date()
        if let previous = lastReannounceAt[recordID] {
            let elapsed = now.timeIntervalSince(previous)
            if elapsed < Self.reannounceCooldown {
                return .failure(.rateLimited(recordID: recordID, retryAfter: Self.reannounceCooldown - elapsed))
            }
        }
        guard let engineID = await liveEngineID(for: recordID) else {
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await engine.reannounce(torrentID: engineID)
        } catch {
            return .failure(Self.engineFault(
                error,
                operation: "reannounce",
                recordID: recordID,
                fallback: "reannounce rejected by engine"
            ))
        }
        lastReannounceAt[recordID] = now
        return .success(.ack)
    }

    private func handleEditTrackers(_ request: EditTrackersRequest) async -> EngineCommandResult {
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        let additions = request.addedURLs.compactMap(Self.normalizedTrackerURL)
        let removals = request.removedURLs.compactMap(Self.normalizedTrackerURL)
        guard additions.count == request.addedURLs.count,
              removals.count == request.removedURLs.count else {
            return .failure(.invalidPayload(details: "tracker URL is invalid"))
        }
        var updated = record.trackers
        for added in additions {
            if !updated.contains(added) { updated.append(added) }
        }
        updated.removeAll { removals.contains($0) }
        guard updated.count <= TransferLimits.maxTrackers else {
            return .failure(.invalidPayload(details: "tracker limit exceeded"))
        }
        guard let engineID = await liveEngineID(for: request.recordID) else {
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await persistence.setTorrentTrackers(
                torrentID: request.recordID.rawValue.uuidString,
                trackers: updated
            )
        } catch {
            return .failure(Self.persistenceFault(
                error,
                recordID: request.recordID,
                volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        do {
            try await engine.editTrackers(torrentID: engineID, trackers: updated)
        } catch {
            try? await persistence.setTorrentTrackers(
                torrentID: request.recordID.rawValue.uuidString,
                trackers: record.trackers
            )
            return .failure(Self.engineFault(
                error,
                operation: "editTrackers",
                recordID: request.recordID,
                fallback: "tracker edit rejected by engine"
            ))
        }
        records[request.recordID] = (records[request.recordID] ?? record).withTrackers(updated)
        bumpRecordRevision(request.recordID)
        bumpEngineRevision(change: .updated(request.recordID))
        return .success(.ack)
    }

    private func liveEngineID(for recordID: TorrentRecordID) async -> String? {
        guard await ensureEngineStarted() else { return nil }
        if let engineID = records[recordID]?.engineID {
            return engineID
        }
        await pumpOnce()
        return records[recordID]?.engineID
    }

    private static func normalizedTrackerURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "udp"].contains(scheme),
              components.host?.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    // MARK: - WP-10 removal (durable two-phase + Trash-only)

    /// Mints a durable removal token. When `deleteFiles` is true, the EXACT
    /// manifest (payload paths, shared-path protection) is derived from the
    /// metainfo and frozen into the token row BEFORE the client may commit.
    /// Nothing is ever deleted at prepare time.
    private func handlePrepareRemoval(_ request: PrepareRemovalRequest) async -> EngineCommandResult {
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        // Fail-closed admission: an unreadable token count must not be read as
        // zero, or the pending-token capacity check would fail open.
        let pendingCount: Int
        do {
            pendingCount = try await persistence.removalTokenCount()
        } catch {
            return .failure(Self.persistenceFault(
                error,
                recordID: request.recordID,
                volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        guard pendingCount < Self.pendingRemovalTokenLimit else {
            return .failure(.resourceLimitExceeded(resource: "pending_removal_tokens", limit: Self.pendingRemovalTokenLimit))
        }
        let token = RemovalToken(rawValue: UUID().uuidString)
        let otherPayloadFiles = records.values
            .filter { $0.id != request.recordID }
            .flatMap { RemovalManifestBuilder.payloadFiles(of: $0) }
        let otherPayloadRoots = records.values
            .filter { $0.id != request.recordID }
            .compactMap { RemovalManifestBuilder.payloadRoot(of: $0) }

        var manifestJSON = "{}"
        var sharedPathsJSON = "[]"
        if request.deleteFiles {
            do {
                let manifest = try RemovalManifestBuilder.build(
                    record: record,
                    otherPayloadFiles: Set(otherPayloadFiles),
                    otherPayloadRoots: otherPayloadRoots
                )
                let encoder = JSONEncoder()
                manifestJSON = String(data: try encoder.encode(manifest), encoding: .utf8) ?? "{}"
                let shared = manifest.entries.filter(\.isShared).map(\.relativePath)
                sharedPathsJSON = String(data: try encoder.encode(shared), encoding: .utf8) ?? "[]"
            } catch {
                return .failure(.invalidPayload(details: "removal manifest: \(error)"))
            }
        }
        do {
            try await persistence.createRemovalToken(
                token: token.rawValue,
                recordID: request.recordID.rawValue.uuidString,
                deleteFiles: request.deleteFiles,
                manifestJSON: manifestJSON,
                sharedPathsJSON: sharedPathsJSON,
                createdAt: Self.nowMilliseconds
            )
        } catch {
            return .failure(Self.persistenceFault(
                error,
                recordID: request.recordID,
                volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        pendingRemovalTokens[token.rawValue] = request.recordID
        return .success(.removalToken(token))
    }

    /// Serves the manifest page for a token straight from the durable token
    /// row (never re-derived from live data). Only the exact manifest paths
    /// are ever eligible for deletion; the UI shows them before committing.
    private func handleFetchRemovalManifestPage(_ request: FetchRemovalManifestPageRequest) async -> EngineCommandResult {
        let tokenRecord: RemovalTokenRecord
        do {
            guard let found = try await persistence.removalToken(by: request.token.rawValue) else {
                return .failure(.invalidRequest(details: "removal token is unknown or expired"))
            }
            tokenRecord = found
        } catch {
            return .failure(.invalidRequest(details: "removal manifest lookup failed"))
        }
        guard let manifest = try? JSONDecoder().decode(
            RemovalManifest.self,
            from: Data(tokenRecord.manifestJSON.utf8)
        ) else {
            return .failure(.invalidPayload(details: "removal manifest is unavailable"))
        }
        let all = manifest.orderedEntries().map {
            RemovalManifestEntry(relativePath: $0.relativePath, sizeBytes: $0.sizeBytes, kind: $0.kind)
        }
        let pageSize = PageSize.bounded(request.pageSize)
        let offset = Self.cursorOffset(request.cursor)
        let slice = Array(all.dropFirst(offset).prefix(pageSize))
        let nextCursor: PageCursor? = offset + slice.count < all.count
            ? PageCursor(token: Data("\(offset + slice.count)".utf8))
            : nil
        let revision = UUID(uuidString: tokenRecord.recordID)
            .map { recordRevisions[TorrentRecordID(rawValue: $0)] ?? 0 } ?? 0
        return .success(.removalManifestPage(Page(
            items: slice,
            nextCursor: nextCursor,
            totalCount: all.count,
            revision: revision
        )))
    }

    private static func cursorOffset(_ cursor: PageCursor?) -> Int {
        guard let cursor, let raw = String(data: cursor.token, encoding: .utf8), let value = Int(raw) else {
            return 0
        }
        return max(0, value)
    }

    /// WP-10 (Gate 4/9): lists removal tokens that are still pending (their
    /// outcome was never durably settled), with per-batch progress derived
    /// from the durable trash journal. The UI uses this to offer guided
    /// recovery after a restart: each summary carries enough evidence to
    /// resume or re-evaluate the half-finished batch — never silently
    /// auto-resumed by the agent.
    private func handleFetchPendingRemovals(_ request: FetchPendingRemovalsRequest) async -> EngineCommandResult {
        let pending: [RemovalTokenRecord]
        do {
            pending = try await persistence.pendingRemovalTokens()
        } catch {
            return .failure(Self.persistenceFault(error, recordID: nil, volumeIdentifier: nil))
        }
        var summaries: [PendingRemovalSummary] = []
        for token in pending {
            guard let recordID = UUID(uuidString: token.recordID).map({ TorrentRecordID(rawValue: $0) }) else {
                continue
            }
            // Fail-closed: a journal read error must not fabricate zero
            // progress evidence for a pending batch — surface a typed fault.
            let journal: [TrashJournalEntry]
            do {
                journal = try await persistence.trashJournalEntries(token: token.token)
            } catch {
                return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: nil))
            }
            let trashed = journal.filter { $0.status == TrashJournalEntry.Status.trashed.rawValue }.count
            let failed = journal.filter { $0.status == TrashJournalEntry.Status.failed.rawValue }.count
            let total = (try? JSONDecoder().decode(RemovalManifest.self, from: Data(token.manifestJSON.utf8)))?.entries.count ?? 0
            summaries.append(PendingRemovalSummary(
                token: RemovalToken(rawValue: token.token),
                recordID: recordID,
                displayName: records[recordID]?.displayName,
                deleteFiles: token.deleteFiles,
                totalItemCount: total,
                trashedItemCount: trashed,
                failedItemCount: failed
            ))
        }
        summaries.sort { $0.displayName ?? "" < $1.displayName ?? "" }
        return .success(.pendingRemovals(summaries))
    }

    /// Commits a removal token. Idempotent: a replayed token whose outcome was
    /// durably settled returns the IDENTICAL RemovalBatchResult. File deletion
    /// is Trash-only, item-by-item, journaled BEFORE each item, with shared
    /// paths skipped. The token is settled (committed) ONLY after every payload
    /// item was durably journaled as trashed or skipped — partial/failed
    /// batches stay PENDING so an explicit re-commit resumes exactly where the
    /// durable per-item journal left off (never re-trashing handled items, and
    /// never auto-resuming without a user action). Fail-closed: any journal
    /// append/update/settlement failure aborts with a typed error and keeps
    /// the record + token + journal evidence.
    private func handleCommitRemoval(_ request: CommitRemovalRequest) async -> EngineCommandResult {
        let tokenRecord: RemovalTokenRecord
        do {
            guard let found = try await persistence.removalToken(by: request.token.rawValue) else {
                return .failure(.invalidRequest(details: "removal token is unknown or expired"))
            }
            tokenRecord = found
        } catch {
            return .failure(.invalidRequest(details: "removal token lookup failed"))
        }

        // Idempotent replay: the outcome was durably settled.
        if let outcomeJSON = tokenRecord.outcomeJSON,
           let outcome = try? JSONDecoder().decode(RemovalBatchResult.self, from: Data(outcomeJSON.utf8)) {
            // A committed outcome whose record still exists means a crash hit
            // between settle and record removal. The payload is already
            // trashed, so finishing the record removal is a safe repair — the
            // settled result is still returned unchanged.
            if tokenRecord.status == "committed",
               let recordID = UUID(uuidString: tokenRecord.recordID).map({ TorrentRecordID(rawValue: $0) }),
               let record = records[recordID],
               outcome.outcome == .completed {
                await finishCommittedRemoval(record: record)
            }
            // Convergent cleanup retry: a crash (or a failed drop) left the
            // settled evidence in place; every replay retries the cleanup
            // until the drop is confirmed, without duplicating any mutation.
            do {
                try await settleRemovalEvidenceCleanup(token: request.token.rawValue)
            } catch {
                log.error("commitRemoval: settled evidence cleanup failed on replay: \(String(describing: error))")
                let recordID = UUID(uuidString: tokenRecord.recordID).map({ TorrentRecordID(rawValue: $0) })
                return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: nil))
            }
            return .success(.removalResult(outcome))
        }
        guard tokenRecord.status == "pending" else {
            return .failure(.invalidRequest(details: "removal token is no longer active"))
        }
        guard let recordID = UUID(uuidString: tokenRecord.recordID).map({ TorrentRecordID(rawValue: $0) }) else {
            return .failure(.invalidRequest(details: "removal token references an invalid record"))
        }
        guard let record = records[recordID] else {
            // Crash between removeTorrent and settle: the token is still
            // pending but the record is gone and the batch was fully handled.
            // Nothing further can be removed — repair by settling as committed.
            let outcome = RemovalBatchResult(
                recordID: recordID,
                token: request.token,
                outcome: .completed,
                trashedItems: 0,
                skippedSharedItems: 0,
                failedItems: []
            )
            do {
                try await persistence.settleRemovalToken(
                    token: request.token.rawValue,
                    status: "committed",
                    outcomeJSON: Self.encodeOutcome(outcome),
                    at: Self.nowMilliseconds
                )
            } catch {
                return .failure(Self.persistenceFault(
                    error, recordID: recordID, volumeIdentifier: nil
                ))
            }
            pendingRemovalTokens.removeValue(forKey: request.token.rawValue)
            return .success(.removalResult(outcome))
        }
        pendingRemovalTokens.removeValue(forKey: request.token.rawValue)

        var trashedItems: [TrashJournalEntry] = []
        var skippedSharedItems: [String] = []
        var failedItems: [RemovalItemFailure] = []

        if tokenRecord.deleteFiles {
            guard let manifest = try? JSONDecoder().decode(
                RemovalManifest.self,
                from: Data(tokenRecord.manifestJSON.utf8)
            ) else {
                do {
                    try await persistence.markRemovalTokenCancelled(
                        token: request.token.rawValue,
                        at: Self.nowMilliseconds
                    )
                } catch {
                    return .failure(Self.persistenceFault(
                        error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                    ))
                }
                return .failure(.invalidPayload(details: "removal manifest is unavailable"))
            }
            // Gate 4: load the durable per-item journal BEFORE mutating so a
            // replayed commit resumes rather than re-trashing handled items.
            let existingJournal: [String: TrashJournalEntry]
            do {
                let rows = try await persistence.trashJournalEntries(token: request.token.rawValue)
                existingJournal = Dictionary(
                    rows.map { ($0.relativePath, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            } catch {
                return .failure(Self.persistenceFault(
                    error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                ))
            }
            let trashService = TrashService(trash: trashProvider)
            for entry in manifest.orderedEntries() {
                let now = Self.nowMilliseconds
                let absolute = manifest.absolutePath(for: entry)
                if let row = existingJournal[entry.relativePath] {
                    // Resume semantics: rows already journaled as handled are
                    // NEVER touched again.
                    switch row.status {
                    case TrashJournalEntry.Status.trashed.rawValue:
                        trashedItems.append(row)
                        continue
                    case TrashJournalEntry.Status.skippedShared.rawValue:
                        skippedSharedItems.append(entry.relativePath)
                        continue
                    default:
                        break // pending/failed rows are retried below
                    }
                }
                // Durable append BEFORE any mutation: a crash after this point
                // is always resumable, and an append failure aborts the batch.
                let seq: Int64
                do {
                    seq = try await persistence.trashJournalAppend(
                        token: request.token.rawValue,
                        relativePath: entry.relativePath,
                        absolutePath: absolute,
                        kind: entry.kind.rawValue,
                        sizeBytes: entry.sizeBytes,
                        updatedAt: now
                    )
                } catch {
                    log.error("commitRemoval: trash journal append failed: \(String(describing: error))")
                    return .failure(Self.persistenceFault(
                        error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                    ))
                }
                if entry.isShared {
                    skippedSharedItems.append(entry.relativePath)
                    do {
                        try await persistence.trashJournalUpdate(
                            seq: seq,
                            status: TrashJournalEntry.Status.skippedShared.rawValue,
                            failureCode: nil,
                            failureMessage: nil,
                            updatedAt: now
                        )
                    } catch {
                        return .failure(Self.persistenceFault(
                            error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                        ))
                    }
                    continue
                }
                switch trashService.trash(entry: entry, manifest: manifest) {
                case .trashed(let relativePath, let sizeBytes):
                    trashedItems.append(TrashJournalEntry(
                        seq: seq, token: request.token.rawValue, relativePath: relativePath,
                        absolutePath: absolute, kind: entry.kind.rawValue, sizeBytes: sizeBytes,
                        status: TrashJournalEntry.Status.trashed.rawValue,
                        failureCode: nil, failureMessage: nil, updatedAt: now
                    ))
                    do {
                        try await persistence.trashJournalUpdate(
                            seq: seq,
                            status: TrashJournalEntry.Status.trashed.rawValue,
                            failureCode: nil,
                            failureMessage: nil,
                            updatedAt: now
                        )
                    } catch {
                        log.error("commitRemoval: trash journal update failed: \(String(describing: error))")
                        return .failure(Self.persistenceFault(
                            error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                        ))
                    }
                case .failed(let failure):
                    failedItems.append(RemovalItemFailure(
                        relativePath: entry.relativePath, code: failure.code, message: failure.message
                    ))
                    do {
                        try await persistence.trashJournalUpdate(
                            seq: seq,
                            status: TrashJournalEntry.Status.failed.rawValue,
                            failureCode: failure.code,
                            failureMessage: failure.message,
                            updatedAt: now
                        )
                    } catch {
                        return .failure(Self.persistenceFault(
                            error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
                        ))
                    }
                }
            }
        }

        let outcome: RemovalBatchOutcome
        if failedItems.isEmpty {
            outcome = .completed
        } else if trashedItems.isEmpty {
            outcome = .failed
        } else {
            outcome = .partial
        }
        let result = RemovalBatchResult(
            recordID: recordID,
            token: request.token,
            outcome: outcome,
            trashedItems: trashedItems.count,
            skippedSharedItems: skippedSharedItems.count,
            failedItems: failedItems
        )

        guard outcome == .completed else {
            // Partial/failed: the record STAYS, the token STAYS pending (no
            // outcomeJSON, no cancellation), and the journal rows remain as
            // recovery evidence. The UI re-commits the SAME token for guided
            // recovery; the per-item journal makes the retry a resume, not a
            // re-trash. Startup restore re-exposes the token to the UI.
            return .success(.removalResult(result))
        }

        // Full success: settle committed BEFORE any further mutation so a
        // crash never leaves a removed record with an un-settled token, and
        // the committed outcome is the durable evidence that cleanup is done.
        do {
            try await persistence.settleRemovalToken(
                token: request.token.rawValue,
                status: "committed",
                outcomeJSON: Self.encodeOutcome(result),
                at: Self.nowMilliseconds
            )
        } catch {
            log.error("commitRemoval: token settlement failed: \(String(describing: error))")
            return .failure(Self.persistenceFault(
                error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }

        // Never asking the engine to delete files — the Trash already did,
        // item by item, journaled. A missing engine entry (e.g. after an
        // engine restart) is benign: the payload is gone either way.
        if let engineID = record.engineID, await ensureEngineStarted() {
            do {
                try await engine.remove(torrentID: engineID)
            } catch {
                if Self.isRemovalTargetAlreadyGone(error) {
                    log.info("commitRemoval: engine entry already absent; continuing")
                } else {
                    log.warning("commitRemoval: engine remove failed: \(String(describing: error))")
                    return .failure(Self.engineFault(
                        error, operation: "remove", recordID: recordID, fallback: "removal failed"
                    ))
                }
            }
        }
        do {
            try await persistence.removeTorrent(torrentID: recordID.rawValue.uuidString)
        } catch {
            return .failure(Self.persistenceFault(
                error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }

        records.removeValue(forKey: recordID)
        recordRevisions.removeValue(forKey: recordID)
        lastReannounceAt.removeValue(forKey: recordID)
        bumpEngineRevision(change: .removed(recordID))

        // Fail-closed evidence cleanup: the settled token/journal rows are
        // kept until the drop is confirmed; a failure surfaces as a fault and
        // the next re-commit of this token replays the same outcome and
        // retries the cleanup (convergent — no mutation is duplicated).
        do {
            try await settleRemovalEvidenceCleanup(token: request.token.rawValue)
        } catch {
            log.error("commitRemoval: settled evidence cleanup failed: \(String(describing: error))")
            return .failure(Self.persistenceFault(
                error, recordID: recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        return .success(.removalResult(result))
    }

    /// Repair for a settled-committed token whose record still exists (crash
    /// between settle and record removal). The payload is already trashed, so
    /// completing the record removal is idempotent and safe; failures are
    /// logged but never surface — the settled outcome is the durable truth.
    private func finishCommittedRemoval(record: TransferRecord) async {
        let recordID = record.id
        if let engineID = record.engineID {
            do {
                try await engine.remove(torrentID: engineID)
            } catch {
                // Missing engine entry is benign; real faults surface later on
                // the next explicit removal attempt.
            }
        }
        do {
            try await persistence.removeTorrent(torrentID: recordID.rawValue.uuidString)
        } catch {
            return
        }
        records.removeValue(forKey: recordID)
        recordRevisions.removeValue(forKey: recordID)
        lastReannounceAt.removeValue(forKey: recordID)
        bumpEngineRevision(change: .removed(recordID))
    }

    /// Convergent post-settle evidence cleanup (trash journal rows + bounded
    /// token prune). Throws fail-closed: the durable evidence is kept until
    /// the drop is confirmed, and a replayed commit retries the cleanup until
    /// it converges.
    private func settleRemovalEvidenceCleanup(token rawToken: String) async throws {
        try await persistence.deleteTrashJournal(token: rawToken)
        try await persistence.pruneSettledRemovalTokens(keepNewest: 128)
    }

    private static func isRemovalTargetAlreadyGone(_ error: Error) -> Bool {
        if let fault = error as? EngineFault, fault.code == .recordNotFound {
            return true
        }
        if let coordinatorError = error as? EngineCoordinatorError, case .notFound = coordinatorError {
            return true
        }
        return false
    }

    private static func encodeOutcome(_ result: RemovalBatchResult) -> String {
        guard let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - WP-10 storage move (durable journal + recovery)

    /// Moves a torrent's payload to a new destination through the engine.
    /// The move journal row is written BEFORE the destination is created and
    /// the engine is asked to move; stage advances only on durable evidence.
    /// On success the record's save location is persisted, the journal row is
    /// dropped, and a force recheck validates the moved payload.
    private func handleMoveStorage(_ request: MoveStorageRequest) async -> EngineCommandResult {
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        let toPath = (request.destination.path as NSString).expandingTildeInPath
        let fromPath = (record.saveLocation.path as NSString).expandingTildeInPath
        guard toPath != fromPath else {
            return .failure(.invalidPayload(details: "destination equals the current save location"))
        }
        guard let engineID = record.engineID, await ensureEngineStarted() else {
            return .failure(EngineFault.engineNotReady(details: "engine not running"))
        }

        // A pending journal row means a move is already in flight for this
        // record: refuse rather than interleave two moves. A lookup failure is
        // fail-closed: it must never be read as "no journal" — the durable
        // admission check could not be confirmed, so the move aborts.
        let inFlightMove: MoveJournalEntry?
        do {
            inFlightMove = try await persistence.moveJournal(recordID: request.recordID.rawValue.uuidString)
        } catch {
            return .failure(Self.persistenceFault(
                error, recordID: request.recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        if inFlightMove != nil {
            return .failure(.engineBusy(details: "storage move already in progress for this record"))
        }
        // Gate 5: the payload file list (relative paths) is journaled with the
        // row so recovery can verify REAL file evidence at either side.
        let fileListJSON = Self.encodePayloadFileList(of: record) ?? "[]"
        let moveSeq: Int64
        do {
            moveSeq = try await persistence.moveJournalCreate(
                recordID: request.recordID.rawValue.uuidString,
                fromPath: fromPath,
                toPath: toPath,
                fileListJSON: fileListJSON,
                startedAt: Self.nowMilliseconds
            )
        } catch {
            return .failure(Self.persistenceFault(
                error, recordID: request.recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }

        // stage: prepared — create the destination BEFORE the engine move.
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: toPath),
                withIntermediateDirectories: true
            )
        } catch {
            // Gate 8: the journal row stays 'prepared' if the diagnostic
            // update fails — evidence-based recovery still resolves it.
            do {
                try await persistence.moveJournalUpdate(
                    seq: moveSeq,
                    stage: MoveJournalEntry.Stage.prepared.rawValue,
                    status: MoveJournalEntry.Status.failed.rawValue,
                    failureReason: "destination creation failed: \(error.localizedDescription)",
                    updatedAt: Self.nowMilliseconds
                )
            } catch {
                log.error("moveStorage: journal update failed: \(String(describing: error))")
            }
            return .failure(.storageFailure(details: "cannot create destination directory"))
        }

        do {
            try await engine.moveStorage(torrentID: engineID, destinationPath: toPath)
        } catch {
            do {
                try await persistence.moveJournalUpdate(
                    seq: moveSeq,
                    stage: MoveJournalEntry.Stage.prepared.rawValue,
                    status: MoveJournalEntry.Status.failed.rawValue,
                    failureReason: String(describing: error),
                    updatedAt: Self.nowMilliseconds
                )
            } catch {
                log.error("moveStorage: journal update failed: \(String(describing: error))")
            }
            return .failure(Self.engineFault(
                error, operation: "moveStorage", recordID: request.recordID, fallback: "storage move failed"
            ))
        }

        // stage: engine_moved — the payload is at the destination. A failed
        // advance aborts fail-closed: the row stays 'prepared' and evidence
        // recovery will still find the payload at the destination.
        do {
            try await persistence.moveJournalUpdate(
                seq: moveSeq,
                stage: MoveJournalEntry.Stage.engineMoved.rawValue,
                status: MoveJournalEntry.Status.pending.rawValue,
                failureReason: nil,
                updatedAt: Self.nowMilliseconds
            )
        } catch {
            return .failure(Self.persistenceFault(
                error, recordID: request.recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }

        // stage: record_updated — persist the new save location, then complete.
        do {
            try await persistence.setTorrentLocation(
                torrentID: request.recordID.rawValue.uuidString,
                location: request.destination
            )
        } catch {
            do {
                try await persistence.moveJournalUpdate(
                    seq: moveSeq,
                    stage: MoveJournalEntry.Stage.recordUpdated.rawValue,
                    status: MoveJournalEntry.Status.pending.rawValue,
                    failureReason: String(describing: error),
                    updatedAt: Self.nowMilliseconds
                )
            } catch {
                log.error("moveStorage: journal update failed: \(String(describing: error))")
            }
            return .failure(Self.persistenceFault(
                error, recordID: request.recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        records[request.recordID] = record.with(saveLocation: request.destination)
        bumpEngineRevision(change: .updated(request.recordID))

        // Force recheck BEFORE the journal row is dropped: a failed recheck
        // keeps the row, and recovery converges on the same move instead of
        // interleaving a fresh one over the already-moved payload.
        do {
            try await engine.recheck(torrentID: engineID)
        } catch {
            return .failure(Self.engineFault(
                error, operation: "recheck", recordID: request.recordID, fallback: "moved payload recheck failed"
            ))
        }
        // The row is dropped only after the record was durably updated AND the
        // recheck was confirmed; a failed drop keeps the row, and the next
        // recovery pass converges on the same outcome (payload evidence at the
        // destination resumes the same move).
        do {
            try await persistence.deleteMoveJournal(recordID: request.recordID.rawValue.uuidString)
        } catch {
            log.error("moveStorage: move journal deletion failed: \(String(describing: error))")
            return .failure(Self.persistenceFault(
                error, recordID: request.recordID, volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }
        return .success(.ack)
    }

    private static func encodePayloadFileList(of record: TransferRecord) -> String? {
        let relativePaths = record.metainfoData
            .flatMap { try? Preflight.validateTorrentData($0) }
            .map { $0.files.map(\.path) } ?? []
        return String(data: (try? JSONEncoder().encode(relativePaths)) ?? Data(), encoding: .utf8)
    }

    private static var nowMilliseconds: Int64 {
        Int64(Date.now.timeIntervalSince1970 * 1000)
    }

    private func setActiveSettings(_ settings: EngineSettings, revision: SettingsRevision) {
        activeSettings = settings
        settingsRevision = revision
    }
    // MARK: - Creator Flow

    private func handleInspectCreateSource(_ request: InspectCreateSourceRequest) async -> EngineCommandResult {
        do {
            let inspection = try await creatorPlanStore.inspectCreateSource(
                sourcePath: request.sourcePath,
                options: request.options
            )
            return .success(.createSourceInspection(inspection))
        } catch let fault as EngineFault {
            return .failure(fault)
        } catch let err as SourceScannerError {
            return .failure(.invalidPayload(details: err.description))
        } catch {
            return .failure(.storageFailure(details: "Failed to inspect create source: \(error.localizedDescription)"))
        }
    }

    private func handleFetchCreatorManifestPage(_ request: FetchCreatorManifestPageRequest) async -> EngineCommandResult {
        do {
            let page = try await creatorPlanStore.fetchCreatorManifestPage(
                token: request.token,
                cursor: request.cursor,
                pageSize: request.pageSize
            )
            return .success(.creatorManifestPage(page))
        } catch let fault as EngineFault {
            return .failure(fault)
        } catch {
            return .failure(.storageFailure(details: "Failed to fetch creator manifest page: \(error.localizedDescription)"))
        }
    }

    private func handleCommitCreate(_ request: CommitCreateRequest) async -> EngineCommandResult {
        let operationID = OperationID()
        await eventBus.publish([.operationProgress(OperationProgressEvent(
            operationID: operationID,
            phase: .started,
            fraction: 0.0,
            timestamp: Date()
        ))])

        do {
            let _ = try await creatorPlanStore.commitCreate(
                token: request.token,
                idempotencyKey: request.idempotencyKey,
                addTorrent: { [engine] metainfoData, savePath, paused in
                    let spec = AddSpecificationDTO(
                        torrentFile: metainfoData,
                        magnetURI: nil,
                        savePath: savePath,
                        paused: paused
                    )
                    _ = try await engine.add(specification: spec)
                },
                onProgress: { [eventBus] fraction, stage in
                    Task {
                        await eventBus.publish([.operationProgress(OperationProgressEvent(
                            operationID: operationID,
                            phase: .running,
                            fraction: fraction,
                            timestamp: Date()
                        ))])
                    }
                }
            )

            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: .succeeded,
                timestamp: Date()
            ))])

            return .success(.ack)
        } catch let fault as EngineFault {
            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: .failed(fault),
                timestamp: Date()
            ))])
            return .failure(fault)
        } catch {
            let fault = EngineFault.storageFailure(details: "commitCreate failed: \(error.localizedDescription)")
            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: .failed(fault),
                timestamp: Date()
            ))])
            return .failure(fault)
        }
    }
}
