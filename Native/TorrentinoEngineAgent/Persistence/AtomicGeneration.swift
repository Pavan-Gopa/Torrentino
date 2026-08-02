// Layer: Agent durable persistence (WP-06).
// Role: atomic generation semantics for resume/metainfo/session records.
//   - GenerationClock: monotonic UInt64 per kind, restored from the highest
//     committed generation at open, so a crashed session can never reuse a
//     generation number.
//   - PersistenceSidecar: the durability-correct file path for every payload —
//     temp write -> file fsync -> rename -> parent-dir fsync (failpoints 1-4)
//     — BEFORE the SQLite row is committed (failpoint 5 lives in the store).
//     The sidecar is forensic evidence; the DB row is the authoritative state.
//   - Checksums: SHA-256 over the payload, stored alongside, verified on read.
// Must-not: reuse generations after a crash, or write a payload whose sidecar
// is not durable before the SQLite transaction starts.
// Invariants: generation numbers are strictly increasing per kind; every
// sidecar file carries a matching checksum; a crash at any point leaves either
// the old generation or the complete new generation, never a partial payload.

import CryptoKit
import Foundation

enum GenerationKind: String, Sendable {
    case resume
    case metainfo
    case session

    var counterKey: String { "gen.\(rawValue)" }
}

/// Monotonic generation clock. Restored from committed state at startup.
/// Confined to the PersistenceStore actor (never shared), so it is a plain
/// class; the @unchecked Sendable silence is safe because every touch happens
/// inside the store's actor isolation.
final class GenerationClock: @unchecked Sendable {
    private var current: UInt64

    init(initial: UInt64) {
        current = initial
    }

    /// Returns the next generation, strictly greater than any previous one.
    func next() -> UInt64 {
        current &+= 1
        return current
    }

    /// Adopts a committed generation (startup restore). Never moves backwards.
    func adopt(_ value: UInt64) {
        if value > current { current = value }
    }
}

/// Namespace for checksum + sidecar mechanics.
enum AtomicGeneration {
    /// SHA-256 hex digest over the payload. Integrity against torn writes and
    /// bit rot; verified on every read of a stored record.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Sidecar file name: <kind>-<owner>-<generation>.bin
    static func sidecarFileName(kind: GenerationKind, owner: String, generation: UInt64) -> String {
        "\(kind.rawValue)-\(owner)-\(generation).bin"
    }
}

/// The durability-correct write path for a generation payload.
enum PersistenceSidecar {
    /// Sidecar directory for a data directory (created on demand).
    static func directory(in dataDirectory: URL) throws -> URL {
        let url = dataDirectory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(kind: GenerationKind, owner: String, generation: UInt64,
                    in dataDirectory: URL) throws -> URL {
        try directory(in: dataDirectory)
            .appendingPathComponent(AtomicGeneration.sidecarFileName(kind: kind, owner: owner, generation: generation))
    }

    /// Writes the payload durably as a sidecar. Failpoints 1-4 fire at the
    /// exact phase boundaries: before temp write, after write before fsync,
    /// after fsync, after rename before parent-dir fsync.
    static func prepare(data: Data, kind: GenerationKind, owner: String,
                        generation: UInt64, dataDirectory: URL) throws -> (url: URL, checksum: String) {
        try FailpointInjector.fire(.beforeTemporaryWrite)

        let target = try url(kind: kind, owner: owner, generation: generation, in: dataDirectory)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).tmp-\(UInt64.random(in: 0...UInt64.max))")

        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else {
            throw PersistenceError.ioFailure(reason: "open(\(temporary.lastPathComponent)) errno=\(errno)")
        }

        var closed = false
        do {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let result = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                    guard result >= 0 else {
                        throw PersistenceError.ioFailure(reason: "write errno=\(errno)")
                    }
                    written += result
                }
            }
            try FailpointInjector.fire(.afterWriteBeforeFileFsync)
            guard Darwin.fsync(descriptor) == 0 else {
                throw PersistenceError.ioFailure(reason: "fsync(tmp) errno=\(errno)")
            }
            try FailpointInjector.fire(.afterFileFsync)
            guard Darwin.close(descriptor) == 0 else {
                throw PersistenceError.ioFailure(reason: "close(tmp) errno=\(errno)")
            }
            closed = true
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                throw PersistenceError.ioFailure(reason: "rename errno=\(errno)")
            }
            try FailpointInjector.fire(.afterRenameBeforeParentFsync)
            let directoryDescriptor = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY, 0)
            if directoryDescriptor >= 0 {
                _ = Darwin.fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        } catch {
            if !closed { Darwin.close(descriptor) }
            Darwin.unlink(temporary.path)
            throw error
        }

        return (target, AtomicGeneration.sha256(data))
    }

    /// Removes a superseded generation sidecar after the DB commit. Best
    /// effort: an orphan sidecar is harmless and swept by the reconciler.
    static func removePrevious(kind: GenerationKind, owner: String,
                               upTo generation: UInt64, dataDirectory: URL) {
        guard let dir = try? directory(in: dataDirectory) else { return }
        let prefix = "\(kind.rawValue)-\(owner)-"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasPrefix(prefix) {
            let suffix = String(file.dropFirst(prefix.count))
            let number = suffix.split(separator: ".").first.flatMap { UInt64($0) }
            if let number, number < generation {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    /// Removes the sidecar of a deleted record.
    static func removeAll(kind: GenerationKind, owner: String, dataDirectory: URL) {
        guard let dir = try? directory(in: dataDirectory) else { return }
        let prefix = "\(kind.rawValue)-\(owner)-"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where file.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
        }
    }

    /// Lists sidecar files for a kind (used by the reconciler's orphan sweep).
    static func sidecarFiles(kind: GenerationKind, dataDirectory: URL) -> [(file: String, generation: UInt64, owner: String)] {
        guard let dir = try? directory(in: dataDirectory),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let prefix = kind.rawValue + "-"
        var result: [(String, UInt64, String)] = []
        for file in files where file.hasPrefix(prefix) && !file.hasPrefix(".") {
            let rest = String(file.dropFirst(prefix.count))
            let parts = rest.split(separator: "-")
            guard parts.count >= 2, let generation = UInt64(parts.last ?? "") else { continue }
            let owner = parts.dropLast().joined(separator: "-")
            result.append((file, generation, owner))
        }
        return result
    }
}
