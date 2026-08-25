# Torrentino Engine Lifecycle Contract (WP-02)

Status: FROZEN for the WP-02 spike. Changes require a plan revision (plan §23).
Scope: signed UI app (`Torrentino.app`) + embedded LaunchAgent
(`TorrentinoEngineAgent`) communicating over Mach XPC, registered through
`SMAppService`. The durable counter is spike scaffolding; WP-06 replaces it
with the real libtorrent store.

---

## 1. Frozen identifiers

| Item | Value |
| --- | --- |
| UI app bundle identifier | `com.torrentino.app` |
| LaunchAgent label | `com.torrentino.app.engine-agent` |
| LaunchAgent plist name | `com.torrentino.app.engine-agent.plist` |
| Mach service name | `com.torrentino.app.engine-agent.mach` |
| Agent code-signing identifier | `com.torrentino.app.engine-agent` |
| Team identifier | `438UQRF7JV` (Stichting Kadamba Foundation) |
| Agent location in bundle | `Torrentino.app/Contents/Library/LaunchAgents/TorrentinoEngineAgent` |
| Plist location in bundle | `Torrentino.app/Contents/Library/LaunchAgents/com.torrentino.app.engine-agent.plist` |
| Engine state directory | `~/Library/Application Support/com.torrentino.app/Engine` (0700) |
| Counter file | `<engine dir>/counter.dat` |
| Instance lock file | `<engine dir>/agent.lock` (flock) |
| Deployment target | macOS 13.0, arm64 |

All of these are compile-time constants in `TorrentinoXPCSecurity`
(`TorrentinoEngineAgent/XPC/TorrentinoEngineXPCProtocol.swift`, compiled into
BOTH targets) so the UI and agent can never drift apart.

## 2. LaunchAgent plist semantics

The plist (`Native/Config/com.torrentino.app.engine-agent.plist`) is embedded
into the app bundle by the "Embed LaunchAgent" copy phase and registered with
`SMAppService.agent(plistName:)`.

