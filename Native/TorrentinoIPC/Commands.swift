// Layer: IPC (command schema v1, plan §7.4).
// Role: the full UI → agent command surface. Every command carries its own
// immutable, Sendable payload with a requestID; mutating commands additionally
// carry an IdempotencyKey so a timeout-then-replay cannot apply twice.
// Must-not: perform I/O or hold state; success payloads live in
// SuccessPayload (Envelope.swift).
// Invariants: the case set is the frozen v1 contract; case names are the wire
// discriminators; every payload is Codable + Sendable + Equatable.

import Foundation

/// Payload protocol: every command carries its correlation ID.
public protocol EngineCommandPayload: Codable, Sendable, Equatable {
    var requestID: RequestID { get }
}

// MARK: - Fetch / read commands

public struct FetchSnapshotRequest: EngineCommandPayload {
    public let requestID: RequestID
    /// Only send the delta when the caller's revision is contiguous; nil = full.
    public let afterRevision: UInt64?

    public init(requestID: RequestID, afterRevision: UInt64?) {
        self.requestID = requestID
        self.afterRevision = afterRevision
    }
}

public struct FetchFilesRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let recordID: TorrentRecordID
    public let cursor: FileCursor?
    public let pageSize: Int
    public let expectedRevision: UInt64

    public init(requestID: RequestID, recordID: TorrentRecordID, cursor: FileCursor?, pageSize: Int, expectedRevision: UInt64) {
        self.requestID = requestID
        self.recordID = recordID
        self.cursor = cursor
        self.pageSize = pageSize
        self.expectedRevision = expectedRevision
    }
}

public struct FetchPeersRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let recordID: TorrentRecordID
    public let cursor: PageCursor?
    public let pageSize: Int
    /// Server-side peer list snapshot token (short TTL); keeps paging stable
    /// even though the torrent revision churns.
    public let peerSnapshotToken: String

    public init(requestID: RequestID, recordID: TorrentRecordID, cursor: PageCursor?, pageSize: Int, peerSnapshotToken: String) {
        self.requestID = requestID
        self.recordID = recordID
        self.cursor = cursor
        self.pageSize = pageSize
        self.peerSnapshotToken = peerSnapshotToken
    }
}

public struct FetchTrackersRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let recordID: TorrentRecordID
    public let cursor: PageCursor?
    public let pageSize: Int
    public let expectedRevision: UInt64

    public init(requestID: RequestID, recordID: TorrentRecordID, cursor: PageCursor?, pageSize: Int, expectedRevision: UInt64) {
        self.requestID = requestID
        self.recordID = recordID
        self.cursor = cursor
        self.pageSize = pageSize
        self.expectedRevision = expectedRevision
    }
}

public struct FetchActivityRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let recordID: TorrentRecordID
    public let cursor: PageCursor?
    public let pageSize: Int
    public let expectedRevision: UInt64

    public init(requestID: RequestID, recordID: TorrentRecordID, cursor: PageCursor?, pageSize: Int, expectedRevision: UInt64) {
        self.requestID = requestID
        self.recordID = recordID
        self.cursor = cursor
        self.pageSize = pageSize
        self.expectedRevision = expectedRevision
    }
}

public struct FetchRemovalManifestPageRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let token: RemovalToken
    public let cursor: PageCursor?
    public let pageSize: Int

    public init(requestID: RequestID, token: RemovalToken, cursor: PageCursor?, pageSize: Int) {
        self.requestID = requestID
        self.token = token
        self.cursor = cursor
        self.pageSize = pageSize
    }
}

public struct FetchCreatorManifestPageRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let token: CreatorPlanToken
    public let cursor: PageCursor?
    public let pageSize: Int

    public init(requestID: RequestID, token: CreatorPlanToken, cursor: PageCursor?, pageSize: Int) {
        self.requestID = requestID
        self.token = token
        self.cursor = cursor
        self.pageSize = pageSize
    }
}

// MARK: - Add flow

