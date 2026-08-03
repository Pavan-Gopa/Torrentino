// Layer: Agent XPC surface.
// Role: implements TorrentinoEngineXPCProtocol over CounterStore + a shutdown
// hook owned by AgentRuntime. WP-07 adds the v1 command lane (sendCommand →
// TransferCoordinator) and the event stream subscription (subscribeEvents →
// TransferEventBus) with the client-side TorrentinoEventSink as the single
// delivery endpoint.
// Must-not: block XPC queues with file IO, hold mutable state, or touch
// libtorrent (all engine work happens inside the coordinator/bridge actors).
// Invariants: all state access goes through the CounterStore/PersistenceStore
// actors; each reply block is invoked exactly once; the shutdown ack is sent
// BEFORE exit begins; WP-06 persistence health (state/clean flag/degraded/
// quarantine) is exposed as extra plist-only keys in health() and never
// blocks the XPC queue.

import Foundation
import OSLog
import TorrentinoIPC

final class AgentService: NSObject, TorrentinoEngineXPCProtocol, @unchecked Sendable {
    /// IPC command catalog version for diagnostics (wire schema lives in TorrentinoIPC).
    private static let ipcSchemaVersion = IPCVersion.current
    private let store: CounterStore
    private let persistence: PersistenceStore
    let healthLane: AgentHealthLane
    /// Wired by AgentRuntime immediately after construction and never replaced
    /// (set-once). Kept settable so the runtime can inject a [weak self] hook
    /// AFTER its own stored properties are fully initialized (Swift phase-1
    /// init rule forbids capturing self inside its own property initializers).
    var shutdownHook: (@Sendable () -> Void)?
    /// WP-07: the transfer coordinator + event bus, wired by AgentRuntime once
    /// the persistence store is open. Nil while booting: sendCommand answers
    /// with a typed engineNotReady fault envelope.
    var coordinator: TransferCoordinator?
    var eventBus: TransferEventBus?
    private let log = Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "xpc")
    /// Single active event sink (the UI process). Guarded by sinkLock.
    private let sinkLock = NSLock()
    private var eventSink: TorrentinoEventSink?
    private var busSinkID: UUID?

    init(store: CounterStore, persistence: PersistenceStore, healthLane: AgentHealthLane = AgentHealthLane()) {
        self.store = store
        self.persistence = persistence
        self.healthLane = healthLane
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
        let lane = healthLane
        let format = store.formatName
        let serverRange = Handshake.serverSupportedRange
        Task {
            let counter = await store.current()
            // Extra keys (e.g. protocolRange) are ignored by AgentHealth; keep
            // required keys stable. protocolRange advertises the agent's
            // supported protocol for the WP-05 handshake negotiation.
            var payload = lane.snapshot(counter: counter, counterFormat: format)
            payload.merge([
                "agentVersion": AgentRuntime.agentVersion,
                "pid": NSNumber(value: ProcessInfo.processInfo.processIdentifier),
                "machService": TorrentinoXPCSecurity.machServiceName,
                "ipcVersion": Self.ipcSchemaVersion.description,
                "protocolRange": "\(serverRange.lowerBound)...\(serverRange.upperBound)",
            ]) { _, new in new }
            reply(payload)
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

    // MARK: - WP-07 command lane

    func sendCommand(commandData: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let coordinator = coordinator else {
            reply(Self.faultEnvelope(EngineFault.engineNotReady(details: "agent booting")))
            return
        }
        guard healthLane.tryBeginCommand() else {
            reply(Self.faultEnvelope(.resourceLimitExceeded(resource: "command_lane", limit: AgentHealthLane.commandLimit)))
            return
        }
        Task {
            defer { healthLane.endCommand() }
            reply(await coordinator.processCommand(commandData))
        }
    }

    func subscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
        let bus = eventBus
        let id = UUID()
        sinkLock.lock()
        let previousID = busSinkID
        busSinkID = id
        sinkLock.unlock()
        Task {
            guard let bus else {
                sinkLock.withLock { busSinkID = nil }
                reply(false)
                return
            }
            if let previousID {
                await bus.unregister(id: previousID)
            }
            await bus.register(TransferEventBus.Sink(id: id) { [weak self] events in
                await self?.deliver(events)
            })
            reply(true)
        }
    }

    func unsubscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
        sinkLock.lock()
        let id = busSinkID
        busSinkID = nil
        sinkLock.unlock()
        guard let bus = eventBus, let id else {
            reply(false)
            return
        }
        Task {
            await bus.unregister(id: id)
            reply(true)
        }
    }

    /// Replaces the connection-side sink (called by the listener on accept)
    /// or clears it (called on interruption/invalidation).
    func setEventSink(_ sink: TorrentinoEventSink?) {
        sinkLock.lock()
        eventSink = sink
        sinkLock.unlock()
    }

    private func deliver(_ events: [EngineEventV1]) async {
        let sink = sinkLock.withLock { eventSink }
        guard let sink else { return }
        let envelopes = events.map { IPCEnvelope.event($0) }
        guard let data = try? JSONEncoder().encode(envelopes) else { return }
        sink.deliver(eventData: data)
    }

    /// Serialized failure envelope for the booting window (before the
    /// coordinator exists).
    private static func faultEnvelope(_ fault: EngineFault) -> Data {
        let envelope = IPCEnvelope.result(requestID: RequestID(), result: .failure(fault))
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }
}

