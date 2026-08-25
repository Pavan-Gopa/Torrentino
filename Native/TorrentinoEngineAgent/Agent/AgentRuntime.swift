// Layer: Agent process lifecycle.
// Role: launchd-facing lifecycle — engine dir, single-instance lock, Mach
// listener, SIGTERM/SIGINT handling, graceful stop with checkpoint.
// Must-not: touch UI state, run a second instance, or exit non-zero on a
// clean stop (launchd would treat it as a crash and restart).
// Invariants: all mutable state is serialized on `stateQueue`; the durable
// counter is flushed before any clean exit; SIGTERM and the XPC shutdown
// method share one stop path (ADR-004); WP-06 persistence is opened in
// background after bootstrap and closed through the clean-shutdown pipeline
// (WAL checkpoint, journal truncation, clean flag) before exit.

import Foundation
import OSLog
import Security
import TorrentinoIPC

final class AgentRuntime: @unchecked Sendable {
    /// Exit codes (see LIFECYCLE_CONTRACT.md):
    /// 0  clean stop (Cmd+Q ack, SIGTERM, duplicate instance) — no restart
    /// 1  bootstrap fault (lock/IO/listener) — launchd may restart (throttled)
    /// 78 downgrade blocked (counter format newer than this binary)
    static let exitCodeFault: Int32 = 1
    static let exitCodeDowngradeBlocked: Int32 = 78

    /// Build-time identity so the update test can distinguish v1/v2 agents.
    static let agentVersion: String = {
        #if COUNTER_FORMAT_V1
        return "1.0.0-wp02-v1"
        #else
        return "1.0.0-wp02-v2"
        #endif
    }()

    private let log = TorrentinoLog.logger(category: "runtime")
    private let stateQueue = DispatchQueue(label: "com.torrentino.app.engine-agent.runtime")
    private let store: CounterStore
    private let persistence: PersistenceStore
    private let eventBus: TransferEventBus
    private let service: AgentService
    private let healthLane: AgentHealthLane
    private let crashLoopGuard: CrashLoopGuard
    private let safeRecovery: Bool
    private var listener: NSXPCListener?
    private var listenerDelegate: ListenerDelegate? // strong: NSXPCListener.delegate is weak
    private var signalSources: [DispatchSourceSignal] = []
    private var lockDescriptor: CInt = -1
    private var advisoryLock: AdvisoryLockHandle?
    private var stopInitiated = false
    private var sessionPhase: EngineLifecycleState = .starting
    private var sessionRevision: UInt64 = 1
    private var degradedReason: String?
    /// WP-07 transfer lane, built after persistence opens (set-once, on
    /// stateQueue). Stopped before the clean-shutdown pipeline in initiateStop.
    private var transferCoordinator: TransferCoordinator?
    private var conditionMonitor: SystemConditionMonitor?
    private var latestConditions = SystemConditions.normal

