// Layer: IPC (handshake, plan §7.4 hello + §10 version policy).
// Role: protocol range negotiation between UI and agent on connect. The two
// sides agree on one IPCVersion; a major mismatch is an EngineFault
// (protocolVersionMismatch) before any other command is served.
// Must-not: perform I/O; the negotiated version is a pure function of the two
// advertised ranges.
// Invariants: negotiated version must lie inside BOTH ranges; the server
// picks the most conservative (smallest) overlapping version.

import Foundation

/// UI → agent handshake request. hello is an EngineCommandV1 case, so it
/// carries a requestID like every other command (plan §7.4).
public struct HelloRequest: Codable, Sendable, Equatable {
    public let requestID: RequestID
    public let clientVersion: String
    public let supportedProtocolRange: ClosedRange<IPCVersion>

    public init(requestID: RequestID, clientVersion: String, supportedProtocolRange: ClosedRange<IPCVersion>) {
        self.requestID = requestID
        self.clientVersion = clientVersion
        self.supportedProtocolRange = supportedProtocolRange
    }
}

/// Agent → UI handshake response. instanceID changes on every agent restart;
/// the UI must discard all cached state and fetch a full snapshot when it
/// differs from the one it saw before.
public struct HelloResponse: Codable, Sendable, Equatable {
    public let agentVersion: String
    public let negotiatedProtocol: IPCVersion
    public let instanceID: UUID
    public let engineRevision: UInt64

    public init(agentVersion: String, negotiatedProtocol: IPCVersion, instanceID: UUID, engineRevision: UInt64) {
        self.agentVersion = agentVersion
        self.negotiatedProtocol = negotiatedProtocol
        self.instanceID = instanceID
        self.engineRevision = engineRevision
    }
}

public enum HandshakeResult: Sendable, Equatable {
    /// Both ranges overlap; the agreed protocol version.
    case negotiated(IPCVersion)
    /// The ranges do not overlap — the connection cannot serve this client.
    case mismatch
}

/// Pure negotiation + validation logic (plan §7.4, §10).
public enum Handshake {
    /// Protocol range this (UI) build supports. Frozen to 1.0 in v1.
    public static let clientSupportedRange: ClosedRange<IPCVersion> =
        IPCVersion.current...IPCVersion.current

    /// Protocol range the agent supports. Frozen to 1.0 in v1.
    public static let serverSupportedRange: ClosedRange<IPCVersion> =
        IPCVersion.current...IPCVersion.current

    /// The client always builds its request from this range.
    public static func makeRequest(clientVersion: String, requestID: RequestID = RequestID()) -> HelloRequest {
        HelloRequest(requestID: requestID, clientVersion: clientVersion, supportedProtocolRange: clientSupportedRange)
    }

    /// A single-version range (for an agent that only advertises one version).
    public static func singleVersionRange(_ version: IPCVersion) -> ClosedRange<IPCVersion> {
        version...version
    }

    /// Negotiates one protocol version. Server picks the most conservative
    /// (smallest) overlapping version; empty overlap ⇒ mismatch.
    public static func negotiate(
        clientRange: ClosedRange<IPCVersion>,
        serverRange: ClosedRange<IPCVersion>
    ) -> HandshakeResult {
        let floor = max(clientRange.lowerBound, serverRange.lowerBound)
        let ceiling = min(clientRange.upperBound, serverRange.upperBound)
        guard ceiling >= floor else { return .mismatch }
        return .negotiated(floor)
    }

    /// Validates a response against the client's own range and major version.
    /// Returns .protocolVersionMismatch when the peer lied or negotiated an
    /// unusable version.
    public static func validateResponse(
        _ response: HelloResponse,
        clientRange: ClosedRange<IPCVersion>
    ) -> Result<HelloResponse, EngineFault> {
        guard clientRange.contains(response.negotiatedProtocol) else {
            return .failure(EngineFault.protocolVersionMismatch(
                clientMajor: clientRange.lowerBound.major,
                serverMajor: response.negotiatedProtocol.major
            ))
        }
        return .success(response)
    }
}

extension IPCVersion {
    /// Parses "major.minor" (the agent's advertised protocol string).
    public init?(parsing string: String) {
        let parts = string.split(separator: ".", maxSplits: 2)
        guard parts.count == 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else {
            return nil
        }
        self.init(major: major, minor: minor)
    }
}
