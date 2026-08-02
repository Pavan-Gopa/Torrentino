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
    case operationTimeout
    case operationCancelled
    case storeError
    case internalError
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
        localizationKey: String? = nil,
        recoveryActions: [String] = [],
        redactedContext: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.affectedRecord = affectedRecord
        self.localizationKey = localizationKey ?? "fault.\(code.rawValue)"
        self.recoveryActions = recoveryActions
        self.redactedContext = redactedContext
    }

    public var errorDescription: String? {
        localizationKey
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
}
