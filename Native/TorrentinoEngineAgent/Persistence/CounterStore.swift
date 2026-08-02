// Layer: Agent durable state (WP-02 spike persistence; real store arrives WP-06).
// Role: single durable int64 counter with versioned payload + atomic writes.
// Must-not: overwrite a newer format (downgrade), silently discard unknown
// data, or perform IO on the main actor.
// Invariants: file is replaced only via write-tmp -> fsync -> rename ->
// fsync(dir); v2 payloads are FNV-1a checksummed; the actor is the sole
// writer; in-memory value == last successfully persisted value.

import Foundation
import OSLog

enum CounterStoreError: Error, CustomStringConvertible {
    /// The on-disk format is NEWER than this binary supports (downgrade attempt).
    case downgradeBlocked(foundFormat: String, supportedFormat: String)
    /// The file exists but cannot be trusted; we never overwrite it silently.
    case corrupt(reason: String)
    /// Filesystem refused a read/write/rename.
    case ioFailure(reason: String)

    var description: String {
        switch self {
        case .downgradeBlocked(let found, let supported):
            return "counter store format \(found) is newer than supported format \(supported); downgrade blocked"
        case .corrupt(let reason):
            return "counter store corrupt: \(reason)"
        case .ioFailure(let reason):
            return "counter store IO failure: \(reason)"
        }
    }
}

