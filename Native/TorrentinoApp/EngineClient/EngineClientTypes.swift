// Layer: UI-side IPC DTOs.
// Role: immutable value types mirroring agent replies + client error taxonomy.
// Must-not: hold references to XPC objects or mutate after creation.
// Invariants: Sendable + value semantics; safe to publish on the main actor.

import Foundation
import TorrentinoDomain

struct AgentHello: Sendable, Equatable {
    let agentVersion: String
    let pid: Int64
}

struct AgentHealth: Sendable, Equatable {
    let agentVersion: String
    let pid: Int64
    let uptimeSeconds: Double
    let counter: Int64
    let counterFormat: String
    let machService: String

    /// Parses the plist dictionary returned by health(reply:). Nil on any
    /// missing/mistyped key => protocol mismatch, surfaced as an error.
    init?(dictionary: [String: Any]) {
        guard let agentVersion = dictionary["agentVersion"] as? String,
              let pid = (dictionary["pid"] as? NSNumber)?.int64Value,
              let uptimeSeconds = (dictionary["uptimeSeconds"] as? NSNumber)?.doubleValue,
              let counter = (dictionary["counter"] as? NSNumber)?.int64Value,
              let counterFormat = dictionary["counterFormat"] as? String,
              let machService = dictionary["machService"] as? String
        else { return nil }
        self.agentVersion = agentVersion
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.counter = counter
        self.counterFormat = counterFormat
        self.machService = machService
    }

    var summary: String {
        String(format: "version=%@ pid=%d uptime=%.1fs counter=%d format=%@",
               agentVersion, pid, uptimeSeconds, counter, counterFormat)
    }
}

enum EngineClientError: Error, CustomStringConvertible, Sendable {
    /// Service missing, peer denied by code signing, or reconnect budget spent.
    case unavailable(reason: String)
    /// Connection dropped while a request was in flight.
    case interrupted(underlying: Error)
    /// Peer answered with an unexpected payload shape.
    case protocolMismatch(details: String)

    var description: String {
        switch self {
        case .unavailable(let reason): return "engine unavailable: \(reason)"
        case .interrupted(let underlying): return "connection interrupted: \(underlying)"
        case .protocolMismatch(let details): return "protocol mismatch: \(details)"
        }
    }

    /// Maps transport-layer failures onto the shared domain error taxonomy.
    var domainError: EngineError {
        switch self {
        case .unavailable: return .xpcUnavailable
        case .interrupted: return .xpcUnavailable
        case .protocolMismatch: return .internalError
        }
    }
}
