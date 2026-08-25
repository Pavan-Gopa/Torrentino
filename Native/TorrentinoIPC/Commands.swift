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
public struct PollAddOperationRequest: EngineCommandPayload {
    public let requestID: RequestID
    public let operationID: AddOperationID

    public init(requestID: RequestID, operationID: AddOperationID) {
        self.requestID = requestID
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
    /// SEC-1 credential delivery (WP13-SEC-HARDEN-001): the proxy password
    /// rides THIS envelope field only — the durable `candidate` stays
    /// credential-free and the agent persists marker-only rows. Optional and
    /// decode-tolerant in both directions: payloads written before this field
    /// existed decode with `nil`, and a `nil` value is omitted from the wire,
    /// so old peers interoperate unchanged.
    public let proxyPassword: String?

    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        candidate: EngineSettings,
        expectedRevision: SettingsRevision? = nil,
        proxyPassword: String? = nil
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.candidate = candidate
        self.expectedRevision = expectedRevision
        self.proxyPassword = proxyPassword
    }

    /// The single delivery rule every UI apply path must use: the credential
    /// held app-side (Keychain-backed form state seeded by
    /// `KeychainStore.loadProxyPassword()`) crosses IPC exactly here. An
    /// anonymously authenticating proxy kind or an empty value delivers nil.
    public static func proxyPasswordForDelivery(
        kind: ProxyConfiguration.Kind,
        entered: String
    ) -> String? {
        guard kind != .none, !entered.isEmpty else { return nil }
        return entered
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
    /// Complete asserted topology for structured edits. When present, the
    /// agent preserves every tier boundary, URL position, and repetition.
    /// A missing value is retained only so older payloads can be decoded and
    /// rejected; it is never reconstructed from the legacy delta fields.
    public let trackerTiers: [[String]]?

    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        recordID: TorrentRecordID,
        addedURLs: [String],
        removedURLs: [String],
        trackerTiers: [[String]]? = nil
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.recordID = recordID
        self.addedURLs = addedURLs
        self.removedURLs = removedURLs
        self.trackerTiers = trackerTiers
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case idempotencyKey
        case recordID
        case addedURLs
        case removedURLs
        case trackerTiers = "tracker-tiers"
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

/// WP-10 (Gate 4/9): read-only enumeration of removal tokens whose outcome was
/// never durably settled. The UI polls this after connecting to offer guided
/// recovery of half-trashed batches from a previous session.
public struct FetchPendingRemovalsRequest: EngineCommandPayload {
    public let requestID: RequestID

    public init(requestID: RequestID) {
        self.requestID = requestID
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
    /// The complete immutable form snapshot asserted by the caller. The agent
    /// compares its canonical value with the snapshot bound to `token` before
    /// it scans, hashes, writes, or admits a seed.
    public let options: CreateOptions
    /// A wire-visible marker retained so a former encoded shape cannot be
    /// mistaken for an assertion. The agent rejects false before any creator
    /// work; complete callers must use the options initializer below.
    public let optionsWereAsserted: Bool
    /// Compatibility initializer for the former caller-proposed operation
    /// identity. The argument is deliberately not serialized or consulted;
    /// the agent mints the authoritative operation at commit admission.
    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        token: CreatorPlanToken,
        operationID: OperationID
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.token = token
        self.options = CreateOptions()
        self.optionsWereAsserted = false
    }

    /// Complete asserted snapshot. Operation identity is intentionally absent;
    /// requestID/idempotencyKey provide correlation while the agent owns the
    /// accepted OperationID.
    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        token: CreatorPlanToken,
        options: CreateOptions
    ) {
        self.requestID = requestID
        self.idempotencyKey = idempotencyKey
        self.token = token
        self.options = options
        self.optionsWereAsserted = true
    }

    /// Source-compatible overload for older in-process callers. The supplied
    /// value is ignored and never crosses the agent boundary as authority.
    public init(
        requestID: RequestID,
        idempotencyKey: IdempotencyKey,
        token: CreatorPlanToken,
        options: CreateOptions,
        operationID: OperationID
    ) {
        self.init(requestID: requestID, idempotencyKey: idempotencyKey, token: token, options: options)
    }
}

/// Accepted creator identity returned immediately after the agent registers
/// the operation. It is the only OperationID the UI may display or cancel.
public struct CreateOperationAccepted: Codable, Sendable, Equatable {
    public let operationID: OperationID