public struct InspectAddSourceRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let source: AddSource
    public let desiredName: String?

    public init(requestID: RequestID, source: AddSource, desiredName: String? = nil) {
        self.requestID = requestID
        self.source = source
        self.desiredName = desiredName
    }
}

public struct CommitAddRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let operationID: AddOperationID
    public let desiredName: String?
    public let saveLocation: PersistedLocation?
    public let fileSelection: [FileSelectionItem]
    /// nil = default (start running); true = add paused (metadata fetch +
    /// queued, no download). Additive optional key (WP-07 AddOptions).
    public let startPaused: Bool?

    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        operationID: AddOperationID,
        desiredName: String? = nil,
        saveLocation: PersistedLocation? = nil,
        fileSelection: [FileSelectionItem] = [],
        startPaused: Bool? = nil
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.operationID = operationID
        self.desiredName = desiredName
        self.saveLocation = saveLocation
        self.fileSelection = fileSelection
        self.startPaused = startPaused
    }
}

public struct CancelAddRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let operationID: AddOperationID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, operationID: AddOperationID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.operationID = operationID
    }
}

// MARK: - Torrent control

public struct PauseRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
    }
}

public struct ResumeRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
    }
}

public struct SetFileSelectionRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID
    public let selection: [FileSelectionItem]
    public let expectedRevision: UInt64

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID, selection: [FileSelectionItem], expectedRevision: UInt64) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.selection = selection
        self.expectedRevision = expectedRevision
    }
}

public struct SetLimitsRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID
    public let limits: TransferLimits

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID, limits: TransferLimits) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.limits = limits
    }
}

// MARK: - Settings

public struct FetchSettingsRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let expectedRevision: SettingsRevision?

    public init(requestID: RequestID, expectedRevision: SettingsRevision? = nil) {
        self.requestID = requestID
        self.expectedRevision = expectedRevision
    }
}

public struct ValidateSettingsRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let candidate: EngineSettings

    public init(requestID: RequestID, candidate: EngineSettings) {
        self.requestID = requestID
        self.candidate = candidate
    }
}

public struct ApplySettingsRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let candidate: EngineSettings
    public let expectedRevision: SettingsRevision?

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, candidate: EngineSettings, expectedRevision: SettingsRevision? = nil) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.candidate = candidate
        self.expectedRevision = expectedRevision
    }
}

// MARK: - Network / environment tests

public struct TestProxyRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let proxy: ProxyConfiguration
    public let timeoutSeconds: TimeInterval

    public init(requestID: RequestID, proxy: ProxyConfiguration, timeoutSeconds: TimeInterval) {
        self.requestID = requestID
        self.proxy = proxy
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct TestIncomingPortRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let port: UInt16

    public init(requestID: RequestID, port: UInt16) {
        self.requestID = requestID
        self.port = port
    }
}

// MARK: - Trackers

public struct EditTrackersRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID
    public let addedURLs: [String]
    public let removedURLs: [String]

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID, addedURLs: [String], removedURLs: [String]) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.addedURLs = addedURLs
        self.removedURLs = removedURLs
    }
}

public struct ReannounceRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
    }
}

public struct RequestRecheckRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
    }
}

// MARK: - Storage / removal

public struct MoveStorageRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID
    public let destination: PersistedLocation

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID, destination: PersistedLocation) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.destination = destination
    }
}

public struct PrepareRemovalRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let recordID: TorrentRecordID
    public let deleteFiles: Bool

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, recordID: TorrentRecordID, deleteFiles: Bool) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.deleteFiles = deleteFiles
    }
}

public struct CommitRemovalRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let token: RemovalToken

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, token: RemovalToken) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.token = token
    }
}

public struct CancelOperationRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let operationID: OperationID

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, operationID: OperationID) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.operationID = operationID
    }
}

// MARK: - Create flow

public struct InspectCreateSourceRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let sourcePath: String
    public let options: CreateOptions?

    public init(requestID: RequestID, sourcePath: String, options: CreateOptions? = nil) {
        self.requestID = requestID
        self.sourcePath = sourcePath
        self.options = options
    }
}

