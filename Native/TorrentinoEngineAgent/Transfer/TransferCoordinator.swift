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
    private let log = Logger(subsystem: "com.torrentino.app.engine-agent", category: "transfer")

    // MARK: - State

    private var records: [TorrentRecordID: TransferRecord] = [:]
    private var recordRevisions: [TorrentRecordID: UInt64] = [:]
    /// Deltas are published contiguously: every publish covers all changes
    /// with revision > publishedRevision and carries publishedRevision + 1.
    private var publishedRevision: UInt64 = 0
    private var engineRevision: UInt64 = 0
    private var pendingOperations: [AddOperationID: TorrentAdder.Inspection] = [:]
    private var idempotencyResults: [IdempotencyKey: CommitAddResult] = [:]
    private var pumpTask: Task<Void, Never>?
    private let instanceID = UUID()
    private var activeSettings: EngineSettings = .default
    private var settingsRevision: SettingsRevision = 1
    private var lastReannounceAt: [TorrentRecordID: Date] = [:]
    private var pendingRemovalTokens: [String: TorrentRecordID] = [:]
    private static let reannounceCooldown: TimeInterval = 30

    // MARK: - Init

    init(
        engine: any TransferEngine,
        persistence: PersistenceStore,
        eventBus: TransferEventBus,
        agentVersion: String,
        defaultSaveLocation: PersistedLocation,
        pumpIntervalNanoseconds: UInt64? = nil
    ) {
        self.engine = engine
        self.persistence = persistence
        self.eventBus = eventBus
        self.agentVersion = agentVersion
        self.defaultSaveLocation = defaultSaveLocation
        self.pumpIntervalNanoseconds = pumpIntervalNanoseconds
    }

    // MARK: - Lifecycle

    /// Starts the status pump (no-op when the coordinator was built with a nil
    /// interval). Safe to call once; the AgentRuntime calls it after restore.
    public func startPump() {
        guard pumpTask == nil else { return }
        guard let pumpIntervalNanoseconds else { return }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pumpIntervalNanoseconds)
                guard let self, !Task.isCancelled else { break }
                await self.pumpOnce()
            }
        }
    }

    /// Stops the status pump and cancels in-flight engine work.
    public func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
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
            let record = TransferRecord(
                id: recordID,
                contentIdentity: identity,
                displayName: torrent.name,
                desiredState: desired,
                activity: .idle,
                health: .healthy,
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
                saveLocation: defaultSaveLocation,
                addedAt: torrent.addedAt,
                revision: 0,
                limits: limits.normalized
            )
            records[recordID] = record
            recordRevisions[recordID] = 0
            engineRevision += 1
        }
        // Nothing was published for restored records (the UI connects fresh
        // and fetches a full snapshot), so the next delta starts above them.
        publishedRevision = engineRevision
        log.info("restore: rebuilt \(self.records.count) record(s), engineRevision \(self.engineRevision)")
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
        case .fetchRemovalManifestPage:
            return .failure(unsupported("fetchRemovalManifestPage"))
        case .fetchCreatorManifestPage:
            return .failure(unsupported("fetchCreatorManifestPage"))
        case .inspectAddSource(let request):
            return await handleInspect(request)
        case .commitAdd(let request):
            return await handleCommitAdd(request)
        case .cancelAdd(let request):
            pendingOperations.removeValue(forKey: request.operationID)
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
        case .prepareForQuit, .restartEngineSafely:
            return .success(.ack)
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
        case .moveStorage,
             .inspectCreateSource, .commitCreate, .exportDiagnostics:
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
        let inspection: TorrentAdder.Inspection
        do {
            switch request.source {
            case .magnet(let uri):
                inspection = try TorrentAdder.inspectMagnet(uri: uri, desiredName: request.desiredName)
            case .torrentFileData(let data):
                inspection = try TorrentAdder.inspectTorrentData(data, desiredName: request.desiredName)
            case .torrentFileURL(let urlString):
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

        pendingOperations[inspection.operationID] = inspection
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
            idempotencyResults[request.idempotencyKey] = result
            return .success(.commitAdd(result))
        }

        let now = Int64(Date().timeIntervalSince1970)
        let recordID = TorrentRecordID(rawValue: UUID())
        let desiredState: DesiredTorrentState = (request.startPaused ?? false) ? .paused : .running
        let saveLocation = request.saveLocation ?? defaultSaveLocation
        let displayName = request.desiredName ?? inspection.displayName
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
            let seq = try await persistence.journalAppend(command: "commitAdd", torrentID: recordID.rawValue.uuidString, timestamp: now)
            if let sourceData = inspection.sourceData {
                _ = try await persistence.storeMetainfo(torrentID: recordID.rawValue.uuidString, data: sourceData)
            }
            try await persistence.journalMarkCommitted(seq: seq)
        } catch {
            log.error("commitAdd persistence failed: \(String(describing: error))")
            return .failure(EngineFault(code: .storeError, severity: .fatal, recoveryActions: ["retry_op"], redactedContext: "\(error)"))
        }

        // 2. Engine add (best-effort: failure degrades THIS record only).
        let engineID: String?
        var health: TorrentHealth = .healthy
        var activity: TorrentActivity = inspection.metainfo == nil ? .fetchingMetadata : .queued
        if await ensureEngineStarted() {
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
                health = .recoverableError(.engineBusy)
                activity = .idle
                log.warning("commitAdd: engine add failed for \(recordID): \(String(describing: error))")
            }
        } else {
            engineID = nil
            health = .recoverableError(.engineNotReady)
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
        pendingOperations.removeValue(forKey: request.operationID)

        bumpEngineRevision(change: .added(recordID))
        let result = CommitAddResult(recordID: recordID, engineRevision: engineRevision)
        idempotencyResults[request.idempotencyKey] = result
        return .success(.commitAdd(result))
    }

    // MARK: - Pause / resume / recheck

    private func handlePauseResume(_ recordID: TorrentRecordID, desired: DesiredTorrentState) async -> EngineCommandResult {
        guard var record = records[recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: recordID))
        }
        record = record.with(desiredState: desired)
        records[recordID] = record
        do {
            try await persistence.updateTorrentState(torrentID: recordID.rawValue.uuidString, state: desired.rawValue)
        } catch {
            log.error("pause/resume: persistence failed for \(recordID): \(String(describing: error))")
        }
        if let engineID = record.engineID, await ensureEngineStarted() {
            do {
                switch desired {
                case .paused: try await engine.pause(torrentID: engineID)
                case .running: try await engine.resume(torrentID: engineID)
                case .removed: break
                }
            } catch {
                records[recordID] = record.with(health: .recoverableError(.engineBusy))
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
        guard await ensureEngineStarted() else { return }

        var statuses: [TransferTorrentStatus] = []
        do {
            statuses = try await engine.statusUpdate()
        } catch {
            log.warning("pump: statusUpdate failed: \(String(describing: error))")
            return
        }
        let statusByEngineID = Dictionary(statuses.map { ($0.engineID, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [TorrentRecordID] = []

        // Re-add records the engine does not know yet (restart + failed adds).
        // Iterate a snapshot of the dictionary: records is mutated inside.
        let toReadd = records.filter { $0.value.engineID == nil }
        for (recordID, record) in toReadd {
            let specification = TorrentAdder.makeSpecification(
                identity: record.contentIdentity,
                metainfoData: record.metainfoData,
                trackers: record.trackers,
                savePath: record.saveLocation.path,
                paused: record.desiredState == .paused
            )
            do {
                let result = try await engine.add(specification: specification)
                records[recordID] = record.with(engineID: result.torrentID, health: .healthy)
                changed.append(recordID)
            } catch {
                records[recordID] = record.with(health: .recoverableError(.engineBusy))
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

    // MARK: - Engine lifecycle helpers

    private func ensureEngineStarted() async -> Bool {
        if await engine.isStarted {
            return true
        }
        do {
            try await engine.start(configuration: activeSettings)
            return true
        } catch {
            log.warning("ensureEngineStarted failed: \(String(describing: error))")
            return false
        }
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

    private func unsupported(_ commandName: String) -> EngineFault {
        EngineFault(
            code: .unsupportedOperation,
            severity: .error,
            recoveryActions: [],
            redactedContext: "command=\(commandName)"
        )
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
        guard let record = records[request.recordID] else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        // Negative values become zero and nil remains unlimited at the engine boundary.
        let normalized = request.limits.normalized
        guard let engineID = await liveEngineID(for: request.recordID) else {
            return .failure(.engineNotReady(details: "torrent engine handle is unavailable"))
        }
        do {
            try await persistence.setTorrentLimits(
                torrentID: request.recordID.rawValue.uuidString,
                limits: normalized
            )
        } catch {
            return .failure(.storeError(underlying: error))
        }
        do {
            try await engine.setLimits(torrentID: engineID, limits: normalized)
        } catch {
            // Persistence must not report a limit that the live engine rejected.
            try? await persistence.setTorrentLimits(
                torrentID: request.recordID.rawValue.uuidString,
                limits: record.limits
            )
            return .failure(.engineBusy(details: "setLimits rejected by engine"))
        }
        records[request.recordID] = (records[request.recordID] ?? record).with(limits: normalized)
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
                        await self.invalidateEngineBindings()
                        await self.setActiveSettings(candidate, revision: previousRevision + 1)
                        return .success(())
                    } catch {
                        return .failure(.engineBusy(details: "settings apply rejected by engine"))
                    }
                },
                rollback: { [weak self] _, _ in
                    if let self {
                        try await self.engine.apply(settings: previousSettings)
                        await self.invalidateEngineBindings()
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
            return .failure(.engineBusy(details: "reannounce rejected by engine"))
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
            return .failure(.storeError(underlying: error))
        }
        do {
            try await engine.editTrackers(torrentID: engineID, trackers: updated)
        } catch {
            try? await persistence.setTorrentTrackers(
                torrentID: request.recordID.rawValue.uuidString,
                trackers: record.trackers
            )
            return .failure(.engineBusy(details: "tracker edit rejected by engine"))
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

    private func invalidateEngineBindings() {
        for (recordID, record) in records where record.engineID != nil {
            records[recordID] = record.with(engineID: nil, health: .healthy)
        }
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

    private func handlePrepareRemoval(_ request: PrepareRemovalRequest) async -> EngineCommandResult {
        guard records[request.recordID] != nil else {
            return .failure(EngineFault.recordNotFound(recordID: request.recordID))
        }
        let token = RemovalToken(rawValue: UUID().uuidString)
        pendingRemovalTokens[token.rawValue] = request.recordID
        return .success(.removalToken(token))
    }

    private func handleCommitRemoval(_ request: CommitRemovalRequest) async -> EngineCommandResult {
        guard let recordID = pendingRemovalTokens.removeValue(forKey: request.token.rawValue),
              let record = records[recordID] else {
            return .failure(.invalidRequest(details: "removal token is unknown or expired"))
        }

        if let engineID = record.engineID, await ensureEngineStarted() {
            do {
                try await engine.remove(torrentID: engineID)
            } catch {
                return .failure(.engineBusy(details: "removal failed"))
            }
        }

        do {
            try await persistence.removeTorrent(torrentID: recordID.rawValue.uuidString)
        } catch {
            return .failure(.storeError(underlying: error))
        }

        records.removeValue(forKey: recordID)
        recordRevisions.removeValue(forKey: recordID)
        lastReannounceAt.removeValue(forKey: recordID)
        bumpEngineRevision(change: .removed(recordID))
        return .success(.ack)
    }

    private func setActiveSettings(_ settings: EngineSettings, revision: SettingsRevision) {
        activeSettings = settings
        settingsRevision = revision
    }
}
