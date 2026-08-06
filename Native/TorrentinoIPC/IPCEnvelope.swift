// Layer: IPC (versioned envelope v1, plan §7.4).
// Role: the discriminated-union wire wrapper for every UI ↔ agent message:
// request (command + requestID), event push, and result (SuccessPayload or
// EngineFault + requestID correlation).
// Must-not: carry non-Sendable payloads or mutable shared state.
// Invariants: immutable; versioned; kind-specific shape enforced at decode
// time (a request envelope missing its command fails to decode); payloads are
// bounded by IPCPayloadLimit.maxBytes.

import Foundation

/// Bound on a single serialized envelope (plan §7.4 "Max payload size").
/// 4 MiB keeps every read page well inside XPC comfortable limits while
/// leaving headroom for large inspection payloads.
public enum IPCPayloadLimit {
    public static let maxBytes = 4 * 1024 * 1024

    /// Rejects payloads that could never be served. Pure size check — cheap
    /// and side-effect free.
    public static func validate(_ data: Data) -> Bool {
        data.count <= maxBytes
    }
}

/// Success payloads, one case per command family (plan §7.4 result types).
/// Void/acknowledgement commands share the single `.ack` case.
public enum SuccessPayload: Codable, Sendable, Equatable {
    case hello(HelloResponse)
    case snapshot(EngineSnapshot)
    case files(Page<FileEntry>)
    case peers(Page<PeerEntry>)
    case trackers(Page<TrackerEntry>)
    case activity(Page<ActivityEntry>)
    case removalManifestPage(Page<RemovalManifestEntry>)
    case creatorManifestPage(Page<CreatorManifestEntry>)
    case addSourceInspection(AddSourceInspection)
    case commitAdd(CommitAddResult)
    case settingsFetch(SettingsFetchResult)
    case settingsValidation(SettingsValidationResult)
    case settingsApply(SettingsApplyResult)
    case proxyTest(ProxyTestResult)
    case incomingPortTest(IncomingPortTestResult)
    case removalToken(RemovalToken)
    /// WP-10 commitRemoval batch outcome (per-record, partial success visible).
    case removalResult(RemovalBatchResult)
    /// WP-10 fetchPendingRemovals: unsettled removal batches for guided recovery.
    case pendingRemovals([PendingRemovalSummary])
    case createSourceInspection(CreateSourceInspection)
    /// The agent returns this before creator work starts; the caller never
    /// supplies or derives the accepted OperationID.
    case creatorOperationAccepted(CreateOperationAccepted)
    case diagnosticsExport(DiagnosticsExportResult)
    case ack
}

/// The result half of the contract: success payload or EngineFault.
public enum EngineCommandResult: Codable, Sendable, Equatable {
    case success(SuccessPayload)
    case failure(EngineFault)
}

/// Structural validation failures of an IPCEnvelope. Each maps to a stable
/// EngineFault for the wire.
public enum EnvelopeValidationError: Sendable, Equatable, CustomStringConvertible {
    case incompatibleVersion(IPCVersion)
    case missingRequestID
    case missingCommand
    case missingEvent
    case missingResult
    case requestIDMismatch
    case unexpectedPayload

    public var description: String {
        switch self {
        case .incompatibleVersion(let version): return "incompatible version \(version)"
        case .missingRequestID: return "missing requestID"
        case .missingCommand: return "missing command"
        case .missingEvent: return "missing event"
        case .missingResult: return "missing result"
        case .requestIDMismatch: return "envelope requestID != command requestID"
        case .unexpectedPayload: return "payload present for wrong envelope kind"
        }
    }

    /// Wire representation: an invalidPayload fault (or the version fault).
    public var fault: EngineFault {
        switch self {
        case .incompatibleVersion(let version):
            return EngineFault(
                code: .protocolVersionMismatch,
                severity: .fatal,
                recoveryActions: ["reinstall_app", "check_updates"],
                redactedContext: "wireVersion=\(version) current=\(IPCVersion.current)"
            )
        default:
            return EngineFault.invalidPayload(details: description)
        }
    }
}

