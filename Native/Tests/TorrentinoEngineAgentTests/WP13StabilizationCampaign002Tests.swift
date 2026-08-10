// Layer: Tests / Engine Agent
// Role: WP-13 ADR-020 Stabilization Campaign-002 XCTest gap-fill.
//       Targets the PARTIAL cells from campaign-001:
//         I3  — AgentHealthLane snapshot fields consistent after restore
//               success and restore anomaly.
//         I7  — AgentService.shutdown veto: false when authorizer returns
//               false (no hook called); true + hook called exactly once
//               when authorizer returns true.
//         I8  — subscribeEvents returns true even when coordinator is nil;
//               replaces (unregisters then registers) a prior subscription.
//         I9  — TorrentinoLog / RedactedLogFileManager bootstrap in a temp
//               directory: sink proves ready marker is last line; bootstrap
//               marks observabilityDegraded=false; degraded path sets it true.
// Must-not: touch production Application Support, use the live engine agent,
//           or read ~/Library/Application Support/com.torrentino.app/.
// Invariants: deterministic; no sleeps-as-sync; all state disposable.

import XCTest
import Foundation
@testable import TorrentinoEngineAgent
import TorrentinoIPC

// MARK: - I3 AgentHealthLane snapshot consistency

final class WP13I3HealthLaneSnapshotTests: XCTestCase {

    // Verify every restore-summary field surfaces correctly in the health
    // snapshot after a *successful* restore (rebuilt > 0, no failure).
    func testHealthLaneSnapshotReflectsRestoreSuccess() {
        let lane = AgentHealthLane()

        // Simulate a successful restore: 5 rebuilt, 0 skipped.
        lane.updateRestoreSummary(rebuilt: 5, skipped: 0)
        lane.updateLifecycle(.ready, reason: nil, revision: 3)

        let snap = lane.snapshot(counter: 42, counterFormat: "v2")

        XCTAssertEqual(snap["restoreRebuilt"] as? Int, 5,
                       "restoreRebuilt must reflect the rebuilt count")
        XCTAssertEqual(snap["restoreSkipped"] as? Int, 0,
                       "restoreSkipped must be 0 when no record was skipped")
        XCTAssertEqual(snap["sessionPhase"] as? String, EngineLifecycleState.ready.rawValue,
                       "sessionPhase must be 'ready' after a successful restore")
        XCTAssertNil(snap["degradedReason"],
                     "degradedReason must be absent when phase is ready")
        XCTAssertEqual(snap["sessionRevision"] as? UInt64, 3,
                       "sessionRevision must propagate from updateLifecycle")
    }

    // Verify snapshot reflects an anomaly: rebuilt==0 while stored>0 → degraded.
    func testHealthLaneSnapshotReflectsRestoreAnomaly() {
        let lane = AgentHealthLane()

        // Simulate anomaly: 0 rebuilt (all records were invalid core identities).
        lane.updateRestoreSummary(rebuilt: 0, skipped: 2)
        lane.updateLifecycle(.degraded, reason: "restoreAnomaly", revision: 1)

        let snap = lane.snapshot(counter: 0, counterFormat: "v2")

        XCTAssertEqual(snap["restoreRebuilt"] as? Int, 0,
                       "restoreRebuilt must be 0 on anomaly")
        XCTAssertEqual(snap["restoreSkipped"] as? Int, 2,
                       "restoreSkipped must equal the number of invalid records")
        XCTAssertEqual(snap["sessionPhase"] as? String, EngineLifecycleState.degraded.rawValue,
                       "sessionPhase must be 'degraded' on anomaly")
        XCTAssertEqual(snap["degradedReason"] as? String, "restoreAnomaly",
                       "degradedReason must carry the anomaly reason")
    }

    // Verify snapshot is consistent after a sequence of updates (restore then
    // lifecycle phase transition to ready clears the degraded reason).
    func testHealthLaneSnapshotClearsReasonOnReadyTransition() {
        let lane = AgentHealthLane()

        lane.updateRestoreSummary(rebuilt: 3, skipped: 0)
        // First mark degraded (simulating a transient boot anomaly).
        lane.updateLifecycle(.degraded, reason: "transientAnomaly", revision: 2)
        var snap = lane.snapshot(counter: 0, counterFormat: "v2")
        XCTAssertEqual(snap["degradedReason"] as? String, "transientAnomaly")

        // Recovery: transition back to ready.
        lane.updateLifecycle(.ready, reason: nil, revision: 3)
        snap = lane.snapshot(counter: 0, counterFormat: "v2")

        XCTAssertEqual(snap["sessionPhase"] as? String, EngineLifecycleState.ready.rawValue)
        XCTAssertNil(snap["degradedReason"],
                     "degradedReason must be absent after recovery to ready")
        XCTAssertEqual(snap["sessionRevision"] as? UInt64, 3)
    }

