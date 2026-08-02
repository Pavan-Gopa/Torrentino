// Layer: IPC (event schema).
// Role: agent → UI event placeholders for future push notifications.
// Must-not: deliver fake progress; payloads stay empty until WP-04+.
// Invariants: Sendable; Codable; cases reserved without fabricated data.

import Foundation

/// Agent-originated events. Placeholders only in WP-03 — no synthetic streams.
public enum EngineEvent: String, Codable, Sendable, Equatable, CaseIterable {
    /// Torrent or agent lifecycle state transition (payload TBD in later WPs).
    case stateChanged
    /// Download/seed progress update (payload TBD in later WPs).
    case progressUpdated
}
