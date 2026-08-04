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
    @Published private(set) var creatorCompletedSummary: CreateSummary?
    @Published private(set) var creatorError: String?
    @Published private(set) var activeCreatorToken: CreatorPlanToken?
    /// Track the in-flight creation Task so cancelCreation() can cancel it.
    private var creatorTask: Task<Void, Never>?
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
                creatorProgressFraction = payload.fraction
            case .operationCompleted(let payload):
                switch payload.outcome {
                case .succeeded:
                    creatorProgressFraction = 1.0
                    creatorProgressStage = "Completed"
                case .cancelled:
                    creatorError = "Operation cancelled"
                case .failed(let fault):
                    creatorError = fault.redactedContext ?? fault.localizationKey
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

    func editTrackers(_ recordID: TorrentRecordID, addedURLs: [String], removedURLs: [String]) async {
        let command = EngineCommandV1.editTrackers(EditTrackersRequest(
            requestID: RequestID(),
            idempotencyKey: IdempotencyKey(),
            recordID: recordID,
            addedURLs: addedURLs,
            removedURLs: removedURLs
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

    // MARK: - Torrent Creator

    func inspectCreateSource(sourcePath: String, options: CreateOptions? = nil) async throws -> CreateSourceInspection {
        creatorError = nil
        creatorProgressFraction = 0.0
        creatorProgressStage = "Scanning"
        let inspection = try await client.inspectCreateSource(sourcePath: sourcePath, options: options)
        activeCreatorToken = inspection.token
        return inspection
    }

    func fetchCreatorManifestPage(token: CreatorPlanToken, cursor: PageCursor? = nil, pageSize: Int = 100) async throws -> Page<CreatorManifestEntry> {
        try await client.fetchCreatorManifestPage(token: token, cursor: cursor, pageSize: pageSize)
    }

    func commitCreate(token: CreatorPlanToken, idempotencyKey: IdempotencyKey = IdempotencyKey()) async throws {
        creatorError = nil
        creatorProgressFraction = 0.0
        creatorProgressStage = "Creating..."
        try await client.commitCreate(token: token, idempotencyKey: idempotencyKey)
        try? await fetchFullSnapshot()
    }

    /// Cancels an in-flight creation operation by cancelling the tracking
    /// task. The agent-side CreatorPlanStore checks cancelCheck between stages
    /// and cleans up the temp file via the defer block.
    func cancelCreation() {
        creatorTask?.cancel()
        creatorTask = nil
        creatorError = nil
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
