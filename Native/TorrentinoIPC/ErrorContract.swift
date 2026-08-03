// Layer: IPC (error contract, plan §7.6).
// Role: the stable wire error taxonomy for every failed command result.
// Must-not: surface raw libtorrent/C++/SQLite text to the UI; technical detail
// stays in redactedContext and is only shown inside diagnostics.
// Invariants: EngineErrorCode raw values are frozen; EngineFault is Codable +
// Sendable + immutable; every fault carries a localization key and safe
// recovery actions.

import Foundation

/// Stable machine-readable error codes (frozen raw values — never renumber).
public enum EngineErrorCode: String, Codable, Sendable, Equatable, CaseIterable {
    // Transport / handshake
    case protocolVersionMismatch
    case xpcUnavailable
    case agentDenied
    case peerRejected

    // Envelope shape
    case invalidPayload
    case invalidArgument
    case oversizedPayload
    case unknownCommand
    case invalidRequest
    case idempotencyConflict

    // Records / operations
    case recordNotFound
    case duplicateAdd
    case operationNotFound
    case unsupportedOperation

    // Settings
    case settingsRevisionConflict
    case settingsValidationFailed

    // Environment
    case permissionDenied
    case insufficientSpace
    case volumeUnavailable
    case networkUnavailable
    case proxyConnectionFailed
    case incomingPortClosed

    // Engine / timing
    case engineNotReady
    case engineBusy
    case rateLimited
    case operationTimeout
    case operationCancelled
    case storeError
    case internalError
    case resourceConstrained
    case systemSleeping
    case crashLoopSafeMode
    case resourceLimitExceeded
    case engineUnresponsive
}

/// How bad a fault is; drives UI presentation priority.
public enum FaultSeverity: String, Codable, Sendable, Equatable, CaseIterable {
    case info
    case warning
    case error
    case fatal
}

/// A complete engine fault per plan §7.6: stable code, severity, affected
/// record, localization key, safe recovery actions, redacted context.
public struct EngineFault: Codable, Sendable, Equatable, Error, LocalizedError {
    public let code: EngineErrorCode
    public let severity: FaultSeverity
    public let affectedRecord: TorrentRecordID?
    /// Stable volume identity when a storage fault is localized to a volume.
    /// The path itself is never put on the wire.
    public let affectedVolume: String?
    /// String Catalog key (e.g. "fault.record_not_found"). Never the raw error text.
    public let localizationKey: String
    /// Safe user-facing recovery actions (not raw instructions from C++).
    public let recoveryActions: [String]
    /// Technical detail for diagnostics only — never rendered verbatim.
    public let redactedContext: String?

    public init(
        code: EngineErrorCode,
        severity: FaultSeverity,
        affectedRecord: TorrentRecordID? = nil,
        affectedVolume: String? = nil,
        localizationKey: String? = nil,
        recoveryActions: [String] = [],
        redactedContext: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.affectedRecord = affectedRecord
        self.affectedVolume = affectedVolume
        self.localizationKey = localizationKey ?? "fault.\(code.rawValue)"
        self.recoveryActions = recoveryActions
        self.redactedContext = redactedContext
    }

    public var errorDescription: String? {
        localizationKey
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case severity
        case affectedRecord
        case affectedVolume
        case localizationKey
        case recoveryActions
        case redactedContext
    }