    public init(operationID: OperationID) {
        self.operationID = operationID
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
/// One file row inside an AddSourceInspection payload.
public struct InspectedFileEntry: Codable, Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let priority: FileSelectionPriority

    public init(path: String, sizeBytes: Int64, priority: FileSelectionPriority = .normal) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.priority = priority
    }
}

/// inspectAddSource outcome: an AddOperationID the UI must remember and hand
/// to commitAdd, plus everything the agent learned about the source.
public struct AddSourceInspection: Codable, Sendable, Equatable {
    public let operationID: AddOperationID
    public let contentIdentity: ContentIdentity?
    public let displayName: String?
    public let sizeBytes: Int64?
    public let warnings: [String]
    public let phase: AddInspectionPhase
    public let files: [InspectedFileEntry]?

    public init(
        operationID: AddOperationID,
        contentIdentity: ContentIdentity?,
        displayName: String?,
        sizeBytes: Int64?,
        warnings: [String],
        phase: AddInspectionPhase = .readyToCommit,
        files: [InspectedFileEntry]? = nil
    ) {
        self.operationID = operationID
        self.contentIdentity = contentIdentity
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.warnings = warnings
        self.phase = phase
        self.files = files
    }

    private enum CodingKeys: String, CodingKey {
        case operationID
        case contentIdentity
        case displayName
        case sizeBytes
        case warnings
        case phase
        case files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.operationID = try container.decode(AddOperationID.self, forKey: .operationID)
        self.contentIdentity = try container.decodeIfPresent(ContentIdentity.self, forKey: .contentIdentity)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes)
        self.warnings = try container.decode([String].self, forKey: .warnings)
        self.phase = try container.decodeIfPresent(AddInspectionPhase.self, forKey: .phase) ?? .readyToCommit
        self.files = try container.decodeIfPresent([InspectedFileEntry].self, forKey: .files)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(contentIdentity, forKey: .contentIdentity)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(sizeBytes, forKey: .sizeBytes)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(phase, forKey: .phase)
        try container.encode(files, forKey: .files)
    }
}

public struct PollAddOperationResult: Codable, Sendable, Equatable {
    public let phase: AddInspectionPhase
    public let inspection: AddSourceInspection?
    public let failure: EngineFault?