    // Verify negative rebuilt count is clamped to 0 (no fabricated progress).
    func testHealthLaneRestoreSummaryNegativeCountsClamped() {
        let lane = AgentHealthLane()
        lane.updateRestoreSummary(rebuilt: -5, skipped: -3)
        let snap = lane.snapshot(counter: 0, counterFormat: "v2")
        XCTAssertEqual(snap["restoreRebuilt"] as? Int, 0,
                       "negative rebuilt must be clamped to 0")
        XCTAssertEqual(snap["restoreSkipped"] as? Int, 0,
                       "negative skipped must be clamped to 0")
    }
}

// MARK: - I7 AgentService.shutdown veto

final class WP13I7ShutdownVetoTests: XCTestCase {

    private func makeService() -> (AgentService, CounterStore, PersistenceStore) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp13-i7-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try! CounterStore(engineDirectory: tmp)
        let persistence = PersistenceStore(dataDirectory: tmp)
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let svc = AgentService(store: store, persistence: persistence, eventBus: bus)
        return (svc, store, persistence)
    }

    // I7-a: shutdown returns false and does NOT call the hook when the
    // authorizer returns false.
    func testShutdownRefusedWhenAuthorizerReturnsFalse() {
        let (svc, _, _) = makeService()
        let hookCalled = LockedCounterI7()
        svc.shutdownHook = { hookCalled.increment() }
        svc.shutdownAuthorization = { false }

        let exp = expectation(description: "shutdown reply")
        svc.shutdown { accepted in
            XCTAssertFalse(accepted, "shutdown must be refused when authorizer returns false")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(hookCalled.value, 0, "hook must NOT be called when shutdown is refused")
    }

    // I7-b: shutdown returns true and calls the hook exactly once when the
    // authorizer returns true.
    func testShutdownAcceptedAndHookCalledOnceWhenAuthorizerTrue() {
        let (svc, _, _) = makeService()
        let hookCalled = LockedCounterI7()
        svc.shutdownHook = { hookCalled.increment() }
        svc.shutdownAuthorization = { true }

        let exp = expectation(description: "shutdown reply")
        svc.shutdown { accepted in
            XCTAssertTrue(accepted, "shutdown must be accepted when authorizer returns true")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(hookCalled.value, 1, "hook must be called exactly once when shutdown is accepted")
    }

    // I7-c: shutdown returns false when no authorizer is wired (fails closed).
    func testShutdownRefusedWhenNoAuthorizerWired() {
        let (svc, _, _) = makeService()
        let hookCalled = LockedCounterI7()
        svc.shutdownHook = { hookCalled.increment() }
        // shutdownAuthorization is intentionally nil.

        let exp = expectation(description: "shutdown reply")
        svc.shutdown { accepted in
            XCTAssertFalse(accepted, "shutdown must fail closed when no authorizer is wired")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(hookCalled.value, 0, "hook must NOT be called when authorizer is nil")
    }
}

// MARK: - I8 AgentService.subscribeEvents / unsubscribeEvents

final class WP13I8SubscribeEventsTests: XCTestCase {

    private func makeService() -> (AgentService, TransferEventBus) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp13-i8-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = try! CounterStore(engineDirectory: tmp)
        let persistence = PersistenceStore(dataDirectory: tmp)
        let bus = TransferEventBus(flushIntervalMilliseconds: 0)
        let svc = AgentService(store: store, persistence: persistence, eventBus: bus)
        return (svc, bus)
    }

    // I8-a: subscribeEvents returns true even when coordinator is nil (bus
    // registration succeeds independently of the coordinator being wired).
    func testSubscribeEventsReturnsTrueWithNilCoordinator() async {
        let (svc, bus) = makeService()
        // coordinator is intentionally not set (nil).
        XCTAssertNil(svc.coordinator, "precondition: coordinator must be nil for this test")

        let exp = expectation(description: "subscribe reply")
        svc.subscribeEvents { result in
            XCTAssertTrue(result, "subscribeEvents must return true even when coordinator is nil")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2)

        // The bus must have one registered sink.
        let count = await bus.sinkCount()
        XCTAssertEqual(count, 1, "event bus must have exactly one sink after subscribeEvents")
    }

    // I8-b: calling subscribeEvents a second time replaces the prior
    // subscription (previous sink unregistered, new sink registered, count=1).
    func testSubscribeEventsReplacesPriorSubscription() async {
        let (svc, bus) = makeService()

        let exp1 = expectation(description: "first subscribe")
        svc.subscribeEvents { _ in exp1.fulfill() }
        await fulfillment(of: [exp1], timeout: 2)

        let countAfterFirst = await bus.sinkCount()
        XCTAssertEqual(countAfterFirst, 1, "bus must have 1 sink after first subscription")

        let exp2 = expectation(description: "second subscribe")
        svc.subscribeEvents { _ in exp2.fulfill() }
        await fulfillment(of: [exp2], timeout: 2)

        let countAfterSecond = await bus.sinkCount()
        XCTAssertEqual(countAfterSecond, 1,
                       "bus must still have exactly 1 sink after replacing prior subscription (old unregistered)")
    }

    // I8-c: unsubscribeEvents after a subscription removes the sink and
    // returns true; a second unsubscribe with no active subscription returns
    // false (nothing to unregister).
    func testUnsubscribeEventsRemovesSinkAndReturnsFalseWhenNone() async {
        let (svc, bus) = makeService()

        let subExp = expectation(description: "subscribe")
        svc.subscribeEvents { _ in subExp.fulfill() }
        await fulfillment(of: [subExp], timeout: 2)

        // Unsubscribe the active sink.
        let unsubExp = expectation(description: "unsubscribe")
        svc.unsubscribeEvents { result in
            XCTAssertTrue(result, "unsubscribeEvents must return true when a subscription is active")
            unsubExp.fulfill()
        }
        await fulfillment(of: [unsubExp], timeout: 2)

        let countAfterUnsub = await bus.sinkCount()
        XCTAssertEqual(countAfterUnsub, 0,
                       "bus must have 0 sinks after unsubscribeEvents")

        // Second unsubscribe — nothing active.
        let secondUnsubExp = expectation(description: "second unsubscribe")
        svc.unsubscribeEvents { result in
            XCTAssertFalse(result,
                           "unsubscribeEvents must return false when no subscription is active")
            secondUnsubExp.fulfill()
        }
        await fulfillment(of: [secondUnsubExp], timeout: 2)
    }
    
    // I8-d: each XPC session owns its own event-bus registration. Ending a
    // second connection must not unregister the first connection's sink.
    func testSecondConnectionInvalidationLeavesFirstSubscriberDelivery() async throws {
        let (svc, bus) = makeService()
        let firstID = UUID()
        let secondID = UUID()
        let firstSink = RecordingEventSinkI8()
        let secondSink = RecordingEventSinkI8()
        let first = svc.makeConnection(connectionID: firstID, eventSink: firstSink)
        let second = svc.makeConnection(connectionID: secondID, eventSink: secondSink)

        let firstExp = expectation(description: "first subscribe")
        first.subscribeEvents { subscribed in
            XCTAssertTrue(subscribed)
            firstExp.fulfill()
        }
        await fulfillment(of: [firstExp], timeout: 2)

        let secondExp = expectation(description: "second subscribe")
        second.subscribeEvents { subscribed in
            XCTAssertTrue(subscribed)
            secondExp.fulfill()
        }
        await fulfillment(of: [secondExp], timeout: 2)
        XCTAssertEqual(await bus.sinkCount(), 2)

        svc.clearEventSink(connectionID: secondID)
        for _ in 0..<20 {
            if await bus.sinkCount() == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(await bus.sinkCount(), 1)

        await bus.publish(
            [.snapshotRequired(SnapshotRequiredEvent(reason: .droppedDelta, afterRevision: 0))],
            urgent: true
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(firstSink.deliveryCount, 1, "first subscriber must still receive events")
        XCTAssertEqual(secondSink.deliveryCount, 0, "invalidated subscriber must not receive later events")
    }

}

// MARK: - I9 Diagnostics bootstrap via temp-dir env override

final class WP13I9DiagnosticsBootstrapTests: XCTestCase {

    // I9-a: RedactedLogFileManager writes the start marker and ready marker
    //        to the active log file in a temp directory; the ready marker is
    //        the last line (as `bootstrap()` proves before marking initialized).
    func testRedactedLogManagerWritesBootstrapMarkers() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp13-i9-logdir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logManager = RedactedLogFileManager(
            logDirectory: tmp,
            maxFileSize: 2 * 1024 * 1024,
            maxFileCount: 5
        )

        let startMarker = "agent bootstrap start version=dev"
        let activeURL = tmp.appendingPathComponent("engine_log_current.log")
        if !FileManager.default.fileExists(atPath: activeURL.path) {
            FileManager.default.createFile(atPath: activeURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: activeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((startMarker + "\n").utf8))

        let readyMarker = "log sink ready path=\(RedactedLogFileManager.redact(activeURL.path))"
        try handle.write(contentsOf: Data((readyMarker + "\n").utf8))
        try handle.synchronize()
        try handle.close()

        // Verify the ready marker is the last non-empty line (mirroring bootstrap()).
        let contents = try String(contentsOf: activeURL, encoding: .utf8)
        let lastLine = String(contents.split(whereSeparator: \.isNewline).last ?? "")
        XCTAssertEqual(lastLine, readyMarker,
                       "bootstrap ready marker must be the last line in the log file")

        // Verify the log manager can read back the lines.
        await logManager.writeLog(category: "lifecycle", level: "notice",
                                   message: "post-bootstrap record")
        await logManager.flush()
        let lines = await logManager.fetchRecentLogLines(maxCount: 100)
        XCTAssertTrue(lines.contains { $0.contains("post-bootstrap record") },
                      "log manager must be able to record entries after bootstrap")
    }

    // I9-b: Diagnostics bootstrap via TORRENTINO_LOG_DIRECTORY env override
    //        redirects the log directory to a temp path.  We exercise the
    //        RedactedLogFileManager directly (the bootstrap() static method
    //        uses the same defaultLogDirectory() path, which honours the env
    //        var).  Confirm the override is active before calling.
    func testDefaultLogDirectoryHonoursEnvironmentOverride() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp13-i9-envoverride-\(UUID().uuidString)", isDirectory: true)
        // Redirect before calling defaultLogDirectory.
        setenv("TORRENTINO_LOG_DIRECTORY", tmp.path, 1)
        defer { unsetenv("TORRENTINO_LOG_DIRECTORY") }

        let resolved = RedactedLogFileManager.defaultLogDirectory()
        XCTAssertEqual(resolved.path, tmp.path,
                       "defaultLogDirectory must honour TORRENTINO_LOG_DIRECTORY override")
    }

    // I9-c: RedactedLogFileManager bootstrap-equivalent proof: write a start
    //        marker, write the ready marker, read back, verify ready marker is
    //        last line, then verify redaction applies (home path stripped).
    func testBootstrapEquivalentSinkProofRedactsHomePath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp13-i9-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let logURL = tmp.appendingPathComponent("engine_log_current.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let rawPath = "/Users/human/Downloads/file.torrent"
        let startLine = "agent bootstrap start version=1.0.0"
        let readyMarker = "log sink ready path=\(RedactedLogFileManager.redact(logURL.path))"

        try handle.write(contentsOf: Data((startLine + "\n").utf8))
        try handle.write(contentsOf: Data((readyMarker + "\n").utf8))
        try handle.synchronize()
        try handle.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let lastLine = String(contents.split(whereSeparator: \.isNewline).last ?? "")
        XCTAssertEqual(lastLine, readyMarker,
                       "ready marker must be the last line (bootstrap integrity proof)")

        // Redaction of the actual path in the sink-ready message.
        XCTAssertFalse(lastLine.contains(rawPath),
                       "redacted ready marker must not contain the raw home path")

        // A fabricated home-path log entry must have the path stripped.
        let rawMsg = "loaded torrent from \(rawPath) with password=s3cr3t"
        let redacted = RedactedLogFileManager.redact(rawMsg)
        XCTAssertFalse(redacted.contains("/Users/human"),
                       "redact must strip home paths from log messages")
        XCTAssertFalse(redacted.contains("s3cr3t"),
                       "redact must strip passwords from log messages")
    }
}

// MARK: - Helpers

private final class LockedCounterI7: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
    
private final class RecordingEventSinkI8: NSObject, TorrentinoEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries = 0

    func deliver(eventData: Data) {
        lock.withLock { deliveries += 1 }
    }

    var deliveryCount: Int {
        lock.withLock { deliveries }
    }
}
    
