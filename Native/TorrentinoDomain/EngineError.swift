// Layer: Domain (error taxonomy).
// Role: shared engine/client error cases for UI and agent boundaries.
// Must-not: wrap non-Sendable payloads or leak XPC/NSError types.
// Invariants: Sendable; stable cases for mapping transport failures.

/// Domain-level engine failures visible across the UI ↔ agent boundary.
/// Transport-specific details map into these cases at the IPC edge.
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Mach service missing, peer not running, or connection cannot be established.
    case xpcUnavailable
    /// Peer rejected by code-signing requirement or SMAppService denial.
    case agentDenied
    /// Operation exceeded its wall-clock budget.
    case timeout
    /// Unexpected internal failure after a successful connection.
    case internalError

    public var description: String {
        switch self {
        case .xpcUnavailable: return "engine XPC unavailable"
        case .agentDenied: return "engine agent denied"
        case .timeout: return "engine operation timed out"
        case .internalError: return "engine internal error"
        }
    }
}