    /// Creates the engine directory, takes the single-instance lock, acquires
    /// the persistence single-writer advisory lock, and loads the durable
    /// counter. Throws CounterStoreError on state problems.
    init() throws {
        TorrentinoLog.record(
            category: "lifecycle",
            level: "notice",
            message: "agent bootstrap start version=\(Self.agentVersion)"
        )
        let engineDirectory = try Self.makeEngineDirectory()
        var descriptor: CInt = -1
        try Self.takeInstanceLock(engineDirectory: engineDirectory, descriptor: &descriptor)
        self.lockDescriptor = descriptor
        // WP-06: one writer per data directory. A second agent holding the
        // lock is a bootstrap fault — exit 1 with a clear message.
        do {
            self.advisoryLock = try AdvisoryLock.acquire(dataDirectory: engineDirectory)
        } catch {
            FileHandle.standardError.write(Data(
                ("FATAL: persistence data directory is locked by another writer: " +
                 "\(String(describing: error))\n").utf8))
            exit(AgentRuntime.exitCodeFault)
        }
        let crashGuard = CrashLoopGuard.begin(in: engineDirectory)
        self.crashLoopGuard = crashGuard
        self.safeRecovery = crashGuard.isSafeRecovery
        self.store = try CounterStore(engineDirectory: engineDirectory)
        self.persistence = PersistenceStore(dataDirectory: engineDirectory)
        let healthLane = AgentHealthLane()
        healthLane.markSafeRecovery(safeRecovery)
        healthLane.updateLifecycle(.starting, reason: nil, revision: 1)
        healthLane.updateObservability(TorrentinoLog.observabilityDegraded)
        self.healthLane = healthLane
        let eventBus = TransferEventBus(healthReporter: healthLane)
        self.eventBus = eventBus
        self.service = AgentService(
            store: store,
            persistence: persistence,
            healthLane: healthLane,
            eventBus: eventBus
        )
        // Phase 1 is complete: capturing self weakly is now legal.
        service.shutdownHook = { [weak self] in
            self?.initiateStop(reason: "xpc-shutdown", exitDelayNanoseconds: 250_000_000)
        }
        log.notice("agent bootstrapped version=\(Self.agentVersion) pid=\(ProcessInfo.processInfo.processIdentifier)")
        TorrentinoLog.record(
            category: "lifecycle",
            level: "notice",
            message: "agent bootstrapped version=\(Self.agentVersion) pid=\(ProcessInfo.processInfo.processIdentifier)"
        )
        TorrentinoLog.record(
            category: "lifecycle",
            level: "notice",
            message: "lifecycle transition from=unregistered to=starting reason=bootstrap"
        )
        Task {
            await eventBus.publish([
                .engineLifecycleChanged(EngineLifecycleChangedEvent(
                    from: .unregistered,
                    to: .starting,
                    degradedReason: nil,
                    revision: 1
                ))
            ], urgent: true)
        }
    }

    /// Installs signal handlers, checks into the Mach service, and returns.
    /// The caller then parks the process with dispatchMain().
    func beginServing() {
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "agent begin serving")
        // Named Mach services can only be vended by launchd-managed jobs: a
        // directly executed process gets EPERM on listener activation
        // ("listener failed to activate: xpc_error=[1: Operation not
        // permitted]") and would sit here as a silent zombie that nothing can
        // talk to. launchd always sets XPC_SERVICE_NAME to the job label, so
        // its absence proves we are not launchd-managed. Fail loud (exit 1,
        // bootstrap fault) instead of pretending to serve.
        let serviceName = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
        guard !serviceName.isEmpty else {
            FileHandle.standardError.write(Data((
                "FATAL: \(TorrentinoXPCSecurity.agentBundleIdentifier) must be launched by launchd " +
                "(SMAppService registration); direct execution cannot check into the Mach service " +
                "named \(TorrentinoXPCSecurity.machServiceName).\n"
            ).utf8))
            exit(AgentRuntime.exitCodeFault)
        }

        installSignalHandlers()
        transition(to: .openingStore, reason: "listener bootstrap")

        let delegate = ListenerDelegate(service: service, stateQueue: stateQueue)
        service.shutdownAuthorization = { [weak delegate] in
            delegate?.authorizeShutdown() ?? false
        }
        let machListener = NSXPCListener(machServiceName: TorrentinoXPCSecurity.machServiceName)
        machListener.delegate = delegate

