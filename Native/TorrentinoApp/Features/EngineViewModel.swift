// Layer: UI presentation model.
// Role: projects EngineClient results + SMAppService status into observable
// state for the lifecycle spike panel.
// Must-not: perform XPC/launchd IO synchronously, or act as source of truth.
// Invariants: MainActor-only; every engine call is async; the degraded banner
// is driven solely by SMAppService status (denied => degraded, never silent).

import Foundation

@MainActor
final class EngineViewModel: ObservableObject {
    @Published private(set) var logLines: [String] = []
    @Published private(set) var statusText: String = "unknown"
    @Published private(set) var degraded: Bool = true
    @Published private(set) var busy: Bool = false

    /// Shared with the transfer list (single XPC connection + event sink).
    let client: EngineClient

    init(client: EngineClient) {
        self.client = client
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    func appendLog(_ line: String) {
        let stamp = Self.timestampFormatter.string(from: Date())
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    // MARK: - Service registration

    /// Rebinds the LaunchAgent once during normal GUI startup, then records
    /// the resulting SMAppService state before the transfer client connects.
    /// This belongs to the app lifecycle rather than a view task: SwiftUI
    /// views can be recreated, while BTM must be re-anchored only once per
    /// process launch.
    func prepareForLaunch() async {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        appendLog("SMAppService launch rebind started (bundle=\(bundleIdentifier))")
        do {
            try await AgentServiceRegistration.register()
            appendLog("SMAppService launch rebind completed (bundle=\(bundleIdentifier))")
        } catch {
            // Keep lifecycle diagnostics useful without exposing paths or
            // system-service details that can contain user data.
            let errorType = String(reflecting: type(of: error))
            appendLog("SMAppService launch rebind failed (bundle=\(bundleIdentifier), errorType=\(errorType))")
        }

        let snapshot = await AgentServiceRegistration.status()
        applyStatus(snapshot, note: "after launch rebind")
    }

    func refreshServiceStatus() {
        Task {
            let snapshot = await AgentServiceRegistration.status()
            applyStatus(snapshot, note: nil)
        }
    }

    func register() {
        Task {
            await run("register") {
                try await AgentServiceRegistration.register()
                return "SMAppService.register() returned"
            }
            let snapshot = await AgentServiceRegistration.status()
            applyStatus(snapshot, note: "after register")
            if snapshot.state == .requiresApproval {
                appendLog("approval required: enable Torrentino in System Settings > General > Login Items")
            }
        }
    }

    func unregister() {
        Task {
            await run("unregister") {
                try await AgentServiceRegistration.unregister()
                return "SMAppService.unregister() returned"
            }
            let snapshot = await AgentServiceRegistration.status()
            applyStatus(snapshot, note: "after unregister")
        }
    }

    private func applyStatus(_ snapshot: StatusSnapshot, note: String?) {
        statusText = snapshot.description
        degraded = !snapshot.isEnabled
        let suffix = note.map { " (\($0))" } ?? ""
        appendLog("SMAppService status: \(snapshot)\(suffix)")
    }

    // MARK: - Engine operations (agent is authoritative)

    func hello() {
        Task {
            await run("hello") { [client] in
                let hello = try await client.hello()
                return "version=\(hello.agentVersion) pid=\(hello.pid)"
            }
        }
    }

    func health() {
        Task {
            await run("health") { [client] in
                let health = try await client.health()
                return health.summary
            }
        }
    }

    func increment() {
        Task {
            await run("increment") { [client] in
                let value = try await client.incrementCounter()
                return "counter=\(value)"
            }
        }
    }

    func getCounter() {
        Task {
            await run("get-counter") { [client] in
                let value = try await client.getCounter()
                return "counter=\(value)"
            }
        }
    }

    func shutdownAgent() {
        Task {
            await run("shutdown") { [client] in
                let acknowledged = try await client.shutdown()
                return acknowledged ? "agent acknowledged; it will exit 0" : "agent refused"
            }
        }
    }

    // MARK: - Plumbing

    private func run(_ name: String, _ operation: @escaping @Sendable () async throws -> String) async {
        busy = true
        defer { busy = false }
        do {
            let detail = try await operation()
            appendLog("\(name) OK — \(detail)")
        } catch {
            appendLog("\(name) FAILED — \(error)")
        }
    }
}
