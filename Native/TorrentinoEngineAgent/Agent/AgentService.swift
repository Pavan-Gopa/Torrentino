// Layer: Agent XPC surface.
// Role: implements TorrentinoEngineXPCProtocol over CounterStore + a shutdown
// hook owned by AgentRuntime. WP-07 adds the v1 command lane (sendCommand →
// TransferCoordinator) and the event stream subscription (subscribeEvents →
// TransferEventBus). Each accepted XPC connection receives a small forwarding
// session so event subscriptions and sinks are scoped to that connection.
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
    /// ListenerDelegate owns the session connection count and supplies the
    /// last-UI veto. A missing authorizer fails closed.
    var shutdownAuthorization: (@Sendable () -> Bool)?
    /// WP-07: the transfer coordinator + event bus, wired by AgentRuntime once
    /// the persistence store is open. Nil while booting: sendCommand answers
    /// with a typed engineNotReady fault envelope.
    var coordinator: TransferCoordinator?
    private let eventBus: TransferEventBus
    private let log = TorrentinoLog.logger(category: "xpc")
    /// Event subscribers are keyed by the accepted XPC connection. A
    /// short-lived CLI connection therefore cannot replace or invalidate the
    /// GUI's sink. Guarded by sinkLock.
    private struct EventSubscriber {
        let busSinkID: UUID
        let sink: TorrentinoEventSink?
    }
    private let sinkLock = NSLock()
    private let legacyConnectionID = UUID()
    private var eventSubscribers: [UUID: EventSubscriber] = [:]
    /// Kept for source-compatible in-process callers that bind a sink before
    /// subscribing. Runtime XPC sessions pass their sink at subscribe time.
    private var pendingEventSinks: [UUID: TorrentinoEventSink] = [:]

    init(
        store: CounterStore,
        persistence: PersistenceStore,
        healthLane: AgentHealthLane = AgentHealthLane(),
        eventBus: TransferEventBus
    ) {
        self.store = store
        self.persistence = persistence
        self.healthLane = healthLane
        self.eventBus = eventBus
    }
    
    /// A connection-scoped exported object. NSXPC invokes methods on one
    /// exported object per accepted connection, which gives subscribe and
    /// unsubscribe an unambiguous connection identity without changing the
    /// frozen wire protocol.
    func makeConnection(connectionID: UUID, eventSink: TorrentinoEventSink?) -> TorrentinoEngineXPCProtocol {
        Connection(service: self, connectionID: connectionID, eventSink: eventSink)
    }

    private final class Connection: NSObject, TorrentinoEngineXPCProtocol, @unchecked Sendable {
        private let service: AgentService
        private let connectionID: UUID
        private let eventSink: TorrentinoEventSink?

        init(service: AgentService, connectionID: UUID, eventSink: TorrentinoEventSink?) {
            self.service = service
            self.connectionID = connectionID
            self.eventSink = eventSink
        }

        func hello(reply: @escaping @Sendable (String, Int64) -> Void) {
            service.hello(reply: reply)
        }

        func health(reply: @escaping @Sendable ([String: Any]) -> Void) {
            service.health(reply: reply)
        }

        func incrementCounter(reply: @escaping @Sendable (Int64) -> Void) {
            service.incrementCounter(reply: reply)
        }

        func getCounter(reply: @escaping @Sendable (Int64) -> Void) {
            service.getCounter(reply: reply)
        }

        func shutdown(reply: @escaping @Sendable (Bool) -> Void) {
            service.shutdown(reply: reply)
        }

        func sendCommand(commandData: Data, reply: @escaping @Sendable (Data) -> Void) {
            service.sendCommand(commandData: commandData, reply: reply)
        }

        func subscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
            service.subscribeEvents(
                connectionID: connectionID,
                sink: eventSink,
                reply: reply
            )
        }

        func unsubscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
            service.unsubscribeEvents(connectionID: connectionID, reply: reply)
        }
    }

    func hello(reply: @escaping @Sendable (String, Int64) -> Void) {
        let pid = Int64(ProcessInfo.processInfo.processIdentifier)
        log.notice("hello from ui pid=\(pid)")
        TorrentinoLog.record(
            category: "xpc",
            level: "info",
            message: "xpc connect hello pid=\(pid)"
        )
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
                TorrentinoLog.logger(category: "xpc")
                    .error("increment failed: \(TorrentinoLog.redactedDescription(error))")
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
        guard shutdownAuthorization?() == true else {
            log.warning("shutdown refused: another UI connection is active")
            TorrentinoLog.record(category: "lifecycle", level: "warning", message: "command shutdown refused activeConnections>1")
            reply(false)
            return
        }
        log.notice("shutdown requested via xpc; acking then stopping")
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "command shutdown start acknowledged=true")
        // Ack first: the runtime delays exit long enough for this reply to be
        // drained by the client connection.
        reply(true)
        shutdownHook?()
    }

    // MARK: - WP-07 command lane

    func sendCommand(commandData: Data, reply: @escaping @Sendable (Data) -> Void) {
        let commandName = Self.commandName(from: commandData)
        TorrentinoLog.record(category: "xpc", level: "info", message: "command start name=\(commandName)")
        guard let coordinator = coordinator else {
            TorrentinoLog.record(category: "xpc", level: "warning", message: "command complete name=\(commandName) result=engineNotReady")
            reply(Self.faultEnvelope(EngineFault.engineNotReady(details: "agent booting")))
            return
        }
        guard healthLane.tryBeginCommand() else {
            TorrentinoLog.record(category: "xpc", level: "warning", message: "command complete name=\(commandName) result=commandLaneFull")
            reply(Self.faultEnvelope(.resourceLimitExceeded(resource: "command_lane", limit: AgentHealthLane.commandLimit)))
            return
        }
        Task {
            defer { healthLane.endCommand() }
            let result = await coordinator.processCommand(commandData)
            TorrentinoLog.record(
                category: "xpc",
                level: "info",
                message: "command complete name=\(commandName) result=\(Self.resultClass(from: result))"
            )
            reply(result)
        }
    }

    func subscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
        subscribeEvents(connectionID: legacyConnectionID, sink: nil, reply: reply)
    }

    /// Registers one event-bus sink for one accepted XPC connection. The
    /// remote sink is intentionally consumed here, not during listener
    /// acceptance, so CLI health/snapshot connections never become event
    /// subscribers unless they explicitly opt in.
    func subscribeEvents(
        connectionID: UUID,
        sink: TorrentinoEventSink?,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        TorrentinoLog.record(category: "xpc", level: "info", message: "event subscription start")
        let id = UUID()
        let previousID: UUID?
        sinkLock.lock()
        let boundSink = sink ?? pendingEventSinks[connectionID]
        pendingEventSinks.removeValue(forKey: connectionID)
        previousID = eventSubscribers[connectionID]?.busSinkID
        eventSubscribers[connectionID] = EventSubscriber(busSinkID: id, sink: boundSink)
        sinkLock.unlock()
        Task { [weak self] in
            guard let self else {
                reply(false)
                return
            }
            if let previousID {
                await eventBus.unregister(id: previousID)
            }
            await eventBus.register(TransferEventBus.Sink(id: id) { [weak self] events in
                await self?.deliver(events, connectionID: connectionID)
            })
            // A connection can invalidate while registration is suspended on
            // the actor. Do not leave a stale sink behind in that race.
            if !isCurrentSubscriber(connectionID: connectionID, busSinkID: id) {
                await eventBus.unregister(id: id)
            }
            TorrentinoLog.record(category: "xpc", level: "info", message: "event subscription complete result=success")
            reply(true)
        }
    }

    func unsubscribeEvents(reply: @escaping @Sendable (Bool) -> Void) {
        unsubscribeEvents(connectionID: legacyConnectionID, reply: reply)
    }

    func unsubscribeEvents(
        connectionID: UUID,
        reply: @escaping @Sendable (Bool) -> Void
    ) {
        sinkLock.lock()
        let id = eventSubscribers.removeValue(forKey: connectionID)?.busSinkID
        pendingEventSinks.removeValue(forKey: connectionID)
        sinkLock.unlock()
        guard let id else {
            reply(false)
            return
        }
        Task {
            await eventBus.unregister(id: id)
            reply(true)
        }
    }

    /// Stores a connection's sink for source-compatible callers that bind
    /// before subscribing. Runtime sessions pass the proxy directly to
    /// `subscribeEvents`, which is the ownership boundary.
    func setEventSink(_ sink: TorrentinoEventSink?, connectionID: UUID) {
        sinkLock.lock()
        if let sink {
            pendingEventSinks[connectionID] = sink
        } else {
            pendingEventSinks.removeValue(forKey: connectionID)
        }
        sinkLock.unlock()
    }

    /// Clears only the event subscription belonging to the connection that
    /// ended. An old CLI connection therefore cannot erase the GUI sink.
    func clearEventSink(connectionID: UUID) {
        sinkLock.lock()
        let id = eventSubscribers.removeValue(forKey: connectionID)?.busSinkID
        pendingEventSinks.removeValue(forKey: connectionID)
        sinkLock.unlock()
        guard let id else { return }
        Task {
            await eventBus.unregister(id: id)
        }
    }

    private func isCurrentSubscriber(connectionID: UUID, busSinkID: UUID) -> Bool {
        sinkLock.lock()
        let isCurrent = eventSubscribers[connectionID]?.busSinkID == busSinkID
        sinkLock.unlock()
        return isCurrent
    }

    private func deliver(_ events: [EngineEventV1], connectionID: UUID) async {
        let sink = sinkLock.withLock { eventSubscribers[connectionID]?.sink }
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

    private static func commandName(from data: Data) -> String {
        guard let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: data),
              let command = envelope.command else {
            return "invalid"
        }
        return command.name
    }

    private static func resultClass(from data: Data) -> String {
        guard let envelope = try? JSONDecoder().decode(IPCEnvelope.self, from: data),
              let result = envelope.result else {
            return "invalidReply"
        }
        switch result {
        case .success:
            return "success"
        case .failure(let fault):
            return "fault:\(fault.code.rawValue)"
        }
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
    private var sessionPhase = EngineLifecycleState.starting.rawValue
    private var sessionRevision: UInt64 = 1
    private var degradedReason: String?
    private var restoreRebuilt = 0
    private var restoreSkipped = 0
    private var observabilityDegraded = false

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

    func updateLifecycle(_ phase: EngineLifecycleState, reason: String?, revision: UInt64) {
        lock.lock()
        sessionPhase = phase.rawValue
        degradedReason = reason
        sessionRevision = revision
        lock.unlock()
    }

    func updateRestoreSummary(rebuilt: Int, skipped: Int) {
        lock.lock()
        restoreRebuilt = max(0, rebuilt)
        restoreSkipped = max(0, skipped)
        lock.unlock()
    }

    func updateObservability(_ degraded: Bool) {
        lock.lock()
        observabilityDegraded = degraded
        lock.unlock()
    }

    func snapshot(counter: Int64, counterFormat: String) -> [String: Any] {
        lock.lock()
        let conditions = self.conditions
        var payload: [String: Any] = [
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
            "sessionPhase": sessionPhase,
            "sessionRevision": NSNumber(value: sessionRevision),
            "restoreRebuilt": NSNumber(value: restoreRebuilt),
            "restoreSkipped": NSNumber(value: restoreSkipped),
            "observability": observabilityDegraded ? "degraded" : "ready",
        ]
        if let degradedReason {
            payload["degradedReason"] = degradedReason
        }
        lock.unlock()
        return payload
    }
}
