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
import TorrentinoDomain
import TorrentinoIPC

@MainActor
final class TorrentListViewModel: ObservableObject {
    @Published private(set) var torrents: [TorrentSnapshot] = []
    @Published private(set) var engineRevision: UInt64 = 0
    @Published private(set) var instanceID: UUID?
    @Published private(set) var usingFixture = false
    @Published private(set) var connectionNote: String?
    @Published private(set) var lifecyclePhase: EngineLifecycleState?
    @Published private(set) var lifecycleDegradedReason: String?
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
    @Published var pendingAddFileURL: URL? = nil
    @Published private(set) var lastAddError: String? = nil
    @Published private(set) var defaultDownloadLocation: String? = nil

    func presentIncomingTorrent(_ url: URL) {
        guard TorrentDropRouting.isTorrentDropURL(url) else { return }
        guard acceptIncomingTorrentURL(url) else { return }
        pendingAddFileURL = url
        showAddSheet = true
    }

    private var recentImportURLs: [URL: Date] = [:]

    func importIncomingTorrent(_ url: URL) {
        // Finder, SwiftUI openURL, and window DnD all use the same preview path.
        presentIncomingTorrent(url)
    }

    private func acceptIncomingTorrentURL(_ url: URL) -> Bool {
        let now = Date()
        if let last = recentImportURLs[url], now.timeIntervalSince(last) < 2.0 {
            return false
        }
        recentImportURLs[url] = now
        recentImportURLs = recentImportURLs.filter { now.timeIntervalSince($0.value) < 10.0 }
        return true
    }

