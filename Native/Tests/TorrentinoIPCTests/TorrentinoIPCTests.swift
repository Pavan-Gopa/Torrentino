// Layer: Unit tests (TorrentinoIPC).
// Role: versioned envelopes, command/event schemas, Codable round-trips (WP-03).
// Must-not: open XPC connections or touch production Application Support.
// ADR-010: happy / error / edge; negative/fuzz for parsers; concurrency stress.

import XCTest
@testable import TorrentinoIPC

final class TorrentinoIPCTests: TestProfileCase {

    // MARK: - IPCVersion

    func testCurrentVersionIs1_0() {
        XCTAssertEqual(IPCVersion.current.major, 1)
        XCTAssertEqual(IPCVersion.current.minor, 0)
        XCTAssertEqual(IPCVersion.current.description, "1.0")
    }

    func testVersionOrderingComparable() {
        let v10 = IPCVersion(major: 1, minor: 0)
        let v11 = IPCVersion(major: 1, minor: 1)
        let v20 = IPCVersion(major: 2, minor: 0)
        let v00 = IPCVersion(major: 0, minor: 9)
        XCTAssertTrue(v10 < v11)
        XCTAssertTrue(v11 < v20)
        XCTAssertTrue(v00 < v10)
        XCTAssertFalse(v20 < v10)
        XCTAssertEqual(v10, IPCVersion.current)
    }

    func testVersionBackwardCompatLogicViaEnvelope() {
        // Same major → compatible; higher major → reject.
        let sameMajorNewerMinor = IPCEnvelope(
            version: IPCVersion(major: 1, minor: 9),
            type: "hello",
            payload: "ok"
        )
        XCTAssertTrue(sameMajorNewerMinor.isCompatibleWithCurrent)

        let olderMinor = IPCEnvelope(
            version: IPCVersion(major: 1, minor: 0),
            type: "hello",
            payload: "ok"
        )
        XCTAssertTrue(olderMinor.isCompatibleWithCurrent)

        let nextMajor = IPCEnvelope(
            version: IPCVersion(major: 2, minor: 0),
            type: "hello",
            payload: "ok"
        )
        XCTAssertFalse(nextMajor.isCompatibleWithCurrent)

        let zeroMajor = IPCEnvelope(
            version: IPCVersion(major: 0, minor: 1),
            type: "hello",
            payload: "ok"
        )
        XCTAssertFalse(zeroMajor.isCompatibleWithCurrent)
    }

    func testVersionCodableRoundTrip() throws {
        let v = IPCVersion(major: 3, minor: 7)
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(IPCVersion.self, from: data)
        XCTAssertEqual(decoded, v)
    }

    // MARK: - EngineCommand

    func testEngineCommandAllCasesMatchWP02Surface() {
        let expected: [EngineCommand] = [
            .hello, .health, .increment, .getCounter, .shutdown
        ]
        XCTAssertEqual(EngineCommand.allCases, expected)
        XCTAssertEqual(EngineCommand.allCases.count, 5)
    }

    func testEngineCommandCodableRoundTrip() throws {
        for cmd in EngineCommand.allCases {
            let data = try JSONEncoder().encode(cmd)
            let decoded = try JSONDecoder().decode(EngineCommand.self, from: data)
            XCTAssertEqual(decoded, cmd)
            let raw = try JSONDecoder().decode(String.self, from: data)
            XCTAssertEqual(raw, cmd.rawValue)
        }
    }

