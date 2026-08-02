// Layer: Agent entry point (TorrentinoEngineAgent executable).
// Role: process bootstrap — instance lock, durable counter load, XPC listener,
// signal handling; parks the process on GCD afterwards.
// Must-not: require root, fork/daemonize, or exit non-zero on a clean stop.
// Invariants: exactly one agent per user session (flock + Mach check-in);
// exit codes follow LIFECYCLE_CONTRACT.md — 0 clean, 1 fault, 78 downgrade.

import Foundation

@main
enum AgentMain {
    static func main() {
        let runtime: AgentRuntime
        do {
            runtime = try AgentRuntime()
        } catch CounterStoreError.downgradeBlocked(let foundFormat, let supportedFormat) {
            // A newer agent already migrated the store. Restarting forever
            // would be pointless: fail loud with a dedicated exit code so the
            // UI and launchctl evidence can distinguish this from a crash.
            FileHandle.standardError.write(Data((
                "FATAL: counter store format \(foundFormat) is newer than this agent supports " +
                "(\(supportedFormat)). Downgrade blocked — reinstall the newer app version.\n"
            ).utf8))
            exit(AgentRuntime.exitCodeDowngradeBlocked)
        } catch {
            FileHandle.standardError.write(Data("FATAL: agent bootstrap failed: \(error)\n".utf8))
            exit(AgentRuntime.exitCodeFault)
        }

        runtime.beginServing()
        // Never returns: XPC listener + signal sources keep the GCD runtime busy.
        dispatchMain()
    }
}
