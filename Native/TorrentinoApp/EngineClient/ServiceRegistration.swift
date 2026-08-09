// Layer: UI -> ServiceManagement bridge.
// Role: register/unregister/query the engine LaunchAgent via SMAppService.
// Must-not: start an in-process engine on denial, or mutate launchd state
// without explicit user intent.
// Invariants: denial (status != .enabled) maps to UI degraded state only;
// launchd IPC never runs on the main actor (nonisolated async, SE-0338).

import Foundation
import ServiceManagement

enum AgentServiceRegistration {
    /// Frozen identifiers (plan §23, LIFECYCLE_CONTRACT.md). The app-side
    /// identity authority is PeerValidation (WP-05).
    static let plistName = PeerValidation.identity.plistFilename
    static let label = PeerValidation.identity.launchAgentLabel

    /// Registers Contents/Library/LaunchAgents/<plistName> from this bundle.
    /// Throws on failure; success still requires status == .enabled afterwards
    /// (first registration may land in .requiresApproval until the user
    /// toggles it in System Settings > Login Items).
    static func register() async throws {
        let agent = SMAppService.agent(plistName: plistName)
        // BTM self-heal: if launchd still pairs this label with a stale app
        // copy (prior build moved/removed), register() alone does not
        // re-anchor BackgroundTaskManagement and the agent spawn later fails
        // inside launchd with copy_bundle_path 0x6f / exit 78 (EX_CONFIG) even
        // though this binary starts fine. Re-writing the entry
        // (unregister + register) while status == .enabled forces BTM to
        // re-resolve against the current app bundle. Fresh registrations skip
        // the extra pair.
        if agent.status == .enabled {
            try await agent.unregister()
        }
        try agent.register()
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
