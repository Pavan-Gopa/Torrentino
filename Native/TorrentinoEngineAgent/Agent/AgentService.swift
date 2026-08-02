// Layer: Agent XPC surface.
// Role: implements TorrentinoEngineXPCProtocol over CounterStore + a shutdown
// hook owned by AgentRuntime.
// Must-not: block XPC queues with file IO, hold mutable state, or touch
// libtorrent (WP-04 replaces the counter with the real engine).
// Invariants: all state access goes through the CounterStore actor; each reply
// block is invoked exactly once; the shutdown ack is sent BEFORE exit begins.

import Foundation
import OSLog
import TorrentinoIPC

final class AgentService: NSObject, TorrentinoEngineXPCProtocol, @unchecked Sendable {
    /// IPC command catalog version for diagnostics (wire schema lives in TorrentinoIPC).
    private static let ipcSchemaVersion = IPCVersion.current
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
        // §7.4 handshake: the agent advertises its supported protocol via
        // health() (ipcVersion + protocolRange); the CLIENT negotiates its own
        // supported range against that advertisement (WP-05 Handshake). The
        // frozen ObjC reply shape only carries app version + pid.
        reply(AgentRuntime.agentVersion, pid)
    }

    func health(reply: @escaping @Sendable ([String: Any]) -> Void) {
        let store = store
        let started = startDate
        let format = store.formatName
        let serverRange = Handshake.serverSupportedRange
        Task {
            let counter = await store.current()
            let uptime = Date().timeIntervalSince(started)
            // Extra keys (e.g. protocolRange) are ignored by AgentHealth; keep
            // required keys stable. protocolRange advertises the agent's
            // supported protocol for the WP-05 handshake negotiation.
            reply([
                "agentVersion": AgentRuntime.agentVersion,
                "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                "uptimeSeconds": NSNumber(value: uptime),
                "counter": NSNumber(value: counter),
                "counterFormat": format,
                "machService": TorrentinoXPCSecurity.machServiceName,
                "ipcVersion": Self.ipcSchemaVersion.description,
                "protocolRange": "\(serverRange.lowerBound)...\(serverRange.upperBound)",
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
