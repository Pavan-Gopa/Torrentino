// Layer: Hashing research (WP-12)
// Role: cancellation tests. A cancelled run must not produce partial output
// and must not silently fall back to CPU; cancellation latency is bounded by
// the batch granularity.
// Invariants: cancelled runs throw .cancelled (or finish cancelled), and no
// result is ever reported for a cancelled run.

import Foundation
import TorrentinoHashing
import XCTest

final class CancellationTests: XCTestCase {
    func testCancelMidRunThrowsNoResult() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "cancel")
            defer { workspace.remove() }
            let corpus = try TestCorpus.make(
                root: workspace.root,
                seed: 3,
                fileSizes: [64 * 1024 * 1024, 48 * 1024 * 1024]
            )
            let task = Task<Void, Error> {
                _ = try await ResearchHashingBackend().hash(
                    scannedFiles: corpus.files,
                    pieceSizeBytes: 256 * 1024,
                    format: .hybrid,
                    choice: .metal
                )
            }
            // Cancel before any dispatch completes.
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("cancelled run must not succeed with a result")
            } catch let error as ResearchHasherError {
                XCTAssertEqual(error, .cancelled)
            } catch is CancellationError {
                // acceptable: propagated task cancellation
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testCancelCheckFiresBetweenBatches() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "cancel2")
            defer { workspace.remove() }
            let corpus = try TestCorpus.make(
                root: workspace.root,
                seed: 9,
                fileSizes: [32 * 1024 * 1024]
            )
            let cancelled = LockedFlag()
            let task = Task<ResearchHasherError?, Never> {
                do {
                    _ = try await ResearchHashingBackend().hash(
                        scannedFiles: corpus.files,
                        pieceSizeBytes: 1024 * 1024,
                        format: .v2,
                        choice: .metal,
                        cancelCheck: {
                            if cancelled.value { throw ResearchHasherError.cancelled }
                        }
                    )
                    return nil
                } catch let error as ResearchHasherError {
                    return error
                } catch {
                    return .hashingFailed("\(error)")
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            cancelled.value = true
            let result = await task.value
            XCTAssertEqual(result, .cancelled)
        }
    }

    func testCancellationLatencyBound() async throws {
        try await withMetalGate {
            let workspace = try TestWorkspace(name: "cancel3")
            defer { workspace.remove() }
            let corpus = try TestCorpus.make(
                root: workspace.root,
                seed: 17,
                fileSizes: [96 * 1024 * 1024]
            )
            let cancelled = LockedFlag()
            let start = DispatchTime.now()
            let task = Task<ResearchHasherError?, Never> {
                do {
                    _ = try await ResearchHashingBackend().hash(
                        scannedFiles: corpus.files,
                        pieceSizeBytes: 1024 * 1024,
                        format: .v2,
                        choice: .metal,
                        cancelCheck: {
                            if cancelled.value { throw ResearchHasherError.cancelled }
                        }
                    )
                    return nil
                } catch let error as ResearchHasherError {
                    return error
                } catch {
                    return .hashingFailed("\(error)")
                }
            }
            // Wait until some work has certainly started, then cancel.
            try await Task.sleep(nanoseconds: 80_000_000)
            cancelled.value = true
            _ = await task.value
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            // Bounded by in-flight batch (max ~256 MiB stage, read + dispatch)
            // plus CPU-side bookkeeping; assert a generous CI-safe bound.
            XCTAssertLessThan(elapsedMs, 30_000, "cancellation latency exceeded 30 s")
        }
    }
}

/// Trivial thread-safe boolean (Swift 6 Sendable).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
