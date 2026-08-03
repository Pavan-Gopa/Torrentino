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
    @Published var showInspector = false
    @Published var searchText = ""
    @Published var searchFocusRequest = 0
    @Published private(set) var busy = false

    let client: EngineClient
    private(set) var directoryStack: [String] = []
    private var fileCursor: PageCursor?
    private var eventHandler: (@Sendable ([EngineEventV1]) -> Void)?

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
            _ = try await client.hello()
            subscribe()
            try await fetchFullSnapshot()
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
    func subscribe() {
        eventHandler = { [weak self] events in
            Task { @MainActor [weak self] in
                self?.apply(events)
            }
        }
        guard let eventHandler else { return }
        Task {
            do {
                try await client.subscribeEvents(handler: eventHandler)
            } catch {
                connectionNote = String(localized: "subscribe.failed")
            }
        }
    }

    func refresh() {
        Task {
            try? await fetchFullSnapshot()
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
                    Task { try? await fetchFullSnapshot() }
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
                Task { try? await fetchFullSnapshot() }
            case .inspectionInvalidated(let payload):
                if selection.contains(payload.recordID),
                   payload.scope == .files || payload.scope == .all {
                    Task { await loadFiles(for: payload.recordID) }
                }
            case .engineHealthChanged, .engineLifecycleChanged, .operationProgress,
                 .operationCompleted, .recoverableIssue, .settingsChanged:
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
                    _ = try await client.sendCommand(commit)
                } catch {
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
            case .engineBusy, .engineNotReady, .operationTimeout:
                return String(localized: "error.engine_operation")
            default: break
            }
        }
        return String(localized: String.LocalizationValue(fallback))
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
