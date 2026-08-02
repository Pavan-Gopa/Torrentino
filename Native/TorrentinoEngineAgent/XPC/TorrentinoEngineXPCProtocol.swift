// Layer: IPC contract (shared between Torrentino UI and TorrentinoEngineAgent;
// this single file has target membership in BOTH targets).
// Role: ObjC-compatible Mach XPC protocol for the WP-02 lifecycle spike.
// Must-not: carry non-plist types, mutable state, or engine internals.
// Invariants: every method is request/reply; reply blocks are Sendable and may
// fire on any XPC queue; frozen identifiers live in TorrentinoXPCSecurity and
// LIFECYCLE_CONTRACT.md.

import Foundation

/// Wire contract between the UI process and the engine LaunchAgent.
///
/// ObjC selector mapping (frozen for the spike):
///   hello(reply:)            -> helloWithReply:
///   health(reply:)           -> healthWithReply:
///   incrementCounter(reply:) -> incrementCounterWithReply:
///   getCounter(reply:)       -> getCounterWithReply:
///   shutdown(reply:)         -> shutdownWithReply:
@objc(TorrentinoEngineXPCProtocol)
protocol TorrentinoEngineXPCProtocol: NSObjectProtocol {
    /// Handshake. Returns the agent version string and the agent pid.
    func hello(reply: @escaping @Sendable (_ agentVersion: String, _ pid: Int64) -> Void)

    /// Health snapshot. Dictionary carries plist types only (NSString/NSNumber).
    func health(reply: @escaping @Sendable (_ health: [String: Any]) -> Void)

    /// Atomically increments the durable counter; replies with the new value,
    /// or -1 if persistence failed (agent stays up; logged on the agent side).
    func incrementCounter(reply: @escaping @Sendable (_ newValue: Int64) -> Void)

    /// Replies with the current durable counter value. The agent file is
    /// authoritative: the value survives SIGKILL and clean restarts.
    func getCounter(reply: @escaping @Sendable (_ value: Int64) -> Void)

    /// Requests graceful shutdown: flush durable state, ack with true, then the
    /// agent exits 0 shortly after the reply is drained.
    func shutdown(reply: @escaping @Sendable (_ acknowledged: Bool) -> Void)
}

/// Frozen identity + peer code-signing policy (plan §23). Both sides install a
/// code-signing requirement (requirement-language string) on their
/// NSXPCConnection via setCodeSigningRequirement BEFORE resume/decode, so an
/// unsigned or wrong-identifier peer is rejected before any payload is touched.
/// makeRequirement validates the expression compiles as a SecRequirement.
enum TorrentinoXPCSecurity {
    static let uiAppBundleIdentifier = "com.torrentino.app"
    static let agentBundleIdentifier = "com.torrentino.app.engine-agent"
    static let launchAgentLabel = "com.torrentino.app.engine-agent"
    static let machServiceName = "com.torrentino.app.engine-agent.mach"
    static let agentPlistName = "com.torrentino.app.engine-agent.plist"
    static let teamIdentifier = "438UQRF7JV"

    /// Requirement the AGENT enforces on incoming UI connections.
    static let expectedUIAppExpression =
        "identifier \"\(uiAppBundleIdentifier)\" and anchor apple generic " +
        "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    /// Requirement the UI enforces on the agent connection.
    static let expectedAgentExpression =
        "identifier \"\(agentBundleIdentifier)\" and anchor apple generic " +
        "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    static func makeRequirement(_ expression: String) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(expression as CFString, [], &requirement)
        guard status == errSecSuccess else { return nil }
        return requirement
    }

    /// Allowlist for the health(reply:) dictionary payload ([String: Any] of
    /// NSString/NSNumber only). The NSDictionary container class itself must be
    /// whitelisted as well: NSXPCDecoder validates the top-level reply object
    /// ("<no key>") against this same set and throws "unexpected class
    /// 'NSDictionary'" when it is absent, which the client observes as a 4101
    /// connection interruption. Swift metatypes are not Hashable, so the class
    /// objects are bridged through NSSet to build the Set<AnyHashable> that
    /// NSXPCInterface.setClasses expects. Computed per call: Set<AnyHashable>
    /// is not Sendable, so a stored static would violate Swift 6 safety.
    static var healthReplyClasses: Set<AnyHashable> {
        (NSSet(objects: NSDictionary.self, NSString.self, NSNumber.self) as? Set<AnyHashable>) ?? []
    }
}
