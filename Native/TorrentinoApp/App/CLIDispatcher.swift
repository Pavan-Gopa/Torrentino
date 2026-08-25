// Layer: UI automation hook (headless mode).
// Role: lets lifecycle_test.sh / update_test.sh drive the real XPC and
// SMAppService flows from the shipped, signed binary — no GUI needed.
// Must-not: change engine semantics relative to GUI mode, or run when --cli
// is absent.
// Invariants: prints one machine-readable result line per command; exit codes:
// 0 ok · 1 usage · 2 unreachable · 3 denied/not-registered.

import Foundation
import TorrentinoIPC

enum CLIDispatcher {
    static func runIfRequestedAndExit() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--cli") else { return }
        let command = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : ""

        // Bridge async work into the synchronous App.init: a detached task
        // does the work, a semaphore bounds it. Blocking here is safe — the
        // run loop has not started and no main-actor work is pending.
        let exitCode = ExitCodeBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let code = await execute(command: command)
            exitCode.set(code)
            semaphore.signal()
        }
        switch semaphore.wait(timeout: .now() + 30) {
        case .success:
            exit(exitCode.get())
        case .timedOut:
            FileHandle.standardError.write(Data("cli timed out\n".utf8))
            exit(2)
        }
    }

    private static func execute(command: String) async -> Int32 {
        let client = EngineClient()
        switch command {
        case "hello":
            do {
                let hello = try await client.hello()
                print("OK hello version=\(hello.agentVersion) pid=\(hello.pid)")
                return 0
            } catch {
                print("FAIL hello error=\(error)")
                return 2
            }

        case "health":
            do {
                let health = try await client.health()
                print("OK health \(health.summary)")
                return 0
            } catch {
                print("FAIL health error=\(error)")
                return 2
            }

        case "snapshot":
            do {
                let command = EngineCommandV1.fetchSnapshot(FetchSnapshotRequest(requestID: RequestID(), afterRevision: nil))
                let reply = try await client.sendCommand(command)
                if case .snapshot(let snapshot) = reply {
                    for t in snapshot.torrents {
                        print("TORRENT id=\(t.id) name=\"\(t.displayName)\" desired=\(t.desiredState) activity=\(t.activity) health=\(t.health) downBps=\(t.rates.downloadBytesPerSec) upBps=\(t.rates.uploadBytesPerSec) peers=\(t.peers.connected) bytes=\(t.progress.downloadedBytes)/\(t.progress.totalBytes)")
                    }
                }
                return 0
            } catch {
                print("FAIL snapshot error=\(error)")
                return 2
            }

        case "increment":
            do {
                let value = try await client.incrementCounter()
                print("OK increment counter=\(value)")
                return 0
            } catch {
                print("FAIL increment error=\(error)")
                return 2
            }

        case "get-counter":
            do {
                let value = try await client.getCounter()
                print("OK counter=\(value)")
                return 0
            } catch {
                print("FAIL get-counter error=\(error)")
                return 2
            }

        case "shutdown":
            do {
                let acknowledged = try await client.shutdown()
                print(acknowledged ? "OK shutdown acknowledged=true" : "OK shutdown acknowledged=false")
                return acknowledged ? 0 : 2
            } catch {
                print("FAIL shutdown error=\(error)")
                return 2
            }

        case "register":
            do {
                try await AgentServiceRegistration.register(forceRebind: true)
                let snapshot = await AgentServiceRegistration.status()
                print("OK register status=\(snapshot)")
                return snapshot.isEnabled ? 0 : 3
            } catch {
                print("FAIL register error=\(error)")
                return 1
            }

        case "unregister":
            do {
                try await AgentServiceRegistration.unregister()
                let snapshot = await AgentServiceRegistration.status()
                print("OK unregister status=\(snapshot)")
                return 0
            } catch {
                print("FAIL unregister error=\(error)")
                return 1
            }

        case "status":
            let snapshot = await AgentServiceRegistration.status()
            print("STATUS service=\(snapshot)")
            guard snapshot.isEnabled else {
                print("STATE degraded reason=service-\(snapshot)")
                return 3
            }
            do {
                let hello = try await client.hello()
                print("STATE operational version=\(hello.agentVersion) pid=\(hello.pid)")
                return 0
            } catch {
                print("STATE degraded reason=unreachable error=\(error)")
                return 2
            }

        default:
            print("usage: Torrentino --cli <hello|health|increment|get-counter|shutdown|register|unregister|status>")
            return 1
        }
    }
}

/// Thread-safe exit-code handoff between the detached CLI task and the
/// blocking App.init path.
private final class ExitCodeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 1

    func set(_ newValue: Int32) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