actor CounterStore {
    // Payload formats (little-endian):
    //   v1: "TTC1" || value:int64                     (12 bytes)
    //   v2: "TTC2" || value:int64 || fnv1a64:int64    (20 bytes)
    // The v2 checksum covers magic + value bytes. v2 builds transparently
    // migrate v1 files on load; v1 builds refuse v2 files (downgrade block).
    static let fileName = "counter.dat"

    #if COUNTER_FORMAT_V1
    static let currentFormatName = "v1"
    private static let magic: [UInt8] = [0x54, 0x54, 0x43, 0x31] // "TTC1"
    #else
    static let currentFormatName = "v2"
    private static let magic: [UInt8] = [0x54, 0x54, 0x43, 0x32] // "TTC2"
    #endif

    private static let magicV1: [UInt8] = [0x54, 0x54, 0x43, 0x31]
    private static let magicV2: [UInt8] = [0x54, 0x54, 0x43, 0x32]

    /// Format this binary writes. Constant after compile; safe to read without await.
    let formatName: String = CounterStore.currentFormatName

    private(set) var value: Int64 = 0
    private let fileURL: URL
    private let log = Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "counter")

    /// Loads (and if needed migrates) the durable counter. Runs in init, i.e.
    /// before the actor is shared, so no isolation hops are needed.
    init(engineDirectory: URL) throws {
        let url = engineDirectory.appendingPathComponent(Self.fileName)
        self.fileURL = url
        let loaded = try Self.loadOrMigrate(fileURL: url)
        self.value = loaded.value
        if loaded.migrated {
            log.notice("counter store migrated to \(Self.currentFormatName, privacy: .public) value=\(loaded.value)")
        } else {
            log.notice("counter store loaded format=\(Self.currentFormatName, privacy: .public) value=\(loaded.value)")
        }
    }

    func current() -> Int64 { value }

    func increment() throws -> Int64 {
        value &+= 1
        try persist()
        return value
    }

    /// Re-writes the payload; used by the graceful-shutdown checkpoint.
    func flush() throws {
        try persist()
    }

    // MARK: - Static (nonisolated) disk mechanics, usable from init

    private struct LoadResult {
        let value: Int64
        let migrated: Bool
    }

    private static func loadOrMigrate(fileURL: URL) throws -> LoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            // First boot: establish the file in the current format so later
            // evidence (magic bytes) is meaningful.
            try writePayload(value: 0, to: fileURL)
            return LoadResult(value: 0, migrated: false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw CounterStoreError.ioFailure(reason: "read failed: \(error)")
        }
        guard data.count >= 4 else {
            throw CounterStoreError.corrupt(reason: "file too short (\(data.count) bytes)")
        }

        let magic = [UInt8](data.prefix(4))
        switch magic {
        case magicV1:
            guard data.count >= 12 else {
                throw CounterStoreError.corrupt(reason: "v1 payload truncated (\(data.count) bytes)")
            }
            let stored = readInt64LE(data, offset: 4)
            #if COUNTER_FORMAT_V1
            return LoadResult(value: stored, migrated: false)
            #else
            // v1 -> v2 migration: rewrite with checksum. The rename-based
            // write means a crash mid-migration leaves the v1 file intact.
            try writePayload(value: stored, to: fileURL)
            return LoadResult(value: stored, migrated: true)
            #endif

        case magicV2:
            #if COUNTER_FORMAT_V1
            // Downgrade block (§8.6): a v1 agent must never serve data written
            // by a v2 agent. Exit path maps to exit code 78 in AgentMain.
            throw CounterStoreError.downgradeBlocked(foundFormat: "v2", supportedFormat: "v1")
            #else
            guard data.count >= 20 else {
                throw CounterStoreError.corrupt(reason: "v2 payload truncated (\(data.count) bytes)")
            }
            let stored = readInt64LE(data, offset: 4)
            let storedChecksum = readUInt64LE(data, offset: 12)
            let computedChecksum = fnv1a64(data.prefix(12))
            guard storedChecksum == computedChecksum else {
                throw CounterStoreError.corrupt(reason: "v2 checksum mismatch (stored=\(storedChecksum) computed=\(computedChecksum))")
            }
            return LoadResult(value: stored, migrated: false)
            #endif

        default:
            throw CounterStoreError.corrupt(reason: "unknown magic \(magic.map { String(format: "%02x", $0) }.joined())")
        }
    }

    private func persist() throws {
        try Self.writePayload(value: value, to: fileURL)
    }

    private static func writePayload(value: Int64, to fileURL: URL) throws {
        var payload = Data(magic)
        appendInt64LE(value, to: &payload)
        #if !COUNTER_FORMAT_V1
        appendUInt64LE(fnv1a64(payload), to: &payload)
        #endif
        try AtomicFile.write(payload, to: fileURL)
    }

    // MARK: - Byte helpers

    private static func readInt64LE(_ data: Data, offset: Int) -> Int64 {
        Int64(bitPattern: readUInt64LE(data, offset: offset))
    }

    private static func readUInt64LE(_ data: Data, offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            result |= UInt64(data[offset + index]) << (8 * index)
        }
        return result
    }

    private static func appendInt64LE(_ value: Int64, to data: inout Data) {
        appendUInt64LE(UInt64(bitPattern: value), to: &data)
    }

    private static func appendUInt64LE(_ value: UInt64, to data: inout Data) {
        for index in 0..<8 {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }

    /// FNV-1a 64-bit. Integrity against torn writes, not adversaries — the
    /// store lives in the user's 0700 engine directory.
    private static func fnv1a64(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Durability-correct file replacement.
/// write-tmp -> fsync(file) -> rename -> fsync(dir): readers never observe a
/// partial payload and a crash at any point leaves either the old file or the
/// complete new file (WP-06 failpoints will formalize this for the real store).
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UInt64.random(in: 0...UInt64.max))",
            isDirectory: false)

        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw CounterStoreError.ioFailure(reason: "open(\(temporary.lastPathComponent)) errno=\(errno)")
        }

        var closed = false
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let result = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                    guard result >= 0 else {
                        throw CounterStoreError.ioFailure(reason: "write errno=\(errno)")
                    }
                    written += result
                }
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw CounterStoreError.ioFailure(reason: "fsync(tmp) errno=\(errno)")
            }
            guard Darwin.close(descriptor) == 0 else {
                throw CounterStoreError.ioFailure(reason: "close(tmp) errno=\(errno)")
            }
            closed = true
            guard Darwin.rename(temporary.path, url.path) == 0 else {
                throw CounterStoreError.ioFailure(reason: "rename errno=\(errno)")
            }
            // fsync the directory so the rename itself is durable.
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY, 0)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        } catch {
            if !closed { Darwin.close(descriptor) }
            Darwin.unlink(temporary.path)
            throw error
        }
    }
}
