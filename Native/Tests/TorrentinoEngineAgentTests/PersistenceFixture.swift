// Layer: Test support (WP-06 persistence fixture).
// Role: deterministic 50-100 record fixture for restore-cycle tests. Every
// torrent gets a stable id, resume payload and metainfo payload; the seed
// offsets ids so several cycles can coexist in one store without collisions.
// Must-not: touch production paths (the store runs on the TestProfile root).
// Invariants: payload(i) is deterministic and seeded by index; ids are unique
// per (seed, index); every generated torrent is valid on its own.

import Foundation

enum PersistenceFixture {
    static func torrent(_ index: Int, seed: Int, state: String = "downloading") -> StoredTorrent {
        StoredTorrent(
            id: String(format: "fixture-%06d-%06d", seed, index),
            infoHashV1: String(format: "%040x", seed &+ index),
            infoHashV2: nil,
            name: "fixture-\(seed)-\(index)",
            state: state,
            addedAt: Int64(Date().timeIntervalSince1970 * 1000),
            quarantined: false
        )
    }

    /// Deterministic payload for the given index (distinct bytes per index).
    static func payload(_ index: Int, size: Int = 4096) -> Data {
        var data = Data(capacity: size)
        var value = UInt8(index & 0xFF)
        for _ in 0..<size {
            data.append(value)
            value &+= 17
        }
        return data
    }

    /// Writes `count` torrents, each with resume + metainfo generations.
    static func write(store: PersistenceStore, count: Int, seed: Int) async throws {
        for index in 0..<count {
            let torrent = torrent(index, seed: seed)
            try await store.addTorrent(torrent)
            _ = try await store.storeResumeData(torrentID: torrent.id, data: payload(seed + index))
            _ = try await store.storeMetainfo(torrentID: torrent.id, data: payload(seed + index, size: 2048))
        }
    }
}
