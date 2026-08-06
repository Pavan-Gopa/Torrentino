// Layer: UI presentation model (WP-07 transfer list).
// Role: consumes the agent's authoritative snapshot + event stream (deltas,
// snapshotRequired, torrentAdded/Removed, inspectionInvalidated) and projects
// them into observable state for the transfer table, detail pane and status
// bar. Falls back to a 100-row demo fixture ONLY when the agent is
// unreachable, so the table's identity/scroll/focus behavior can be validated
// without a running engine.
// Must-not: invent torrents, cache agent state as source of truth, mutate
// engine state except through the v1 command lane, or perform file IO on the
// main actor.
// Invariants: MainActor-only published state; the agent's revision counter is
// applied strictly (any gap triggers a full snapshot refetch); selection and
// pagination cursors are the UI's own, not the agent's.

import Foundation
import AppKit
import TorrentinoIPC

@MainActor
final class TorrentListViewModel: ObservableObject {
    @Published private(set) var torrents: [TorrentSnapshot] = []
    @Published private(set) var engineRevision: UInt64 = 0
    @Published private(set) var instanceID: UUID?
    @Published private(set) var usingFixture = false
    @Published private(set) var connectionNote: String?
    @Published private(set) var commandError: String?
    /// Table row selection; single-selection UI keeps at most one element.
    @Published var selection: Set<TorrentRecordID> = []
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var filesLoading = false
    @Published private(set) var fileRevision: UInt64 = 0
    @Published private(set) var connectionGeneration: UInt64 = 0
    @Published var showAddSheet = false
    @Published var showCreateSheet = false
    @Published private(set) var creatorProgressFraction: Double = 0.0
    @Published private(set) var creatorProgressStage: String = ""
    @Published private(set) var creatorProgressBackend: String = ""
    @Published private(set) var creatorProcessedBytes: Int64?
    @Published private(set) var creatorTotalBytes: Int64?
    @Published private(set) var creatorProcessedFiles: Int?
    @Published private(set) var creatorTotalFiles: Int?
    @Published private(set) var creatorETASeconds: Int64?
    @Published private(set) var creatorCancellationRequested = false
    @Published private(set) var creatorTerminalCancellation = false
    @Published private(set) var creatorCompletedSummary: CreateSummary?
    @Published private(set) var creatorError: String?
    @Published private(set) var creatorOperationActive = false
    @Published private(set) var creatorTerminalOutcome: OperationOutcome?
    @Published private(set) var activeCreatorToken: CreatorPlanToken?
    /// The accepted identity returned by the agent. It remains set through the
    /// terminal presentation so late foreign events stay filtered out.
    private var creatorOperationID: OperationID?
    private var awaitingCreatorOperationID = false
    private var creatorCancelPending = false
    private var bufferedCreatorEvents: [OperationID: [EngineEventV1]] = [:]
    @Published var showInspector = false
    @Published var searchText = ""
    @Published var searchFocusRequest = 0
    @Published private(set) var busy = false
    @Published private(set) var systemConditions = SystemConditions.normal
    /// WP-10 (Gate 9): the most recent commitRemoval batch outcome, surfaced
    /// inline instead of being silently discarded.
    @Published private(set) var lastRemovalResult: RemovalBatchResult?
    /// WP-10 (Gate 4/9): unsettled removal batches from a previous session
    /// (guided recovery), discovered via fetchPendingRemovals on connect.
    @Published private(set) var pendingRemovals: [PendingRemovalSummary] = []

    let client: EngineClient
    private(set) var directoryStack: [String] = []
    private var fileCursor: PageCursor?
    private var eventHandler: (@Sendable ([EngineEventV1]) -> Void)?
    private var recoveryInFlight = false

    init(client: EngineClient) {
        self.client = client
    }

    // MARK: - Derived presentation

    var selectedTorrent: TorrentSnapshot? {
        guard let selectedRecordID = selection.first else { return nil }
        return torrents.first { $0.id == selectedRecordID }
    }