    public init(phase: AddInspectionPhase, inspection: AddSourceInspection? = nil, failure: EngineFault? = nil) {
        self.phase = phase
        self.inspection = inspection
        self.failure = failure
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

/// One failed item of a removal batch (WP-10 per-record batch result).
/// The code is a stable machine-readable classifier; the message is
/// diagnostic-only and never rendered verbatim by the UI.
public struct RemovalItemFailure: Codable, Sendable, Equatable {
    public let relativePath: String
    public let code: String
    public let message: String?

    public init(relativePath: String, code: String, message: String? = nil) {
        self.relativePath = relativePath
        self.code = code
        self.message = message
    }
}

/// Batch-level outcome of a commitRemoval (WP-10: partial success is visible,
/// never silently collapsed into success or failure).
public enum RemovalBatchOutcome: String, Codable, Sendable, Equatable, CaseIterable {
    /// Every manifest item was trashed (or skipped as shared) and the record
    /// was removed.
    case completed
    /// Some items were trashed, at least one failed; the record was kept and
    /// the token remains usable for guided recovery.
    case partial
    /// The removal could not start (e.g. token expired, engine refused);
    /// nothing was trashed by this attempt.
    case failed
}

/// The per-record batch result of commitRemoval (WP-10 ADR: per-record batch
/// result, partial success visible).
public struct RemovalBatchResult: Codable, Sendable, Equatable {
    public let recordID: TorrentRecordID
    public let token: RemovalToken
    public let outcome: RemovalBatchOutcome
    public let trashedItems: Int
    public let skippedSharedItems: Int
    public let failedItems: [RemovalItemFailure]

    public init(
        recordID: TorrentRecordID,
        token: RemovalToken,
        outcome: RemovalBatchOutcome,
        trashedItems: Int,
        skippedSharedItems: Int,
        failedItems: [RemovalItemFailure]
    ) {
        self.recordID = recordID
        self.token = token
        self.outcome = outcome
        self.trashedItems = trashedItems
        self.skippedSharedItems = skippedSharedItems
        self.failedItems = failedItems
    }
}

/// WP-10 (Gate 4/9): one pending (unsettled) removal batch, as enumerated by
/// fetchPendingRemovals. Derived from the durable token row and trash journal
/// so the UI can show evidence-based guided recovery after a restart.
public struct PendingRemovalSummary: Codable, Sendable, Equatable {
    public let token: RemovalToken
    public let recordID: TorrentRecordID
    public let displayName: String?
    public let deleteFiles: Bool
    public let totalItemCount: Int
    public let trashedItemCount: Int
    public let failedItemCount: Int

    public init(
        token: RemovalToken,
        recordID: TorrentRecordID,
        displayName: String?,
        deleteFiles: Bool,
        totalItemCount: Int,
        trashedItemCount: Int,
        failedItemCount: Int
    ) {
        self.token = token
        self.recordID = recordID
        self.displayName = displayName
        self.deleteFiles = deleteFiles
        self.totalItemCount = totalItemCount
        self.trashedItemCount = trashedItemCount
        self.failedItemCount = failedItemCount
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
public struct CreatorPlanToken: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum TorrentFormat: String, Codable, Sendable, Equatable, CaseIterable {
    case hybrid
    case v1
    case v2

    public var displayName: String {
        switch self {
        case .hybrid: return "Hybrid (v1 + v2)"
        case .v1: return "v1 (Legacy)"
        case .v2: return "v2 (Next-Gen)"
        }
    }
}

/// Create flow options (v1/v2/hybrid; WP-11). Tracker tier and URL order are
/// significant and are deliberately retained by the canonical snapshot.
public struct CreateOptions: Codable, Sendable, Equatable {
    public let outputPath: String?
    public let format: TorrentFormat
    public let trackers: [[String]]
    public let isPrivate: Bool
    public let pieceSizeKiB: Int64?
    public let comment: String?
    public let source: String?
    public let seedWhileDownloading: Bool
    public let includeHiddenFiles: Bool

    public init(
        outputPath: String? = nil,
        format: TorrentFormat = .hybrid,
        trackers: [[String]] = [],
        isPrivate: Bool = false,
        pieceSizeKiB: Int64? = nil,
        comment: String? = nil,
        source: String? = nil,
        seedWhileDownloading: Bool = true,
        includeHiddenFiles: Bool = true
    ) {
        self.outputPath = outputPath
        self.format = format
        self.trackers = trackers
        self.isPrivate = isPrivate
        self.pieceSizeKiB = pieceSizeKiB
        self.comment = comment
        self.source = source
        self.seedWhileDownloading = seedWhileDownloading
        self.includeHiddenFiles = includeHiddenFiles
    }

    public init(seedWhileDownloading: Bool, includeHiddenFiles: Bool, pieceSizeKiB: Int64? = nil) {
        self.init(
            outputPath: nil,
            format: .hybrid,
            trackers: [],
            isPrivate: false,
            pieceSizeKiB: pieceSizeKiB,
            comment: nil,
            source: nil,
            seedWhileDownloading: seedWhileDownloading,
            includeHiddenFiles: includeHiddenFiles
        )
    }

    /// Canonical structural snapshot used by the inspect -> commit contract.
/// Text and path presentation fields are canonicalized, while tracker URL
/// bytes, tier order, and URL order are retained exactly after validation.
    public var canonicalSnapshot: CreateOptions {
        CreateOptions(
            outputPath: outputPath.map { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? nil,
            format: format,
            trackers: trackers,
            isPrivate: isPrivate,
            pieceSizeKiB: pieceSizeKiB,
            comment: canonicalText(comment),
            source: canonicalText(source),
            seedWhileDownloading: seedWhileDownloading,
            includeHiddenFiles: includeHiddenFiles
        )
    }

    private func canonicalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CreateSummary: Codable, Sendable, Equatable {
    public let fileCount: Int
    public let totalBytes: Int64
    public let pieceSizeBytes: Int64
    public let willSeed: Bool
    public let skippedSymlinksCount: Int
    public let hardlinkCount: Int

    public init(
        fileCount: Int,
        totalBytes: Int64,
        pieceSizeBytes: Int64,
        willSeed: Bool,
        skippedSymlinksCount: Int = 0,
        hardlinkCount: Int = 0
    ) {
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.pieceSizeBytes = pieceSizeBytes
        self.willSeed = willSeed
        self.skippedSymlinksCount = skippedSymlinksCount
        self.hardlinkCount = hardlinkCount
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
    case pollAddOperation(PollAddOperationRequest)
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
    case fetchPendingRemovals(FetchPendingRemovalsRequest)
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
            .pollAddOperation(PollAddOperationRequest(requestID: rid, operationID: AddOperationID())),
            .pause(PauseRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .resume(ResumeRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .setFileSelection(SetFileSelectionRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, selection: fileSelection, expectedRevision: 0)),
            .setLimits(SetLimitsRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, limits: TransferLimits(maxDownloadBytesPerSec: nil, maxUploadBytesPerSec: nil))),
            .fetchSettings(FetchSettingsRequest(requestID: rid, expectedRevision: nil)),
            .validateSettings(ValidateSettingsRequest(requestID: rid, candidate: .default)),
            .applySettings(ApplySettingsRequest(requestID: rid, idempotencyKey: idempotency, candidate: .default, expectedRevision: nil, proxyPassword: nil)),
            .testProxy(TestProxyRequest(requestID: rid, proxy: ProxyConfiguration(kind: .none, host: "", port: 0), timeoutSeconds: 10)),
            .testIncomingPort(TestIncomingPortRequest(requestID: rid, port: 0)),
            .editTrackers(EditTrackersRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, addedURLs: [], removedURLs: [])),
            .reannounce(ReannounceRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .requestRecheck(RequestRecheckRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID)),
            .moveStorage(MoveStorageRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, destination: PersistedLocation(path: ""))),
            .prepareRemoval(PrepareRemovalRequest(requestID: rid, idempotencyKey: idempotency, recordID: recordID, deleteFiles: false)),
            .commitRemoval(CommitRemovalRequest(requestID: rid, idempotencyKey: idempotency, token: emptyRemoval)),
            .fetchPendingRemovals(FetchPendingRemovalsRequest(requestID: rid)),
            .cancelOperation(CancelOperationRequest(requestID: rid, idempotencyKey: idempotency, operationID: OperationID())),
            .inspectCreateSource(InspectCreateSourceRequest(requestID: rid, sourcePath: "")),
            .commitCreate(CommitCreateRequest(
                requestID: rid,
                idempotencyKey: idempotency,
                token: emptyPlan,
                options: CreateOptions()
            )),
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
        case .pollAddOperation: return "pollAddOperation"
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
        case .fetchPendingRemovals: return "fetchPendingRemovals"
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
        case .pollAddOperation(let p): return p.requestID
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
        case .fetchPendingRemovals(let p): return p.requestID
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
