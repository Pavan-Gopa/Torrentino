// Layer: EngineCoordinator (WP-04 bridge errors).
// Role:     structured failures surfaced by EngineCoordinator to the agent.
//           Mirrors torrentino::bridge::BridgeError so a Swift caller can
//           switch on the same taxonomy the C++ engine uses internally.
// Must not: wrap non-Sendable payloads, NSError pointers, or C++ exceptions.
// Invariants: Sendable; Equatable; raw values are frozen to the C++ enum.

import Foundation

/// Structured bridge failure mirroring `torrentino::bridge::BridgeError`.
public enum EngineCoordinatorError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case notStarted
    case alreadyStarted
    case notFound
    case timeout
    case invalidArgument
    case engineFailure
    case io
    case stopped
    case internalError
    /// The adapter failed to produce or consume a JSON envelope.
    case malformedPayload(String)

    /// Maps a bridge NSError code (TorrentinoEngineBridgeError) to a case.
    public static func bridgeError(from codeValue: Int) -> EngineCoordinatorError {
        switch codeValue {
        case 1: return .notStarted
        case 2: return .alreadyStarted
        case 3: return .notFound
        case 4: return .timeout
        case 5: return .invalidArgument
        case 6: return .engineFailure
        case 7: return .io
        case 8: return .stopped
        default: return .internalError
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notStarted: return "Engine is not running."
        case .alreadyStarted: return "Engine is already running."
        case .notFound: return "Torrent is not known to the engine."
        case .timeout: return "Engine operation timed out."
        case .invalidArgument: return "Invalid argument to engine operation."
        case .engineFailure: return "Engine failure."
        case .io: return "Filesystem-level engine failure."
        case .stopped: return "Operation aborted because the engine is shutting down."
        case .internalError: return "Internal engine error."
        case .malformedPayload(let detail): return "Malformed engine payload: \(detail)"
        }
    }

    public var description: String {
        errorDescription ?? "engine coordinator error"
    }
}