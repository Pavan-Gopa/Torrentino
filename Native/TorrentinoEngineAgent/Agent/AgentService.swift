// Layer: Agent XPC surface.
// Role: implements TorrentinoEngineXPCProtocol over CounterStore + a shutdown
// hook owned by AgentRuntime.
// Must-not: block XPC queues with file IO, hold mutable state, or touch
// libtorrent (WP-04 replaces the counter with the real engine).
// Invariants: all state access goes through the CounterStore actor; each reply
// block is invoked exactly once; the shutdown ack is sent BEFORE exit begins.

import Foundation
import OSLog

final class AgentService: NSObject, TorrentinoEngineXPCProtocol, @unchecked Sendable {
    private let store: CounterStore
    /// Wired by AgentRuntime immediately after construction and never replaced
    /// (set-once). Kept settable so the runtime can inject a [weak self] hook
    /// AFTER its own stored properties are fully initialized (Swift phase-1
    /// init rule forbids capturing self inside its own property initializers).
    var shutdownHook: (@Sendable () -> Void)?
    private let startDate = Date()
    private let log = Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "xpc")

    init(store: CounterStore) {
        self.store = store
    }

    func hello(reply: @escaping @Sendable (String, Int64) -> Void) {
        let pid = Int64(ProcessInfo.processInfo.processIdentifier)
        log.notice("hello from ui pid=\(pid)")
        reply(AgentRuntime.agentVersion, pid)
    }

    func health(reply: @escaping @Sendable ([String: Any]) -> Void) {
        let store = store
        let started = startDate
        let format = store.formatName
        Task {
            let counter = await store.current()
            let uptime = Date().timeIntervalSince(started)
            reply([
                "agentVersion": AgentRuntime.agentVersion,
                "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                "uptimeSeconds": NSNumber(value: uptime),
                "counter": NSNumber(value: counter),
                "counterFormat": format,
                "machService": TorrentinoXPCSecurity.machServiceName,
            ])
        }
    }

    func incrementCounter(reply: @escaping @Sendable (Int64) -> Void) {
        let store = store
        Task {
            do {
                let newValue = try await store.increment()
                reply(newValue)
            } catch {
                // Persistence failed: report the sentinel -1, keep serving.
                // The UI treats -1 as an error; the agent logs the cause.
                Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "xpc")
                    .error("increment failed: \(String(describing: error), privacy: .public)")
                reply(-1)
            }
        }
    }

    func getCounter(reply: @escaping @Sendable (Int64) -> Void) {
        let store = store
        Task {
            reply(await store.current())
        }
    }

    func shutdown(reply: @escaping @Sendable (Bool) -> Void) {
        log.notice("shutdown requested via xpc; acking then stopping")
        // Ack first: the runtime delays exit long enough for this reply to be
        // drained by the client connection.
        reply(true)
        shutdownHook?()
    }
}
