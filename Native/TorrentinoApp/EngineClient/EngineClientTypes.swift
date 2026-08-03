// Layer: UI-side IPC DTOs.
// Role: immutable value types mirroring agent replies + client error taxonomy.
// Must-not: hold references to XPC objects or mutate after creation.
// Invariants: Sendable + value semantics; safe to publish on the main actor.

import Foundation
import TorrentinoDomain
import TorrentinoIPC

struct AgentHello: Sendable, Equatable {
    let agentVersion: String
    let pid: Int64
    /// The protocol version agreed during the §7.4 handshake negotiation.
    let negotiatedProtocol: IPCVersion
}

struct AgentHealth: Sendable, Equatable {
    let agentVersion: String
    let pid: Int64
    let uptimeSeconds: Double
    let counter: Int64
    let counterFormat: String
    let machService: String
    let ipcVersion: String
    let healthLane: String
    let commandInFlight: Int
    let commandLimit: Int
    let eventQueueDepth: Int
    let engineFailures: UInt64
    let watchdog: String
    let safeRecovery: Bool
    let network: NetworkReachability
    let networkGeneration: UInt64
    let thermal: ThermalCondition
    let memoryPressure: MemoryPressureLevel
    let lowPower: Bool
    let sleeping: Bool

    /// Parses the plist dictionary returned by health(reply:). Nil on any
    /// missing/mistyped key => protocol mismatch, surfaced as an error.
    /// Extra keys (e.g. protocolRange) are ignored; required keys are stable.
    init?(dictionary: [String: Any]) {
        guard let agentVersion = dictionary["agentVersion"] as? String,
              let pid = (dictionary["pid"] as? NSNumber)?.int64Value,
              let uptimeSeconds = (dictionary["uptimeSeconds"] as? NSNumber)?.doubleValue,
              let counter = (dictionary["counter"] as? NSNumber)?.int64Value,
              let counterFormat = dictionary["counterFormat"] as? String,
              let machService = dictionary["machService"] as? String,
              let ipcVersion = dictionary["ipcVersion"] as? String
        else { return nil }
        self.agentVersion = agentVersion
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.counter = counter
        self.counterFormat = counterFormat
        self.machService = machService
        self.ipcVersion = ipcVersion
        self.healthLane = dictionary["healthLane"] as? String ?? "unknown"
        self.commandInFlight = (dictionary["commandInFlight"] as? NSNumber)?.intValue ?? 0
        self.commandLimit = (dictionary["commandLimit"] as? NSNumber)?.intValue ?? 0
        self.eventQueueDepth = (dictionary["eventQueueDepth"] as? NSNumber)?.intValue ?? 0
        self.engineFailures = (dictionary["engineFailures"] as? NSNumber)?.uint64Value ?? 0
        self.watchdog = dictionary["watchdog"] as? String ?? "unknown"
        self.safeRecovery = (dictionary["safeRecovery"] as? NSNumber)?.boolValue ?? false
        self.network = NetworkReachability(rawValue: dictionary["network"] as? String ?? "") ?? .unknown
        self.networkGeneration = (dictionary["networkGeneration"] as? NSNumber)?.uint64Value ?? 0
        self.thermal = ThermalCondition(rawValue: dictionary["thermal"] as? String ?? "") ?? .nominal
        self.memoryPressure = MemoryPressureLevel(rawValue: dictionary["memoryPressure"] as? String ?? "") ?? .normal
        self.lowPower = (dictionary["lowPower"] as? NSNumber)?.boolValue ?? false
        self.sleeping = (dictionary["sleeping"] as? NSNumber)?.boolValue ?? false
    }

    var summary: String {
        String(format: "version=%@ pid=%d uptime=%.1fs counter=%d format=%@ lane=%@ queue=%d/%d network=%@",
               agentVersion, pid, uptimeSeconds, counter, counterFormat, healthLane,
               commandInFlight, commandLimit, network.rawValue)
    }
}

enum EngineClientError: Error, CustomStringConvertible, Sendable {
    /// Service missing, peer denied by code signing, or reconnect budget spent.
    case unavailable(reason: String)
    /// Connection dropped while a request was in flight.
    case interrupted(underlying: Error)
    /// Peer answered with an unexpected payload shape.
    case protocolMismatch(details: String)
    /// The embedded agent binary failed the §23 peer code-signing validation.
    case peerValidationFailed(PeerValidation.PeerValidationError)
    /// The agent rejected the request with a structured EngineFault.
    case fault(EngineFault)

    var description: String {
        switch self {
        case .unavailable(let reason): return "engine unavailable: \(reason)"
        case .interrupted(let underlying): return "connection interrupted: \(underlying)"
        case .protocolMismatch(let details): return "protocol mismatch: \(details)"
        case .peerValidationFailed(let validation): return "peer validation failed: \(validation)"
        case .fault(let fault): return "engine fault \(fault.code.rawValue)"
        }
    }

    /// Maps transport-layer failures onto the shared domain error taxonomy.
    var domainError: EngineError {
        switch self {
        case .unavailable: return .xpcUnavailable
        case .interrupted: return .xpcUnavailable
        case .protocolMismatch: return .internalError
        case .peerValidationFailed: return .agentDenied
        case .fault(let fault):
            switch fault.code {
            case .xpcUnavailable: return .xpcUnavailable
            case .agentDenied: return .agentDenied
            case .operationTimeout: return .timeout
            default: return .internalError
            }
        }
    }
}
