// Layer: Domain (pure value types).
// Role: torrent lifecycle states shared by UI projection and agent authority.
// Must-not: perform I/O, hold UI references, or mutate after observation.
// Invariants: Sendable; exhaustive switch-friendly; no UI strings here.

/// Authoritative torrent lifecycle states. The agent owns transitions;
/// the UI only projects snapshots of this enum.
public enum TorrentState: String, Codable, Sendable, Equatable, CaseIterable {
    case queued
    case downloading
    case seeding
    case paused
    case error
    case stopped
}
