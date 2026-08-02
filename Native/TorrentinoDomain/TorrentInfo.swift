// Layer: Domain (pure value types).
// Role: immutable torrent snapshot DTO for UI projection and tests.
// Must-not: own handles, perform I/O, or act as source of truth.
// Invariants: Sendable value type; progress is 0.0...1.0 when valid.

import Foundation

/// Immutable torrent snapshot. The agent is authoritative; UI never invents records.
public struct TorrentInfo: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let size: Int64
    /// Fraction complete in 0.0...1.0. Values outside that range are invalid input.
    public let progress: Double
    public let state: TorrentState

    public init(
        id: UUID,
        name: String,
        size: Int64,
        progress: Double,
        state: TorrentState
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.progress = progress
        self.state = state
    }
}