public struct CommitCreateRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey
    public let token: CreatorPlanToken

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey, token: CreatorPlanToken) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.token = token
    }
}

// MARK: - Lifecycle / diagnostics

public struct PrepareForQuitRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let reason: String?

    public init(requestID: RequestID, reason: String? = nil) {
        self.requestID = requestID
        self.reason = reason
    }
}

public struct RestartEngineSafelyRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let idempotencyKey: IdempotencyKey

    public init(requestID: RequestID, idempotencyKey: IdempotencyKey) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
    }
}

public struct ExportDiagnosticsRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let reason: String
    public let destinationURL: String?

    public init(requestID: RequestID, reason: String, destinationURL: String? = nil) {
        self.requestID = requestID
        self.reason = reason
        self.destinationURL = destinationURL
    }
}

// MARK: - Command result payloads (success side)

/// inspectAddSource outcome: an AddOperationID the UI must remember and hand
/// to commitAdd, plus everything the agent learned about the source.
public struct AddSourceInspection: Codable, Sendable, Equatable {
    public let operationID: AddOperationID
    public let contentIdentity: ContentIdentity?
    public let displayName: String?
    public let sizeBytes: Int64?
    public let warnings: [String]

    public init(operationID: AddOperationID, contentIdentity: ContentIdentity?, displayName: String?, sizeBytes: Int64?, warnings: [String]) {
        self.operationID = operationID
        self.contentIdentity = contentIdentity
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.warnings = warnings
    }
}

/// commitAdd outcome: the agent-minted record identity and the engine
/// revision it landed on. Replaying commitAdd with the same idempotency key
/// returns the same recordID.
public struct CommitAddResult: Codable, Sendable, Equatable {
    public let recordID: TorrentRecordID
    public let engineRevision: UInt64

    public init(recordID: TorrentRecordID, engineRevision: UInt64) {
        self.recordID = recordID
        self.engineRevision = engineRevision
    }
}

public struct SettingsFetchResult: Codable, Sendable, Equatable {
    public let settings: EngineSettings
    public let revision: SettingsRevision

    public init(settings: EngineSettings, revision: SettingsRevision) {
        self.settings = settings
        self.revision = revision
    }
}

public struct SettingsValidationResult: Codable, Sendable, Equatable {
    public let valid: Bool
    public let errors: [SettingsValidationError]

    public init(valid: Bool, errors: [SettingsValidationError]) {
        self.valid = valid
        self.errors = errors
    }
}

public struct SettingsApplyResult: Codable, Sendable, Equatable {
    public let revision: SettingsRevision

    public init(revision: SettingsRevision) {
        self.revision = revision
    }
}

public struct ProxyTestResult: Codable, Sendable, Equatable {
    public let succeeded: Bool
    public let latencyMilliseconds: Int64?
    public let message: String?

    public init(succeeded: Bool, latencyMilliseconds: Int64?, message: String?) {
        self.succeeded = succeeded
        self.latencyMilliseconds = latencyMilliseconds
        self.message = message
    }
}

public struct IncomingPortTestResult: Codable, Sendable, Equatable {
    public let reachable: Bool
    public let localAddresses: [String]
    public let message: String?

    public init(reachable: Bool, localAddresses: [String], message: String?) {
        self.reachable = reachable
        self.localAddresses = localAddresses
        self.message = message
    }
}

/// Opaque one-shot token for the two-phase removal (plan ADR-010).
public struct RemovalToken: Codable, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Opaque one-shot token for the two-phase create flow (plan §7.4).
public struct CreatorPlanToken: Codable, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// Create flow options (v1).
public struct CreateOptions: Codable, Sendable, Equatable {
    public let seedWhileDownloading: Bool
    public let includeHiddenFiles: Bool
    public let pieceSizeKiB: Int64?

    public init(seedWhileDownloading: Bool, includeHiddenFiles: Bool, pieceSizeKiB: Int64? = nil) {
        self.seedWhileDownloading = seedWhileDownloading
        self.includeHiddenFiles = includeHiddenFiles
        self.pieceSizeKiB = pieceSizeKiB
    }
}