    let client: EngineClient
    private(set) var directoryStack: [String] = []
    private var fileCursor: PageCursor?
    private var filesLoadRequestID = UUID()
    private var eventHandler: (@Sendable ([EngineEventV1]) -> Void)?
    private var recoveryInFlight = false
    /// Push events are authoritative but intentionally best-effort. This
    /// backstop heals a missed batch while a transfer is live.
    private var snapshotBackstopTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private var snapshotRequestGeneration: UInt64 = 0
    init(client: EngineClient) {
        self.client = client
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAfterAppActivation()
            }
        }
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
    /// Fixtures are used only after bounded transport reconnect is exhausted;
    /// a reachable degraded agent remains visible as a truthful empty/list
    /// state with a lifecycle note.
    func start() async {
        await client.setReconnectHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.recoverAfterReconnect()
            }
        }

        for _ in 0..<5 {
            do {
                _ = try await client.hello()
                try await subscribe()
                try await fetchFullSnapshot()
                await refreshPendingRemovals()
                usingFixture = false
                lifecyclePhase = .ready
                lifecycleDegradedReason = nil
                connectionNote = nil
                connectionGeneration &+= 1
                startSnapshotBackstop()
                return
            } catch let error as EngineClientError {
                if case .fault(let fault) = error, fault.code == .engineNotReady {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if Self.isTransportFailure(error) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                applyReachableFault(error)
                return
            } catch {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        usingFixture = true
        lifecyclePhase = nil
        lifecycleDegradedReason = nil
        connectionNote = String(localized: "fixture.note")
        torrents = FixtureLibrary.snapshot(count: 100)
        engineRevision = UInt64(torrents.count)
        if selection.isEmpty { selection = torrents.first.map { [$0.id] } ?? [] }
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
    
    /// Keeps the authoritative snapshot moving even if an event batch is
    /// dropped or a short-lived XPC client interrupts push delivery.
    private func startSnapshotBackstop() {
        guard snapshotBackstopTask == nil else { return }
        snapshotBackstopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.hasActiveTransfers else { continue }
                await self.refreshActiveSnapshot()
            }
        }
    }

    private var hasActiveTransfers: Bool {
        torrents.contains { torrent in
            guard torrent.desiredState == .running else { return false }
            switch torrent.activity {
            case .fetchingMetadata, .queued, .checking, .downloading, .seeding, .moving:
                return true
            case .pendingAdd, .removing, .idle:
                return false
            }
        }
    }

    private func refreshActiveSnapshot() async {
        guard !usingFixture, !recoveryInFlight else { return }
        try? await fetchFullSnapshot()
    }

    private func refreshAfterAppActivation() async {
        guard !usingFixture else { return }
        try? await fetchFullSnapshot()
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

    /// Reads the agent-owned setting so the Add sheet can show the actual
    /// default destination instead of presenting a guessed path.
    func loadDefaultDownloadLocation() async {
        do {
            let command = EngineCommandV1.fetchSettings(FetchSettingsRequest(requestID: RequestID()))
            guard case .settingsFetch(let result) = try await client.sendCommand(command) else {
                throw EngineClientError.protocolMismatch(details: "unexpected fetchSettings reply")
            }
            let path = (result.settings.downloadDirectory as NSString).expandingTildeInPath
            defaultDownloadLocation = path.isEmpty ? nil : path
        } catch {
            defaultDownloadLocation = nil
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
            case .engineLifecycleChanged(let payload):
                lifecyclePhase = payload.to
                lifecycleDegradedReason = payload.to == .degraded ? payload.degradedReason : nil
                if payload.to == .degraded {
                    usingFixture = false
                    connectionNote = Self.localizedLifecycleReason(payload.degradedReason)
                } else if payload.to == .ready, !usingFixture {
                    connectionNote = nil
                }
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
            case .engineHealthChanged, .recoverableIssue, .settingsChanged:
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
        if selection.remove(recordID) != nil {
            filesLoadRequestID = UUID()
            files = []
            fileCursor = nil
            directoryStack = []
            filesLoading = false
        }
    }

    // MARK: - Commands

    private func fetchFullSnapshot() async throws {
        snapshotRequestGeneration &+= 1
        let requestGeneration = snapshotRequestGeneration
        let command = EngineCommandV1.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil))
        guard case .snapshot(let snapshot) = try await client.sendCommand(command) else {
            throw EngineClientError.protocolMismatch(details: "unexpected fetchSnapshot reply")
        }
        // A newer backstop/mutation fetch wins if an older XPC reply arrives
        // later; stale snapshots must never roll the published list backwards.
        guard requestGeneration == snapshotRequestGeneration else { return }
        torrents = snapshot.torrents
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        engineRevision = snapshot.engineRevision
        instanceID = snapshot.instanceID
        usingFixture = false
        if lifecyclePhase != .degraded {
            connectionNote = nil
        }
        NotificationManager.shared.processSnapshots(torrents)
    }
    /// Mutation acknowledgements are not snapshots; reconcile after every
    /// successful command so delayed or dropped events cannot leave stale
    /// desired/activity state or rows in the table.
    private func refreshAuthoritativeSnapshotAfterMutation() async {
        do {
            try await fetchFullSnapshot()
        } catch {
            // The mutation already succeeded. Do not misreport a subsequent
            // snapshot transport failure as pause/resume/remove failure.
            connectionNote = String(localized: "snapshot.failed")
        }
    }

    /// A completed removal is authoritative even if its event is delayed.
    private func applyRemovalResult(_ result: RemovalBatchResult) {
        lastRemovalResult = result
        if result.outcome == .completed {
            remove(result.recordID)
        }
    }

    private func clearRemovalError() {
        commandError = nil
        if connectionNote == String(localized: "remove.failed") {
            connectionNote = nil
        }
    }

    private func reconcileAlreadyRemoved(_ recordID: TorrentRecordID) async {
        // Remove locally first so the stale row disappears even if the
        // follow-up snapshot cannot be fetched.
        remove(recordID)
        clearRemovalError()
        await refreshAuthoritativeSnapshotAfterMutation()
        clearRemovalError()
    }

    private static func isRecordNotFound(_ error: Error) -> Bool {
        if let clientError = error as? EngineClientError,
           case .fault(let fault) = clientError {
            return fault.code == .recordNotFound
        }
        if let fault = error as? EngineFault {
            return fault.code == .recordNotFound
        }
        return false
    }


    private func applyReachableFault(_ error: EngineClientError) {
        usingFixture = false
        lifecyclePhase = .degraded
        torrents.removeAll()
        selection.removeAll()
        engineRevision = 0
        if case .fault(let fault) = error {
            lifecycleDegradedReason = fault.code.rawValue
            connectionNote = Self.localizedLifecycleReason(fault.code.rawValue)
        } else {
            connectionNote = String(localized: "engine.degraded.generic")
        }
    }

    private static func isTransportFailure(_ error: EngineClientError) -> Bool {
        switch error {
        case .unavailable, .interrupted, .peerValidationFailed:
            return true
        case .protocolMismatch, .fault:
            return false
        }
    }

    private static func localizedLifecycleReason(_ reason: String?) -> String {
        switch reason {
        case "persistenceUnavailable", "storeError":
            return String(localized: "engine.degraded.persistence_unavailable")
        case "restoreAnomaly", "internalError":
            return String(localized: "engine.degraded.restore_anomaly")
        case "crashLoopSafeMode":
            return String(localized: "engine.degraded.safe_recovery")
        case "observability":
            return String(localized: "engine.degraded.observability")
        default:
            return String(localized: "engine.degraded.generic")
        }
    }

    private func recoverFromFullSnapshot() async {
        guard !recoveryInFlight else { return }
        recoveryInFlight = true
        defer { recoveryInFlight = false }
        do {
            try await fetchFullSnapshot()
            connectionGeneration &+= 1
        } catch let error as EngineClientError {
            if Self.isTransportFailure(error) {
                usingFixture = true
                connectionNote = String(localized: "fixture.note")
                torrents = FixtureLibrary.snapshot(count: 100)
                engineRevision = UInt64(torrents.count)
                if selection.isEmpty { selection = torrents.first.map { [$0.id] } ?? [] }
            } else {
                applyReachableFault(error)
            }
        } catch {
            connectionNote = String(localized: "snapshot.failed")
        }
    }

    private func recoverAfterReconnect() async {
        // EngineClient has already restored the event subscription before this
        // callback. The snapshot is still required because the agent may have
        // restarted and its revision/instance are authoritative again.
        // An in-flight creator op died with the previous agent process; there
        // will be no matching operationCompleted, so fail the sheet closed.
        failActiveCreatorAfterAgentLoss()
        await recoverFromFullSnapshot()
        // A fresh engine session may hold unsettled removal batches (Gate 4/9).
        await refreshPendingRemovals()
    }

    /// Agent restart drops in-memory creator plans and progress publishers.
    /// Without a terminal event the sheet would stay on "Creating..." forever.
    private func failActiveCreatorAfterAgentLoss() {
        guard creatorTerminalOutcome == nil else { return }
        guard creatorOperationActive
            || awaitingCreatorOperationID
            || creatorOperationID != nil else { return }
        creatorOperationActive = false
        awaitingCreatorOperationID = false
        creatorCancelPending = false
        bufferedCreatorEvents.removeAll()
        creatorProgressStage = "Failed"
        creatorTerminalOutcome = .failed(
            EngineFault.creatorUnavailable(details: "agent restarted during creation")
        )
        creatorError = String(localized: "creator.fault.interrupted")
    }

    @discardableResult
    func addMagnet(_ uri: String, startPaused: Bool) async -> Bool {
        do {
            let inspection = try await inspect(source: .magnet(uri))
            try await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
            lastAddError = nil
            return true
        } catch EngineClientError.fault(let fault) {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch let fault as EngineFault {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch {
            lastAddError = String(localized: "add.failed")
            connectionNote = String(localized: "add.failed")
            return false
        }
    }

    @discardableResult
    func addTorrentFile(_ url: URL, startPaused: Bool) async -> Bool {
        do {
            let data = try await readTorrentData(from: url)
            let inspection = try await inspect(source: .torrentFileData(data))
            try await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
            lastAddError = nil
            return true
        } catch EngineClientError.fault(let fault) {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch let fault as EngineFault {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch {
            lastAddError = String(localized: "add.failed")
            connectionNote = String(localized: "add.failed")
            return false
        }
    }

    @discardableResult
    func addTorrentFileURL(_ urlString: String, startPaused: Bool) async -> Bool {
        do {
            let inspection = try await inspect(source: .torrentFileURL(urlString))
            try await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
            lastAddError = nil
            return true
        } catch EngineClientError.fault(let fault) {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch let fault as EngineFault {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch {
            lastAddError = String(localized: "add.failed")
            connectionNote = String(localized: "add.failed")
            return false
        }
    }

    /// Performs the same agent inspection used by commit, then builds a local
    /// file preview from the inspected source bytes for the Add sheet.
    func inspectTorrentFile(_ url: URL) async -> LatestInspectionState<AddTorrentPreview>.Result {
        do {
            let data = try await readTorrentData(from: url)
            let inspection = try await inspect(source: .torrentFileData(data))
            let metainfo = try await Task.detached(priority: .userInitiated) {
                try MetainfoParser.parse(data)
            }.value
            let files = metainfo.files.map { file in
                FileEntry(
                    relativePath: file.path,
                    name: file.path.split(separator: "/").last.map(String.init) ?? file.path,
                    sizeBytes: file.sizeBytes,
                    kind: .file,
                    selection: .normal
                )
            }
            return .success(AddTorrentPreview(inspection: inspection, files: files))
        } catch EngineClientError.fault(let fault) {
            let message = localizedFaultDescription(fault, fallback: "torrents.add.inspection_failed")
            return AddTorrentInspectionResultApplication.failure(message, preserving: &connectionNote)
        } catch let fault as EngineFault {
            let message = localizedFaultDescription(fault, fallback: "torrents.add.inspection_failed")
            return AddTorrentInspectionResultApplication.failure(message, preserving: &connectionNote)
        } catch {
            let message = String(localized: "torrents.add.inspection_failed")
            return AddTorrentInspectionResultApplication.failure(message, preserving: &connectionNote)
        }
    }

    @discardableResult
    func commitInspectedTorrent(
        _ preview: AddTorrentPreview,
        saveLocation: PersistedLocation?,
        fileSelection: [FileSelectionItem],
        startPaused: Bool
    ) async -> Bool {
        do {
            try await commitAdd(
                operationID: preview.inspection.operationID,
                saveLocation: saveLocation,
                fileSelection: fileSelection,
                startPaused: startPaused
            )
            lastAddError = nil
            return true
        } catch EngineClientError.fault(let fault) {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch let fault as EngineFault {
            lastAddError = localizedFaultDescription(fault)
            connectionNote = lastAddError
            return false
        } catch {
            lastAddError = String(localized: "add.failed")
            connectionNote = lastAddError
            return false
        }
    }

    private func readTorrentData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            return try Data(contentsOf: url)
        }.value
    }

    private func localizedFaultDescription(_ fault: EngineFault, fallback: String = "add.failed") -> String {
        switch fault.code {
        case .insufficientSpace:
            return String(localized: "error.insufficient_space")
        case .duplicateAdd:
            return String(localized: "error.duplicate_add", defaultValue: "This torrent has already been added")
        case .permissionDenied:
            return String(localized: "error.permission_denied")
        case .volumeUnavailable:
            return String(localized: "error.volume_unavailable")
        case .networkUnavailable:
            return String(localized: "error.network_unavailable")
        default:
            return String(localized: String.LocalizationValue(fallback))
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

    private func commitAdd(
        operationID: AddOperationID,
        saveLocation: PersistedLocation? = nil,
        fileSelection: [FileSelectionItem] = [],
        startPaused: Bool
    ) async throws {
        let command = EngineCommandV1.commitAdd(
            CommitAddRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                operationID: operationID,
                desiredName: nil,
                saveLocation: saveLocation,
                fileSelection: fileSelection,
                startPaused: startPaused
            )
        )
        guard case .commitAdd(let result) = try await client.sendCommand(command) else {
            throw EngineClientError.protocolMismatch(details: "unexpected commitAdd reply")
        }
        selection = [result.recordID]
        do {
            try await fetchFullSnapshot()
            selection = [result.recordID]
        } catch {
            connectionNote = String(localized: "snapshot.failed")
        }
    }

    func pause(_ recordID: TorrentRecordID) async {
        let command = EngineCommandV1.pause(PauseRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        do {
            _ = try await client.sendCommand(command)
            await refreshAuthoritativeSnapshotAfterMutation()
            commandError = nil
        } catch {
            if Self.isRecordNotFound(error) {
                // A stale row cannot be paused; reconcile it as already gone
                // instead of leaving a ghost with a red command error.
                await reconcileAlreadyRemoved(recordID)
            } else {
                surfaceCommandError(error, fallback: "pause.failed")
            }
        }
    }

    func resume(_ recordID: TorrentRecordID) async {
        let command = EngineCommandV1.resume(ResumeRequest(requestID: RequestID(), idempotencyKey: IdempotencyKey(), recordID: recordID))
        do {
            _ = try await client.sendCommand(command)
            await refreshAuthoritativeSnapshotAfterMutation()
            commandError = nil
        } catch {
            if Self.isRecordNotFound(error) {
                // A stale row cannot be resumed; reconcile it as already gone
                // instead of leaving a ghost with a red command error.
                await reconcileAlreadyRemoved(recordID)
            } else {
                surfaceCommandError(error, fallback: "resume.failed")
            }
        }
    }

    var canPauseSelected: Bool {
        canPause(selection)
    }

    var canResumeSelected: Bool {
        canResume(selection)
    }

    func canPause(_ ids: Set<TorrentRecordID>) -> Bool {
        torrents.contains { ids.contains($0.id) && $0.desiredState == .running }
    }

    func canResume(_ ids: Set<TorrentRecordID>) -> Bool {
        torrents.contains { ids.contains($0.id) && $0.desiredState == .paused }
    }

    func pauseSelected() {
        pauseIDs(selection)
    }

    func resumeSelected() {
        resumeIDs(selection)
    }

    func pauseIDs(_ ids: Set<TorrentRecordID>) {
        let targets = torrents.filter { ids.contains($0.id) && $0.desiredState == .running }.map(\.id)
        Task {
            for id in targets {
                await pause(id)
            }
        }
    }

    func resumeIDs(_ ids: Set<TorrentRecordID>) {
        let targets = torrents.filter { ids.contains($0.id) && $0.desiredState == .paused }.map(\.id)
        Task {
            for id in targets {
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
                    applyRemovalResult(result)
                    await refreshAuthoritativeSnapshotAfterMutation()
                    clearRemovalError()
                } catch {
                    if Self.isRecordNotFound(error) {
                        // The record may have been removed by a prior successful
                        // attempt while this UI still held its old row.
                        await reconcileAlreadyRemoved(recordID)
                    } else {
                        commandError = nil
                        connectionNote = String(localized: "remove.failed")
                    }
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
                applyRemovalResult(result)
                await refreshAuthoritativeSnapshotAfterMutation()
                clearRemovalError()
                await refreshPendingRemovals()
            } catch {
                if Self.isRecordNotFound(error) {
                    await reconcileAlreadyRemoved(summary.recordID)
                    await refreshPendingRemovals()
                } else {
                    commandError = nil
                    connectionNote = String(localized: "remove.failed")
                }
            }
        }
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func revealSelected() {
        guard let torrent = selectedTorrent else { return }
        revealTorrentFolder(torrent)
    }

    /// WP-13: opens the torrent content in Finder on row activation.
    /// Multi-file torrents reveal their content folder; a single-file torrent
    /// reveals/selects the file itself; anything missing falls back to the
    /// closest existing ancestor and, failing everything, surfaces a
    /// non-destructive localized status note instead of failing silently.
    func revealTorrentFolder(_ torrent: TorrentSnapshot) {
        let base = URL(fileURLWithPath: torrent.saveLocation.path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        // Directory layout: <saveLocation>/<torrent name>/ (classic multi-file
        // bundles that keep their root folder).
        let namedFolder = base.appendingPathComponent(torrent.displayName)
        if fileManager.fileExists(atPath: namedFolder.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: namedFolder.path)
            return
        }

        // Flat layout: files live directly under saveLocation (single-file
        // torrent named after the torrent itself, or flattened multi-file).
        let candidateFile = base.appendingPathComponent(torrent.displayName)
        if fileManager.fileExists(atPath: candidateFile.path) {
            // Single-file torrent contents (or the folder when namedFolder was
            // not found in directory form): reveal/select the item.
            NSWorkspace.shared.activateFileViewerSelecting([candidateFile])
            return
        }

        if fileManager.fileExists(atPath: base.path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: base.path)
            return
        }

        // Nothing on disk yet (pre-allocation disabled, removed payload, or an
        // unmounted volume): show the nearest recoverable location and surface
        // a status note rather than silently doing nothing.
        NSWorkspace.shared.activateFileViewerSelecting([base])
        connectionNote = String(localized: "reveal.missingPath")
    }

    /// WP-13: opens a single file from the files pane with the default macOS
    /// application (e.g. .mkv in the default video player). Called only from
    /// explicit row activation (double-click) — plain selection and checkbox
    /// toggles never reach this path. When the local file is not on disk yet
    /// (skipped, unstarted, or payload removed), it never fails silently: the
    /// torrent is revealed in Finder as a fallback and a localized status note
    /// explains what happened.
    func openSelectedFile(_ entry: FileEntry) {
        guard let torrent = selectedTorrent else { return }
        guard entry.kind == .file else { return }
        let base = URL(fileURLWithPath: torrent.saveLocation.path)
        let fileManager = FileManager.default

        let directURL = base.appendingPathComponent(entry.relativePath)
        if fileManager.fileExists(atPath: directURL.path) {
            NSWorkspace.shared.open(directURL)
            return
        }

        // Classic multi-file layout: files live under the torrent root folder.
        let nestedURL = base.appendingPathComponent(torrent.displayName).appendingPathComponent(entry.relativePath)
        if fileManager.fileExists(atPath: nestedURL.path) {
            NSWorkspace.shared.open(nestedURL)
            return
        }

        revealTorrentFolder(torrent)
        connectionNote = String(localized: "openfile.unavailable")
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

    func setLimits(_ recordID: TorrentRecordID, limits: TorrentinoIPC.TransferLimits) async {
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
        scheduleFilesLoad(for: recordID)
    }

    /// Table-selection hook: mirrors `select(_:)` without forcing single
    /// selection. Fires on any selection change so the files pane tracks the
    /// currently highlighted torrent (multi-select shows no file list).
    func selectionDidChange() {
        let recordID = selection.count == 1 ? selection.first : nil
        files = []
        fileCursor = nil
        directoryStack = []
        scheduleFilesLoad(for: recordID)
    }

    func enterDirectory(_ name: String) {
        directoryStack.append(name)
        scheduleFilesLoad(for: selection.first)
    }

    func goUpDirectory() {
        guard !directoryStack.isEmpty else { return }
        directoryStack.removeLast()
        scheduleFilesLoad(for: selection.first)
    }

    func loadFiles(for recordID: TorrentRecordID?, pageSize: Int = 200) async {
        let requestID = UUID()
        filesLoadRequestID = requestID
        await loadFiles(for: recordID, pageSize: pageSize, requestID: requestID)
    }

    private func scheduleFilesLoad(for recordID: TorrentRecordID?) {
        let requestID = UUID()
        filesLoadRequestID = requestID
        guard let recordID else {
            filesLoading = false
            return
        }
        Task { await loadFiles(for: recordID, requestID: requestID) }
    }

    private func loadFiles(
        for recordID: TorrentRecordID?,
        pageSize: Int = 200,
        requestID: UUID
    ) async {
        guard let recordID,
              let torrent = torrents.first(where: { $0.id == recordID }),
              selection.count == 1,
              selection.first == recordID else {
            if filesLoadRequestID == requestID {
                filesLoading = false
            }
            return
        }
        let requestedDirectoryStack = directoryStack
        filesLoading = true
        defer {
            if filesLoadRequestID == requestID {
                filesLoading = false
            }
        }
        let cursor = FileCursor(directoryStack: directoryStack, token: fileCursor)
        let command = EngineCommandV1.fetchFiles(
            FetchFilesRequest(requestID: RequestID(), recordID: recordID, cursor: cursor, pageSize: pageSize, expectedRevision: torrent.revision)
        )
        do {
            guard case .files(let page) = try await client.sendCommand(command) else { return }
            guard filesLoadRequestID == requestID,
                  selection.count == 1,
                  selection.first == recordID,
                  directoryStack == requestedDirectoryStack else { return }
            files = page.items
            fileCursor = page.nextCursor
            fileRevision = page.revision
        } catch {
            guard filesLoadRequestID == requestID else { return }
            connectionNote = String(localized: "files.failed")
        }
    }

    func setSelection(_ relativePath: String, priority: FileSelectionPriority) async {
        guard let recordID = selection.first,
              let torrent = torrents.first(where: { $0.id == recordID }) else { return }
        if let idx = files.firstIndex(where: { $0.relativePath == relativePath }) {
            let old = files[idx]
            files[idx] = FileEntry(
                relativePath: old.relativePath,
                name: old.name,
                sizeBytes: old.sizeBytes,
                kind: old.kind,
                selection: priority
            )
        }
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

    func selectAllFiles() async {
        await setBulkSelection(priority: .normal)
    }

    func deselectAllFiles() async {
        await setBulkSelection(priority: .skip)
    }

    private func setBulkSelection(priority: FileSelectionPriority) async {
        guard let recordID = selection.first,
              let torrent = torrents.first(where: { $0.id == recordID }) else { return }
        let items = files.compactMap { entry -> FileSelectionItem? in
            guard entry.kind == .file else { return nil }
            return FileSelectionItem(relativePath: entry.relativePath, priority: priority)
        }
        guard !items.isEmpty else { return }

        files = files.map { entry in
            guard entry.kind == .file else { return entry }
            return FileEntry(
                relativePath: entry.relativePath,
                name: entry.name,
                sizeBytes: entry.sizeBytes,
                kind: entry.kind,
                selection: priority
            )
        }

        let command = EngineCommandV1.setFileSelection(
            SetFileSelectionRequest(
                requestID: RequestID(),
                idempotencyKey: IdempotencyKey(),
                recordID: recordID,
                selection: items,
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
