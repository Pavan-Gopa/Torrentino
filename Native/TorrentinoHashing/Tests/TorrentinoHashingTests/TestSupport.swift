// Layer: Hashing research (WP-12) — test support
// Role: deterministic corpus generation and isolated temp workspaces for the
// TorrentinoHashing tests.
// Invariants: reproducible (seeded PRNG); never touches production
// Application Support; teardown removes the temp tree.

import Foundation
import TorrentinoHashing
import XCTest

/// Deterministic byte generator (SplitMix64) — same seed → same corpus.
public struct DeterministicBytes: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func data(count: Int) -> Data {
        var out = Data(capacity: count)
        while out.count < count {
            var value = next()
            withUnsafeBytes(of: &value) { out.append(contentsOf: $0) }
        }
        return Data(out.prefix(count))
    }
}

/// Minimal hash source manifest for in-memory tests. Since the hashers read
/// real files with identity checks, corpora are materialized on disk.
public struct TestCorpus {
    public let root: URL
    public let files: [HashSourceFile]

    public static func make(
        root: URL,
        seed: UInt64,
        fileSizes: [Int],
        hiddenSubdirs: Bool = false
    ) throws -> TestCorpus {
        var generator = DeterministicBytes(seed: seed)
        var entries: [HashSourceFile] = []
        for (index, size) in fileSizes.enumerated() {
            let relative = "file_\(index).bin"
            let url = root.appendingPathComponent(relative)
            let data = generator.data(count: size)
            try data.write(to: url)
            var st = stat()
            XCTAssertEqual(lstat(url.path, &st), 0)
            entries.append(HashSourceFile(
                relativePath: relative,
                fullPath: url.path,
                deviceID: UInt64(st.st_dev),
                fileResourceID: UInt64(st.st_ino),
                sizeBytes: Int64(st.st_size),
                mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
                mtimeNanos: Int64(st.st_mtimespec.tv_nsec)
            ))
        }
        if hiddenSubdirs {
            let hiddenDir = root.appendingPathComponent(".hidden", isDirectory: true)
            try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
            let hiddenFile = hiddenDir.appendingPathComponent("secret.bin")
            try generator.data(count: 4096).write(to: hiddenFile)
        }
        return TestCorpus(root: root, files: entries)
    }

    public func wipe() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// A temp root that owns its cleanup; standard pattern for SPM test targets.
public final class TestWorkspace {
    public let root: URL

    public init(name: String) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("torrentino-hashing-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let unique = base.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unique, withIntermediateDirectories: true)
        self.root = unique
    }

    public func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Enables the experimental Metal gate for the duration of a test.
public enum TestGate {
    public static func enable() {
        setenv(ExperimentalGate.flagName, "1", 1)
    }

    public static func disable() {
        unsetenv(ExperimentalGate.flagName)
    }
}

extension XCTestCase {
    /// Runs the assertion after restoring the experimental gate state.
    public func withMetalGate(assertions: () async throws -> Void) async rethrows {
        TestGate.enable()
        defer { TestGate.disable() }
        try await assertions()
    }
}