public struct CreateSummary: Codable, Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let pieceSizeBytes: Int64
    public let willSeed: Bool

    public init(fileCount: Int, totalBytes: Int64, pieceSizeBytes: Int64, willSeed: Bool) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.pieceSizeBytes = pieceSizeBytes
        self.willSeed = willSeed
    }
}

public struct CreateSourceInspection: Codable, Sendable, Equatable {
    public let token: CreatorPlanToken
    public let summary: CreateSummary
    public let warnings: [String]
    public let sourceIdentity: ContentIdentity?
    public let exclusions: [String]

    public init(token: CreatorPlanToken, summary: CreateSummary, warnings: [String], sourceIdentity: ContentIdentity?, exclusions: [String]) {
        self.token = token
        self.summary = summary
        self.warnings = warnings
        self.sourceIdentity = sourceIdentity
        self.exclusions = exclusions
    }
}

public struct DiagnosticsExportResult: Codable, Sendable, Equatable {
    public let archiveURL: String
    public let entryCount: Int

    public init(archiveURL: String, entryCount: Int) {
        self.archiveURL = archiveURL
        self.entryCount = entryCount
    }
}

// MARK: - Command enum (frozen v1 surface, plan §7.4)

/// The complete v1 command surface. Case names are the wire discriminators;
/// the case set must NOT change within major version 1.
public enum EngineCommandV1: Codable, Sendable, Equatable {
    case hello(HelloRequest)
    case fetchSnapshot(FetchSnapshotRequest)
    case fetchFiles(FetchFilesRequest)
    case fetchPeers(FetchPeersRequest)
    case fetchTrackers(FetchTrackersRequest)
    case fetchActivity(FetchActivityRequest)
    case fetchRemovalManifestPage(FetchRemovalManifestPageRequest)
    case fetchCreatorManifestPage(FetchCreatorManifestPageRequest)
    case inspectAddSource(InspectAddSourceRequest)
    case commitAdd(CommitAddRequest)
    case cancelAdd(CancelAddRequest)
    case pause(PauseRequest)
    case resume(ResumeRequest)
    case setFileSelection(SetFileSelectionRequest)
    case setLimits(SetLimitsRequest)
    case fetchSettings(FetchSettingsRequest)
    case validateSettings(ValidateSettingsRequest)
    case applySettings(ApplySettingsRequest)
    case testProxy(TestProxyRequest)
    case testIncomingPort(TestIncomingPortRequest)
    case editTrackers(EditTrackersRequest)
    case reannounce(ReannounceRequest)
    case requestRecheck(RequestRecheckRequest)
    case moveStorage(MoveStorageRequest)
    case prepareRemoval(PrepareRemovalRequest)
    case commitRemoval(CommitRemovalRequest)
    case cancelOperation(CancelOperationRequest)
    case inspectCreateSource(InspectCreateSourceRequest)
    case commitCreate(CommitCreateRequest)
    case prepareForQuit(PrepareForQuitRequest)
    case restartEngineSafely(RestartEngineSafelyRequest)
    case exportDiagnostics(ExportDiagnosticsRequest)