    /// `affectedVolume` was added after the first v1 payloads. Decode it
    /// optionally so a reconnect can still understand an older fault.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try container.decode(EngineErrorCode.self, forKey: .code)
        self.severity = try container.decode(FaultSeverity.self, forKey: .severity)
        self.affectedRecord = try container.decodeIfPresent(TorrentRecordID.self, forKey: .affectedRecord)
        self.affectedVolume = try container.decodeIfPresent(String.self, forKey: .affectedVolume)
        self.localizationKey = try container.decode(String.self, forKey: .localizationKey)
        self.recoveryActions = try container.decode([String].self, forKey: .recoveryActions)
        self.redactedContext = try container.decodeIfPresent(String.self, forKey: .redactedContext)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(affectedRecord, forKey: .affectedRecord)
        try container.encodeIfPresent(affectedVolume, forKey: .affectedVolume)
        try container.encode(localizationKey, forKey: .localizationKey)
        try container.encode(recoveryActions, forKey: .recoveryActions)
        try container.encodeIfPresent(redactedContext, forKey: .redactedContext)
    }

    // MARK: - Factories (stable constructors for the common contract faults)

    public static func protocolVersionMismatch(clientMajor: Int, serverMajor: Int) -> EngineFault {
        EngineFault(
            code: .protocolVersionMismatch,
            severity: .fatal,
            recoveryActions: ["reinstall_app", "check_updates"],
            redactedContext: "clientMajor=\(clientMajor) serverMajor=\(serverMajor)"
        )
    }

    public static func oversizedPayload(limitBytes: Int) -> EngineFault {
        EngineFault(
            code: .oversizedPayload,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: "limitBytes=\(limitBytes)"
        )
    }

    public static func invalidPayload(details: String) -> EngineFault {
        EngineFault(
            code: .invalidPayload,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func invalidArgument(details: String, recordID: TorrentRecordID? = nil) -> EngineFault {
        EngineFault(
            code: .invalidArgument,
            severity: .error,
            affectedRecord: recordID,
            recoveryActions: ["edit_limits"],
            redactedContext: details
        )
    }

    public static func unknownCommand(name: String) -> EngineFault {
        EngineFault(
            code: .unknownCommand,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: "command=\(name)"
        )
    }

    public static func invalidRequest(details: String) -> EngineFault {
        EngineFault(
            code: .invalidRequest,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func idempotencyConflict(details: String) -> EngineFault {
        EngineFault(
            code: .idempotencyConflict,
            severity: .warning,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func settingsRevisionConflict(current: SettingsRevision, expected: SettingsRevision) -> EngineFault {
        EngineFault(
            code: .settingsRevisionConflict,
            severity: .warning,
            recoveryActions: ["refetch_settings", "retry_op"],
            redactedContext: "current=\(current) expected=\(expected)"
        )
    }

    public static func settingsValidationFailed(errors: [SettingsValidationError]) -> EngineFault {
        EngineFault(
            code: .settingsValidationFailed,
            severity: .warning,
            recoveryActions: ["edit_settings"],
            redactedContext: errors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
        )
    }

    public static func recordNotFound(recordID: TorrentRecordID) -> EngineFault {
        EngineFault(
            code: .recordNotFound,
            severity: .error,
            affectedRecord: recordID,
            recoveryActions: ["refetch_snapshot"]
        )
    }

    public static func duplicateAdd(identity: ContentIdentity?) -> EngineFault {
        EngineFault(
            code: .duplicateAdd,
            severity: .warning,
            recoveryActions: ["select_existing_torrent"],
            redactedContext: identity?.description
        )
    }

    public static func internalError(details: String) -> EngineFault {
        EngineFault(
            code: .internalError,
            severity: .fatal,
            recoveryActions: ["restart_engine", "export_diagnostics"],
            redactedContext: details
        )
    }

    public static func operationTimeout(details: String) -> EngineFault {
        EngineFault(
            code: .operationTimeout,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func networkUnavailable(details: String) -> EngineFault {
        EngineFault(
            code: .networkUnavailable,
            severity: .warning,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func permissionDenied(
        recordID: TorrentRecordID? = nil,
        volumeIdentifier: String? = nil,
        details: String? = nil
    ) -> EngineFault {
        EngineFault(
            code: .permissionDenied,
            severity: .error,
            affectedRecord: recordID,
            affectedVolume: volumeIdentifier,
            recoveryActions: ["check_permissions", "choose_storage"],
            redactedContext: details ?? "storage_permissions"
        )
    }

    public static func insufficientSpace(
        recordID: TorrentRecordID? = nil,
        volumeIdentifier: String? = nil,
        availableBytes: Int64? = nil
    ) -> EngineFault {
        EngineFault(
            code: .insufficientSpace,
            severity: .error,
            affectedRecord: recordID,
            affectedVolume: volumeIdentifier,
            recoveryActions: ["free_disk_space", "choose_storage"],
            redactedContext: availableBytes.map { "availableBytes=\($0)" } ?? "disk_full"
        )
    }

    public static func volumeUnavailable(
        recordID: TorrentRecordID? = nil,
        volumeIdentifier: String? = nil,
        details: String? = nil
    ) -> EngineFault {
        EngineFault(
            code: .volumeUnavailable,
            severity: .warning,
            affectedRecord: recordID,
            affectedVolume: volumeIdentifier,
            recoveryActions: ["attach_volume", "choose_storage"],
            redactedContext: details ?? "volume_unavailable"
        )
    }

    public static func resourceConstrained(details: String) -> EngineFault {
        EngineFault(
            code: .resourceConstrained,
            severity: .warning,
            recoveryActions: ["wait_for_resources"],
            redactedContext: details
        )
    }

    public static func systemSleeping() -> EngineFault {
        EngineFault(
            code: .systemSleeping,
            severity: .info,
            recoveryActions: ["wait_for_wake"],
            redactedContext: "system_sleep"
        )
    }

    public static func crashLoopSafeMode() -> EngineFault {
        EngineFault(
            code: .crashLoopSafeMode,
            severity: .error,
            recoveryActions: ["review_diagnostics", "restart_engine_safely"],
            redactedContext: "safe_recovery_after_repeated_start_failures"
        )
    }

    public static func resourceLimitExceeded(resource: String, limit: Int) -> EngineFault {
        EngineFault(
            code: .resourceLimitExceeded,
            severity: .warning,
            recoveryActions: ["wait_for_resources"],
            redactedContext: "resource=\(resource) limit=\(limit)"
        )
    }

    public static func engineUnresponsive(details: String) -> EngineFault {
        EngineFault(
            code: .engineUnresponsive,
            severity: .error,
            recoveryActions: ["export_diagnostics", "restart_engine_safely"],
            redactedContext: details
        )
    }

    /// Maps storage text from a lower layer to a stable, non-sensitive fault.
    /// Raw bridge/SQLite text stays in logs and is never returned to the UI.
    public static func storageFailure(
        details: String,
        recordID: TorrentRecordID? = nil,
        volumeIdentifier: String? = nil
    ) -> EngineFault {
        let text = details.lowercased()
        if text.contains("no space") || text.contains("disk full") || text.contains("enospc") {
            return .insufficientSpace(recordID: recordID, volumeIdentifier: volumeIdentifier)
        }
        if text.contains("permission") || text.contains("access denied") || text.contains("read-only") || text.contains("eacces") {
            return .permissionDenied(recordID: recordID, volumeIdentifier: volumeIdentifier)
        }
        return EngineFault(
            code: .storeError,
            severity: .error,
            affectedRecord: recordID,
            affectedVolume: volumeIdentifier,
            recoveryActions: ["retry_op", "export_diagnostics"],
            redactedContext: "storage_failure"
        )
    }

    public static func engineNotReady(details: String) -> EngineFault {
        EngineFault(
            code: .engineNotReady,
            severity: .warning,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func engineBusy(details: String) -> EngineFault {
        EngineFault(
            code: .engineBusy,
            severity: .warning,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func rateLimited(recordID: TorrentRecordID, retryAfter: TimeInterval) -> EngineFault {
        EngineFault(
            code: .rateLimited,
            severity: .warning,
            affectedRecord: recordID,
            recoveryActions: ["retry_op"],
            redactedContext: "retryAfterSeconds=\(Int(ceil(retryAfter)))"
        )
    }

    public static func operationNotFound(details: String) -> EngineFault {
        EngineFault(
            code: .operationNotFound,
            severity: .error,
            recoveryActions: ["retry_op"],
            redactedContext: details
        )
    }

    public static func unsupportedOperation(
        operation: String,
        recordID: TorrentRecordID? = nil,
        details: String? = nil
    ) -> EngineFault {
        EngineFault(
            code: .unsupportedOperation,
            severity: .error,
            affectedRecord: recordID,
            recoveryActions: [],
            redactedContext: details ?? "operation=\(operation)"
        )
    }
}
