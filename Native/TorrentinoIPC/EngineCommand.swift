// Layer: IPC (command schema).
// Role: request command identifiers for UI → agent calls (WP-02 surface).
// Must-not: encode replies or own transport connections.
// Invariants: Sendable; Codable raw values stable for wire decoding.

/// Engine commands exposed over XPC. Mirrors the WP-02 lifecycle protocol surface.
public enum EngineCommand: String, Codable, Sendable, Equatable, CaseIterable {
    case hello
    case health
    case increment
    case getCounter
    case shutdown
}
