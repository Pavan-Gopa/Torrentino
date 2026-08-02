// Layer: UI -> agent transport (Mach XPC client).
// Role: owns the NSXPCConnection lifecycle, bounded reconnect, peer
// code-signing validation (PeerValidation), and async wrappers over the ObjC
// reply-block protocol.
// Must-not: cache engine state (the agent is authoritative), retry forever,
// or decode payloads before the peer code-signing requirement is installed.
// Invariants: at most one live connection; reconnect attempts are bounded by
// ClientReconnectPolicy; hello performs the §7.4 protocol negotiation; every
// public call returns authoritative state or throws EngineClientError.

import Foundation
import OSLog
import TorrentinoIPC

actor EngineClient {
    /// Shared reconnect contract (WP-05): budget + backoff are frozen here so
    /// tests and the client agree on reconnect semantics.
    private let reconnectPolicy = ClientReconnectPolicy.standard
    private var connection: NSXPCConnection?

    /// IPC command surface from TorrentinoIPC (schema identity; transport is still ObjC XPC).
    nonisolated var supportedCommands: [EngineCommandV1] { EngineCommandV1.allCases }
    /// Non-nil only if the frozen requirement expression parses as a valid
    /// requirement (validated once via SecRequirementCreateWithString). The
    /// NSXPCConnection API takes the requirement-language string itself.
    private let agentExpression: String?
    private let log = Logger(subsystem: PeerValidation.identity.appSigningID, category: "engine-client")

    init() {
        let expression = PeerValidation.expectedAgentRequirement
        self.agentExpression = PeerValidation.makeRequirement(expression) != nil
            ? expression
            : nil
    }

    // MARK: - Public API (agent is the source of truth)

    /// Handshake (plan §7.4): hello + health advertise the agent protocol,
    /// then the client negotiates; a major mismatch surfaces as a
    /// protocolVersionMismatch fault before any other command.
    func hello() async throws -> AgentHello {
        let base: (version: String, pid: Int64) = try await call { proxy, deliver in
            proxy.hello { version, pid in
                deliver(.success((version, pid)))
            }
        }
        // The agent advertises its protocol version over health (ipcVersion);
        // negotiate the client's supported range against the agent's single
        // advertised version. v1: both sides freeze to 1.0.
        let health = try await health()
        guard let advertisedProtocol = IPCVersion(parsing: health.ipcVersion) else {
            throw EngineClientError.protocolMismatch(
                details: "agent advertised unparsable ipcVersion \(health.ipcVersion)")
        }
        let request = Handshake.makeRequest(clientVersion: Self.clientVersion)
        let negotiated: IPCVersion
        switch Handshake.negotiate(
            clientRange: request.supportedProtocolRange,
            serverRange: Handshake.singleVersionRange(advertisedProtocol)
        ) {
        case .negotiated(let version):
            negotiated = version
        case .mismatch:
            throw EngineClientError.fault(EngineFault.protocolVersionMismatch(
                clientMajor: request.supportedProtocolRange.lowerBound.major,
                serverMajor: advertisedProtocol.major
            ))
        }
        return AgentHello(agentVersion: base.version, pid: base.pid, negotiatedProtocol: negotiated)
    }

    func health() async throws -> AgentHealth {
        try await call { proxy, deliver in
            proxy.health { dictionary in
                if let health = AgentHealth(dictionary: dictionary) {
                    deliver(.success(health))
                } else {
                    deliver(.failure(EngineClientError.protocolMismatch(
                        details: "unexpected health payload: \(dictionary)")))
                }
            }
        }
    }

    func incrementCounter() async throws -> Int64 {
        let value: Int64 = try await call { proxy, deliver in
            proxy.incrementCounter { deliver(.success($0)) }
        }
        guard value >= 0 else {
            throw EngineClientError.unavailable(reason: "agent reported persistence failure (counter=-1)")
        }
        return value
    }

    func getCounter() async throws -> Int64 {
        try await call { proxy, deliver in
            proxy.getCounter { deliver(.success($0)) }
        }
    }

    /// Asks the agent to stop gracefully; true means the ack arrived. The
    /// agent exits 0 shortly after; KeepAlive.SuccessfulExit=false means
    /// launchd will NOT respawn it until the next on-demand Mach message.
    func shutdown() async throws -> Bool {
        try await call { proxy, deliver in
            proxy.shutdown { deliver(.success($0)) }
        }
    }

    // MARK: - Bounded reconnect

    /// One logical request = up to maxAttempts transport attempts with backoff.
    /// Covers: agent not yet spawned (on-demand Mach launch), agent mid-restart
    /// after SIGKILL, and transient interruptions.
    private func call<T: Sendable>(
        _ invoke: @escaping @Sendable (
            any TorrentinoEngineXPCProtocol,
            @escaping @Sendable (Result<T, Error>) -> Void
        ) -> Void
    ) async throws -> T {
        var lastError: Error = EngineClientError.unavailable(reason: "no attempts performed")
        let maxAttempts = reconnectPolicy.maxAttempts
        for attempt in 0..<maxAttempts {
            if let delay = reconnectPolicy.delayNanoseconds(forAttempt: attempt), delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                let connection = try currentOrNewConnection()
                return try await send(on: connection, invoke: invoke)
            } catch {
                lastError = error
                log.warning("xpc attempt \(attempt + 1)/\(maxAttempts) failed: \(String(describing: error), privacy: .public)")
                teardownConnection()
            }
        }
        throw EngineClientError.unavailable(
            reason: "engine agent unreachable after \(maxAttempts) attempts: \(lastError)")
    }

    /// Sends one request over a connection, bridging ObjC reply blocks (and
    /// the connection error handler) into a checked continuation. A guard
    /// guarantees exactly-once resume: under failure races XPC may invoke
    /// both the error handler and a reply block for the same request.
    private func send<T: Sendable>(
        on connection: NSXPCConnection,
        invoke: @escaping @Sendable (
            any TorrentinoEngineXPCProtocol,
            @escaping @Sendable (Result<T, Error>) -> Void
        ) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let resumeGuard = ResumeGuard()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resumeGuard.resume(continuation, with: .failure(EngineClientError.interrupted(underlying: error)))
            }
            guard let typedProxy = proxy as? any TorrentinoEngineXPCProtocol else {
                resumeGuard.resume(continuation, with: .failure(EngineClientError.protocolMismatch(
                    details: "remote proxy does not implement TorrentinoEngineXPCProtocol")))
                return
            }
            invoke(typedProxy) { result in
                resumeGuard.resume(continuation, with: result)
            }
        }
    }

    private func currentOrNewConnection() throws -> NSXPCConnection {
        if let connection { return connection }

        guard let agentExpression else {
            throw EngineClientError.unavailable(reason: "invalid agent code-signing requirement expression")
        }

        // Peer code-signing policy (plan §23): validate the embedded agent
        // binary's designated requirement BEFORE any payload is decoded.
        // Debug builds skip both checks (unsigned dev binaries, no embedded
        // agent); Developer-ID Release builds enforce them.
        if PeerValidation.isEnforcementActive {
            switch PeerValidation.validateAgentBinary() {
            case .success:
                break
            case .failure(let validationError):
                throw EngineClientError.peerValidationFailed(validationError)
            }
        }

        let connection = NSXPCConnection(machServiceName: PeerValidation.identity.machServiceName, options: [])
        // macOS 13+: refuse to talk to an agent that is not our Developer-ID
        // signed bundle id — enforced before any payload decode (plan §23).
        if PeerValidation.isEnforcementActive {
            connection.setCodeSigningRequirement(agentExpression)
        }

        let interface = NSXPCInterface(with: TorrentinoEngineXPCProtocol.self)
        interface.setClasses(TorrentinoXPCSecurity.healthReplyClasses,
                             for: #selector(TorrentinoEngineXPCProtocol.health(reply:)),
                             argumentIndex: 0,
                             ofReply: true)
        connection.remoteObjectInterface = interface

        connection.interruptionHandler = { [weak self] in
            Task { await self?.handleInterruption() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.handleInvalidation() }
        }
        connection.resume()
        self.connection = connection
        log.notice("xpc connection resumed service=\(PeerValidation.identity.machServiceName, privacy: .public)")
        return connection
    }

    private func handleInterruption() {
        log.notice("xpc connection interrupted; next request will reconnect")
        teardownConnection()
    }

    private func handleInvalidation() {
        connection = nil
    }

    private func teardownConnection() {
        if let connection {
            connection.invalidate()
            self.connection = nil
        }
    }

    /// Version string this UI build reports in HelloRequest. The bundle
    /// version when available; "dev" outside a bundle (tests, bare CLI runs).
    nonisolated private static var clientVersion: String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return bundleVersion?.isEmpty == false ? bundleVersion! : "dev"
    }
}

/// Exactly-once continuation resume guard (see EngineClient.send).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume<T: Sendable>(_ continuation: CheckedContinuation<T, Error>, with result: Result<T, Error>) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume {
            continuation.resume(with: result)
        }
    }
}