    /// Every v1 command, once, with minimal payloads. Used for schema
    /// enumeration and diagnostics; never for executing work.
    public static let allCases: [EngineCommandV1] = {
        let rid = RequestID()
        let recordID = TorrentRecordID(rawValue: UUID())
        let idempotency = IdempotencyKey()
        let fileSelection: [FileSelectionItem] = []
        let emptyRemoval = RemovalToken(rawValue: "")
        let emptyPlan = CreatorPlanToken(rawValue: "")
        return [
            .hello(HelloRequest(requestID: rid, clientVersion: "dev", supportedProtocolRange: Handshake.clientSupportedRange)),
            .fetchSnapshot(FetchSnapshotRequest(requestID: rid, afterRevision: 0)),
            .fetchFiles(FetchFilesRequest(requestID: rid, recordID: recordID, cursor: nil, pageSize: 100, expectedRevision: 0)),
            .fetchPeers(FetchPeersRequest(requestID: rid, recordID: recordID, cursor: nil, pageSize: 100, peerSnapshotToken: "")),
            .fetchTrackers(FetchTrackersRequest(requestID: rid, recordID: recordID, cursor: nil, pageSize: 100, expectedRevision: 0)),
            .fetchActivity(FetchActivityRequest(requestID: rid, recordID: recordID, cursor: nil, pageSize: 100, expectedRevision: 0)),
            .fetchRemovalManifestPage(FetchRemovalManifestPageRequest(requestID: rid, token: emptyRemoval, cursor: nil, pageSize: 100)),
            .fetchCreatorManifestPage(FetchCreatorManifestPageRequest(requestID: rid, token: emptyPlan, cursor: nil, pageSize: 100)),
            .inspectAddSource(InspectAddSourceRequest(requestID: rid, source: .magnet(""))),
            .commitAdd(CommitAddRequest(requestID: rid, idempotencyKey: idempotency, operationID: AddOperationID())),
            .cancelAdd(CancelAddRequest(requestID: rid, idempotencyKey: idempotency, operationID: AddOperationID())),
            .pause(PauseRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .resume(ResumeRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .setFileSelection(SetFileSelectionRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, selection: fileSelection, expectedRevision: 0)),
            .setLimits(SetLimitsRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, limits: TransferLimits(maxDownloadBytesPerSec: nil, maxUploadBytesPerSec: nil))),
            .fetchSettings(FetchSettingsRequest(requestID: rid, expectedRevision: nil)),
            .validateSettings(ValidateSettingsRequest(requestID: rid, candidate: .default)),
            .applySettings(ApplySettingsRequest(requestID: rid, idempotencyKey: idempotency, candidate: .default, expectedRevision: nil)),
            .testProxy(TestProxyRequest(requestID: rid, proxy: ProxyConfiguration(kind: .none, host: "", port: 0), timeoutSeconds: 10)),
            .testIncomingPort(TestIncomingPortRequest(requestID: rid, port: 0)),
            .editTrackers(EditTrackersRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, addedURLs: [], removedURLs: [])),
            .reannounce(ReannounceRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .requestRecheck(RequestRecheckRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .moveStorage(MoveStorageRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, destination: PersistedLocation(path: ""))),
            .prepareRemoval(PrepareRemovalRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, deleteFiles: false)),
            .commitRemoval(CommitRemovalRequest(requestID: rid, idempotencyKey: idempotency, token: emptyRemoval)),
            .cancelOperation(CancelOperationRequest(requestID: rid, idempotencyKey: idempotency, operationID: OperationID())),
            .inspectCreateSource(InspectCreateSourceRequest(requestID: rid, sourcePath: "")),
            .commitCreate(CommitCreateRequest(requestID: rid, idempotencyKey: idempotency, token: emptyPlan)),
            .prepareForQuit(PrepareForQuitRequest(requestID: rid, reason: nil)),
            .restartEngineSafely(RestartEngineSafelyRequest(requestID: rid, idempotencyKey: idempotency)),
            .exportDiagnostics(ExportDiagnosticsRequest(requestID: rid, reason: "")),
        ]
    }()
}

