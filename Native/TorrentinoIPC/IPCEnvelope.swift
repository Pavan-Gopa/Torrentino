// Layer: IPC (versioned Codable envelope).
// Role: XPC-compatible request/response/event wrapper with schema version.
// Must-not: carry non-Sendable payloads or mutable shared state.
// Invariants: immutable; payload is Codable & Sendable; version is required.

import Foundation

/// Versioned envelope for IPC messages. Keeps payload typing at the edge
/// while allowing the agent to reject unsupported major versions early.
public struct IPCEnvelope<T: Codable & Sendable>: Codable, Sendable, Equatable where T: Equatable {
    public let version: IPCVersion
    public let type: String
    public let payload: T

    public init(version: IPCVersion = .current, type: String, payload: T) {
        self.version = version
        self.type = type
        self.payload = payload
    }

    /// True when the envelope major version matches the local current major.
    public var isCompatibleWithCurrent: Bool {
        version.major == IPCVersion.current.major
    }
}
