// Layer: UI app delegate (AppKit bridge).
// Role: bounded termination deferral for Cmd+Q / quit per LIFECYCLE_CONTRACT.md
// §6: ask the agent to stop, wait at most 5s for the ack, then terminate.
// Must-not: terminate before answering applicationShouldTerminate, wait longer
// than the 5s budget, or run engine IO synchronously on the main thread.
// Invariants: always replies to applicationShouldTerminate; agent shutdown is
// best-effort — UI termination is never held beyond the timeout (ADR-004).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hard cap for the agent shutdown ack (plan §8.4: <= 5s).
    static let terminationAckTimeout: TimeInterval = 5.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppContext.shared.refreshServiceStatus()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let viewModel = AppContext.shared
        viewModel.appendLog("quit requested — asking engine agent for bounded shutdown (5s)")
        Task { @MainActor in
            let acknowledged = await TerminationCoordinator.requestAgentShutdown(
                client: viewModel.client,
                timeout: AppDelegate.terminationAckTimeout)
            viewModel.appendLog(acknowledged
                ? "agent acknowledged shutdown — terminating"
                : "agent did not acknowledge within 5s — terminating anyway")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Bounded "ask the agent to stop" used by the quit path.
enum TerminationCoordinator {
    static func requestAgentShutdown(client: EngineClient, timeout: TimeInterval) async -> Bool {
        do {
            return try await withTimeout(seconds: timeout) {
                try await client.shutdown()
            }
        } catch {
            return false
        }
    }
}

/// Thrown by withTimeout when the deadline task wins the race.
struct DeadlineExceeded: Error, CustomStringConvertible {
    var description: String { "deadline exceeded" }
}

/// Races an operation against a wall-clock deadline; the loser is cancelled.
/// Used to keep the UI quit path bounded no matter what the agent does.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded()
        }
        guard let first = try await group.next() else { throw DeadlineExceeded() }
        group.cancelAll()
        return first
    }
}
