// Layer: Unit tests (TorrentinoDomain).
// Role: verify domain value types, Sendable DTOs, error taxonomy (WP-03).
// Must-not: perform network I/O or touch production Application Support.
// ADR-010: happy / error / edge for every public API; concurrency stress for values.

import XCTest
@testable import TorrentinoDomain

final class TorrentinoDomainTests: TestProfileCase {

    // MARK: - TorrentState

    func testTorrentStateAllCasesExhaustive() {
        let expected: [TorrentState] = [
            .queued, .downloading, .seeding, .paused, .error, .stopped
        ]
        XCTAssertEqual(TorrentState.allCases.count, 6)
        XCTAssertEqual(TorrentState.allCases, expected)
    }

    func testTorrentStateRawValuesStable() {
        XCTAssertEqual(TorrentState.queued.rawValue, "queued")
        XCTAssertEqual(TorrentState.downloading.rawValue, "downloading")
        XCTAssertEqual(TorrentState.seeding.rawValue, "seeding")
        XCTAssertEqual(TorrentState.paused.rawValue, "paused")
        XCTAssertEqual(TorrentState.error.rawValue, "error")
        XCTAssertEqual(TorrentState.stopped.rawValue, "stopped")
    }

    func testTorrentStateCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in TorrentState.allCases {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(TorrentState.self, from: data)
            XCTAssertEqual(decoded, state, "round-trip failed for \(state)")
            // Wire format is raw string (not keyed object).
            let asString = try decoder.decode(String.self, from: data)
            XCTAssertEqual(asString, state.rawValue)
        }
    }

    func testTorrentStateUnknownRawValueFails() {
        XCTAssertNil(TorrentState(rawValue: "completed"))
        XCTAssertNil(TorrentState(rawValue: ""))
        XCTAssertNil(TorrentState(rawValue: "DOWNLOADING"))
    }

    func testTorrentStateUnknownJSONDecodeFails() {
        let junk = Data("\"not-a-state\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TorrentState.self, from: junk))
    }

    func testTorrentStateSendableConcurrentReads() {
        // Value type + Sendable: concurrent pure reads must not race.
        let states = TorrentState.allCases
        let iterations = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let state = states[i % states.count]
            XCTAssertEqual(TorrentState(rawValue: state.rawValue), state)
        }
    }

    // MARK: - TorrentInfo

    func testTorrentInfoHappyPathFields() {
        let id = UUID()
        let info = TorrentInfo(
            id: id,
            name: "ubuntu.iso",
            size: 4_294_967_296,
            progress: 0.42,
            state: .downloading
        )
        XCTAssertEqual(info.id, id)
        XCTAssertEqual(info.name, "ubuntu.iso")
        XCTAssertEqual(info.size, 4_294_967_296)
        XCTAssertEqual(info.progress, 0.42, accuracy: 1e-12)
        XCTAssertEqual(info.state, .downloading)
    }

    func testTorrentInfoCodableRoundTrip() throws {
        let info = TorrentInfo(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "round-trip.torrent",
            size: 99,
            progress: 1.0,
            state: .seeding
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(TorrentInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testTorrentInfoEdgeEmptyNameSizeZeroProgressBounds() throws {
        let emptyName = TorrentInfo(
            id: UUID(),
            name: "",
            size: 0,
            progress: 0.0,
            state: .queued
        )
        XCTAssertEqual(emptyName.name, "")
        XCTAssertEqual(emptyName.size, 0)
        XCTAssertEqual(emptyName.progress, 0.0, accuracy: 0)

        let done = TorrentInfo(
            id: UUID(),
            name: "done",
            size: 1,
            progress: 1.0,
            state: .seeding
        )
        XCTAssertEqual(done.progress, 1.0, accuracy: 0)

        // Struct is a value type: mutation of a copy does not exist (let fields).
        let copy = emptyName
        XCTAssertEqual(copy, emptyName)

        let data = try JSONEncoder().encode(emptyName)
        let decoded = try JSONDecoder().decode(TorrentInfo.self, from: data)
        XCTAssertEqual(decoded.name, "")
        XCTAssertEqual(decoded.size, 0)
    }

    func testTorrentInfoNegativeFuzzProgressOutOfRangeStillCodable() throws {
        // Domain documents 0...1 as valid; encoder still accepts out-of-range
        // Doubles so callers can detect invalid snapshots without crashing decode.
        let over = TorrentInfo(
            id: UUID(),
            name: "overflow",
            size: -1,
            progress: 1.5,
            state: .error
        )
        let under = TorrentInfo(
            id: UUID(),
            name: "underflow",
            size: Int64.min,
            progress: -0.01,
            state: .error
        )
        for info in [over, under] {
            let data = try JSONEncoder().encode(info)
            let decoded = try JSONDecoder().decode(TorrentInfo.self, from: data)
            XCTAssertEqual(decoded, info)
        }
    }

    func testTorrentInfoTamperedJSONDecodeFails() {
        let junk = Data(#"{"id":"not-uuid","name":1,"size":"x","progress":true,"state":"nope"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(TorrentInfo.self, from: junk))
    }

    func testTorrentInfoConcurrentEncodeDecodeStress() throws {
        let sample = TorrentInfo(
            id: UUID(),
            name: "stress",
            size: 1_024,
            progress: 0.5,
            state: .paused
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let counter = ConcurrentFailureCounter()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            do {
                let data = try encoder.encode(sample)
                let decoded = try decoder.decode(TorrentInfo.self, from: data)
                if decoded != sample {
                    counter.increment()
                }
            } catch {
                counter.increment()
            }
        }
        XCTAssertEqual(counter.value, 0, "concurrent encode/decode produced failures")
    }

    // MARK: - EngineError

    func testEngineErrorAllCasesPresent() {
        let cases: [EngineError] = [
            .xpcUnavailable, .agentDenied, .timeout, .internalError
        ]
        XCTAssertEqual(cases.count, 4)
        // Distinct by equatable identity.
        XCTAssertEqual(Set(cases.map { String(describing: $0) }).count, 4)
    }

    func testEngineErrorConformsToError() {
        let asError: Error = EngineError.timeout
        XCTAssertTrue(asError is EngineError)
        XCTAssertEqual(asError as? EngineError, .timeout)
    }

    func testEngineErrorLocalizedErrorConformance() {
        // Kick requires LocalizedError so UI can surface errorDescription.
        // Check through the Error existential: a direct `is` on the concrete
        // type is statically always true in Swift 6 and would not compile.
        let errors: [any Error] = [
            EngineError.xpcUnavailable,
            EngineError.agentDenied,
            EngineError.timeout,
            EngineError.internalError
        ]
        for e in errors {
            XCTAssertTrue(
                e is LocalizedError,
                "EngineError must conform to LocalizedError for UI-facing copy"
            )
        }
    }

    func testEngineErrorDescriptionsNonEmptyAndDistinct() {
        let descriptions = [
            EngineError.xpcUnavailable.description,
            EngineError.agentDenied.description,
            EngineError.timeout.description,
            EngineError.internalError.description
        ]
        for d in descriptions {
            XCTAssertFalse(d.isEmpty)
            XCTAssertFalse(d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(Set(descriptions).count, 4, "error descriptions must be unique")
    }

    func testEngineErrorEquality() {
        XCTAssertEqual(EngineError.xpcUnavailable, .xpcUnavailable)
        XCTAssertNotEqual(EngineError.xpcUnavailable, .agentDenied)
        XCTAssertNotEqual(EngineError.timeout, .internalError)
    }

    // MARK: - TestProfile isolation (also covered by shell script)

    func testTestProfileCreatesIsolatedTempDirectory() throws {
        let path = profile.rootURL.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.contains("torrentino-test."))
        XCTAssertFalse(
            path.contains(TestProfile.productionAppSupportMarker),
            "TestProfile must not use production path: \(path)"
        )
        let sub = try profile.subdirectory("engine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path))
        XCTAssertTrue(sub.path.hasPrefix(profile.rootURL.path))
    }

    func testTestProfileCleanupRemovesDirectory() throws {
        let isolated = try TestProfile()
        let root = isolated.rootURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let marker = try isolated.subdirectory("cleanup").appendingPathComponent("x.txt")
        try "probe".write(to: marker, atomically: true, encoding: .utf8)
        isolated.tearDown()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.path),
            "tearDown must remove isolated root"
        )
    }
}

/// Thread-safe failure tally for concurrentPerform stress tests (Swift 6 Sendable).
private final class ConcurrentFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
