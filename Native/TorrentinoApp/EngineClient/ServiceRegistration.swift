// Layer: UI -> ServiceManagement bridge.
// Role: register/unregister/query the engine LaunchAgent via SMAppService.
// Must-not: start an in-process engine on denial, or mutate launchd state
// without explicit user intent.
// Invariants: denial (status != .enabled) maps to UI degraded state only;
// launchd IPC never runs on the main actor (nonisolated async, SE-0338).

import Foundation
import ServiceManagement

enum RegistrationPolicyAction: String, Sendable, Equatable {
    case noOp
    case rebind
    case register
}

enum AgentServiceRegistration {
    /// Frozen identifiers (plan §23, LIFECYCLE_CONTRACT.md). The app-side
    /// identity authority is PeerValidation (WP-05).
    static let plistName = PeerValidation.identity.plistFilename
    static let label = PeerValidation.identity.launchAgentLabel

    /// Pure policy helper for registration requests given current state and force flag.
    static func registrationAction(status: StatusSnapshot.State, forceRebind: Bool) -> RegistrationPolicyAction {
        switch (status, forceRebind) {
        case (.enabled, false):
            return .noOp
        case (.enabled, true):
            return .rebind
        default:
            return .register
        }
    }

    /// Registers Contents/Library/LaunchAgents/<plistName> from this bundle.
    /// Default `forceRebind: false` is idempotent: returns without mutation if already enabled.
    /// Explicit `forceRebind: true` forces a rebind (unregister + register) if enabled.
    /// Throws on failure; success still requires status == .enabled afterwards
    /// (first registration may land in .requiresApproval until the user
    /// toggles it in System Settings > Login Items).
    static func register(forceRebind: Bool = false) async throws {
        let agent = SMAppService.agent(plistName: plistName)
        let currentStatus = StatusSnapshot(status: agent.status).state
        let action = registrationAction(status: currentStatus, forceRebind: forceRebind)
        switch action {
        case .noOp:
            return
        case .rebind:
            // BTM self-heal: if launchd still pairs this label with a stale app
            // copy (prior build moved/removed), explicit forceRebind forces
            // BackgroundTaskManagement to re-resolve against current app bundle.
            try await agent.unregister()
            try agent.register()
        case .register:
            try agent.register()
        }
    }

    static func unregister() async throws {
        try await SMAppService.agent(plistName: plistName).unregister()
    }

    static func status() async -> StatusSnapshot {
        StatusSnapshot(status: SMAppService.agent(plistName: plistName).status)
    }
}

struct StatusSnapshot: Sendable, CustomStringConvertible, Equatable {
    enum State: String, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unknown
    }

    let state: State

    init(status: SMAppService.Status) {
        if status == .enabled { self.state = .enabled }
        else if status == .requiresApproval { self.state = .requiresApproval }
        else if status == .notRegistered { self.state = .notRegistered }
        else if status == .notFound { self.state = .notFound }
        else { self.state = .unknown }
    }

    var isEnabled: Bool { state == .enabled }

    var description: String { state.rawValue }
}