/// Small lock-backed health state shared by the XPC health lane and the agent
/// workers. It deliberately has no file/network/engine calls, so health stays
/// responsive while the heavy command lane is blocked or faulting.
final class AgentHealthLane: @unchecked Sendable, EngineHealthReporter {
    static let commandLimit = 64

    private let lock = NSLock()
    private let startedAt = Date()
    private var conditions = SystemConditions.normal
    private var commandInFlight = 0
    private var eventQueueDepth = 0
    private var engineTicks: UInt64 = 0
    private var engineFailures: UInt64 = 0
    private var lastEngineTick: Date?
    private var lastCheckpoint: Date?
    private var persistenceState = "unopened"
    private var persistenceDegraded = false
    private var cleanShutdown = false
    private var quarantined = 0
    private var reconciliation = "none"
    private var safeRecovery = false

    func tryBeginCommand() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard commandInFlight < Self.commandLimit else { return false }
        commandInFlight += 1
        return true
    }

    func endCommand() {
        lock.lock()
        commandInFlight = max(0, commandInFlight - 1)
        lock.unlock()
    }

    func noteEngineTick() {
        lock.lock()
        engineTicks += 1
        lastEngineTick = Date()
        lock.unlock()
    }

    func noteEngineFailure() {
        lock.lock()
        engineFailures += 1
        lock.unlock()
    }

    func updateSystemConditions(_ conditions: SystemConditions) {
        lock.lock()
        self.conditions = conditions
        lock.unlock()
    }

    func updateEventQueueDepth(_ depth: Int) {
        lock.lock()
        eventQueueDepth = max(0, depth)
        lock.unlock()
    }

    func updatePersistence(_ health: PersistenceHealthSnapshot) {
        lock.lock()
        persistenceState = health.state
        persistenceDegraded = health.degraded
        cleanShutdown = health.cleanShutdown
        quarantined = health.quarantinedCount
        reconciliation = health.reconciliation
        lock.unlock()
    }

    func updatePersistenceFailure() {
        lock.lock()
        persistenceState = "degraded"
        persistenceDegraded = true
        lock.unlock()
    }

    func markCheckpoint() {
        lock.lock()
        lastCheckpoint = Date()
        lock.unlock()
    }

    func markSafeRecovery(_ enabled: Bool) {
        lock.lock()
        safeRecovery = enabled
        lock.unlock()
    }

    func snapshot(counter: Int64, counterFormat: String) -> [String: Any] {
        lock.lock()
        let conditions = self.conditions
        let payload: [String: Any] = [
            "uptimeSeconds": NSNumber(value: Date().timeIntervalSince(startedAt)),
            "counter": NSNumber(value: counter),
            "counterFormat": counterFormat,
            "persistenceState": persistenceState,
            "cleanShutdown": NSNumber(value: cleanShutdown),
            "degraded": NSNumber(value: persistenceDegraded),
            "quarantined": NSNumber(value: quarantined),
            "reconciliation": reconciliation,
            "healthLane": "liveness",
            "commandInFlight": NSNumber(value: commandInFlight),
            "commandLimit": NSNumber(value: Self.commandLimit),
            "eventQueueDepth": NSNumber(value: eventQueueDepth),
            "engineTicks": NSNumber(value: engineTicks),
            "engineFailures": NSNumber(value: engineFailures),
            "lastEngineTick": NSNumber(value: lastEngineTick?.timeIntervalSince1970 ?? 0),
            "lastCheckpoint": NSNumber(value: lastCheckpoint?.timeIntervalSince1970 ?? 0),
            "watchdog": "disabled",
            "safeRecovery": NSNumber(value: safeRecovery),
            "network": conditions.network.rawValue,
            "networkGeneration": NSNumber(value: conditions.networkGeneration),
            "thermal": conditions.thermal.rawValue,
            "memoryPressure": conditions.memoryPressure.rawValue,
            "lowPower": NSNumber(value: conditions.lowPower),
            "sleeping": NSNumber(value: conditions.sleeping),
        ]
        lock.unlock()
        return payload
    }
}
