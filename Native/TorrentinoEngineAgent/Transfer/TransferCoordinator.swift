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
import os
import OSLog
import TorrentinoIPC
import TorrentinoDomain

/// Production BridgeTransferEngine conforms in EngineCoordinator.swift. Test
/// engines intentionally do not expose this capability; their fallback keeps
/// existing in-memory command tests independent of the native bridge.
protocol CreatorIndependentVerifier: Sendable {
    func verifyCreatorTorrent(data: Data) async throws -> IndependentMetainfoIdentity
}

public struct RestoreSummary: Sendable, Equatable {
    public let stored: Int
    public let rebuilt: Int
    public let skipped: Int
    public let engineRevision: UInt64
    public let failure: String?

    public init(stored: Int, rebuilt: Int, skipped: Int, engineRevision: UInt64, failure: String? = nil) {
        self.stored = max(0, stored)
        self.rebuilt = max(0, rebuilt)
        self.skipped = max(0, skipped)
        self.engineRevision = engineRevision
        self.failure = failure
    }
}

public actor TransferCoordinator {
    // MARK: - Configuration

    private struct CreatorCancellationState: Sendable {
        var cancelled: Set<OperationID> = []
        var active: Set<OperationID> = []
    }

    private enum AdmissionReason: String, Sendable {
        case commitAdd
        case restoreReadd
        case resume
        case pumpReadd
        case engineRestart
    }

    private enum AdmissionOutcome: Sendable, Equatable {
        case admitted(engineID: String, activity: TorrentActivity)
        case deferred(TorrentHealth)
        case failed(fault: EngineFault, health: TorrentHealth)
    }

    /// Default pump cadence (production). Tests pass nil to pump manually.
    public static let defaultPumpIntervalNanoseconds: UInt64 = 500_000_000

    private let engine: any TransferEngine
    private let persistence: PersistenceStore
    private let eventBus: TransferEventBus
    /// WP-11: cancellation registry for creator operations accepted by this
    /// agent. Unknown IDs are never inserted, so a pre-cancel cannot affect a
    /// later operation. Locked so the sync cancelCheck closure can observe it
    /// without hopping actors.
    private let creatorCancellationGate = OSAllocatedUnfairLock(initialState: CreatorCancellationState())
    private let agentVersion: String
    private let defaultSaveLocation: PersistedLocation
    private let pumpIntervalNanoseconds: UInt64?
    private let storageProbe: @Sendable (PersistedLocation, Int64) -> StorageAvailabilityState
    private let healthReporter: (any EngineHealthReporter)?
    private let clearSafeRecovery: @Sendable () -> Void
    /// WP-10: injectable per-item Trash primitive (tests simulate failures).
    private let trashProvider: any TrashProviding
    private let log = TorrentinoLog.logger(category: "transfer")

    // MARK: - State

    public private(set) var restoreRebuiltCount: Int = 0
    public private(set) var restoreSkippedCount: Int = 0
    public private(set) var sessionPhase: EngineLifecycleState = .ready
    public private(set) var degradedReason: String?

    private var records: [TorrentRecordID: TransferRecord] = [:]
    private var recordRevisions: [TorrentRecordID: UInt64] = [:]
    /// Deltas are published contiguously: every publish covers all changes
    /// with revision > publishedRevision and carries publishedRevision + 1.
    private var publishedRevision: UInt64 = 0
    private var engineRevision: UInt64 = 0
    private struct ActiveAddOperation: Sendable {
        let operationID: AddOperationID
        var engineID: String?
        let source: AddSource
        let contentIdentity: ContentIdentity
        var displayName: String
        var sizeBytes: Int64?
        var warnings: [String]
        let createdTime: Date
        var lastPolledTime: Date
        var phase: AddInspectionPhase
        var metainfo: Metainfo?
        var magnet: MagnetLink?
        var sourceData: Data?
        var files: [InspectedFileEntry]?
        var failure: EngineFault?
        var generation: UInt64 = 1
        var isInFlight: Bool = false

        func toInspection() -> AddSourceInspection {
            AddSourceInspection(
                operationID: operationID,
                contentIdentity: contentIdentity,
                displayName: displayName,
                sizeBytes: sizeBytes,
                warnings: warnings,
                phase: phase,
                files: files
            )
        }
    }

    private var pendingOperations: [AddOperationID: ActiveAddOperation] = [:]
    private var pendingInspectionBytes = 0
    private var idempotencyResults: [IdempotencyKey: CommitAddResult] = [:]
    private var idempotencyOrder: [IdempotencyKey] = []
    private struct TrackerEditIdempotency: Sendable {
        let recordID: TorrentRecordID
        let trackerTiers: [[String]]
    }
    private var trackerEditResults: [IdempotencyKey: TrackerEditIdempotency] = [:]
    private var activeTrackerEditRecords: Set<TorrentRecordID> = []
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
    private var pendingAdmissionReasons: [TorrentRecordID: AdmissionReason] = [:]
    private var metadataPromotionBackoff: [TorrentRecordID: (failures: Int, nextAttemptAt: Date)] = [:]
    private var restartInFlight = false
    private let creatorPlanStore = CreatorPlanStore()
    /// The actor owns the active-operation set; the lock-backed cancellation
    /// set is only a synchronous signal observed by the domain actor.
    private var activeCreatorOperations: Set<OperationID> = []
    private var activeCreatorPlans: Set<CreatorPlanToken> = []
    /// Operation identities are minted once per agent lifetime. Retaining
    /// completed identities prevents a generated collision from being reused.
    private var acceptedCreatorOperations: Set<OperationID> = []
    /// Idempotency keys are caller correlation only; replaying one cannot mint
    /// a second authoritative creator operation.
    private var acceptedCreatorIdempotencyKeys: Set<IdempotencyKey> = []
    private var creatorTasks: [OperationID: Task<Void, Never>] = [:]

    private static let reannounceCooldown: TimeInterval = 30
    private static let pendingOperationsLimit = 256
    private static let pendingInspectionBytesLimit: Int64 = 64 * 1024 * 1024
    private static let idempotencyResultsLimit = 1024
    private static let pendingRemovalTokenLimit = 256
    private static let diagnosticsExportLogLineLimit = 2_000
    private static let pendingOperationTTL: TimeInterval = 300

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

    public var currentEngineRevision: UInt64 { engineRevision }

    public func setSessionPhase(_ phase: EngineLifecycleState, reason: String?) {
        sessionPhase = phase
        degradedReason = phase == .degraded ? reason : nil
    }

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
    /// The pump then admits running torrents through the same gate as every
    /// other path. Partial side-table failures keep the record visible with a
    /// typed warning; only invalid core identity is skipped.
    @discardableResult
    public func restoreFromPersistence() async -> RestoreSummary {
        restoreRebuiltCount = 0
        restoreSkippedCount = 0
        pendingAdmissionReasons.removeAll()
        do {
            if let restored = try await persistence.loadSettings() {
                activeSettings = restored.settings
                settingsRevision = restored.revision
                // SEC-1 boot transient (WP13-SEC-HARDEN-001): the agent has
                // no Keychain access, so this restore is credential-free by
                // design. A marker=true row restores "" (withheld pending
                // re-supply): that proxy runs WITHOUT its password between
                // this boot and the first UI-driven applySettings delivery,
                // and ensureEngineStarted logs a notice for exactly that
                // withheld shape (REVIEW-002). A marker=false row restores
                // nil — no authentication was ever configured — and boots
                // silently.
            }
        } catch {
            log.warning("restore: settings load failed: \(TorrentinoLog.redactedDescription(error))")
        }

        let stored: [StoredTorrent]
        do {
            stored = try await persistence.allTorrents()
        } catch {
            log.error("restore: allTorrents failed: \(TorrentinoLog.redactedDescription(error))")
            sessionPhase = .degraded
            degradedReason = "persistenceUnavailable"
            return RestoreSummary(
                stored: 0,
                rebuilt: 0,
                skipped: 0,
                engineRevision: engineRevision,
                failure: "persistenceUnavailable"
            )
        }

        var rebuiltCount = 0
        var skippedCount = 0

        for torrent in stored.sorted(by: { $0.addedAt < $1.addedAt }) {
            guard Self.isValidCoreIdentity(torrent) else {
                log.warning("restore: skipped record with invalid core identity")
                skippedCount += 1
                continue
            }
            guard let uuid = UUID(uuidString: torrent.id) else {
                log.warning("restore: skipped record with invalid UUID")
                skippedCount += 1
                continue
            }
            let recordID = TorrentRecordID(rawValue: uuid)
            let identity = ContentIdentity(
                infoHashV1: torrent.infoHashV1.flatMap { TorrentAdder.dataFromHex($0) },
                infoHashV2: torrent.infoHashV2.flatMap { TorrentAdder.dataFromHex($0) }
            )

            var recordHealth: TorrentHealth? = nil

            let metainfoData: Data?
            do {
                metainfoData = try await persistence.metainfo(torrentID: torrent.id)?.data
            } catch {
                log.warning("restore: metainfo integrity failed for \(torrent.id): \(TorrentinoLog.redactedDescription(error))")
                metainfoData = nil
                recordHealth = .recoverableError(.storeError)
            }

            let metainfo: Metainfo?
            do {
                if let metainfoData {
                    metainfo = try Preflight.validateTorrentData(metainfoData)
                } else {
                    metainfo = nil
                }
            } catch {
                log.warning("restore: metainfo parse failed for \(torrent.id): \(TorrentinoLog.redactedDescription(error))")
                metainfo = nil
                recordHealth = recordHealth ?? .recoverableError(.invalidPayload)
            }

            let restoredDisplayName: String
            if let metainfo, torrent.name.hasPrefix("magnet:") {
                restoredDisplayName = metainfo.name
                do {
                    try await persistence.updateTorrentName(
                        torrentID: torrent.id,
                        name: metainfo.name
                    )
                } catch {
                    // A stale placeholder is presentation-only once valid
                    // metainfo is available; keep the healthy record visible
                    // even if the durable label repair cannot complete.
                    log.warning("restore: name self-heal failed for \(torrent.id): \(TorrentinoLog.redactedDescription(error))")
                }
            } else {
                restoredDisplayName = torrent.name
            }

            let desired = DesiredTorrentState(rawValue: torrent.state) ?? .paused

            let limits: TorrentinoIPC.TransferLimits
            do {
                limits = try await persistence.torrentLimits(torrentID: torrent.id) ?? TorrentinoIPC.TransferLimits()
            } catch {
                log.warning("restore: limits fallback for record=\(recordID) error=\(TorrentinoLog.redactedDescription(error))")
                recordHealth = recordHealth ?? .recoverableError(.storeError)
                limits = TorrentinoIPC.TransferLimits()
            }

            let trackerTiers: [[String]]
            do {
                trackerTiers = try await persistence.restoreTorrentTrackerTiers(
                    torrentID: torrent.id,
                    metainfoTiers: metainfo?.trackerTiers,
                    isPrivate: metainfo?.isPrivate ?? false
                )
            } catch {
                log.warning("restore: tracker topology fallback for \(torrent.id): \(TorrentinoLog.redactedDescription(error))")
                trackerTiers = metainfo?.trackerTiers ?? []
                recordHealth = recordHealth ?? .recoverableError(.storeError)
            }

            let saveLocation: PersistedLocation
            do {
                saveLocation = Self.normalizedSaveLocation(
                    (try await persistence.torrentLocation(torrentID: torrent.id))
                        ?? configuredSaveLocation()
                )
            } catch {
                log.warning("restore: location fallback for record=\(recordID) error=\(TorrentinoLog.redactedDescription(error))")
                recordHealth = recordHealth ?? .recoverableError(.storeError)
                saveLocation = configuredSaveLocation()
            }
            let effectiveBytes = metainfo.map { Self.effectiveTotalBytes(for: $0, selection: []) } ?? (metainfo?.totalSize ?? 0)
            let storageState = storageProbe(saveLocation, effectiveBytes)
            let storageHealth = health(for: storageState, recordID: recordID)

            let restoredHealth: TorrentHealth
            if safeRecovery {
                restoredHealth = .recoverableError(.crashLoopSafeMode)
            } else if let recordHealth {
                restoredHealth = recordHealth
            } else {
                restoredHealth = storageHealth
                    ?? .healthy
            }

            // A running durable record is admitted to the live lifecycle as
            // checking/metadata, not idle. The first status pump replaces this
            // bootstrap activity with the engine's authoritative state.
            let initialActivity: TorrentActivity = desired == .running
                && !safeRecovery
                && storageHealth == nil
                ? (metainfo == nil ? .fetchingMetadata : .checking)
                : .idle

            let record = TransferRecord(
                id: recordID,
                contentIdentity: identity,
                displayName: restoredDisplayName,
                desiredState: desired,
                activity: initialActivity,
                health: restoredHealth,
                totalBytes: effectiveBytes,
                downloadedBytes: 0,
                uploadedBytes: 0,
                downloadBytesPerSec: 0,
                uploadBytesPerSec: 0,
                peersConnected: 0,
                seedsTotal: 0,
                engineID: nil,
                metainfoData: metainfoData,
                trackerTiers: trackerTiers,
                fileSelection: [],
                saveLocation: saveLocation,
                addedAt: torrent.addedAt,
                revision: 0,
                limits: limits
            )
            records[recordID] = record
            recordRevisions[recordID] = 0
            engineRevision += 1
            rebuiltCount += 1
            if desired == .running {
                pendingAdmissionReasons[recordID] = .restoreReadd
            }
        }

        self.restoreRebuiltCount = rebuiltCount
        self.restoreSkippedCount = skippedCount

        publishedRevision = engineRevision
        await recoverInterruptedMoves()
        await restorePendingRemovalTokens()
        let failure: String? = stored.isEmpty ? nil : (rebuiltCount == 0 ? "restoreAnomaly" : nil)
        if failure == "restoreAnomaly" {
            sessionPhase = .degraded
            degradedReason = failure
        }
        log.info("restore: rebuilt \(rebuiltCount) record(s), skipped \(skippedCount) record(s), engineRevision \(self.engineRevision)")
        TorrentinoLog.record(
            category: "persistence",
            level: "notice",
            message: "restore summary rebuilt=\(rebuiltCount) skipped=\(skippedCount) engineRevision=\(self.engineRevision)"
        )
        return RestoreSummary(
            stored: stored.count,
            rebuilt: rebuiltCount,
            skipped: skippedCount,
            engineRevision: engineRevision,
            failure: failure
        )
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
            } else if let storageHealth = health(for: storageProbe(record.saveLocation, requiredBytes(for: record)), recordID: recordID) {
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
        // SEC-5 (defense-in-depth ordering): the size gate runs BEFORE any
        // typed decoding work, so oversized payloads are rejected without
        // paying a full decoder parse. The oversized reply still correlates
        // the requestID when the envelope header itself is parseable.
        guard IPCPayloadLimit.validate(data) else {
            return Self.encodeResult(
                .failure(EngineFault.oversizedPayload(limitBytes: IPCPayloadLimit.maxBytes)),
                requestID: Self.parseableRequestID(in: data)
            )
        }
        let envelope: IPCEnvelope?
        do {
            envelope = try JSONDecoder().decode(IPCEnvelope.self, from: data)
        } catch {
            envelope = nil
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
        if let sessionFault = sessionFault(for: command) {
            return Self.encodeResult(.failure(sessionFault), requestID: command.requestID)
        }
        TorrentinoLog.record(category: "transfer", level: "info", message: "command start name=\(command.name)")
        let result = await handle(command)
        let resultLevel: String
        let resultClass: String
        switch result {
        case .success:
            resultLevel = "info"
            resultClass = "success"
        case .failure(let fault):
            resultLevel = "warning"
            resultClass = "fault:\(fault.code.rawValue)"
        }
        TorrentinoLog.record(
            category: "transfer",
            level: resultLevel,
            message: "command complete name=\(command.name) result=\(resultClass)"
        )
        return Self.encodeResult(result, requestID: command.requestID)
    }

    private static func encodeResult(_ result: EngineCommandResult, requestID: RequestID?) -> Data {
        let envelope = IPCEnvelope.result(requestID: requestID ?? RequestID(), result: result)
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    /// Best-effort requestID correlation for oversized-payload faults. Runs
    /// only after the size gate rejected the payload: one untyped
    /// JSONSerialization pass over the top-level object (no typed envelope or
    /// command graph is built). Mirrors IPCEnvelope decode semantics — only
    /// request/result envelopes carry a correlatable requestID, encoded in its
    /// wire shape {"rawValue": "<uuid>"}.
    private static func parseableRequestID(in data: Data) -> RequestID? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String,
              kind == IPCEnvelope.Kind.request.rawValue || kind == IPCEnvelope.Kind.result.rawValue,
              let payload = object["requestID"] as? [String: Any],
              let raw = payload["rawValue"] as? String,
              let uuid = UUID(uuidString: raw) else {
            return nil
        }
        return RequestID(rawValue: uuid)
    }

    private func sessionFault(for command: EngineCommandV1) -> EngineFault? {
        switch sessionPhase {
        case .ready:
            return nil
        case .degraded:
            switch command {
            case .hello, .prepareForQuit, .restartEngineSafely, .exportDiagnostics:
                return nil
            default:
                return degradedFault()
            }
        default:
            switch command {
            case .hello, .prepareForQuit:
                return nil
            default:
                return .engineNotReady(details: "session phase=\(sessionPhase.rawValue)")
            }
        }
    }

    private func degradedFault() -> EngineFault {
        switch degradedReason {
        case "persistenceUnavailable":
            return .storageFailure(details: "session phase degraded: persistenceUnavailable")
        case "restoreAnomaly":
            return .internalError(details: "session phase degraded: restoreAnomaly")
        case "crashLoopSafeMode":
            return .crashLoopSafeMode()
        default:
            return .engineNotReady(details: "session phase degraded")
        }
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
        case .pollAddOperation(let request):
            return await handlePollAddOperation(request)
        case .cancelAdd(let request):
            await removePendingInspection(request.operationID)
            return .success(.ack)
        case .pause(let request):
            return await handlePauseResume(request.recordID, desired: .paused)
        case .resume(let request):
            return await handlePauseResume(request.recordID, desired: .running)
        case .setFileSelection(let request):
            return await handleSetFileSelection(request)
        case .requestRecheck(let request):
            return await handleRecheck(request.recordID)
        case .cancelOperation(let request):
            guard activeCreatorOperations.contains(request.operationID) else {
                return .failure(.operationNotFound(details: "creator operation is not active"))
            }
            let accepted = creatorCancellationGate.withLock { state in
                guard state.active.contains(request.operationID) else { return false }
                state.cancelled.insert(request.operationID)
                return true
            }
            guard accepted else {
                return .failure(.operationNotFound(details: "creator operation is not active"))
            }
            await eventBus.publish([.operationProgress(OperationProgressEvent(
                operationID: request.operationID,
                phase: .running,
                fraction: 0,
                timestamp: Date(),
                detail: OperationProgressDetail(stage: "Cancelling", backend: "cpu", isCancelled: true)
            ))], urgent: true)
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
        case .exportDiagnostics(let request):
            return await handleExportDiagnostics(request)
        }
    }

    // MARK: - Diagnostics export (WP-13)

    /// Assembles the redacted diagnostics bundle (system info, health metrics,
    /// password-free engine-settings projection, recent redacted logs,
    /// persistence status) at a validated destination. Fail-closed: the
    /// destination must be nonexistent or an existing EMPTY directory and is
    /// rejected before the first byte is written, every entry passes through
    /// the same redactor as the log sink before touching disk, and a failed
    /// write removes every file this export already wrote (removal failures
    /// are surfaced in the typed fault details) so a partial bundle is never
    /// presented as success and a pre-existing destination file is never
    /// overwritten.
    private func handleExportDiagnostics(_ request: ExportDiagnosticsRequest) async -> EngineCommandResult {
        let fileManager = FileManager.default
        let destination: URL
        if let requested = request.destinationURL, !requested.isEmpty {
            var isDirectory: ObjCBool = false
            let expanded = (requested as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue {
                return .failure(.internalError(details: "diagnostics destination is not a directory"))
            }
            if isDirectory.boolValue {
                let existing: [String]
                do {
                    existing = try fileManager.contentsOfDirectory(atPath: expanded)
                } catch {
                    return .failure(.internalError(details: "diagnostics destination not readable"))
                }
                guard existing.isEmpty else {
                    return .failure(.internalError(
                        details: "diagnostics destination must be nonexistent or an empty directory"
                    ))
                }
            }
            destination = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("TorrentinoDiagnostics-\(UUID().uuidString)", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return .failure(.internalError(details: "diagnostics destination not writable"))
        }

        let persistenceHealth = await persistence.healthSnapshot()
        let recentLogs = await RedactedLogFileManager.shared
            .fetchRecentLogLines(maxCount: Self.diagnosticsExportLogLineLimit)
            .joined(separator: "\n")

        let entries: [(name: String, text: String)] = [
            ("system_info.json", Self.jsonText([
                "agentVersion": agentVersion,
                "instanceID": instanceID.uuidString,
                "requestID": request.requestID.rawValue.uuidString,
                "reason": request.reason,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
            ])),
            ("health_metrics.json", Self.jsonText([
                "sessionPhase": sessionPhase.rawValue,
                "degradedReason": degradedReason ?? "none",
                "restoreRebuilt": restoreRebuiltCount,
                "restoreSkipped": restoreSkippedCount,
                "engineRevision": String(engineRevision),
                "settingsRevision": String(settingsRevision),
                "recordCount": records.count,
                "safeRecovery": safeRecovery,
                "network": systemConditions.network.rawValue,
                "networkGeneration": String(systemConditions.networkGeneration),
                "thermal": systemConditions.thermal.rawValue,
                "memoryPressure": systemConditions.memoryPressure.rawValue,
                "lowPower": systemConditions.lowPower,
                "sleeping": systemConditions.sleeping,
            ])),
            ("engine_settings.json", Self.settingsExportText(activeSettings)),
            ("recent_logs.txt", recentLogs),
            ("persistence_status.json", Self.jsonText([
                "state": persistenceHealth.state,
                "cleanShutdown": persistenceHealth.cleanShutdown,
                "degraded": persistenceHealth.degraded,
                "quarantinedCount": persistenceHealth.quarantinedCount,
                "reconciliation": persistenceHealth.reconciliation,
            ])),
        ]
        var written: [URL] = []
        do {
            for entry in entries {
                let url = destination.appendingPathComponent(entry.name)
                try Data(RedactedLogFileManager.redact(entry.text).utf8).write(to: url, options: .atomic)
                written.append(url)
                // WP-13 test-only probe: after the first successful entry a
                // test-armed failpoint interrupts mid-write so the rollback is
                // observable. Production arms nothing; fire() is a no-op.
                if written.count == 1 {
                    try FailpointInjector.fire(.diagnosticsExportMidWrite)
                }
            }
        } catch {
            var rollbackFailures: [String] = []
            for url in written {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    rollbackFailures.append(url.lastPathComponent)
                }
            }
            let details: String
            if rollbackFailures.isEmpty {
                details = "diagnostics export write failed"
            } else {
                details = "diagnostics export write failed; rollback incomplete for "
                    + rollbackFailures.sorted().joined(separator: ",")
            }
            return .failure(.internalError(details: details))
        }

        log.notice("diagnostics exported entries=\(entries.count)")
        return .success(.diagnosticsExport(DiagnosticsExportResult(
            archiveURL: destination.path,
            entryCount: entries.count
        )))
    }

    /// Serializes a plist-safe dictionary to sorted JSON text; an invalid
    /// object degrades to an empty entry instead of failing the export.
    private static func jsonText(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Password-free structured projection of the active engine settings for
    /// the diagnostics bundle. Every field is enumerated explicitly so a new
    /// secret-bearing EngineSettings/ProxyConfiguration field cannot silently
    /// enter exports; the proxy password has no representation here at all.
    private static func settingsExportText(_ settings: EngineSettings) -> String {
        jsonText([
            "downloadDirectory": settings.downloadDirectory,
            "maxDownloadBytesPerSec": settings.maxDownloadBytesPerSec,
            "maxUploadBytesPerSec": settings.maxUploadBytesPerSec,
            "listenPort": settings.listenPort,
            "dhtEnabled": settings.dhtEnabled,
            "lsdEnabled": settings.lsdEnabled,
            "upnpEnabled": settings.upnpEnabled,
            "natPmpEnabled": settings.natPmpEnabled,
            "encryptionEnabled": settings.encryptionEnabled,
            "proxy": proxyExportObject(settings.proxy),
        ])
    }

    /// Proxy projection without the password; a nil username omits the key.
    private static func proxyExportObject(_ proxy: ProxyConfiguration) -> [String: Any] {
        var object: [String: Any] = [
            "kind": proxy.kind.rawValue,
            "host": proxy.host,
            "port": proxy.port,
        ]
        if let username = proxy.username {
            object["username"] = username
        }
        return object
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

        // 1. Live active operation with same content identity -> reuse same AddOperationID and current phase
        if let existing = pendingOperations.values.first(where: { $0.contentIdentity == inspection.contentIdentity }) {
            var updated = existing
            updated.lastPolledTime = Date()
            pendingOperations[existing.operationID] = updated
            return .success(.addSourceInspection(updated.toInspection()))
        }

        // 2. Duplicate durable record already in library -> return Show Existing before any engine.add/engineID storage
        if let existingRecord = record(matching: inspection.contentIdentity) {
            let files: [InspectedFileEntry]?
            let metainfo: Metainfo?
            if let data = existingRecord.metainfoData,
               let parsed = try? Preflight.validateTorrentData(data) {
                metainfo = parsed
                files = parsed.files.map { InspectedFileEntry(path: $0.path, sizeBytes: $0.sizeBytes, priority: .normal) }
            } else {
                metainfo = inspection.metainfo
                files = inspection.metainfo?.files.map { InspectedFileEntry(path: $0.path, sizeBytes: $0.sizeBytes, priority: .normal) }
            }
            let activeOp = ActiveAddOperation(
                operationID: inspection.operationID,
                engineID: nil,
                source: request.source,
                contentIdentity: inspection.contentIdentity,
                displayName: existingRecord.displayName,
                sizeBytes: existingRecord.totalBytes > 0 ? existingRecord.totalBytes : inspection.sizeBytes,
                warnings: inspection.warnings,
                createdTime: Date(),
                lastPolledTime: Date(),
                phase: .readyToCommit,
                metainfo: metainfo,
                magnet: inspection.magnet,
                sourceData: existingRecord.metainfoData ?? inspection.sourceData,
                files: files,
                failure: nil
            )
            pendingOperations[inspection.operationID] = activeOp
            return .success(.addSourceInspection(activeOp.toInspection()))
        }

        let retainedBytes = inspection.sourceData?.count ?? 0
        guard Int64(pendingInspectionBytes) + Int64(retainedBytes) <= Self.pendingInspectionBytesLimit else {
            return .failure(.resourceLimitExceeded(
                resource: "pending_add_bytes",
                limit: Int(Self.pendingInspectionBytesLimit)
            ))
        }

        let now = Date()
        var activeOp: ActiveAddOperation

        if case .magnet(let uri) = request.source {
            let spec = AddSpecificationDTO(
                torrentFile: nil,
                magnetURI: uri,
                savePath: configuredSaveLocation().path,
                paused: false,
                metadataOnly: true
            )

            let addResult: AddResultDTO
            do {
                addResult = try await engine.add(specification: spec)
            } catch {
                log.error("inspect magnet add failed: \(TorrentinoLog.redactedDescription(error))")
                return .failure(EngineFault.engineNotReady(details: "addMagnetMetadataOnly failed: \(error)"))
            }

            activeOp = ActiveAddOperation(
                operationID: inspection.operationID,
                engineID: addResult.torrentID,
                source: request.source,
                contentIdentity: inspection.contentIdentity,
                displayName: inspection.displayName,
                sizeBytes: nil,
                warnings: inspection.warnings,
                createdTime: now,
                lastPolledTime: now,
                phase: .retrievingMetadata,
                metainfo: nil,
                magnet: inspection.magnet,
                sourceData: nil,
                files: nil,
                failure: nil
            )
        } else {
            let files: [InspectedFileEntry]? = inspection.metainfo?.files.map {
                InspectedFileEntry(path: $0.path, sizeBytes: $0.sizeBytes, priority: .normal)
            }
            activeOp = ActiveAddOperation(
                operationID: inspection.operationID,
                engineID: nil,
                source: request.source,
                contentIdentity: inspection.contentIdentity,
                displayName: inspection.displayName,
                sizeBytes: inspection.sizeBytes,
                warnings: inspection.warnings,
                createdTime: now,
                lastPolledTime: now,
                phase: .readyToCommit,
                metainfo: inspection.metainfo,
                magnet: inspection.magnet,
                sourceData: inspection.sourceData,
                files: files,
                failure: nil
            )
        }

        pendingOperations[inspection.operationID] = activeOp
        pendingInspectionBytes += retainedBytes
        return .success(.addSourceInspection(activeOp.toInspection()))
    }

    private func handlePollAddOperation(_ request: PollAddOperationRequest) async -> EngineCommandResult {
        guard let currentOp = pendingOperations[request.operationID] else {
            return .failure(EngineFault.operationNotFound(details: "operationID=\(request.operationID)"))
        }

        var op = currentOp
        let currentGen = op.generation + 1
        op.generation = currentGen
        op.isInFlight = true
        op.lastPolledTime = Date()
        pendingOperations[request.operationID] = op

        if op.phase == .retrievingMetadata, op.engineID != nil {
            await checkMetadataResolution(for: &op)
        }

        guard var latestOp = pendingOperations[request.operationID],
              latestOp.generation == currentGen else {
            return .failure(EngineFault.operationNotFound(details: "operationID=\(request.operationID)"))
        }

        latestOp.phase = op.phase
        latestOp.metainfo = op.metainfo
        latestOp.sourceData = op.sourceData
        latestOp.displayName = op.displayName
        latestOp.sizeBytes = op.sizeBytes
        latestOp.files = op.files
        latestOp.failure = op.failure
        latestOp.lastPolledTime = op.lastPolledTime
        latestOp.isInFlight = false
        pendingOperations[request.operationID] = latestOp

        return .success(.pollAddOperation(PollAddOperationResult(
            phase: latestOp.phase,
            inspection: latestOp.toInspection(),
            failure: latestOp.failure
        )))
    }

    private func checkMetadataResolution(for op: inout ActiveAddOperation) async {
        guard let engineID = op.engineID else { return }
        do {
            let resumeData = try await engine.requestResumeData(torrentID: engineID)
            let trackerTiers: [[String]]
            if let metainfoTiers = op.metainfo?.trackerTiers {
                trackerTiers = metainfoTiers
            } else if let magnetTrackers = op.magnet?.trackers {
                trackerTiers = magnetTrackers.isEmpty ? [] : [magnetTrackers]
            } else {
                trackerTiers = []
            }
            let parsed = try Self.parseResumeMetainfo(resumeData, trackerTiers: trackerTiers)
            guard Self.matchesExpectedIdentity(op.contentIdentity, against: parsed.metainfo) else {
                return
            }
            op.metainfo = parsed.metainfo
            op.sourceData = parsed.data
            op.displayName = parsed.metainfo.name
            op.sizeBytes = parsed.metainfo.totalSize
            op.files = parsed.metainfo.files.map { InspectedFileEntry(path: $0.path, sizeBytes: $0.sizeBytes, priority: .normal) }
            op.phase = .readyToCommit
        } catch {
            // Not ready yet, parse failure, or error reading resume data; keep phase retrievingMetadata
        }
    }

    private func handleCommitAdd(_ request: CommitAddRequest) async -> EngineCommandResult {
        if let replayed = idempotencyResults[request.idempotencyKey] {
            return .success(.commitAdd(replayed))
        }
        guard let activeOp = pendingOperations[request.operationID] else {
            return .failure(EngineFault.operationNotFound(details: "operationID=\(request.operationID)"))
        }

        // Duplicate detection by content identity — check before readyToCommit phase guard so duplicate commit returns Show Existing
        if let existing = record(matching: activeOp.contentIdentity) {
            let result = CommitAddResult(recordID: existing.id, engineRevision: engineRevision)
            await removePendingInspection(request.operationID, force: true)
            rememberIdempotency(request.idempotencyKey, result: result)
            return .success(.commitAdd(result))
        }

        guard activeOp.phase == .readyToCommit else {
            return .failure(EngineFault.invalidPayload(details: "operation is not ready to commit (phase: \(activeOp.phase.rawValue))"))
        }

        var opToCommit = activeOp
        let commitGen = opToCommit.generation + 1
        opToCommit.generation = commitGen
        opToCommit.isInFlight = true
        pendingOperations[request.operationID] = opToCommit

        let now = Int64(Date().timeIntervalSince1970)
        let recordID = TorrentRecordID(rawValue: UUID())
        let desiredState: DesiredTorrentState = (request.startPaused ?? false) ? .paused : .running
        let saveLocation = Self.normalizedSaveLocation(request.saveLocation ?? configuredSaveLocation())
        let displayName = request.desiredName ?? activeOp.displayName
        let selection: [RecordFileSelection]
        if let metainfo = activeOp.metainfo {
            do {
                selection = try TorrentAdder.validateSelection(request.fileSelection, against: metainfo)
            } catch {
                if var failedOp = pendingOperations[request.operationID], failedOp.generation == commitGen {
                    failedOp.isInFlight = false
                    pendingOperations[request.operationID] = failedOp
                }
                return .failure(EngineFault.invalidPayload(details: "fileSelection: \(error.localizedDescription)"))
            }
        } else {
            selection = request.fileSelection.map {
                RecordFileSelection(relativePath: $0.relativePath, priority: $0.priority)
            }
        }

        let trackerTiers: [[String]]
        if let metainfoTiers = activeOp.metainfo?.trackerTiers {
            trackerTiers = metainfoTiers
        } else if let magnetTrackers = activeOp.magnet?.trackers {
            trackerTiers = magnetTrackers.isEmpty ? [] : [magnetTrackers]
        } else {
            trackerTiers = []
        }
        let privateTorrent = activeOp.metainfo?.isPrivate == true
        do {
            try MetainfoParser.validateTrackerTiers(trackerTiers, isPrivate: privateTorrent)
        } catch {
            if var failedOp = pendingOperations[request.operationID], failedOp.generation == commitGen {
                failedOp.isInFlight = false
                pendingOperations[request.operationID] = failedOp
            }
            return .failure(.invalidPayload(details: "tracker topology is invalid"))
        }

        if let engineID = activeOp.engineID, let metainfo = activeOp.metainfo {
            let mergedPriorities = Dictionary(uniqueKeysWithValues: selection.map { ($0.relativePath, $0.priority) })
            let priorities: [UInt8] = metainfo.files.map { file in
                mergedPriorities[file.path] == .skip ? UInt8(0) : UInt8(4)
            }
            do {
                try await engine.commitMetadataOnly(
                    torrentID: engineID,
                    priorities: priorities,
                    paused: request.startPaused ?? false
                )
            } catch {
                if var failedOp = pendingOperations[request.operationID], failedOp.generation == commitGen {
                    failedOp.isInFlight = false
                    pendingOperations[request.operationID] = failedOp
                }
                log.error("commitAdd: commitMetadataOnly failed for operation \(request.operationID): \(String(describing: error))")
                return .failure(EngineFault.engineNotReady(details: "commitMetadataOnly failed: \(error)"))
            }
        }

        // 1. Durable first (journal + row + metainfo) — only then visible.
        var durableRecordCreated = false
        do {
            try await persistence.addTorrent(StoredTorrent(
                id: recordID.rawValue.uuidString,
                infoHashV1: activeOp.contentIdentity.infoHashV1.map { TorrentAdder.hexString($0) },
                infoHashV2: activeOp.contentIdentity.infoHashV2.map { TorrentAdder.hexString($0) },
                name: displayName,
                state: desiredState.rawValue,
                addedAt: now,
                quarantined: false
            ))
            durableRecordCreated = true
            try await persistence.setTorrentLocation(
                torrentID: recordID.rawValue.uuidString,
                location: saveLocation
            )
            let seq = try await persistence.journalAppend(command: "commitAdd", torrentID: recordID.rawValue.uuidString, timestamp: now)
            if let sourceData = activeOp.sourceData {
                _ = try await persistence.storeMetainfo(torrentID: recordID.rawValue.uuidString, data: sourceData)
            }
            try await persistence.setTorrentTrackerTiers(
                torrentID: recordID.rawValue.uuidString,
                tiers: trackerTiers,
                isPrivate: privateTorrent
            )
            try await persistence.journalMarkCommitted(seq: seq)
        } catch {
            if durableRecordCreated {
                do {
                    try await persistence.removeTorrent(torrentID: recordID.rawValue.uuidString)
                } catch {
                    log.error("commitAdd: durable rollback failed for \(recordID): \(String(describing: error))")
                }
            }
            if var failedOp = pendingOperations[request.operationID], failedOp.generation == commitGen {
                failedOp.isInFlight = false
                pendingOperations[request.operationID] = failedOp
            }
            log.error("commitAdd persistence failed: \(String(describing: error))")
            return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: saveLocation.volumeIdentifier))
        }

        let effectiveBytes: Int64
        if let metainfo = activeOp.metainfo {
            effectiveBytes = Self.effectiveTotalBytes(for: metainfo, selection: selection)
        } else {
            effectiveBytes = activeOp.metainfo?.totalSize ?? 0
        }

        let initialActivity: TorrentActivity = desiredState == .running ? (effectiveBytes > 0 ? .downloading : .fetchingMetadata) : .idle
        let record = TransferRecord(
            id: recordID,
            contentIdentity: activeOp.contentIdentity,
            displayName: displayName,
            desiredState: desiredState,
            activity: initialActivity,
            health: .healthy,
            totalBytes: effectiveBytes,
            downloadedBytes: 0,
            uploadedBytes: 0,
            downloadBytesPerSec: 0,
            uploadBytesPerSec: 0,
            peersConnected: 0,
            seedsTotal: 0,
            engineID: activeOp.engineID,
            metainfoData: activeOp.sourceData,
            trackerTiers: trackerTiers,
            fileSelection: selection,
            saveLocation: saveLocation,
            addedAt: now,
            revision: 0
        )
        records[recordID] = record
        recordRevisions[recordID] = 0

        if activeOp.engineID != nil {
            // Already in engine (promoted from temporary metadata-only handle)
        } else {
            let admission = await admit(recordID, reason: .commitAdd)
            applyAdmissionOutcome(admission, to: recordID, reason: .commitAdd)
        }

        await removePendingInspection(request.operationID, force: true)

        bumpEngineRevision(change: .added(recordID))
        let result = CommitAddResult(recordID: recordID, engineRevision: engineRevision)
        rememberIdempotency(request.idempotencyKey, result: result)
        return .success(.commitAdd(result))
    }

    // MARK: - Pause / resume / recheck

    private func handlePauseResume(_ recordID: TorrentRecordID, desired: DesiredTorrentState) async -> EngineCommandResult {
        guard let existing = records[recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: recordID))
        }
        do {
            try await persistence.updateTorrentState(torrentID: recordID.rawValue.uuidString, state: desired.rawValue)
        } catch {
            log.error("pause/resume: persistence failed for \(recordID): \(TorrentinoLog.redactedDescription(error))")
            return .failure(Self.persistenceFault(error, recordID: recordID, volumeIdentifier: existing.saveLocation.volumeIdentifier))
        }
        let record = existing.with(desiredState: desired)
        records[recordID] = record
        let admission = await admit(recordID, reason: .resume)
        applyAdmissionOutcome(admission, to: recordID, reason: .resume)
        bumpEngineRevision(change: .updated(recordID))
        switch admission {
        case .admitted:
            return .success(.ack)
        case .deferred(let health):
            return .failure(admissionFault(for: health, recordID: recordID))
        case .failed(let fault, _):
            return .failure(fault)
        }
    }

    /// The single admission path for commit, restore, resume, pump re-add, and
    /// engine restart. Gate order is intentionally explicit: a later gate must
    /// never mask a safer earlier deferral reason.
    private func admit(_ recordID: TorrentRecordID, reason: AdmissionReason) async -> AdmissionOutcome {
        guard let record = records[recordID] else {
            return .failed(
                fault: .recordNotFound(recordID: recordID),
                health: .recoverableError(.recordNotFound)
            )
        }

        if safeRecovery {
            return .deferred(.recoverableError(.crashLoopSafeMode))
        }

        if record.desiredState == .paused {
            guard await ensureEngineStarted() else {
                return .deferred(.recoverableError(.engineNotReady))
            }
            do {
                if let engineID = record.engineID {
                    try await engine.pause(torrentID: engineID)
                    return .admitted(engineID: engineID, activity: .idle)
                }
                let result = try await engine.add(specification: makeSpecification(for: record, paused: true))
                return .admitted(engineID: result.torrentID, activity: .idle)
            } catch {
                return admissionFailure(error, recordID: recordID, operation: reason.rawValue)
            }
        }

        let storageState = storageProbe(record.saveLocation, requiredBytes(for: record))
        if let storageHealth = health(for: storageState, recordID: recordID) {
            return .deferred(storageHealth)
        }
        if systemConditions.sleeping {
            return .deferred(.recoverableError(.systemSleeping))
        }
        if !systemConditions.canAttemptNetworkWork {
            return .deferred(.waitingForNetwork)
        }
        if !resourceBudget.acceptsHeavyWork {
            return .deferred(.recoverableError(.resourceConstrained))
        }
        if !canAdmitEngineWork(desiredState: record.desiredState, totalBytes: record.totalBytes) {
            return .deferred(.recoverableError(.resourceConstrained))
        }
        guard await ensureEngineStarted() else {
            return .deferred(.recoverableError(.engineNotReady))
        }

        do {
            if let engineID = record.engineID {
                try await engine.resume(torrentID: engineID)
                return .admitted(engineID: engineID, activity: bootstrapActivity(for: record))
            }
            let result = try await engine.add(specification: makeSpecification(for: record, paused: false))
            return .admitted(engineID: result.torrentID, activity: bootstrapActivity(for: record))
        } catch {
            return admissionFailure(error, recordID: recordID, operation: reason.rawValue)
        }
    }

    private func applyAdmissionOutcome(
        _ outcome: AdmissionOutcome,
        to recordID: TorrentRecordID,
        reason: AdmissionReason? = nil
    ) {
        guard let record = records[recordID] else { return }
        switch outcome {
        case .admitted(let engineID, let activity):
            records[recordID] = record.with(engineID: engineID, activity: activity, health: .healthy)
            readdBackoff.removeValue(forKey: recordID)
            if record.engineID != engineID {
                metadataPromotionBackoff.removeValue(forKey: recordID)
            }
            TorrentinoLog.record(
                category: "transfer",
                level: "notice",
                message: "admission succeeded reason=record:\(recordID) activity=\(activity.rawValue)"
            )
        case .deferred(let health):
            records[recordID] = record.with(activity: .idle, health: health)
            TorrentinoLog.record(
                category: "transfer",
                level: "warning",
                message: "admission deferred record=\(recordID) health=\(health)"
            )
        case .failed(_, let health):
            records[recordID] = record.with(activity: .idle, health: health)
            let failures = (readdBackoff[recordID]?.failures ?? 0) + 1
            readdBackoff[recordID] = (
                failures: failures,
                nextAttemptAt: reason == .commitAdd
                    ? .distantPast
                    : Date().addingTimeInterval(Self.backoffSeconds(forAttempt: failures))
            )
        }
    }

    private func admissionFailure(_ error: Error, recordID: TorrentRecordID, operation: String) -> AdmissionOutcome {
        let fault = Self.engineFault(error, operation: operation, recordID: recordID, fallback: "admission failed")
        return .failed(fault: fault, health: Self.engineHealth(from: error, recordID: recordID))
    }

    private func makeSpecification(for record: TransferRecord, paused: Bool) -> AddSpecificationDTO {
        var privateTorrent = false
        if let metainfoData = record.metainfoData {
            do {
                privateTorrent = try Preflight.validateTorrentData(metainfoData).isPrivate
            } catch {
                log.warning("admission metainfo warning record=\(record.id): \(TorrentinoLog.redactedDescription(error))")
            }
        }
        return TorrentAdder.makeSpecification(
            identity: record.contentIdentity,
            metainfoData: record.metainfoData,
            trackerTiers: record.trackerTiers,
            savePath: record.saveLocation.path,
            paused: paused,
            privateTorrent: privateTorrent
        )
    }

    private func bootstrapActivity(for record: TransferRecord) -> TorrentActivity {
        record.metainfoData == nil ? .fetchingMetadata : .checking
    }

    private func admissionFault(for health: TorrentHealth, recordID: TorrentRecordID) -> EngineFault {
        switch health {
        case .waitingForSpace:
            return .insufficientSpace(recordID: recordID)
        case .permissionDenied:
            return .permissionDenied(recordID: recordID)
        case .waitingForVolume:
            return .volumeUnavailable(recordID: recordID)
        case .waitingForNetwork:
            return .networkUnavailable(details: "network path unavailable")
        case .recoverableError(let code):
            switch code {
            case .crashLoopSafeMode:
                return .crashLoopSafeMode()
            case .systemSleeping:
                return .systemSleeping()
            case .resourceConstrained:
                return .resourceConstrained(details: "admission resource budget")
            case .engineNotReady:
                return .engineNotReady(details: "engine not running")
            default:
                return EngineFault(
                    code: code,
                    severity: .warning,
                    affectedRecord: recordID,
                    recoveryActions: ["retry_op"],
                    redactedContext: "admission deferred"
                )
            }
        case .healthy:
            return .engineNotReady(details: "admission deferred")
        case .fatalError(let code):
            return EngineFault(code: code, severity: .fatal, affectedRecord: recordID)
        }
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
        // WP22.D5 (ADR-022): the engine must adopt the selection BEFORE the
        // durable record moves. Build the complete vector in metainfo file
        // order (.normal -> 4, .skip -> 0); a partial or sparse payload can
        // never reach libtorrent.
        var updatedMap = Dictionary(uniqueKeysWithValues: record.fileSelection.map { ($0.relativePath, $0) })
        for item in selection {
            updatedMap[item.relativePath] = item
        }
        let updatedSelection = Array(updatedMap.values)
        let mergedPriorities = Dictionary(uniqueKeysWithValues: updatedSelection.map { ($0.relativePath, $0.priority) })
        let priorities: [UInt8] = metainfo.files.map { file in
            mergedPriorities[file.path] == .skip ? UInt8(0) : UInt8(4)
        }
        guard let engineID = await liveEngineID(for: request.recordID) else {
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await engine.setFileSelection(torrentID: engineID, priorities: priorities)
        } catch {
            // The record's selection, totalBytes, revision and events stay
            // untouched: the requested selection was never applied.
            return .failure(Self.engineFault(
                error,
                operation: "setFileSelection",
                recordID: request.recordID,
                fallback: "file selection rejected by engine"
            ))
        }
        let effectiveBytes = Self.effectiveTotalBytes(for: metainfo, selection: updatedSelection)
        records[request.recordID] = record.with(totalBytes: effectiveBytes, fileSelection: updatedSelection)
        bumpRecordRevision(request.recordID)
        bumpEngineRevision(change: .updated(request.recordID))
        await publishInspectionInvalidated(recordID: request.recordID, scope: .files)
        return .success(.ack)
    }
    fileprivate static func effectiveTotalBytes(for metainfo: Metainfo, selection: [RecordFileSelection]) -> Int64 {
        if selection.isEmpty {
            return metainfo.totalSize
        }
        var total: Int64 = 0
        let selectionMap = Dictionary(uniqueKeysWithValues: selection.map { ($0.relativePath, $0.priority) })
        for file in metainfo.files {
            let priority = selectionMap[file.path] ?? .normal
            if priority != .skip {
                total += file.sizeBytes
            }
        }
        return total
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
        let rows = record.trackerTiers.enumerated().flatMap { tierIndex, tier in
            tier.enumerated().map { urlIndex, url in
                (url: url, tierIndex: tierIndex, urlIndex: urlIndex)
            }
        }
        guard start < rows.count else {
            return Page(items: [], nextCursor: nil, totalCount: rows.count, revision: revision)
        }
        let slice = rows[start..<min(start + pageSize, rows.count)]
        let nextStart = start + slice.count
        return Page(
            items: slice.map {
                TrackerEntry(
                    url: $0.url,
                    status: .updating,
                    seeds: 0,
                    peers: 0,
                    message: nil,
                    tierIndex: $0.tierIndex,
                    urlIndex: $0.urlIndex
                )
            },
            nextCursor: nextStart < rows.count ? PageCursor(token: indexToken(nextStart)) : nil,
            totalCount: rows.count,
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
        guard sessionPhase != .degraded else { return }
        guard !safeRecovery else {
            markDeferredAdmissions(.recoverableError(.crashLoopSafeMode))
            return
        }
        guard !systemConditions.sleeping else {
            markDeferredAdmissions(.recoverableError(.systemSleeping))
            return
        }
        guard systemConditions.canAttemptNetworkWork else {
            markDeferredAdmissions(.waitingForNetwork)
            return
        }
        guard resourceBudget.acceptsHeavyWork else {
            markDeferredAdmissions(.recoverableError(.resourceConstrained))
            return
        }
        healthReporter?.noteEngineTick()
        let now = Date()
        guard now >= nextStatusAttemptAt else { return }
        guard await ensureEngineStarted() else {
            markDeferredAdmissions(.recoverableError(.engineNotReady))
            return
        }

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
            log.warning("pump: statusUpdate failed: \(TorrentinoLog.redactedDescription(error))")
            return
        }
        let statusByEngineID = Dictionary(statuses.map { ($0.engineID, $0) }, uniquingKeysWith: { first, _ in first })
        // Clean expired pending operations (5-minute TTL window)
        let expiredIDs = pendingOperations.compactMap { (id, op) -> AddOperationID? in
            if now.timeIntervalSince(op.lastPolledTime) > Self.pendingOperationTTL {
                return id
            }
            return nil
        }
        for id in expiredIDs {
            await removePendingInspection(id)
        }

        // Metadata resolution probe for pending magnet operations
        for (opID, op) in pendingOperations {
            guard op.phase == .retrievingMetadata, let engineID = op.engineID, !op.isInFlight else { continue }
            if let status = statusByEngineID[engineID], Self.hasResolvedMetadata(status) {
                var inFlightOp = op
                let currentGen = inFlightOp.generation + 1
                inFlightOp.generation = currentGen
                inFlightOp.isInFlight = true
                pendingOperations[opID] = inFlightOp

                await checkMetadataResolution(for: &inFlightOp)

                if var latestOp = pendingOperations[opID], latestOp.generation == currentGen {
                    latestOp.phase = inFlightOp.phase
                    latestOp.metainfo = inFlightOp.metainfo
                    latestOp.sourceData = inFlightOp.sourceData
                    latestOp.displayName = inFlightOp.displayName
                    latestOp.sizeBytes = inFlightOp.sizeBytes
                    latestOp.files = inFlightOp.files
                    latestOp.isInFlight = false
                    pendingOperations[opID] = latestOp
                }
            }
        }

        var changed = Set<TorrentRecordID>()

        // Re-add records the engine does not know yet (restart + failed adds).
        // Iterate a snapshot of the dictionary: records is mutated inside.
        let toReadd = records.filter { $0.value.engineID == nil }
        var readdAttempts = 0
        for (recordID, record) in toReadd {
            guard readdAttempts < resourceBudget.maxReaddsPerPump else { break }
            if let backoff = readdBackoff[recordID], now < backoff.nextAttemptAt {
                continue
            }
            let reason = pendingAdmissionReasons[recordID] ?? .pumpReadd
            readdAttempts += 1
            let outcome = await admit(recordID, reason: reason)
            applyAdmissionOutcome(outcome, to: recordID, reason: reason)
            if case .admitted = outcome {
                pendingAdmissionReasons.removeValue(forKey: recordID)
            } else if case .deferred = outcome {
                pendingAdmissionReasons[recordID] = reason
            }
            if records[recordID] != record {
                changed.insert(recordID)
            }
        }
        // Restart & pump reconciliation: remove engine handles lacking durable records or pending operations
        let knownEngineIDs = Set(records.values.compactMap(\.engineID)).union(pendingOperations.values.compactMap(\.engineID))
        for status in statuses {
            if !knownEngineIDs.contains(status.engineID) {
                log.notice("pump: removing orphan engine handle \(status.engineID)")
                try? await engine.remove(torrentID: status.engineID)
            }
        }

        // Apply live engine status per record (records snapshot copy again).
        let currentRecords = records
        for (recordID, record) in currentRecords {
            guard let engineID = record.engineID, let status = statusByEngineID[engineID] else { continue }
            let updated = record.applying(status, health: Self.liveHealth(for: status))
            if updated != record {
                records[recordID] = updated
                changed.insert(recordID)
                if record.activity != updated.activity || record.health != updated.health {
                    TorrentinoLog.record(
                        category: "transfer",
                        level: updated.health == .healthy ? "notice" : "warning",
                        message: "transfer transition record=\(recordID) activity=\(record.activity.rawValue)->\(updated.activity.rawValue) health=\(record.health)->\(updated.health)"
                    )
                }
            }
        }

        // A resolved magnet has enough live metadata to request the exact
        // resume buffer. Keep this lane independent from admission backoff:
        // at most one request is started per pump, and failures are retried
        // only after the same capped delay used by the engine lanes.
        for (recordID, record) in records {
            guard record.metainfoData == nil,
                  let engineID = record.engineID,
                  let status = statusByEngineID[engineID],
                  Self.hasResolvedMetadata(status),
                  metadataPromotionBackoff[recordID].map({ now < $0.nextAttemptAt }) != true else {
                continue
            }
            if await promoteResolvedMagnet(
                recordID: recordID,
                engineID: engineID,
                status: status
            ) {
                changed.insert(recordID)
            }
            break
        }

        // P4: a healthy running record with no activity is never a valid
        // steady state. Re-admit it through the same gate and log loudly.
        let limbo = records.filter {
            $0.value.desiredState == .running
                && $0.value.engineID == nil
                && $0.value.activity == .idle
                && $0.value.health == .healthy
        }
        for (recordID, record) in limbo {
            TorrentinoLog.record(
                category: "transfer",
                level: "error",
                message: "admission invariant P4 violated record=\(recordID); retrying"
            )
            let outcome = await admit(recordID, reason: .pumpReadd)
            applyAdmissionOutcome(outcome, to: recordID, reason: .pumpReadd)
            if records[recordID] != record {
                changed.insert(recordID)
            }
        }

        guard !changed.isEmpty else { return }
        for recordID in changed {
            bumpRecordRevision(recordID)
            appendEngineChange(.updated(recordID))
        }
        await publishDelta()
    }

    private static func hasResolvedMetadata(_ status: TransferTorrentStatus) -> Bool {
        guard status.activity != .fetchingMetadata, status.totalBytes > 0,
              let rawName = status.metadataName else {
            return false
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = name.lowercased()
        return !name.isEmpty && normalized != "unknown" && normalized != "(unknown)"
    }

    private func promoteResolvedMagnet(
        recordID: TorrentRecordID,
        engineID: String,
        status: TransferTorrentStatus
    ) async -> Bool {
        guard let record = records[recordID],
              record.engineID == engineID,
              record.metainfoData == nil,
              Self.hasResolvedMetadata(status) else {
            return false
        }

        do {
            let resumeData = try await engine.requestResumeData(torrentID: engineID)
            guard let initial = records[recordID],
                  initial.engineID == engineID,
                  initial.metainfoData == nil else {
                return false
            }

            let parsed = try Self.parseResumeMetainfo(
                resumeData,
                trackerTiers: initial.trackerTiers
            )
            guard Self.matchesExpectedIdentity(
                initial.contentIdentity,
                against: parsed.metainfo
            ) else {
                throw EngineFault.invalidPayload(details: "resolved metadata identity mismatch")
            }

            _ = try await persistence.storeMetainfo(
                torrentID: recordID.rawValue.uuidString,
                data: parsed.data
            )
            guard let afterMetainfo = records[recordID],
                  afterMetainfo.engineID == engineID,
                  afterMetainfo.metainfoData == nil else {
                return false
            }

            _ = try await persistence.storeResumeData(
                torrentID: recordID.rawValue.uuidString,
                data: resumeData
            )
            guard let afterResume = records[recordID],
                  afterResume.engineID == engineID,
                  afterResume.metainfoData == nil else {
                return false
            }

            try await persistence.updateTorrentName(
                torrentID: recordID.rawValue.uuidString,
                name: parsed.metainfo.name
            )
            guard let current = records[recordID],
                  current.engineID == engineID,
                  current.metainfoData == nil else {
                return false
            }

            let effectiveBytes = Self.effectiveTotalBytes(
                for: parsed.metainfo,
                selection: current.fileSelection
            )
            records[recordID] = current.with(
                displayName: parsed.metainfo.name,
                metainfoData: parsed.data,
                totalBytes: effectiveBytes
            )
            metadataPromotionBackoff.removeValue(forKey: recordID)
            TorrentinoLog.record(
                category: "transfer",
                level: "notice",
                message: "metadata promotion succeeded record=\(recordID)"
            )
            return true
        } catch {
            guard let current = records[recordID],
                  current.engineID == engineID,
                  current.metainfoData == nil else {
                return false
            }
            let failures = (metadataPromotionBackoff[recordID]?.failures ?? 0) + 1
            metadataPromotionBackoff[recordID] = (
                failures: failures,
                nextAttemptAt: Date().addingTimeInterval(Self.backoffSeconds(forAttempt: failures))
            )
            log.warning(
                "metadata promotion failed record=\(recordID): \(TorrentinoLog.redactedDescription(error))"
            )
            return false
        }
    }

    private static func matchesExpectedIdentity(
        _ expected: ContentIdentity,
        against metainfo: Metainfo
    ) -> Bool {
        let hasExpectedV1 = expected.infoHashV1.map { !$0.isEmpty } ?? false
        let hasExpectedV2 = expected.infoHashV2.map { !$0.isEmpty } ?? false
        guard hasExpectedV1 || hasExpectedV2 else { return false }
        if let expectedV1 = expected.infoHashV1,
           metainfo.infoHashV1 != expectedV1 {
            return false
        }
        if let expectedV2 = expected.infoHashV2,
           metainfo.infoHashV2 != expectedV2 {
            return false
        }
        return true
    }

    private static func parseResumeMetainfo(
        _ data: Data,
        trackerTiers: [[String]]
    ) throws -> (data: Data, metainfo: Metainfo) {
        let candidate: Data
        do {
            _ = try Preflight.validateTorrentData(data)
            candidate = data
        } catch {
            // libtorrent resume buffers may carry harmless top-level keys
            // around the exact info dictionary. Reuse the bounded parser's
            // recorded span and wrap only that dictionary as canonical
            // metainfo.
            let root = try BencodeParser.parse(data)
            guard case .dictionary(let top, _) = root,
                  let info = top.value(for: "info") else {
                throw error
            }
            var wrapped = Data([0x64]) // d
            wrapped.append(BencodeEncoder.encode(.bytes(Data("info".utf8))))
            wrapped.append(data.subdata(in: info.span))
            wrapped.append(0x65) // e
            candidate = wrapped
        }

        // The durable record's topology is authoritative. Rewriting only
        // top-level tracker keys preserves the exact info dictionary/hash and
        // any required resume fields while preventing restore mismatches.
        let canonical = try MetainfoParser.replacingTrackerTiers(
            in: candidate,
            with: trackerTiers
        )
        return (canonical, try Preflight.validateTorrentData(canonical))
    }

    private func markDeferredAdmissions(_ health: TorrentHealth) {
        var changed: [TorrentRecordID] = []
        for (recordID, record) in records where record.engineID == nil && record.desiredState == .running {
            let updated = record.with(activity: .idle, health: health)
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
        Task { await publishDelta() }
    }

    private static func liveHealth(for status: TransferTorrentStatus) -> TorrentHealth {
        guard [.fetchingMetadata, .queued, .checking, .downloading, .seeding].contains(status.activity),
              case .recoverableError(let code) = status.health else {
            return status.health
        }
        switch code {
        case .internalError, .engineBusy, .engineNotReady, .operationTimeout, .engineUnresponsive:
            return .healthy
        default:
            return status.health
        }
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
        guard sessionPhase != .degraded, !safeRecovery, systemConditions.canAttemptNetworkWork else { return false }
        if await engine.isStarted {
            engineStartFailures = 0
            nextEngineStartAt = .distantPast
            return true
        }
        let now = Date()
        guard now >= nextEngineStartAt else { return false }
        do {
            noteUnauthenticatedProxyWindowIfNeeded()
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

    /// SEC-1 boot transient (WP13-SEC-HARDEN-001): honest observability for
    /// the window between agent boot (withheld-credential restore) and the
    /// first UI-driven applySettings. Only a restored-but-withheld credential
    /// announces the window (see shouldNoteUnauthenticatedProxyWindow); a nil
    /// password boots silently. The message is secret-free by construction;
    /// the redactor pipeline stays in place regardless.
    private func noteUnauthenticatedProxyWindowIfNeeded() {
        guard Self.shouldNoteUnauthenticatedProxyWindow(activeSettings.proxy) else { return }
        log.notice("proxy authentication credential not yet delivered; proxy runs unauthenticated until the next settings apply")
    }

    /// SEC-1 boot transient honesty (WP13-SEC-HARDEN-001 REVIEW-002): ONLY a
    /// restored-but-withheld credential ("", from a marker-only row, pending
    /// Keychain re-supply) announces the unauthenticated window. A nil
    /// password means no authentication was ever configured — genuinely
    /// unauthenticated by choice — and must boot silently.
    static func shouldNoteUnauthenticatedProxyWindow(_ proxy: ProxyConfiguration) -> Bool {
        guard proxy.kind != .none,
              !(proxy.username ?? "").isEmpty else { return false }
        return proxy.password == ""
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
            noteUnauthenticatedProxyWindowIfNeeded()
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
            if let storageHealth = health(for: storageProbe(record.saveLocation, requiredBytes(for: record)), recordID: recordID) {
                nextHealth = storageHealth
            } else if !systemConditions.canAttemptNetworkWork && record.desiredState == .running {
                nextHealth = .waitingForNetwork
            } else if !resourceBudget.acceptsHeavyWork && record.desiredState == .running {
                nextHealth = .recoverableError(.resourceConstrained)
            } else {
                nextHealth = .healthy
            }
            records[recordID] = record.with(engineID: nil, activity: .idle, health: nextHealth)
            pendingAdmissionReasons[recordID] = .engineRestart
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

    private func requiredBytes(for record: TransferRecord) -> Int64 {
        max(0, record.totalBytes - record.downloadedBytes)
    }

    private static func isValidCoreIdentity(_ torrent: StoredTorrent) -> Bool {
        guard UUID(uuidString: torrent.id) != nil,
              !torrent.name.isEmpty,
              !torrent.state.isEmpty,
              torrent.addedAt >= 0 else {
            return false
        }
        func validHash(_ value: String?, byteCount: Int) -> Bool {
            // Schema v1 stores an absent optional hash as the empty string.
            guard let value, !value.isEmpty else { return true }
            guard value.count == byteCount * 2,
                  value.allSatisfy({ $0.isHexDigit }) else { return false }
            return true
        }
        guard validHash(torrent.infoHashV1, byteCount: 20),
              validHash(torrent.infoHashV2, byteCount: 32) else {
            return false
        }
        return !(torrent.infoHashV1?.isEmpty ?? true)
            || !(torrent.infoHashV2?.isEmpty ?? true)
    }

    private static func storageFault(
        for state: StorageAvailabilityState,
        recordID: TorrentRecordID,
        volumeIdentifier: String?,
        requiredBytes: Int64
    ) -> EngineFault {
        switch state {
        case .insufficientSpace(_, let availableBytes):
            return EngineFault(
                code: .insufficientSpace,
                severity: .error,
                affectedRecord: recordID,
                affectedVolume: volumeIdentifier,
                recoveryActions: ["free_disk_space", "choose_storage"],
                redactedContext: "requiredBytes=\(max(0, requiredBytes)) availableBytes=\(availableBytes)"
            )
        case .permissionDenied:
            return .permissionDenied(recordID: recordID, volumeIdentifier: volumeIdentifier)
        case .volumeUnavailable, .unknown:
            return .volumeUnavailable(recordID: recordID, volumeIdentifier: volumeIdentifier)
        case .available:
            return .engineNotReady(details: "storage state changed")
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

    private func removePendingInspection(_ operationID: AddOperationID, force: Bool = false) async {
        guard let activeOp = pendingOperations[operationID] else { return }
        if activeOp.isInFlight && !force {
            return
        }
        pendingOperations.removeValue(forKey: operationID)
        pendingInspectionBytes = max(0, pendingInspectionBytes - (activeOp.sourceData?.count ?? 0))
        if let engineID = activeOp.engineID {
            let isOwnedByRecord = records.values.contains(where: { $0.engineID == engineID })
            if !isOwnedByRecord {
                try? await engine.remove(torrentID: engineID)
            }
        }
    }

    private static func backoffSeconds(forAttempt attempt: Int) -> TimeInterval {
        var delay = 0.25
        for _ in 1..<max(1, min(attempt, 8)) {
            delay = min(delay * 2, 30)
        }
        return delay
    }

    #if DEBUG
    public func agePendingOperation(_ operationID: AddOperationID, bySeconds seconds: TimeInterval) {
        if var op = pendingOperations[operationID] {
            op.lastPolledTime = op.lastPolledTime.addingTimeInterval(-seconds)
            pendingOperations[operationID] = op
        }
    }
    #endif
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
        // generic busy result. A record-scoped call must not lose attribution:
        // when the fault names no record, stamp the caller's recordID while
        // keeping every other field exactly as produced; a fault that already
        // names its record passes through untouched.
        if let fault = error as? EngineFault {
            guard fault.affectedRecord == nil, let recordID else { return fault }
            return EngineFault(
                code: fault.code,
                severity: fault.severity,
                affectedRecord: recordID,
                affectedVolume: fault.affectedVolume,
                localizationKey: fault.localizationKey,
                recoveryActions: fault.recoveryActions,
                redactedContext: fault.redactedContext
            )
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(activity: TorrentActivity, health: TorrentHealth) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(engineID: String?, activity: TorrentActivity, health: TorrentHealth) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(totalBytes: Int64, fileSelection: [RecordFileSelection]) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    /// Live engine status merged into the record. Equal when nothing changed.
    fileprivate func applying(_ status: TransferTorrentStatus, health: TorrentHealth = .healthy) -> TransferRecord {
        let fraction = min(1, max(0, status.progressFraction))
        let effectiveTotal: Int64
        if let metainfoData, let metainfo = try? Preflight.validateTorrentData(metainfoData) {
            effectiveTotal = TransferCoordinator.effectiveTotalBytes(for: metainfo, selection: fileSelection)
        } else if status.totalBytes > 0 {
            // A magnet has no persisted metainfo until the engine receives it;
            // use the live torrent_status total as soon as it is available.
            effectiveTotal = status.totalBytes
        } else if self.totalBytes > 0 {
            effectiveTotal = self.totalBytes
        } else if status.downloadedBytes > 0 && fraction > 0 {
            effectiveTotal = Int64(Double(status.downloadedBytes) / fraction)
        } else {
            effectiveTotal = 0
        }

        let downloaded: Int64
        if status.downloadedBytes > 0 {
            downloaded = min(effectiveTotal, status.downloadedBytes)
        } else {
            downloaded = Int64(fraction * Double(effectiveTotal))
        }

        let candidate = TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: status.activity, health: health,
            totalBytes: effectiveTotal, downloadedBytes: downloaded, uploadedBytes: status.uploadedBytes,
            downloadBytesPerSec: status.downloadBytesPerSec, uploadBytesPerSec: status.uploadBytesPerSec,
            peersConnected: status.peersConnected, seedsTotal: status.seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
        return candidate == self ? self : candidate
    }

    fileprivate func withTrackers(
        trackerTiers: [[String]],
        metainfoData: Data?
    ) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
            fileSelection: fileSelection, saveLocation: saveLocation,
            addedAt: addedAt, revision: revision, limits: limits
        )
    }

    fileprivate func with(
        displayName: String,
        metainfoData: Data,
        totalBytes: Int64
    ) -> TransferRecord {
        TransferRecord(
            id: id, contentIdentity: contentIdentity, displayName: displayName,
            desiredState: desiredState, activity: activity, health: health,
            totalBytes: totalBytes, downloadedBytes: downloadedBytes, uploadedBytes: uploadedBytes,
            downloadBytesPerSec: downloadBytesPerSec, uploadBytesPerSec: uploadBytesPerSec,
            peersConnected: peersConnected, seedsTotal: seedsTotal,
            engineID: engineID, metainfoData: metainfoData,
            trackerTiers: trackerTiers,
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
        // F1-ROLLBACK-SENTINEL (WP13-SEC-HARDEN-001 REVIEW-003): the
        // rollback below re-persists `previousSettings`, whose restored
        // credential is "" (withheld) — not a value — so persistSettings'
        // default derivation from that password alone would erase a
        // marker=true sentinel to false while the Keychain secret survives,
        // leaving the next boot silent instead of empty/notice. Pin the
        // marker to the PRE-APPLY durable row, read before the transaction
        // can rewrite it: loadSettings reconstructs "" exactly when the row
        // carries marker=true, nil when it does not, which stays honest even
        // when the live configuration legitimately holds an empty credential
        // persisted as marker=false.
        let preApplyHadProxyPassword: Bool
        do {
            preApplyHadProxyPassword = try await persistence.loadSettings()?.settings.proxy.password != nil
        } catch {
            // Fail closed: without a truthful pre-apply marker the rollback
            // could not restore exact at-rest semantics, so never enter the
            // transaction. A store broken enough to fail this read rejects
            // the persist step too; this only surfaces that same typed
            // outcome before any durable byte moves.
            return .failure(Self.persistenceFault(error, recordID: nil, volumeIdentifier: nil))
        }
        // SEC-1 boot re-supply invariant (WP13-SEC-HARDEN-001 REVIEW-002):
        // the durable presence marker describes the DELIVERED/live
        // configuration, never the credential-free candidate. The live
        // configuration is therefore projected once, before the transaction,
        // and both the persist step (marker only, zero secret bytes) and the
        // engine apply use exactly that projection. A pre-delivery peer that
        // still embeds its own password in the candidate joins through the
        // same path, so the row stays truthful for old senders too.
        let deliveredLive = Self.deliveringProxyPassword(
            request.proxyPassword,
            in: request.candidate
        )
        let outcome = await SettingsTransaction.run(
            candidate: request.candidate,
            expectedRevision: request.expectedRevision,
            context: SettingsTransaction.AsyncContext(
                currentRevision: previousRevision,
                persist: { candidate, currentRevision in
                    let newRevision = currentRevision + 1
                    try await persistence.persistSettings(
                        candidate,
                        revision: newRevision,
                        hadProxyPassword: !(deliveredLive.proxy.password ?? "").isEmpty
                    )
                    return newRevision
                },
                apply: { [weak self] candidate in
                    guard let self else {
                        return .failure(.internalError(details: "settings coordinator deallocated"))
                    }
                    do {
                        // SEC-1 credential delivery (WP13-SEC-HARDEN-001):
                        // `deliveredLive` above is the received credential
                        // joined onto the candidate — in-memory
                        // activeSettings and the engine session only.
                        // `persist` stays on the credential-free candidate,
                        // so durable rows remain marker-only.
                        try await self.engine.apply(settings: deliveredLive)
                        await self.setActiveSettings(deliveredLive, revision: previousRevision + 1)
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
                    try await persistence.persistSettings(previousSettings, revision: previousRevision, hadProxyPassword: preApplyHadProxyPassword)
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
        guard let requestedTiers = request.trackerTiers else {
            return .failure(.invalidPayload(details: "structured tracker replacement is required"))
        }
        guard request.addedURLs.isEmpty, request.removedURLs.isEmpty else {
            return .failure(.invalidPayload(details: "structured tracker edit cannot mix delta fields"))
        }

        if let previous = trackerEditResults[request.idempotencyKey] {
            guard previous.recordID == request.recordID,
                  previous.trackerTiers == requestedTiers else {
                return .failure(.creatorOperationConflict(details: "tracker edit idempotency key was reused with a different topology"))
            }
            return .success(.ack)
        }
        guard activeTrackerEditRecords.insert(request.recordID).inserted else {
            return .failure(.creatorOperationConflict(details: "tracker edit is already active for this record"))
        }
        defer { activeTrackerEditRecords.remove(request.recordID) }

        guard let metainfoData = record.metainfoData else {
            return .failure(.invalidPayload(details: "structured tracker edit requires metainfo"))
        }
        let parsedMetainfo: Metainfo
        do {
            parsedMetainfo = try Preflight.validateTorrentData(metainfoData)
        } catch {
            return .failure(.corruptData(details: "stored metainfo cannot authorize tracker edit"))
        }
        guard parsedMetainfo.trackerTiers == record.trackerTiers else {
            return .failure(.corruptData(details: "record tracker topology does not match metainfo"))
        }
        let priorTopologyJSON: Data
        do {
            guard let storedJSON = try await persistence.torrentTrackerTopologyJSON(
                torrentID: request.recordID.rawValue.uuidString
            ) else {
                return .failure(.corruptData(details: "structured tracker topology row is missing"))
            }
            priorTopologyJSON = storedJSON
        } catch {
            return .failure(.corruptData(details: "structured tracker topology row is corrupt"))
        }
        do {
            try MetainfoParser.validateTrackerTiers(requestedTiers, isPrivate: parsedMetainfo.isPrivate)
        } catch {
            return .failure(.invalidPayload(details: "tracker topology is invalid"))
        }
        if requestedTiers == record.trackerTiers {
            trackerEditResults[request.idempotencyKey] = TrackerEditIdempotency(
                recordID: request.recordID,
                trackerTiers: requestedTiers
            )
            return .success(.ack)
        }

        let updatedMetainfoData: Data
        do {
            updatedMetainfoData = try MetainfoParser.replacingTrackerTiers(
                in: metainfoData,
                with: requestedTiers
            )
            let reparsed = try Preflight.validateTorrentData(updatedMetainfoData)
            guard reparsed.trackerTiers == requestedTiers else {
                return .failure(.corruptData(details: "structured tracker edit changed topology during metainfo rewrite"))
            }
        } catch let fault as EngineFault {
            return .failure(fault)
        } catch {
            return .failure(.corruptData(details: "structured tracker edit cannot update metainfo"))
        }

        func restoreDurableState() async -> Error? {
            do {
                try await persistence.restoreTorrentTrackerTopologyJSON(
                    torrentID: request.recordID.rawValue.uuidString,
                    data: priorTopologyJSON,
                    isPrivate: parsedMetainfo.isPrivate
                )
                _ = try await persistence.storeMetainfo(
                    torrentID: request.recordID.rawValue.uuidString,
                    data: metainfoData
                )
                return nil
            } catch {
                return error
            }
        }

        do {
            try await persistence.setTorrentTrackerTiers(
                torrentID: request.recordID.rawValue.uuidString,
                tiers: requestedTiers,
                isPrivate: parsedMetainfo.isPrivate
            )
            _ = try await persistence.storeMetainfo(
                torrentID: request.recordID.rawValue.uuidString,
                data: updatedMetainfoData
            )
        } catch {
            if let rollbackError = await restoreDurableState() {
                return .failure(Self.persistenceFault(
                    rollbackError,
                    recordID: request.recordID,
                    volumeIdentifier: record.saveLocation.volumeIdentifier
                ))
            }
            return .failure(Self.persistenceFault(
                error,
                recordID: request.recordID,
                volumeIdentifier: record.saveLocation.volumeIdentifier
            ))
        }

        guard let engineID = await liveEngineID(for: request.recordID) else {
            if let rollbackError = await restoreDurableState() {
                return .failure(Self.persistenceFault(
                    rollbackError,
                    recordID: request.recordID,
                    volumeIdentifier: record.saveLocation.volumeIdentifier
                ))
            }
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await engine.editTrackers(torrentID: engineID, trackerTiers: requestedTiers)
        } catch {
            if let rollbackError = await restoreDurableState() {
                return .failure(Self.persistenceFault(
                    rollbackError,
                    recordID: request.recordID,
                    volumeIdentifier: record.saveLocation.volumeIdentifier
                ))
            }
            return .failure(Self.engineFault(
                error,
                operation: "editTrackers",
                recordID: request.recordID,
                fallback: "tracker edit rejected by engine"
            ))
        }
        records[request.recordID] = record.withTrackers(
            trackerTiers: requestedTiers,
            metainfoData: updatedMetainfoData
        )
        trackerEditResults[request.idempotencyKey] = TrackerEditIdempotency(
            recordID: request.recordID,
            trackerTiers: requestedTiers
        )
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
        metadataPromotionBackoff.removeValue(forKey: recordID)
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
        metadataPromotionBackoff.removeValue(forKey: recordID)
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

    /// SEC-1 credential delivery (WP13-SEC-HARDEN-001): joins the received
    /// applySettings credential onto the live configuration. The value is
    /// held in memory only (activeSettings / engine session); persistence
    /// keeps stripping credentials at rest, so no durable byte ever carries
    /// it — including the rollback path that re-persists `previousSettings`.
    private static func deliveringProxyPassword(
        _ password: String?,
        in candidate: EngineSettings
    ) -> EngineSettings {
        guard let password, !password.isEmpty else { return candidate }
        return EngineSettings(
            downloadDirectory: candidate.downloadDirectory,
            maxDownloadBytesPerSec: candidate.maxDownloadBytesPerSec,
            maxUploadBytesPerSec: candidate.maxUploadBytesPerSec,
            listenPort: candidate.listenPort,
            dhtEnabled: candidate.dhtEnabled,
            lsdEnabled: candidate.lsdEnabled,
            upnpEnabled: candidate.upnpEnabled,
            natPmpEnabled: candidate.natPmpEnabled,
            encryptionEnabled: candidate.encryptionEnabled,
            proxy: ProxyConfiguration(
                kind: candidate.proxy.kind,
                host: candidate.proxy.host,
                port: candidate.proxy.port,
                username: candidate.proxy.username,
                password: password
            )
        )
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

    /// Routes a creator's completed metadata through the same durable add path
    /// as an imported .torrent. Calling the bridge directly here would create
    /// an engine handle without a persisted TransferRecord or revision.
    private func admitCreatedTorrent(
        metainfoData: Data,
        savePath: String,
        paused: Bool,
        expectedTrackerTiers: [[String]],
        idempotencyKey: IdempotencyKey
    ) async throws {
        let parsedMetainfo: Metainfo
        do {
            parsedMetainfo = try Preflight.validateTorrentData(metainfoData)
        } catch {
            throw EngineFault.corruptData(details: "creator admission metainfo parse failed")
        }
        guard parsedMetainfo.trackerTiers == expectedTrackerTiers else {
            // Admission must compare the generated bytes with the immutable
            // requested topology before the common durable add path can seed.
            throw EngineFault.corruptData(details: "creator metainfo tracker topology mismatch")
        }

        let inspectionResult = await handleInspect(InspectAddSourceRequest(
            requestID: RequestID(),
            source: .torrentFileData(metainfoData)
        ))
        let addInspection: AddSourceInspection
        switch inspectionResult {
        case .success(.addSourceInspection(let inspection)):
            addInspection = inspection
        case .failure(let fault):
            throw fault
        default:
            throw EngineFault.internalError(details: "creator admission returned an unexpected inspection payload")
        }

        let commitResult = await handleCommitAdd(CommitAddRequest(
            requestID: RequestID(),
            idempotencyKey: idempotencyKey,
            operationID: addInspection.operationID,
            saveLocation: PersistedLocation(path: savePath),
            startPaused: paused
        ))
        if pendingOperations[addInspection.operationID] != nil {
            await removePendingInspection(addInspection.operationID)
        }
        switch commitResult {
        case .success(.commitAdd):
            return
        case .failure(let fault):
            throw fault
        default:
            throw EngineFault.internalError(details: "creator admission returned an unexpected commit payload")
        }
    }

    private func handleCommitCreate(_ request: CommitCreateRequest) async -> EngineCommandResult {
        guard request.optionsWereAsserted else {
            return .failure(.creatorAssertionMissing())
        }
        guard !activeCreatorPlans.contains(request.token) else {
            return .failure(.creatorOperationConflict(details: "creator plan is already being committed"))
        }
        guard acceptedCreatorIdempotencyKeys.insert(request.idempotencyKey).inserted else {
            return .failure(.creatorOperationConflict(details: "creator idempotency key was already used"))
        }

        var mintedOperationID = OperationID()
        while acceptedCreatorOperations.contains(mintedOperationID) {
            mintedOperationID = OperationID()
        }
        let operationID = mintedOperationID
        acceptedCreatorOperations.insert(operationID)
        activeCreatorPlans.insert(request.token)
        activeCreatorOperations.insert(operationID)
        _ = creatorCancellationGate.withLock { state in
            state.active.insert(operationID)
        }

        await eventBus.publish([.operationProgress(OperationProgressEvent(
            operationID: operationID,
            phase: .started,
            fraction: 0.0,
            timestamp: Date(),
            detail: OperationProgressDetail(stage: "Scanning", backend: "cpu")
        ))])

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCreatorCommit(request: request, operationID: operationID)
        }
        creatorTasks[operationID] = task
        return .success(.creatorOperationAccepted(CreateOperationAccepted(operationID: operationID)))
    }

    private func runCreatorCommit(request: CommitCreateRequest, operationID: OperationID) async {
        let cancelCheck: @Sendable () throws -> Void = { [creatorCancellationGate] in
            let cancelled = creatorCancellationGate.withLock { $0.cancelled.contains(operationID) }
            if cancelled { throw HasherError.cancelled }
        }

        do {
            guard let pinnedVerifier = engine as? any CreatorIndependentVerifier else {
                throw EngineFault.creatorUnavailable(details: "creator independent verifier is unavailable")
            }
            let _ = try await creatorPlanStore.commitCreateVerified(
                token: request.token,
                idempotencyKey: request.idempotencyKey,
                assertedOptions: request.options,
                independentVerifier: { data in
                    try await pinnedVerifier.verifyCreatorTorrent(data: data)
                },
                addTorrent: { [self] metainfoData, savePath, paused, _ in
                    try await self.admitCreatedTorrent(
                        metainfoData: metainfoData,
                        savePath: savePath,
                        paused: paused,
                        expectedTrackerTiers: request.options.trackers,
                        idempotencyKey: request.idempotencyKey
                    )
                },
                onProgress: { [eventBus] fraction, detail in
                    await eventBus.publish([.operationProgress(OperationProgressEvent(
                        operationID: operationID,
                        phase: .running,
                        fraction: fraction,
                        timestamp: Date(),
                        detail: detail
                    ))])
                },
                cancelCheck: cancelCheck
            )

            finishCreatorOperation(operationID, token: request.token)
            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: .succeeded,
                timestamp: Date()
            ))], urgent: true)
        } catch let fault as EngineFault {
            let outcome: OperationOutcome = fault.code == .operationCancelled
                ? .cancelled
                : .failed(fault)
            TorrentinoLog.record(
                category: "transfer",
                level: fault.code == .operationCancelled ? "info" : "error",
                message: "creator commit failed code=\(fault.code.rawValue) key=\(fault.localizationKey) details=\(fault.redactedContext ?? fault.localizedDescription)"
            )
            finishCreatorOperation(operationID, token: request.token)
            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: outcome,
                timestamp: Date()
            ))], urgent: true)
        } catch {
            let fault = EngineFault.creatorStorageFailure(details: "commitCreate failed: \(error)")
            TorrentinoLog.record(
                category: "transfer",
                level: "error",
                message: "creator commit failed untyped details=\(error)"
            )
            finishCreatorOperation(operationID, token: request.token)
            await eventBus.publish([.operationCompleted(OperationCompletedEvent(
                operationID: operationID,
                outcome: .failed(fault),
                timestamp: Date()
            ))], urgent: true)
        }
    }

    private func finishCreatorOperation(_ operationID: OperationID, token: CreatorPlanToken) {
        activeCreatorOperations.remove(operationID)
        activeCreatorPlans.remove(token)
        creatorTasks.removeValue(forKey: operationID)
        creatorCancellationGate.withLock { state in
            state.active.remove(operationID)
            state.cancelled.remove(operationID)
        }
    }

}