extension EngineCommandV1 {
    /// Stable wire discriminator for this command.
    public var name: String {
        switch self {
        case .hello: return "hello"
        case .fetchSnapshot: return "fetchSnapshot"
        case .fetchFiles: return "fetchFiles"
        case .fetchPeers: return "fetchPeers"
        case .fetchTrackers: return "fetchTrackers"
        case .fetchActivity: return "fetchActivity"
        case .fetchRemovalManifestPage: return "fetchRemovalManifestPage"
        case .fetchCreatorManifestPage: return "fetchCreatorManifestPage"
        case .inspectAddSource: return "inspectAddSource"
        case .commitAdd: return "commitAdd"
        case .cancelAdd: return "cancelAdd"
        case .pause: return "pause"
        case .resume: return "resume"
        case .setFileSelection: return "setFileSelection"
        case .setLimits: return "setLimits"
        case .fetchSettings: return "fetchSettings"
        case .validateSettings: return "validateSettings"
        case .applySettings: return "applySettings"
        case .testProxy: return "testProxy"
        case .testIncomingPort: return "testIncomingPort"
        case .editTrackers: return "editTrackers"
        case .reannounce: return "reannounce"
        case .requestRecheck: return "requestRecheck"
        case .moveStorage: return "moveStorage"
        case .prepareRemoval: return "prepareRemoval"
        case .commitRemoval: return "commitRemoval"
        case .cancelOperation: return "cancelOperation"
        case .inspectCreateSource: return "inspectCreateSource"
        case .commitCreate: return "commitCreate"
        case .prepareForQuit: return "prepareForQuit"
        case .restartEngineSafely: return "restartEngineSafely"
        case .exportDiagnostics: return "exportDiagnostics"
        }
    }

    /// The correlation ID every payload carries (envelope consistency check).
    public var requestID: RequestID {
        switch self {
        case .hello(let p): return p.requestID
        case .fetchSnapshot(let p): return p.requestID
        case .fetchFiles(let p): return p.requestID
        case .fetchPeers(let p): return p.requestID
        case .fetchTrackers(let p): return p.requestID
        case .fetchActivity(let p): return p.requestID
        case .fetchRemovalManifestPage(let p): return p.requestID
        case .fetchCreatorManifestPage(let p): return p.requestID
        case .inspectAddSource(let p): return p.requestID
        case .commitAdd(let p): return p.requestID
        case .cancelAdd(let p): return p.requestID
        case .pause(let p): return p.requestID
        case .resume(let p): return p.requestID
        case .setFileSelection(let p): return p.requestID
        case .setLimits(let p): return p.requestID
        case .fetchSettings(let p): return p.requestID
        case .validateSettings(let p): return p.requestID
        case .applySettings(let p): return p.requestID
        case .testProxy(let p): return p.requestID
        case .testIncomingPort(let p): return p.requestID
        case .editTrackers(let p): return p.requestID
        case .reannounce(let p): return p.requestID
        case .requestRecheck(let p): return p.requestID
        case .moveStorage(let p): return p.requestID
        case .prepareRemoval(let p): return p.requestID
        case .commitRemoval(let p): return p.requestID
        case .cancelOperation(let p): return p.requestID
        case .inspectCreateSource(let p): return p.requestID
        case .commitCreate(let p): return p.requestID
        case .prepareForQuit(let p): return p.requestID
        case .restartEngineSafely(let p): return p.requestID
        case .exportDiagnostics(let p): return p.requestID
        }
    }

    /// The dedup key mutating commands carry (nil for pure reads).
    public var idempotencyKey: IdempotencyKey? {
        switch self {
        case .commitAdd(let p): return p.idempotencyKey
        case .cancelAdd(let p): return p.idempotencyKey
        case .pause(let p): return p.idempotencyKey
        case .resume(let p): return p.idempotencyKey
        case .setFileSelection(let p): return p.idempotencyKey
        case .setLimits(let p): return p.idempotencyKey
        case .applySettings(let p): return p.idempotencyKey
        case .editTrackers(let p): return p.idempotencyKey
        case .reannounce(let p): return p.idempotencyKey
        case .requestRecheck(let p): return p.idempotencyKey
        case .moveStorage(let p): return p.idempotencyKey
        case .prepareRemoval(let p): return p.idempotencyKey
        case .commitRemoval(let p): return p.idempotencyKey
        case .cancelOperation(let p): return p.idempotencyKey
        case .commitCreate(let p): return p.idempotencyKey
        case .restartEngineSafely(let p): return p.idempotencyKey
        default: return nil
        }
    }

    /// True for commands that mutate durable engine state.
    public var isMutating: Bool {
        idempotencyKey != nil
    }
}
