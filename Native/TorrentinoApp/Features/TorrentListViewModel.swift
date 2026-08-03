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
import TorrentinoIPC

@MainActor
final class TorrentListViewModel: ObservableObject {
    @Published private(set) var torrents: [TorrentSnapshot] = []
    @Published private(set) var engineRevision: UInt64 = 0
    @Published private(set) var instanceID: UUID?
    @Published private(set) var usingFixture = false
    @Published private(set) var connectionNote: String?
    /// Table row selection; single-selection UI keeps at most one element.
    @Published var selection: Set<TorrentRecordID> = []
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var filesLoading = false
    @Published private(set) var fileRevision: UInt64 = 0
    @Published var showAddSheet = false
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
        } catch {
            usingFixture = true
            connectionNote = "fixture.note"
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
                connectionNote = "subscribe.failed"
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
            case .torrentAdded(let payload):
                upsert(payload.snapshot)
                engineRevision = max(engineRevision, payload.engineRevision)
            case .torrentRemoved(let payload):
                remove(payload.recordID)
                engineRevision = max(engineRevision, payload.engineRevision)
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
    }

    func addMagnet(_ uri: String, startPaused: Bool) async {
        do {
            let inspection = try await inspect(source: .magnet(uri))
            await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
        } catch {
            connectionNote = "add.failed"
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
            connectionNote = "add.failed"
        }
    }

    func addTorrentFileURL(_ urlString: String, startPaused: Bool) async {
        do {
            let inspection = try await inspect(source: .torrentFileURL(urlString))
            await commitAdd(operationID: inspection.operationID, startPaused: startPaused)
        } catch {
            connectionNote = "add.failed"
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
            connectionNote = "add.failed"
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
            connectionNote = "files.failed"
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
        _ = try? await client.sendCommand(command)
    }
}

/// Aggregate numbers for the status bar (UI-side projection of the snapshot).
struct TorrentStatusBarModel: Equatable {
    let downloadBytesPerSec: Int64
    let uploadBytesPerSec: Int64
    let downloading: Int
    let seeding: Int
    let paused: Int
    let total: Int
}

/// Deterministic 100-row demo snapshot used only when the agent is
/// unreachable. Names are invented and generic; rows carry varied states so
/// identity/scroll/focus behavior can be exercised.
enum FixtureLibrary {
    static func snapshot(count: Int = 100) -> [TorrentSnapshot] {
        (1...count).map { index in
            let cycle = index % 8
            let activity: TorrentActivity
            let desired: DesiredTorrentState
            let fraction: Double
            switch cycle {
            case 0: activity = .downloading; desired = .running; fraction = 0.05 + 0.9 * Double(index) / Double(count)
            case 1: activity = .seeding; desired = .running; fraction = 1.0
            case 2: activity = .checking; desired = .running; fraction = 0.5
            case 3: activity = .idle; desired = .paused; fraction = Double(index % 90) / 100.0
            case 4: activity = .downloading; desired = .running; fraction = Double(index % 70) / 100.0
            case 5: activity = .fetchingMetadata; desired = .running; fraction = 0.0
            case 6: activity = .queued; desired = .running; fraction = 0.0
            default: activity = .seeding; desired = .running; fraction = 1.0
            }
            let totalBytes = Int64(1_500_000_000 + index * 37_000_000)
            let downloaded = Int64(Double(totalBytes) * fraction)
            let recordID = TorrentRecordID(rawValue: UUID())
            let name = String(format: "Demo Archive %03d — %@", index, Self.suffixes[index % Self.suffixes.count])
            return TorrentSnapshot(
                id: recordID,
                contentIdentity: ContentIdentity(infoHashV1: Data([UInt8(index & 0xFF)]), infoHashV2: nil),
                displayName: name,
                desiredState: desired,
                activity: activity,
                health: .healthy,
                progress: TransferProgress(
                    fraction: fraction,
                    totalBytes: totalBytes,
                    downloadedBytes: downloaded,
                    uploadedBytes: activity == .seeding ? downloaded / 2 : downloaded / 10
                ),
                rates: TransferRates(
                    downloadBytesPerSec: activity == .downloading ? Int64(400_000 + index * 7_000) : 0,
                    uploadBytesPerSec: activity == .seeding ? Int64(120_000 + index * 3_000) : 0
                ),
                peers: PeerSummary(
                    connected: activity == .downloading || activity == .seeding ? 4 + index % 40 : 0,
                    halfOpen: activity == .downloading ? index % 12 : 0,
                    total: activity == .downloading || activity == .seeding ? 20 + index % 200 : 0
                ),
                saveLocation: PersistedLocation(path: "/Users/Shared/Demo"),
                revision: UInt64(index)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static let suffixes = [
        "Source", "Assets", "Backup", "Pack", "Bundle", "Collection",
        "Dataset", "Release", "Build", "Episode",
    ]
}