/// Versioned discriminated-union envelope (plan §7.4).
public struct IPCEnvelope: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case request
        case event
        case result
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case kind
        case requestID
        case command
        case event
        case result
    }

    public let version: IPCVersion
    public let kind: Kind
    /// Present for request + result envelopes (correlation), nil for events.
    public let requestID: RequestID?
    /// Present iff kind == .request.
    public let command: EngineCommandV1?
    /// Present iff kind == .event.
    public let event: EngineEventV1?
    /// Present iff kind == .result.
    public let result: EngineCommandResult?

    public init(
        version: IPCVersion,
        kind: Kind,
        requestID: RequestID?,
        command: EngineCommandV1?,
        event: EngineEventV1?,
        result: EngineCommandResult?
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.command = command
        self.event = event
        self.result = result
    }

    /// Builds a request envelope; the payload's requestID is authoritative.
    public static func request(_ command: EngineCommandV1, version: IPCVersion = .current) -> IPCEnvelope {
        IPCEnvelope(version: version, kind: .request, requestID: command.requestID, command: command, event: nil, result: nil)
    }

    /// Builds an event push.
    public static func event(_ event: EngineEventV1, version: IPCVersion = .current) -> IPCEnvelope {
        IPCEnvelope(version: version, kind: .event, requestID: nil, command: nil, event: event, result: nil)
    }

    /// Builds a reply correlated with the request it answers.
    public static func result(requestID: RequestID, result: EngineCommandResult, version: IPCVersion = .current) -> IPCEnvelope {
        IPCEnvelope(version: version, kind: .result, requestID: requestID, command: nil, event: nil, result: result)
    }

    /// True when the envelope major version matches the local current major.
    public var isCompatibleWithCurrent: Bool {
        version.major == IPCVersion.current.major
    }

    /// Structural consistency check. A valid envelope has exactly the payload
    /// its kind requires, a matching requestID, and a compatible version.
    public func validate() -> EnvelopeValidationError? {
        guard isCompatibleWithCurrent else { return .incompatibleVersion(version) }
        switch kind {
        case .request:
            guard let requestID else { return .missingRequestID }
            guard let command else { return .missingCommand }
            guard requestID == command.requestID else { return .requestIDMismatch }
            if event != nil || result != nil { return .unexpectedPayload }
        case .event:
            guard event != nil else { return .missingEvent }
            if command != nil || result != nil || requestID != nil { return .unexpectedPayload }
        case .result:
            guard requestID != nil else { return .missingRequestID }
            guard result != nil else { return .missingResult }
            if command != nil || event != nil { return .unexpectedPayload }
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(IPCVersion.self, forKey: .version)
        let kind = try container.decode(Kind.self, forKey: .kind)
        self.version = version
        self.kind = kind
        switch kind {
        case .request:
            self.requestID = try container.decodeIfPresent(RequestID.self, forKey: .requestID)
            self.command = try container.decodeIfPresent(EngineCommandV1.self, forKey: .command)
            self.event = nil
            self.result = nil
        case .event:
            self.requestID = nil
            self.command = nil
            self.event = try container.decodeIfPresent(EngineEventV1.self, forKey: .event)
            self.result = nil
        case .result:
            self.requestID = try container.decodeIfPresent(RequestID.self, forKey: .requestID)
            self.command = nil
            self.event = nil
            self.result = try container.decodeIfPresent(EngineCommandResult.self, forKey: .result)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(kind, forKey: .kind)
        switch kind {
        case .request:
            try container.encode(requestID, forKey: .requestID)
            try container.encode(command, forKey: .command)
        case .event:
            try container.encode(event, forKey: .event)
        case .result:
            try container.encode(requestID, forKey: .requestID)
            try container.encode(result, forKey: .result)
        }
    }
}