**Bundle location is load-bearing:** `SMAppService.agent(plistName:)` resolves
the plist ONLY under `Contents/Library/LaunchAgents/` (verified empirically on
macOS 26.5). Embedding it under `Contents/Library/LaunchServices/` makes
registration fail with `SMAppServiceErrorDomain Code=108` ("Unable to read
plist…"), even though the file is present and readable. The agent binary lives
next to its plist in `Contents/Library/LaunchAgents/` and `BundleProgram`
points there.

| Key | Value | Why |
| --- | --- | --- |
| `Label` | `com.torrentino.app.engine-agent` | Unique job in the user's GUI domain. |
| `BundleProgram` | `Contents/Library/LaunchAgents/TorrentinoEngineAgent` | App-bundle-relative executable (SMAppService-only key). The agent travels with the app; updates replace it atomically with the bundle. |
| `MachServices` | `{ com.torrentino.app.engine-agent.mach = true }` | launchd owns the port. If no instance is running, the first Mach message spawns the agent on demand. |
| `RunAtLoad` | `true` | Start at registration/login so the UI sees an engine immediately. |
| `KeepAlive.SuccessfulExit` | `false` | Restart ONLY after a non-zero exit (crash/SIGKILL). A clean `exit(0)` (Cmd+Q ack, SIGTERM, duplicate instance) is final until the next on-demand Mach message or re-login. Static `KeepAlive=true` is deliberately NOT used: it would fight graceful stop (ADR-004). |
| `ExitTimeOut` | `30` | On unload/logout/system shutdown launchd sends SIGTERM, waits 30 s, then SIGKILL. The agent's graceful path completes in milliseconds. |
| `ThrottleInterval` | `10` | A crash-looping agent is respawned at most once per 10 s. |
| `AssociatedBundleIdentifiers` | `com.torrentino.app` | Shows the job under Torrentino in System Settings > Login Items. |


### 2.1 Registration & Rebind Policy (WP22-D6-SERVICE-003)

- **Normal GUI Startup (`EngineViewModel.prepareForLaunch`)**: Idempotent check (`AgentServiceRegistration.register(forceRebind: false)`). If `SMAppService.status == .enabled`, registration is a no-op so a running, healthy LaunchAgent is not un-registered or interrupted with a SIGTERM. If status is `.notRegistered` or `.notFound`, it performs initial registration.
- **Explicit Register Action (Settings UI / `Torrentino --cli register`)**: Explicit rebind (`AgentServiceRegistration.register(forceRebind: true)`). If `status == .enabled`, it unregisters and re-registers the agent (`SMAppService.unregister` followed by `SMAppService.register`), forcing BackgroundTaskManagement to re-anchor against the current app bundle (useful when the app bundle was moved or replaced).
- **Approval State (`.requiresApproval`)**: Registration never unregisters an agent requiring approval, ensuring user approval status is truthfully preserved and never bypassed.
## 3. Process exit codes

| Code | Meaning | launchd consequence |
| --- | --- | --- |
| `0` | Clean stop: XPC `shutdown` ack, SIGTERM/SIGINT, or duplicate-instance bail-out (flock already held). | No restart (`KeepAlive.SuccessfulExit=false`). The Mach service stays registered; the next message respawns on demand. |
| `1` | Bootstrap fault: lock IO failure, counter IO/corruption, listener failure. | Restart, throttled to 10 s. |
| `78` | Downgrade blocked: `counter.dat` format is NEWER than this binary supports (`EX_CONFIG` from `sysexits.h`). | Restart would be pointless; launchd throttles it. The UI must surface "reinstall the newer version". |

Signals: SIGTERM/SIGINT/SIGHUP/SIGPIPE default dispositions are ignored; GCD
signal sources drive the shared graceful-stop path (`initiateStop`), which
flushes the counter and exits `0`. SIGKILL is of course uncatchable; the
counter survives it because every increment persists before replying.

## 4. XPC protocol (frozen wire contract)

`TorrentinoEngineXPCProtocol` (`@objc`, reply-block style). The agent checks the exact live client `SecCode` (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity` via shared `TorrentinoXPCSecurity.validateDynamicPeer`) on each suspended accepted connection in `listener(_:shouldAcceptNewConnection:)` before configuring interfaces, exporting objects, acquiring remote proxy, attaching handlers, or resuming the connection. The UI performs static package preflight, resumes a candidate connection, sends one bounded identity-neutral `hello` bootstrap, verifies live PID equality + exact dynamic Security validation (`SecCodeCheckValidity` with cached requirement), and permits any other request only after authentication succeeds. Public `hello()` repeats normally; no payload or mutation is permitted before authentication. Foundation `setConnectionCodeSigningRequirement` and `setCodeSigningRequirement` setters false-reject valid peers on tested macOS 26.6.2 (and macOS 13+) and are not trust mechanisms; direct Security.framework dynamic code-signing evaluation is authoritative.
| Selector | Reply | Semantics |
| --- | --- | --- |
| `helloWithReply:` | `(String agentVersion, Int64 pid)` | Handshake; used to detect respawns (pid change) and version (update test). |
| `healthWithReply:` | `([String: Any])` plist-only: `agentVersion: NSString`, `pid/uptimeSeconds/counter: NSNumber`, `counterFormat/machService: NSString` | Health snapshot. Allowed classes are whitelisted via `NSXPCInterface.setClasses` on both sides. The allowlist MUST include `NSDictionary` itself: secure decoding validates the top-level reply container, so allowing only `NSString`/`NSNumber` fails the whole reply with "not allowed class" even though every value conforms. |
| `incrementCounterWithReply:` | `(Int64 newValue)` | Atomic increment + durable persist; `-1` sentinel on persistence failure (agent stays up). |
| `getCounterWithReply:` | `(Int64 value)` | Authoritative durable value; survives SIGKILL and restarts. |
| `shutdownWithReply:` | `(Bool acknowledged)` | Graceful stop: ack FIRST, flush, then `exit(0)` ~250 ms later so the reply drains. |

## 5. Code-signing policy

Both products are signed `Developer ID Application` with the hardened runtime
(`flags=0x10000(runtime)`), no `get-task-allow`, no App Sandbox.

- Agent enforces on incoming UI connections:
  On each suspended accepted connection in `shouldAcceptNewConnection`, before any interface setup or resume, the agent evaluates the live client PID against the cached exact requirement `identifier "com.torrentino.app" and anchor apple generic and certificate leaf[subject.OU] = "438UQRF7JV"` via `TorrentinoXPCSecurity.validateDynamicPeer` (`SecCodeCopyGuestWithAttributes` + `SecCodeCheckValidity`). Foundation setter `setConnectionCodeSigningRequirement` is removed because Foundation setters false-reject valid peers on tested macOS 26.6.2 and are not trust mechanisms.
- UI enforces on the agent candidate connection:
  Static embedded binary preflight (`validateAgentBinary`), followed by dynamic live-PID SecCode requirement validation (`validateRunningAgent` via `TorrentinoXPCSecurity.validateDynamicPeer` using `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity` with cached exact requirement `identifier "com.torrentino.app.engine-agent" and anchor apple generic and certificate leaf[subject.OU] = "438UQRF7JV"`). Foundation setter `setCodeSigningRequirement` is not used because Foundation setters false-reject valid peers on tested macOS 26.6.2 and are not trust mechanisms.

The agent tool gets its identifier via
`OTHER_CODE_SIGN_FLAGS = --identifier=com.torrentino.app.engine-agent`
(command-line tools have no Info.plist to derive it from).


## 6. Shutdown budgets (ADR-004)

- UI quit path (`applicationShouldTerminate`): asks the agent to stop, waits
  AT MOST 5 s for the ack (`TerminationCoordinator` + `withTimeout`), then
  terminates regardless. The UI is never held hostage by the engine.
- Agent after ack: flush + `exit(0)` within ~250 ms.
- launchd `ExitTimeOut`: 30 s SIGTERM→SIGKILL ceiling on logout/shutdown.

## 7. Reconnect policy (UI)

`EngineClient` keeps at most one live connection. One logical request = up to
5 transport attempts with backoff `[0.25, 0.5, 1, 2, 4]` s (~7.75 s total),
covering: on-demand Mach spawn after registration, respawn after SIGKILL
(modulo the 10 s launchd throttle — callers that expect a crash-respawn wait
for the throttle first), and transient interruptions. After the budget:
`EngineClientError.unavailable` → UI shows DEGRADED, never an in-process
engine fallback.

## 8. Durable counter formats

Little-endian payloads in `counter.dat`:

```
v1: "TTC1" || value:int64                      (12 bytes)
v2: "TTC2" || value:int64 || fnv1a64:int64     (20 bytes; checksum covers magic+value)
```

- v2 builds load v1 files and migrate transparently (rewrite as v2 on the
  next persist).
- v1 builds refuse v2 files: bootstrap throws `downgradeBlocked` → exit `78`.
- Checksum mismatch or truncation → `corrupt` → exit `1` (never silently
  overwritten).
- Writes are atomic: write-tmp → `fsync(file)` → `rename` → `fsync(dir)`.
  Readers never observe a partial payload; a crash at any point leaves either
  the old or the complete new file.

Builds select the format with `COUNTER_FORMAT_V1` in
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` (absent = v2). `update_test.sh` uses
this to produce an N-1 binary from the same source tree.

## 9. Single instance

`flock(LOCK_EX | LOCK_NB)` on `<engine dir>/agent.lock`. A second instance
(race between RunAtLoad and on-demand spawn, or a stray manual launch) exits
`0` immediately without touching the listener or the store.

**OS constraint — launchd-only Mach check-in:** named Mach services can only
be vended by launchd-managed jobs. A directly executed agent binary gets
`EPERM` on listener activation (unified log: `listener failed to activate:
xpc_error=[1: Operation not permitted]`, verified on macOS 26.5) and would sit
as a silent zombie. `AgentRuntime.beginServing()` therefore refuses to serve
unless `XPC_SERVICE_NAME` is set (launchd always sets it to the job label) and
exits `1` with a fatal stderr message otherwise. The bootstrap-fault paths
(downgrade `78`, corruption `1`) exit BEFORE this guard, so direct execution
remains a valid way to observe those exit codes — `update_test.sh` relies on
that for its fault phases and drives the serving phases through temporary
`launchctl bootstrap gui/$UID` jobs that mirror this plist's semantics.

## 10. UI state model

| SMAppService status | Engine reachable | UI state |
| --- | --- | --- |
| `.enabled` | yes | OPERATIONAL |
| `.enabled` | no (transient) | DEGRADED — reconnecting (bounded) |
| `.requiresApproval` | n/a | DEGRADED — "approve in System Settings > Login Items" |
| `.notRegistered` / `.notFound` | n/a | DEGRADED — "register the engine service" |

Denial never triggers an in-process engine fallback (plan §6).

## 11. Verification matrix

| Behavior | Script | Key evidence |
| --- | --- | --- |
| Signing + hardened runtime + frozen requirements | both (preflight) | `codesign --verify -R=<requirement>` |
| SMAppService register/unregister | `lifecycle_test.sh` | `--cli register/unregister` status lines |
| RunAtLoad spawn, Mach on-demand respawn | `lifecycle_test.sh` | pid changes across `--cli hello` |
| XPC round-trips (hello/health/increment/get/shutdown) | `lifecycle_test.sh` | `OK ...` CLI lines |
| SIGKILL durability + KeepAlive crash-respawn | `lifecycle_test.sh` | counter stable across `kill -9`; `launchctl print` last exit code |
| Graceful stop exit codes (XPC shutdown, SIGTERM) | `lifecycle_test.sh` | `launchctl print` → `last exit code = 0` |
| Duplicate-instance lock | `lifecycle_test.sh` | direct launch exits `0` while agent runs |
| v1→v2 migration preserving value | `update_test.sh` | counter + magic bytes across versions (v1/v2 served via temporary `launchctl bootstrap` jobs) |
| Downgrade block | `update_test.sh` | v1 binary exits `78` on v2 file (direct run; exits before Mach check-in) |
| Checksum corruption detection | `update_test.sh` | v2 binary exits `1` on flipped byte (direct run; exits before Mach check-in) |


### 11.1 Open Limitation (WP22-D6-CLI-004)

On tested macOS 26.6.2, direct `Torrentino --cli` app-binary invocation does not reach fresh SMAppService Mach listener (WP22-D6-CLI-004); CLI matrix rows are pending dedicated helper/LaunchServices architecture and are not current Release evidence.
Evidence lands in `Native/test-results/<test>-<timestamp>/` (`evidence.log` +
`EVIDENCE.md`).