    /// Aggregated rates + counts for the status bar (derived from the
    /// authoritative snapshot only).
    var statusBar: TorrentStatusBarModel {
        var downloadBytesPerSec: Int64 = 0
        var uploadBytesPerSec: Int64 = 0
        var downloading = 0
        var seeding = 0
        var paused = 0
        for torrent in torrents {
            downloadBytesPerSec += torrent.rates.downloadBytesPerSec
            uploadBytesPerSec += torrent.rates.uploadBytesPerSec
            switch torrent.activity {
            case .downloading, .fetchingMetadata, .checking, .queued: downloading += 1
            case .seeding: seeding += 1
            case .pendingAdd, .moving, .removing, .idle: break
            }
            if torrent.desiredState == .paused { paused += 1 }
        }
        return TorrentStatusBarModel(
            downloadBytesPerSec: downloadBytesPerSec,
            uploadBytesPerSec: uploadBytesPerSec,
            downloading: downloading,
            seeding: seeding,
            paused: paused,
            total: torrents.count
        )
    }

    // MARK: - Lifecycle

    /// Connects, subscribes to the event stream, and pulls the full snapshot.
    /// Any transport failure switches to the demo fixture so the UI remains
    /// fully interactive without an agent.
    func start() async {
        do {
            await client.setReconnectHandler { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.recoverAfterReconnect()
                }
            }
            _ = try await client.hello()
            try await subscribe()
            try await fetchFullSnapshot()
            await refreshPendingRemovals()
            usingFixture = false
            connectionNote = nil
            connectionGeneration &+= 1
        } catch {
            usingFixture = true
            connectionNote = String(localized: "fixture.note")
            torrents = FixtureLibrary.snapshot(count: 100)
            engineRevision = UInt64(torrents.count)
            if selection.isEmpty { selection = torrents.first.map { [$0.id] } ?? [] }
        }
    }

    /// Registers the event handler on the XPC queue; batches hop to MainActor.
    func subscribe() async throws {
        eventHandler = { [weak self] events in
            Task { @MainActor [weak self] in
                self?.apply(events)
            }
        }
        guard let eventHandler else { return }
        try await client.subscribeEvents(handler: eventHandler)
    }

    func refresh() {
        Task {
            try? await fetchFullSnapshot()
        }
    }

    func restartEngineSafely() {
        Task {
            do {
                try await client.restartEngineSafely()
                commandError = nil
                connectionNote = nil
                try await fetchFullSnapshot()
            } catch {
                surfaceCommandError(error, fallback: "recovery.restart_failed")
            }
        }
    }

    // MARK: - Event application (reconciliation)

    private func apply(_ events: [EngineEventV1]) {
        var changedAuthoritativeState = false
        for event in events {
            switch event {
            case .torrentDelta(let payload):
                let delta = payload.delta
                guard delta.engineRevision == engineRevision + 1, !usingFixture else {
                    Task { await recoverFromFullSnapshot() }
                    continue
                }
                for snapshot in delta.added { upsert(snapshot) }
                for snapshot in delta.updated { upsert(snapshot) }
                for recordID in delta.removed { remove(recordID) }
                engineRevision = delta.engineRevision
                torrents = torrents.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                changedAuthoritativeState = true
            case .torrentAdded(let payload):
                upsert(payload.snapshot)
                engineRevision = max(engineRevision, payload.engineRevision)
                changedAuthoritativeState = true
            case .torrentRemoved(let payload):
                remove(payload.recordID)
                engineRevision = max(engineRevision, payload.engineRevision)
                changedAuthoritativeState = true
            case .snapshotRequired:
                Task { await recoverFromFullSnapshot() }
            case .inspectionInvalidated(let payload):
                if selection.contains(payload.recordID),
                   payload.scope == .files || payload.scope == .all {
                     Task { await loadFiles(for: payload.recordID) }
                 }
            case .systemCondition(let payload):
                // This is an agent observation, not UI-owned state. Keeping it
                // published lets the presentation layer show offline/sleep/
                // pressure recovery without polling the heavy command lane.
                systemConditions = payload.conditions
            case .operationProgress(let payload):
                guard let creatorOperationID else {
                    guard awaitingCreatorOperationID else { break }
                    bufferedCreatorEvents[payload.operationID, default: []].append(event)
                    break
                }
                // WP-11: only the accepted creator operation drives the sheet.
                guard payload.operationID == creatorOperationID else { break }
                guard creatorTerminalOutcome == nil else { break }
                creatorOperationActive = true
                creatorProgressFraction = payload.fraction
                let detail = payload.detail
                creatorProgressStage = detail?.stage ?? ""
                creatorProgressBackend = detail?.backend ?? ""
                creatorProcessedBytes = detail?.processedBytes
                creatorTotalBytes = detail?.totalBytes
                creatorProcessedFiles = detail?.fileCount
                creatorTotalFiles = detail?.totalFileCount
                creatorETASeconds = detail?.etaSeconds
                if detail?.isCancelled == true {
                    // Cancellation is monotonic until the matching terminal
                    // event; a late ordinary progress update cannot hide it.
                    creatorCancellationRequested = true
                }
                if creatorCancellationRequested {
                    creatorProgressStage = "Cancelling"
                }
            case .operationCompleted(let payload):
                guard let creatorOperationID else {
                    guard awaitingCreatorOperationID else { break }
                    bufferedCreatorEvents[payload.operationID, default: []].append(event)
                    break
                }
                guard payload.operationID == creatorOperationID else { break }
                creatorOperationActive = false
                creatorTerminalOutcome = payload.outcome
                switch payload.outcome {
                case .succeeded:
                    creatorProgressFraction = 1.0
                    creatorProgressStage = "Completed"
                    creatorCancellationRequested = false
                    creatorTerminalCancellation = false
                case .cancelled:
                    creatorProgressStage = "Cancelled"
                    creatorCancellationRequested = true
                    creatorTerminalCancellation = true
                    creatorError = String(localized: "creator.fault.cancelled")
                case .failed(let fault):
                    creatorProgressStage = "Failed"
                    creatorError = creatorUserMessage(for: fault)
                    creatorTerminalCancellation = false
                }
            case .engineHealthChanged, .engineLifecycleChanged, .recoverableIssue, .settingsChanged:
                break
            }
        }
        if changedAuthoritativeState && !usingFixture {
            NotificationManager.shared.processSnapshots(torrents)
        }
    }

    private func upsert(_ snapshot: TorrentSnapshot) {
        if let index = torrents.firstIndex(where: { $0.id == snapshot.id }) {
            torrents[index] = snapshot
        } else {
            torrents.append(snapshot)
        }
    }

    private func remove(_ recordID: TorrentRecordID) {
        torrents.removeAll { $0.id == recordID }
        selection.remove(recordID)
    }

    // MARK: - Commands

    private func fetchFullSnapshot() async throws {
        let command = EngineCommandV1.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil))
        guard case .snapshot(let snapshot) = try await client.sendCommand(command) else { return }
        torrents = snapshot.torrents.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        engineRevision = snapshot.engineRevision
        instanceID = snapshot.instanceID
        usingFixture = false
        connectionNote = nil
        NotificationManager.shared.processSnapshots(torrents)
    }

    private func recoverFromFullSnapshot() async {
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        defer { recoveryInFlight = false }
        do {
            try await fetchFullSnapshot()
            connectionGeneration &+= 1
        } catch {
            connectionNote = String(localized: "snapshot.failed")
        }
    }

    private func recoverAfterReconnect() async {
        // EngineClient has already restored the event subscription before this
        // callback. The snapshot is still required because the agent may have
        // restarted and its revision/instance are authoritative again.
        await recoverFromFullSnapshot()
        // A fresh engine session may hold unsettled removal batches (Gate 4/9).
        await refreshPendingRemovals()
    }

    func addMagnet(_ uri: String, startPaused: Bool) async {
        do {
            let inspection = try await inspect(source: .magnet(uri))
            await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
        } catch {
            connectionNote = String(localized: "add.failed")
        }
    }

    func addTorrentFile(_ url: URL, startPaused: Bool) async {
        do {
            // File IO off the main actor; the bytes travel through the v1 lane.
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
            let inspection = try await inspect(source: .torrentFileData(data))
            await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
        } catch {
            connectionNote = String(localized: "add.failed")
        }
    }

    func addTorrentFileURL(_ urlString: String, startPaused: Bool) async {
        do {
            let inspection = try await inspect(source: .torrentFileURL(urlString))
            await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
        } catch {
            connectionNote = String(localized: "add.failed")
        }
    }

    private func inspect(source: AddSource) async throws -> AddSourceInspection {
        let command = EngineCommandV1.inspectAddSource(
            InspectAddSourceRequest(requestID: RequestID(), source: source))
        guard case .addSourceInspection(let inspection) = try await client.sendCommand(command) else {
            throw EngineClientError.protocolMismatch(details: "unexpected inspectAddSource reply")
        }
        return inspection
    }

    private func commitAdd(operationID: AddOperationID, startPaused: Bool) async {
        let command = EngineCommandV1.commitAdd(
            CommitAddRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                operationID: operationID,
                desiredName: nil,
                saveLocation: nil,
                fileSelection: [],
                startPaused: startPaused
            )
        )
        do {
            guard case .commitAdd(let result) = try await client.sendCommand(command) else { return }
            selection = [result.recordID]
        } catch {
            connectionNote = String(localized: "add.failed")
        }
    }

    func pause(_ recordID: TorrentRecordID) async {
        let command = EngineCommandV1.pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        _ = try? await client.sendCommand(command)
    }

    func resume(_ recordID: TorrentRecordID) async {
        let command = EngineCommandV1.resume(ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        _ = try? await client.sendCommand(command)
    }

    var canPauseSelected: Bool {
        torrents.contains { selection.contains($0.id) && $0.desiredState == .running }
    }

    var canResumeSelected: Bool {
        torrents.contains { selection.contains($0.id) && $0.desiredState == .paused }
    }

    func pauseSelected() {
        let selectedIDs = Array(selection)
        Task {
            for id in selectedIDs {
                await pause(id)
            }
        }
    }

    func resumeSelected() {
        let selectedIDs = Array(selection)
        Task {
            for id in selectedIDs {
                await resume(id)
            }
        }
    }

    func removeSelected() {
        let selectedIDs = Array(selection)
        Task {
            for recordID in selectedIDs {
                let prepare = EngineCommandV1.prepareRemoval(PrepareRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    recordID: recordID,
                    deleteFiles: false
                ))
                do {
                    guard case .removalToken(let token) = try await client.sendCommand(prepare) else {
                        throw EngineClientError.protocolMismatch(details: "unexpected prepareRemoval reply")
                    }
                    let commit = EngineCommandV1.commitRemoval(CommitRemovalRequest(
                        requestID: RequestID(),
                        idempotencyKey: IdempotencyKey(),
                        token: token
                    ))
                    // WP-10 (Gate 9): the batch outcome (completed/partial/
                    // failed + per-item failures) is surfaced, never discarded.
                    // The engine itself is resumable: a partial or failed batch
                    // keeps its token pending for an explicit guided retry.
                    guard case .removalResult(let result) = try await client.sendCommand(commit) else {
                        throw EngineClientError.protocolMismatch(details: "unexpected commitRemoval reply")
                    }
                    lastRemovalResult = result
                } catch {
                    connectionNote = String(localized: "remove.failed")
                }
            }
            await refreshPendingRemovals()
        }
    }

    /// WP-10 (Gate 4/9): asks the agent for unsettled removal batches so a
    /// half-trashed session (app or engine crash) is offered for guided
    /// recovery instead of disappearing. Never auto-resumes anything.
    func refreshPendingRemovals() async {
        let command = EngineCommandV1.fetchPendingRemovals(FetchPendingRemovalsRequest(requestID: RequestID()))
        do {
            guard case .pendingRemovals(let summaries) = try await client.sendCommand(command) else {
                throw EngineClientError.protocolMismatch(details: "unexpected fetchPendingRemovals reply")
            }
            pendingRemovals = summaries
        } catch {
            // Non-fatal: the removal flow still works, recovery discovery is
            // best-effort on connect.
            connectionNote = String(localized: "remove.pendingLookupFailed")
        }
    }

    /// WP-10 (Gate 4/9): explicitly resumes a pending removal batch from a
    /// previous session. The per-item journal makes this a resume — already
    /// trashed items are never touched again — and partial outcomes keep the
    /// token pending for further retries.
    func retryRemoval(_ summary: PendingRemovalSummary) {
        Task {
            do {
                let commit = EngineCommandV1.commitRemoval(CommitRemovalRequest(
                    requestID: RequestID(),
                    idempotencyKey: IdempotencyKey(),
                    token: summary.token
                ))
                guard case .removalResult(let result) = try await client.sendCommand(commit) else {
                    throw EngineClientError.protocolMismatch(details: "unexpected commitRemoval reply")
                }
                lastRemovalResult = result
                await refreshPendingRemovals()
            } catch {
                connectionNote = String(localized: "remove.failed")
            }
        }
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func revealSelected() {
        guard let torrent = selectedTorrent else { return }
        let url = URL(fileURLWithPath: torrent.saveLocation.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func toggleInspector() {
        showInspector.toggle()
    }

    func reannounce(_ recordID: TorrentRecordID) async {
        let command = EngineCommandV1.reannounce(ReannounceRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        do {
            _ = try await client.sendCommand(command)
            commandError = nil
        } catch {
            surfaceCommandError(error, fallback: "reannounce.failed")
        }
    }

    func editTrackers(_ recordID: TorrentRecordID, trackerTiers: [[String]]) async {
        let command = EngineCommandV1.editTrackers(EditTrackersRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            addedURLs: [],
            removedURLs: [],
            trackerTiers: trackerTiers
        ))
        do {
            _ = try await client.sendCommand(command)
            commandError = nil
        } catch {
            surfaceCommandError(error, fallback: "trackers.failed")
        }
    }

    func setLimits(_ recordID: TorrentRecordID, limits: TransferLimits) async {
        let command = EngineCommandV1.setLimits(SetLimitsRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID, limits: limits))
        do {
            _ = try await client.sendCommand(command)
            commandError = nil
        } catch {
            surfaceCommandError(error, fallback: "limits.failed")
        }
    }

    // MARK: - Files pane (paginated, off-main friendly)

    func select(_ recordID: TorrentRecordID?) {
        selection = recordID.map { [$0] } ?? []
        files = []
        fileCursor = nil
        directoryStack = []
        if let recordID {
            Task { await loadFiles(for: recordID) }
        }
    }

    func enterDirectory(_ name: String) {
        directoryStack.append(name)
        Task { await loadFiles(for: selection.first) }
    }

    func goUpDirectory() {
        guard !directoryStack.isEmpty else { return }
        directoryStack.removeLast()
        Task { await loadFiles(for: selection.first) }
    }

    func loadFiles(for recordID: TorrentRecordID?, pageSize: Int = 200) async {
        guard let recordID, let torrent = torrents.first(where: { $0.id == recordID }) else { return }
        filesLoading = true
        defer { filesLoading = false }
        let cursor = FileCursor(directoryStack: directoryStack, token: fileCursor)
        let command = EngineCommandV1.fetchFiles(
            FetchFilesRequest(requestID: RequestID(), recordID: recordID, cursor: cursor, pageSize: pageSize, expectedRevision: torrent.revision)
        )
        do {
            guard case .files(let page) = try await client.sendCommand(command) else { return }
            files = page.items
            fileCursor = page.nextCursor
            fileRevision = page.revision
        } catch {
            connectionNote = String(localized: "files.failed")
        }
    }

    func setSelection(_ relativePath: String, priority: FileSelectionPriority) async {
        guard let recordID = selection.first,
              let torrent = torrents.first(where: { $0.id == recordID }) else { return }
        let command = EngineCommandV1.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                selection: [FileSelectionItem(relativePath: relativePath, priority: priority)],
                expectedRevision: torrent.revision
            )
        )
        do {
            _ = try await client.sendCommand(command)
            commandError = nil
        } catch {
            surfaceCommandError(error, fallback: "files.failed")
        }
    }

    func surfaceCommandError(_ error: Error, fallback: String) {
        let message = localizedCommandError(error, fallback: fallback)
        commandError = message
        connectionNote = message
    }

    private func localizedCommandError(_ error: Error, fallback: String) -> String {
        if let clientError = error as? EngineClientError,
           case .fault(let fault) = clientError {
            switch fault.code {
            case .rateLimited: return String(localized: "error.rate_limited")
            case .unsupportedOperation: return String(localized: "error.unsupported_operation")
            case .engineBusy, .engineNotReady, .operationTimeout:
                return String(localized: "error.engine_operation")
            case .networkUnavailable: return String(localized: "error.network_unavailable")
            case .volumeUnavailable: return String(localized: "error.volume_unavailable")
            case .permissionDenied: return String(localized: "error.permission_denied")
            case .insufficientSpace: return String(localized: "error.insufficient_space")
            case .resourceConstrained: return String(localized: "error.resource_constrained")
            case .systemSleeping: return String(localized: "error.system_sleeping")
            case .crashLoopSafeMode, .engineUnresponsive:
                return String(localized: "error.restart_engine_safely")
            case .storeError: return String(localized: "error.store_error")
            case .internalError: return String(localized: "error.internal")
            default: break
            }
        }
        return String(localized: String.LocalizationValue(fallback))
    }

    /// Creator presentation is a closed catalog mapping. `redactedContext` is
    /// intentionally absent here because it is diagnostics-only, even when a
    /// fault happens to carry a stable localization key.
    func creatorUserMessage(for error: Error, fallback: String = "creator.fault.storage") -> String {
        if let clientError = error as? EngineClientError,
           case .fault(let fault) = clientError {
            return creatorUserMessage(for: fault, fallback: fallback)
        }
        if let fault = error as? EngineFault {
            return creatorUserMessage(for: fault, fallback: fallback)
        }
        return String(localized: String.LocalizationValue(fallback))
    }

    private func creatorUserMessage(for fault: EngineFault, fallback: String = "creator.fault.storage") -> String {
        let key: String
        switch fault.localizationKey {
        case "creator.fault.private_tracker_missing":
            key = fault.localizationKey
        case "creator.fault.stale_plan":
            key = fault.localizationKey
        case "creator.fault.assertion_mismatch":
            key = fault.localizationKey
        case "creator.fault.storage":
            key = fault.localizationKey
        case "creator.fault.cancelled":
            key = fault.localizationKey
        case "creator.fault.operation_conflict":
            key = fault.localizationKey
        case "creator.fault.unavailable":
            key = fault.localizationKey
        case "creator.fault.invalid_options":
            key = fault.localizationKey
        default:
            switch fault.code {
            case .operationCancelled:
                key = "creator.fault.cancelled"
            case .operationNotFound, .idempotencyConflict:
                key = "creator.fault.operation_conflict"
            case .invalidPayload, .invalidArgument:
                key = "creator.fault.invalid_options"
            case .permissionDenied, .insufficientSpace, .volumeUnavailable, .storeError:
                key = "creator.fault.storage"
            default:
                key = fallback
            }
        }
        return String(localized: String.LocalizationValue(key))
    }

    // MARK: - Torrent Creator

    /// Invalidates the UI's local token before any form reinspection starts.
    /// The agent remains the source of truth; this only prevents a stale local
    /// token from being selected by the commit button.
    func invalidateCreatorInspection() {
        activeCreatorToken = nil
        creatorOperationID = nil
        awaitingCreatorOperationID = false
        creatorOperationActive = false
        creatorCancelPending = false
        bufferedCreatorEvents.removeAll()
        creatorTerminalOutcome = nil
        creatorTerminalCancellation = false
        creatorError = nil
    }

    func inspectCreateSource(sourcePath: String, options: CreateOptions? = nil) async throws -> CreateSourceInspection {
        creatorError = nil
        creatorProgressFraction = 0.0
        creatorProgressStage = "Scanning"
        creatorProgressBackend = "cpu"
        creatorProcessedBytes = nil
        creatorTotalBytes = nil
        creatorProcessedFiles = nil
        creatorTotalFiles = nil
        creatorETASeconds = nil
        creatorCancellationRequested = false
        creatorTerminalCancellation = false
        creatorOperationID = nil
        awaitingCreatorOperationID = false
        creatorOperationActive = false
        creatorCancelPending = false
        bufferedCreatorEvents.removeAll()
        creatorTerminalOutcome = nil
        creatorCompletedSummary = nil
        let inspection = try await client.inspectCreateSource(sourcePath: sourcePath, options: options)
        activeCreatorToken = inspection.token
        return inspection
    }

    func fetchCreatorManifestPage(token: CreatorPlanToken, cursor: PageCursor? = nil, pageSize: Int = 100) async throws -> Page<CreatorManifestEntry> {
        try await client.fetchCreatorManifestPage(token: token, cursor: cursor, pageSize: pageSize)
    }

    func commitCreate(
        token: CreatorPlanToken,
        options: CreateOptions,
        idempotencyKey: IdempotencyKey = IdempotencyKey()
    ) async throws {
        creatorError = nil
        creatorProgressFraction = 0.0
        creatorProgressStage = "Creating..."
        creatorProgressBackend = "cpu"
        creatorProcessedBytes = nil
        creatorTotalBytes = nil
        creatorProcessedFiles = nil
        creatorTotalFiles = nil
        creatorETASeconds = nil
        creatorCancellationRequested = false
        creatorTerminalCancellation = false
        creatorOperationID = nil
        awaitingCreatorOperationID = true
        creatorOperationActive = false
        creatorCancelPending = false
        bufferedCreatorEvents.removeAll()
        creatorTerminalOutcome = nil
        do {
            let acceptedOperationID = try await client.commitCreate(
                token: token,
                options: options,
                idempotencyKey: idempotencyKey
            )
            creatorOperationID = acceptedOperationID
            awaitingCreatorOperationID = false
            creatorOperationActive = true
            let acceptedEvents = bufferedCreatorEvents.removeValue(forKey: acceptedOperationID) ?? []
            bufferedCreatorEvents.removeAll()
            if !acceptedEvents.isEmpty {
                apply(acceptedEvents)
            }
            if creatorCancelPending, creatorOperationActive {
                creatorCancelPending = false
                sendCreatorCancellation(acceptedOperationID)
            } else if !creatorOperationActive {
                creatorCancelPending = false
            }
        } catch {
            awaitingCreatorOperationID = false
            creatorCancelPending = false
            bufferedCreatorEvents.removeAll()
            throw error
        }
    }

    /// Requests cancellation only after an accepted agent operation exists. If
    /// the acceptance reply is still in flight, the request is held locally
    /// and sent once that authoritative ID arrives; the agent rejects an
    /// unknown ID instead of retaining a pre-cancel signal.
    func cancelCreation() {
        guard creatorOperationActive || awaitingCreatorOperationID else { return }
        creatorCancellationRequested = true
        creatorProgressStage = "Cancelling"
        creatorCancelPending = true
        if let operationID = creatorOperationID, creatorOperationActive {
            creatorCancelPending = false
            sendCreatorCancellation(operationID)
        }
    }

    private func sendCreatorCancellation(_ operationID: OperationID) {
        let client = self.client
        Task { @MainActor [weak self] in
            do {
                try await client.cancelOperation(operationID: operationID)
            } catch {
                guard let self, self.creatorTerminalOutcome == nil else { return }
                self.creatorError = self.creatorUserMessage(
                    for: error,
                    fallback: "creator.fault.operation_conflict"
                )
            }
        }
    }
}
// FixtureLibrary is kept in its dependency-free source file so the app tests
// can exercise the same generator: enum FixtureLibrary { static func snapshot(count: Int = 100) -> [TorrentSnapshot] { return (1...count).map { _ in fatalError() } } }

/// Aggregate numbers for the status bar (UI-side projection of the snapshot).
struct TorrentStatusBarModel: Equatable {
    let downloadBytesPerSec: Int64
    let uploadBytesPerSec: Int64
    let downloading: Int
    let seeding: Int
    let paused: Int
    let total: Int
}
