// Layer: IPC (versioned protocol).
// Role: wire-protocol version for Codable envelopes between UI and agent.
// Must-not: perform I/O or depend on UI/AppKit.
// Invariants: Sendable; current = 1.0; major bumps are breaking.

/// Semantic version of the IPC envelope schema.
public struct IPCVersion: Codable, Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    /// Current frozen schema for WP-03 foundation (aligns with WP-02 command surface).
    public static let current = IPCVersion(major: 1, minor: 0)

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: IPCVersion, rhs: IPCVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    public var description: String { "\(major).\(minor)" }
}