        stateQueue.sync {
            self.listenerDelegate = delegate
            self.listener = machListener
        }
        machListener.resume()
        log.notice("mach listener resumed service=\(TorrentinoXPCSecurity.machServiceName)")
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "mach listener resumed service=\(TorrentinoXPCSecurity.machServiceName)")

        // WP-06: open the durable store in the background (schema/migrations,
        // WAL recovery, startup reconciliation). A corrupt database degrades
        // to a rebuilt/limited store — the agent never fails to serve.
        Task {
            do {
                TorrentinoLog.record(category: "persistence", level: "info", message: "persistence restore start")
                let report = try await persistence.open()
                healthLane.updatePersistence(await persistence.healthSnapshot())
                healthLane.updateObservability(TorrentinoLog.observabilityDegraded)
                log.notice("persistence ready: \(report.message)")
                TorrentinoLog.record(
                    category: "persistence",
                    level: report.degraded ? "warning" : "notice",
                    message: "persistence open report=\(report.message) verified=\(report.checksumsVerified) quarantined=\(report.quarantined)"
                )
                if report.degraded {
                    transition(to: .degraded, reason: "persistenceUnavailable")
                } else {
                    transition(to: .restoringSession, reason: "persistence opened")
                }
                await wireTransferLanes(persistenceReady: true, startupReport: report)
            } catch {
                healthLane.updatePersistenceFailure()
                healthLane.updateObservability(TorrentinoLog.observabilityDegraded)
                log.error("persistence open failed, serving degraded: \(TorrentinoLog.redactedDescription(error))")
                TorrentinoLog.record(
                    category: "persistence",
                    level: "error",
                    message: "persistence open failed verified=0 quarantined=0 error=\(TorrentinoLog.redactedDescription(error))"
                )
                transition(to: .degraded, reason: "persistenceUnavailable")
                await wireTransferLanes(persistenceReady: false, startupReport: nil)
            }
        }
    }

    // MARK: - WP-07 transfer lane

    /// Builds the event bus + production engine bridge + coordinator, injects
    /// them into the service, restores persisted records, and starts the
    /// status pump. Runs after persistence.open (the coordinator persists
    /// through the same store). Restore and pump are best-effort: a failed
    /// restore leaves the coordinator empty; the pump re-adds running torrents
    /// on the next tick.
    private func wireTransferLanes(persistenceReady: Bool, startupReport: StartupReport?) async {
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "transfer lane bootstrap start")
        let bridge = BridgeTransferEngine(coordinator: EngineCoordinator())
        let coordinator = TransferCoordinator(
            engine: bridge,
            persistence: persistence,
            eventBus: eventBus,
            agentVersion: AgentRuntime.agentVersion,
            defaultSaveLocation: PersistedLocation(path: Self.defaultDownloadsPath),
            pumpIntervalNanoseconds: 500_000_000,
            healthReporter: healthLane,
            safeRecovery: safeRecovery,
            clearSafeRecovery: { [weak self] in
                self?.clearSafeRecoveryAfterExplicitRestart()
            }
        )
        stateQueue.sync {
            self.transferCoordinator = coordinator
            service.coordinator = coordinator
        }
        let conditions = stateQueue.sync { latestConditions }
        await coordinator.applySystemConditions(conditions)
        let restoreSummary: RestoreSummary
        if persistenceReady {
            await coordinator.setSessionPhase(.restoringSession, reason: nil)
            restoreSummary = await coordinator.restoreFromPersistence()
        } else {
            restoreSummary = RestoreSummary(
                stored: 0,
                rebuilt: 0,
                skipped: 0,
                engineRevision: await coordinator.currentEngineRevision,
                failure: "persistenceUnavailable"
            )
        }
        healthLane.updateRestoreSummary(rebuilt: restoreSummary.rebuilt, skipped: restoreSummary.skipped)
        TorrentinoLog.record(
            category: "persistence",
            level: "notice",
            message: "restore summary rebuilt=\(restoreSummary.rebuilt) skipped=\(restoreSummary.skipped) engineRevision=\(restoreSummary.engineRevision)"
        )
        let persistenceFailure = startupReport?.degraded == true ? "persistenceUnavailable" : nil
        if let failure = restoreSummary.failure ?? persistenceFailure {
            await coordinator.setSessionPhase(.degraded, reason: failure)
            transition(to: .degraded, reason: failure)
        } else if restoreSummary.stored > 0 && restoreSummary.rebuilt == 0 {
            await coordinator.setSessionPhase(.degraded, reason: "restoreAnomaly")
            transition(to: .degraded, reason: "restoreAnomaly")
        } else {
            transition(to: .reconcilingRecords, reason: "restore summary ready")
            await coordinator.setSessionPhase(.reconcilingRecords, reason: nil)
        }
        await coordinator.startPump()
        if restoreSummary.failure == nil && persistenceFailure == nil
            && !(restoreSummary.stored > 0 && restoreSummary.rebuilt == 0) {
            // A failed native start is deliberately non-fatal: the pump owns
            // retry/backoff and records a typed deferred health instead.
            await coordinator.pumpOnce()
            await coordinator.setSessionPhase(.ready, reason: nil)
            transition(to: .ready, reason: "first pump scheduled")
        }
        startConditionMonitoring()
        log.notice("transfer lane wired (bus + coordinator + bridge engine)")
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "transfer lane wired and status pump started")
    }

    private func startConditionMonitoring() {
        let monitor = SystemConditionMonitor { [weak self] conditions in
            guard let self else { return }
            self.healthLane.updateSystemConditions(conditions)
            self.stateQueue.async { [weak self] in
                guard let self else { return }
                self.latestConditions = conditions
                let coordinator = self.transferCoordinator
                Task {
                    await coordinator?.applySystemConditions(conditions)
                }
            }
        }
        stateQueue.sync { conditionMonitor = monitor }
        monitor.start()
    }

    private func clearSafeRecoveryAfterExplicitRestart() {
        stateQueue.sync {
            crashLoopGuard.clearHistory()
            healthLane.markSafeRecovery(false)
        }
        TorrentinoLog.record(category: "lifecycle", level: "notice", message: "safe recovery cleared after explicit restart")
    }

    private func transition(to next: EngineLifecycleState, reason: String?) {
        stateQueue.sync {
            transitionLocked(to: next, reason: reason)
        }
    }

    private func transitionLocked(to next: EngineLifecycleState, reason: String?) {
        guard sessionPhase != next else { return }
        guard Self.isAllowedTransition(from: sessionPhase, to: next) else {
            TorrentinoLog.record(
                category: "lifecycle",
                level: "error",
                message: "lifecycle transition rejected from=\(sessionPhase.rawValue) to=\(next.rawValue) reason=non-monotonic"
            )
            return
        }

        let previous = sessionPhase
        sessionPhase = next
        sessionRevision &+= 1
        degradedReason = next == .degraded ? reason : nil
        healthLane.updateLifecycle(next, reason: degradedReason, revision: sessionRevision)
        healthLane.updateObservability(TorrentinoLog.observabilityDegraded)
        TorrentinoLog.record(
            category: "lifecycle",
            level: next == .degraded ? "error" : "notice",
            message: "lifecycle transition from=\(previous.rawValue) to=\(next.rawValue) reason=\(reason ?? "none")"
        )
        let event = EngineLifecycleChangedEvent(
            from: previous,
            to: next,
            degradedReason: degradedReason,
            revision: sessionRevision
        )
        let eventBus = self.eventBus
        Task {
            await eventBus.publish([.engineLifecycleChanged(event)], urgent: true)
        }
    }

    private static func isAllowedTransition(from: EngineLifecycleState, to: EngineLifecycleState) -> Bool {
        if to == .degraded {
            return from != .checkpointing && from != .stopping && from != .stopped
        }
        if from == .degraded {
            return to == .checkpointing
        }
        func rank(_ phase: EngineLifecycleState) -> Int {
            switch phase {
            case .unregistered, .registering: return 0
            case .starting: return 1
            case .openingStore: return 2
            case .migratingStore: return 3
            case .restoringSession: return 4
            case .reconcilingRecords: return 5
            case .ready: return 6
            case .checkpointing: return 7
            case .stopping: return 8
            case .stopped: return 9
            case .degraded: return 6
            }
        }
        return rank(to) > rank(from)
    }

    /// Default torrent save location: the current user's Downloads folder.
    private static var defaultDownloadsPath: String {
        (try? FileManager.default.url(for: .downloadsDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: false).path) ?? "~/Downloads"
    }

    // MARK: - Graceful stop (shared by SIGTERM/SIGINT and XPC shutdown)

    private func initiateStop(reason: String, exitDelayNanoseconds: UInt64) {
        stateQueue.async { [self] in
            guard !stopInitiated else { return }
            stopInitiated = true
            transitionLocked(to: .checkpointing, reason: reason)
            log.notice("graceful shutdown initiated reason=\(reason)")
            TorrentinoLog.record(category: "lifecycle", level: "notice", message: "graceful shutdown initiated reason=\(reason)")
            let store = store
            let persistence = persistence
            let coordinator = transferCoordinator // captured on stateQueue
            Task {
                do {
                    try await store.flush()
                    log.notice("counter checkpoint flushed; exiting 0")
                } catch {
                    // Still exit 0: the in-memory value was already persisted
                    // on every increment; flush is a belt-and-braces checkpoint.
                    log.error("final flush failed: \(TorrentinoLog.redactedDescription(error))")
                }
                // Stop the WP-07 status pump so no engine/persistence work
                // overlaps the clean-shutdown pipeline.
                if let coordinator {
                    await coordinator.stop()
                }
                stateQueue.sync { conditionMonitor?.stop() }
                transition(to: .stopping, reason: "pump stopped")
                // WP-06 clean shutdown: WAL flush -> TRUNCATE checkpoint ->
                // journal truncation -> clean flag -> close. Any failure here
                // still exits 0; the next boot runs startup reconciliation.
                do {
                    try await persistence.close(clean: true)
                    log.notice("persistence clean shutdown complete")
                    TorrentinoLog.record(category: "persistence", level: "notice", message: "persistence clean shutdown complete")
                } catch {
                    log.error("persistence clean shutdown failed, WAL left for replay: \(TorrentinoLog.redactedDescription(error))")
                    TorrentinoLog.record(category: "persistence", level: "error", message: "persistence clean shutdown failed: \(TorrentinoLog.redactedDescription(error))")
                }
                crashLoopGuard.markClean()
                healthLane.markCheckpoint()
                transition(to: .stopped, reason: "clean shutdown complete")
                TorrentinoLog.record(category: "lifecycle", level: "notice", message: "checkpoint complete clean shutdown")
                await TorrentinoLog.flush()
                // Short delay lets the XPC shutdown ack drain to the client.
                try? await Task.sleep(nanoseconds: exitDelayNanoseconds)
                exit(0)
            }
        }
    }

    // MARK: - Signals

    private func installSignalHandlers() {
        // Ignore default dispositions; GCD sources drive the graceful path.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: stateQueue)
            source.setEventHandler { [weak self] in
                self?.initiateStop(reason: "signal-\(sig)", exitDelayNanoseconds: 50_000_000)
            }
            source.resume()
            stateQueue.sync { signalSources.append(source) }
        }
    }

    // MARK: - Engine directory + instance lock

    /// ~/Library/Application Support/com.torrentino.app/Engine (0700).
    /// This is the spike's engine dir; WP-06 extends it with the real store.
    private static func makeEngineDirectory() throws -> URL {
        let fileManager = FileManager.default
#if DEBUG
        // Test-only seam: a disposable launchd proof may redirect the entire
        // agent Engine directory without touching Human Application Support.
        if let override = ProcessInfo.processInfo.environment["TORRENTINO_ENGINE_DIRECTORY"], !override.isEmpty {
            let engine = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            do {
                try fileManager.createDirectory(at: engine, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
            } catch {
                throw CounterStoreError.ioFailure(reason: "cannot create test engine dir: \(error)")
            }
            return engine
        }
#endif
        let base = try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: true)
        let engine = base.appendingPathComponent(TorrentinoXPCSecurity.uiAppBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Engine", isDirectory: true)
        do {
            try fileManager.createDirectory(at: engine, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
        } catch {
            throw CounterStoreError.ioFailure(reason: "cannot create engine dir \(engine.path): \(error)")
        }
        return engine
    }

    /// flock(LOCK_EX|LOCK_NB) on Engine/instance.lock. A second agent (manual
    /// run, stale copy, race) exits 0 immediately: launchd's Mach check-in
    /// already guarantees one owner, and SuccessfulExit=false means a clean
    /// bail-out is NOT restarted.
    private static func takeInstanceLock(engineDirectory: URL, descriptor: inout CInt) throws {
        let lockURL = engineDirectory.appendingPathComponent("instance.lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
        }
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw CounterStoreError.ioFailure(reason: "open(instance.lock) errno=\(errno)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Another instance owns the session. Clean exit, no restart.
            FileHandle.standardError.write(Data(
                "another engine agent instance holds instance.lock; exiting cleanly\n".utf8))
            close(fd)
            exit(0)
        }
        descriptor = fd
    }

    // MARK: - XPC listener delegate

    private final class ConnectionLease: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        private let releaseAction: @Sendable () -> Void

        init(releaseAction: @escaping @Sendable () -> Void) {
            self.releaseAction = releaseAction
        }

        func releaseOnce() {
            lock.lock()
            guard !released else {
                lock.unlock()
                return
            }
            released = true
            lock.unlock()
            releaseAction()
        }
    }

    /// Handles incoming connections for the agent listener: shouldAcceptNewConnection
    /// validates the still-suspended connection via TorrentinoXPCSecurity.validateDynamicPeer,
    /// re-reads stable PID, and returns false to reject unauthenticated peers before lease,
    /// interfaces, proxy, exported object, handlers, or resume.
    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        private let service: AgentService
        private let stateQueue: DispatchQueue
        private let log = TorrentinoLog.logger(category: "xpc")
        private let uiRequirement: SecRequirement?
        private var activeConnections = 0

        init(service: AgentService, stateQueue: DispatchQueue) {
            self.service = service
            self.stateQueue = stateQueue
            self.uiRequirement = TorrentinoXPCSecurity.makeRequirement(TorrentinoXPCSecurity.expectedUIAppExpression)
        }

        func authorizeShutdown() -> Bool {
            stateQueue.sync { activeConnections <= 1 }
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            let pid = connection.processIdentifier
            guard pid > 0 else {
                TorrentinoLog.record(
                    category: "xpc-security",
                    level: "error",
                    message: "xpc connection rejected invalid pid=\(pid)"
                )
                return false
            }
            guard let requirement = uiRequirement else {
                TorrentinoLog.record(
                    category: "xpc-security",
                    level: "error",
                    message: "xpc connection rejected requirement compilation failed pid=\(pid)"
                )
                return false
            }
            let validationResult = TorrentinoXPCSecurity.validateDynamicPeer(processIdentifier: pid, requirement: requirement)
            guard case .success = validationResult else {
                let statusText: String
                if case .failure(let err) = validationResult {
                    statusText = "\(err)"
                } else {
                    statusText = "unknown"
                }
                TorrentinoLog.record(
                    category: "xpc-security",
                    level: "error",
                    message: "xpc connection rejected dynamic validation failed pid=\(pid) error=\(statusText)"
                )
                return false
            }
            let reReadPID = connection.processIdentifier
            guard reReadPID > 0, reReadPID == pid else {
                TorrentinoLog.record(
                    category: "xpc-security",
                    level: "error",
                    message: "xpc connection rejected pid instability initialPid=\(pid) reReadPid=\(reReadPID)"
                )
                return false
            }

            let connectionID = UUID()

            stateQueue.sync { activeConnections += 1 }
            let lease = ConnectionLease { [weak self] in
                self?.releaseConnection()
            }
            let interface = NSXPCInterface(with: TorrentinoEngineXPCProtocol.self)
            // health(reply:) replies with [String: Any]; whitelist plist classes.
            interface.setClasses(TorrentinoXPCSecurity.healthReplyClasses,
                                 for: #selector(TorrentinoEngineXPCProtocol.health(reply:)),
                                 argumentIndex: 0,
                                 ofReply: true)
            connection.exportedInterface = interface
            // Export a forwarding object scoped to this accepted connection.
            // AgentService binds its event sink only if this connection calls
            // subscribeEvents; snapshot/health CLI clients never overwrite
            // the GUI subscriber.
            connection.remoteObjectInterface = NSXPCInterface(with: TorrentinoEventSink.self)
            let eventSink = connection.remoteObjectProxy as? TorrentinoEventSink
            connection.exportedObject = service.makeConnection(
                connectionID: connectionID,
                eventSink: eventSink
            )
            connection.interruptionHandler = { [weak service, weak self] in
                self?.log.notice("ui connection interrupted")
                service?.clearEventSink(connectionID: connectionID)
                lease.releaseOnce()
            }
            connection.invalidationHandler = { [weak service, weak self] in
                self?.log.notice("ui connection invalidated")
                service?.clearEventSink(connectionID: connectionID)
                lease.releaseOnce()
            }
            connection.resume()
            log.notice("accepted ui connection effectiveUserIdentifier=\(connection.effectiveUserIdentifier)")
            TorrentinoLog.record(
                category: "xpc",
                level: "notice",
                message: "xpc connect peer verification accepted effectiveUserIdentifier=\(connection.effectiveUserIdentifier)"
            )
            return true
        }

        private func releaseConnection() {
            stateQueue.sync {
                activeConnections = max(0, activeConnections - 1)
            }
        }
    }

}
