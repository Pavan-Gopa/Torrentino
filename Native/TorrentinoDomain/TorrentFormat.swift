// Layer: Domain
// Role: Re-exports TorrentFormat from TorrentinoIPC for domain usage.
// Must-not: duplicate enum definitions across frameworks.
// Invariants: Sendable, Codable, Equatable.

import Foundation
import TorrentinoIPC

// TorrentFormat is defined in TorrentinoIPC for wire serialization.
