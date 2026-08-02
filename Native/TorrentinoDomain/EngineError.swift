// Layer: Domain (error taxonomy).
// Role: shared engine/client error cases for UI and agent boundaries.
// Must-not: wrap non-Sendable payloads or leak XPC/NSError types.
// Invariants: Sendable; stable cases for mapping transport failures.

import Foundation

/// Domain-level engine failures visible across the UI ↔ agent boundary.
/// Transport-specific details map into these cases at the IPC edge.
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// Mach service missing, peer not running, or connection cannot be established.
    case xpcUnavailable
    /// Peer rejected by code-signing requirement or SMAppService denial.
    case agentDenied
    /// Operation exceeded its wall-clock budget.
    case timeout
    /// Unexpected internal failure after a successful connection.
    case internalError

    /// UI-facing copy. Maps each case to a stable String Catalog key
    /// (error.xpc_unavailable, error.agent_denied, error.timeout, error.internal)
    /// when rendered through the app bundle; the literals below keep Domain
    /// framework output deterministic regardless of bundle context.
    public var errorDescription: String? {
        switch self {
        case .xpcUnavailable: return "Engine agent is not available."
        case .agentDenied: return "Agent registration was denied by the user."
        case .timeout: return "Operation timed out."
        case .internalError: return "Internal engine error."
        }
    }

    public var description: String {
        errorDescription ?? "engine error"
    }
}
