// Layer: EngineAgent (Transfer).
// Role: byte-bounded live status retention for the bridge-backed engine.
// Must-not: retain unbounded alert text or claim an entry-count cap is a byte
// cap. The cache measures the retained strings and fixed value payload.

import Foundation

struct CachedTorrentStatus: Sendable, Equatable {
    let fraction: Double
    let state: Int
    let error: String?
}

struct ByteBoundedStatusCache: Sendable {
    private(set) var entries: [String: CachedTorrentStatus] = [:]
    private(set) var byteCount = 0

    private var order: [String] = []
    private let entryLimit: Int
    private var byteLimit: Int64

    init(entryLimit: Int = 1024, byteLimit: Int64 = 64 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.byteLimit = max(0, byteLimit)
    }

    mutating func setByteLimit(_ limit: Int64) {
        byteLimit = max(0, limit)
        trim()
    }

    mutating func insert(_ status: CachedTorrentStatus, for key: String) {
        if let previous = entries[key] {
            byteCount -= Self.estimatedBytes(key: key, status: previous)
        } else {
            order.removeAll { $0 == key }
        }
        entries[key] = status
        order.append(key)
        byteCount += Self.estimatedBytes(key: key, status: status)
        trim()
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        byteCount = 0
    }

    private mutating func trim() {
        while (entries.count > entryLimit || Int64(byteCount) > byteLimit),
              let oldest = order.first {
            order.removeFirst()
            guard let removed = entries.removeValue(forKey: oldest) else { continue }
            byteCount -= Self.estimatedBytes(key: oldest, status: removed)
        }
        byteCount = max(0, byteCount)
    }

    private static func estimatedBytes(key: String, status: CachedTorrentStatus) -> Int {
        // The fixed portion covers the scalar fields and dictionary storage;
        // UTF-8 counts cover the only variable-size retained payloads.
        64 + key.utf8.count + (status.error?.utf8.count ?? 0)
    }
}
