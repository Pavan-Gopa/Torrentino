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

    private let log = Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "runtime")
    private let stateQueue = DispatchQueue(label: "com.torrentino.app.engine-agent.runtime")
    private let store: CounterStore
    private let persistence: PersistenceStore
    private let service: AgentService
    private var listener: NSXPCListener?
    private var listenerDelegate: ListenerDelegate? // strong: NSXPCListener.delegate is weak
    private var signalSources: [DispatchSourceSignal] = []
    private var lockDescriptor: CInt = -1
    private var advisoryLock: AdvisoryLockHandle?
    private var stopInitiated = false

    /// Creates the engine directory, takes the single-instance lock, acquires
    /// the persistence single-writer advisory lock, and loads the durable
    /// counter. Throws CounterStoreError on state problems.
    init() throws {
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
        self.store = try CounterStore(engineDirectory: engineDirectory)
        self.persistence = PersistenceStore(dataDirectory: engineDirectory)
        self.service = AgentService(store: store, persistence: persistence)
        // Phase 1 is complete: capturing self weakly is now legal.
        service.shutdownHook = { [weak self] in
            self?.initiateStop(reason: "xpc-shutdown", exitDelayNanoseconds: 250_000_000)
        }
        log.notice("agent bootstrapped version=\(Self.agentVersion, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Installs signal handlers, checks into the Mach service, and returns.
    /// The caller then parks the process with dispatchMain().
    func beginServing() {
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

        // WP-06: open the durable store in the background (schema/migrations,
        // WAL recovery, startup reconciliation). A corrupt database degrades
        // to a rebuilt/limited store — the agent never fails to serve.
        Task {
            do {
                let report = try await persistence.open()
                log.notice("persistence ready: \(report.message, privacy: .public)")
            } catch {
                log.error("persistence open failed, serving degraded: \(String(describing: error), privacy: .public)")
            }
        }

        let delegate = ListenerDelegate(service: service)
        let machListener = NSXPCListener(machServiceName: TorrentinoXPCSecurity.machServiceName)
        machListener.delegate = delegate

        stateQueue.sync {
            self.listenerDelegate = delegate
            self.listener = machListener
        }
        machListener.resume()
        log.notice("mach listener resumed service=\(TorrentinoXPCSecurity.machServiceName, privacy: .public)")
    }

    // MARK: - Graceful stop (shared by SIGTERM/SIGINT and XPC shutdown)

    private func initiateStop(reason: String, exitDelayNanoseconds: UInt64) {
        stateQueue.async { [self] in
            guard !stopInitiated else { return }
            stopInitiated = true
            log.notice("graceful shutdown initiated reason=\(reason, privacy: .public)")
            let store = store
            let persistence = persistence
            Task {
                do {
                    try await store.flush()
                    log.notice("counter checkpoint flushed; exiting 0")
                } catch {
                    // Still exit 0: the in-memory value was already persisted
                    // on every increment; flush is a belt-and-braces checkpoint.
                    log.error("final flush failed: \(String(describing: error), privacy: .public)")
                }
                // WP-06 clean shutdown: WAL flush -> TRUNCATE checkpoint ->
                // journal truncation -> clean flag -> close. Any failure here
                // still exits 0; the next boot runs startup reconciliation.
                do {
                    try await persistence.close(clean: true)
                    log.notice("persistence clean shutdown complete")
                } catch {
                    log.error("persistence clean shutdown failed, WAL left for replay: \(String(describing: error), privacy: .public)")
                }
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

    /// Validates the connecting UI process against the frozen code-signing
    /// requirement BEFORE any payload is decoded (plan §23).
    private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        private let service: AgentService
        private let uiAppRequirement: SecRequirement?
        private let log = Logger(subsystem: TorrentinoXPCSecurity.agentBundleIdentifier, category: "xpc")

        init(service: AgentService) {
            self.service = service
            self.uiAppRequirement = TorrentinoXPCSecurity.makeRequirement(
                TorrentinoXPCSecurity.expectedUIAppExpression)
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            guard uiAppRequirement != nil else {
                log.error("rejecting connection: invalid ui requirement expression")
                return false
            }
            // macOS 13+: peer must satisfy this or the connection is invalidated
            // before any message decode. The API takes a requirement-language
            // string; the expression was validated into uiAppRequirement at init.
            connection.setCodeSigningRequirement(TorrentinoXPCSecurity.expectedUIAppExpression)

            let interface = NSXPCInterface(with: TorrentinoEngineXPCProtocol.self)
            // health(reply:) replies with [String: Any]; whitelist plist classes.
            interface.setClasses(TorrentinoXPCSecurity.healthReplyClasses,
                                 for: #selector(TorrentinoEngineXPCProtocol.health(reply:)),
                                 argumentIndex: 0,
                                 ofReply: true)
            connection.exportedInterface = interface
            connection.exportedObject = service
            connection.interruptionHandler = { [log] in
                log.notice("ui connection interrupted")
            }
            connection.resume()
            log.notice("accepted ui connection effectiveUserIdentifier=\(connection.effectiveUserIdentifier)")
            return true
        }
    }
}