    func testEngineCommandUnknownDecodeFails() {
        let unknown = Data("\"launchNukes\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineCommand.self, from: unknown))
        XCTAssertNil(EngineCommand(rawValue: "pause"))
        XCTAssertNil(EngineCommand(rawValue: ""))
        XCTAssertNil(EngineCommand(rawValue: "HELLO"))
    }

    // MARK: - EngineEvent

    func testEngineEventAllCases() {
        XCTAssertEqual(
            Set(EngineEvent.allCases),
            Set([.stateChanged, .progressUpdated])
        )
        XCTAssertEqual(EngineEvent.stateChanged.rawValue, "stateChanged")
        XCTAssertEqual(EngineEvent.progressUpdated.rawValue, "progressUpdated")
    }

    func testEngineEventCodableRoundTrip() throws {
        for event in EngineEvent.allCases {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(EngineEvent.self, from: data)
            XCTAssertEqual(decoded, event)
        }
    }

    func testEngineEventUnknownDecodeFails() {
        let junk = Data("\"torrentFinished\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EngineEvent.self, from: junk))
        XCTAssertNil(EngineEvent(rawValue: "error"))
    }

    // MARK: - IPCEnvelope

    func testEnvelopeRoundTripHappy() throws {
        let envelope = IPCEnvelope(
            version: .current,
            type: EngineCommand.hello.rawValue,
            payload: "ping"
        )
        XCTAssertTrue(envelope.isCompatibleWithCurrent)
        XCTAssertEqual(envelope.version, .current)
        XCTAssertEqual(envelope.type, "hello")
        XCTAssertEqual(envelope.payload, "ping")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope<String>.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeWithCommandPayload() throws {
        let envelope = IPCEnvelope(
            version: .current,
            type: "command",
            payload: EngineCommand.getCounter
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope<EngineCommand>.self, from: data)
        XCTAssertEqual(decoded.payload, .getCounter)
        XCTAssertTrue(decoded.isCompatibleWithCurrent)
    }

    func testEnvelopeWithEventPayload() throws {
        let envelope = IPCEnvelope(
            version: .current,
            type: EngineEvent.progressUpdated.rawValue,
            payload: EngineEvent.progressUpdated
        )
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope<EngineEvent>.self, from: data)
        XCTAssertEqual(decoded, envelope)
    }

    func testEnvelopeVersionCheckIncompatibleMajor() {
        let incompatible = IPCEnvelope(
            version: IPCVersion(major: 99, minor: 0),
            type: EngineCommand.health.rawValue,
            payload: "x"
        )
        XCTAssertFalse(incompatible.isCompatibleWithCurrent)
    }

    func testEnvelopeTamperedPayloadDecodeFails() {
        // Valid outer shape but wrong payload type → decode fail.
        let tampered = Data(
            #"{"version":{"major":1,"minor":0},"type":"hello","payload":{"nested":true}}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCEnvelope<String>.self, from: tampered)
        )
    }

    func testEnvelopeMissingVersionDecodeFails() {
        let missing = Data(#"{"type":"hello","payload":"ping"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCEnvelope<String>.self, from: missing)
        )
    }

    func testEnvelopeGarbageJSONDecodeFails() {
        let garbage = Data("not-json-at-all".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCEnvelope<String>.self, from: garbage)
        )
        let empty = Data()
        XCTAssertThrowsError(
            try JSONDecoder().decode(IPCEnvelope<String>.self, from: empty)
        )
    }

    func testEnvelopeFuzzTruncatedJSON() {
        let full = try! JSONEncoder().encode(
            IPCEnvelope(version: .current, type: "hello", payload: "ping")
        )
        // Truncate mid-stream — decoder must fail, not crash.
        for cut in [1, 3, 8, full.count / 2, max(1, full.count - 2)] {
            let slice = full.prefix(cut)
            XCTAssertThrowsError(
                try JSONDecoder().decode(IPCEnvelope<String>.self, from: Data(slice)),
                "expected fail at cut=\(cut)"
            )
        }
    }

    func testEnvelopeConcurrentEncodeDecodeStress() {
        let sample = IPCEnvelope(
            version: .current,
            type: EngineCommand.increment.rawValue,
            payload: 42
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let counter = ConcurrentFailureCounter()
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            do {
                let data = try encoder.encode(sample)
                let decoded = try decoder.decode(IPCEnvelope<Int>.self, from: data)
                if decoded != sample {
                    counter.increment()
                }
                if !decoded.isCompatibleWithCurrent {
                    counter.increment()
                }
            } catch {
                counter.increment()
            }
        }
        XCTAssertEqual(counter.value, 0)
    }

    // MARK: - TestProfile

    func testProfileIsolation() {
        XCTAssertFalse(
            profile.rootURL.path.contains(TestProfile.productionAppSupportMarker)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.rootURL.path))
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
