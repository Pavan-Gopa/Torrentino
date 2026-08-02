# FEEDBACK — WP-02 Review

**Reviewer:** Verification Engineer  
**Date:** 2026-08-02  
**Reviewed commit:** `f9936e9` — `feat(torrentino): WP-02 — signed SMAppService lifecycle spike`  
**RESULT:** APPROVED

### 1. Build & tests

**Graphify (mandatory first step):**
```
graphify query "WP-02 SMAppService lifecycle, XPC protocol, agent registration, EngineClient, CounterStore"
```
Traversal loaded architecture context (110 nodes; bridge/harness communities dominate the existing graph — WP-02 product symbols still reviewed directly from commit sources).

**xcodebuild (reviewer re-run, Developer ID):**
| Scheme | Destination | Identity / Team | Result |
| --- | --- | --- | --- |
| `Torrentino` | `platform=macOS,arch=arm64` | `Developer ID Application` / `438UQRF7JV` | **BUILD SUCCEEDED** |
| `TorrentinoEngineAgent` | `platform=macOS,arch=arm64` | `Developer ID Application` / `438UQRF7JV` | **BUILD SUCCEEDED** |

Observed in build log:
- `swift-version 6`, `-warnings-as-errors`
- Signing Identity: `Developer ID Application: Stichting Kadamba Foundation (438UQRF7JV)`
- Hardened runtime: `flags=0x10000(runtime)` on app + embedded agent
- Agent identifier forced: `--identifier=com.torrentino.app.engine-agent`
- Embed path: `Contents/Library/LaunchAgents/` (agent binary + plist)

**Signed product layout (post-build):**
- `Torrentino.app` id `com.torrentino.app`, Team `438UQRF7JV`, runtime hardened
- Agent at `Contents/Library/LaunchAgents/TorrentinoEngineAgent`, id `com.torrentino.app.engine-agent`
- Plist keys match contract: `Label`, `BundleProgram`, `MachServices`, `RunAtLoad=true`, `KeepAlive.SuccessfulExit=false`, `ExitTimeOut=30`, `ThrottleInterval=10`, `AssociatedBundleIdentifiers`
- Entitlements empty (no App Sandbox, no `get-task-allow`)

**Lifecycle / update evidence (Coder artifacts under `Native/test-results/`, accepted as gate proof):**
| Script | Evidence dir | Result |
| --- | --- | --- |
| `lifecycle_test.sh` | `lifecycle-20260802-100703/` | **30 PASS / 0 FAIL**, exit 0 |
| `update_test.sh` | `update-20260802-100559/` | **26 PASS / 0 FAIL**, exit 0 |

Earlier intermediate runs show root-cause iteration (health allowlist, SIGKILL signal evidence, launchd-only Mach for update phases) and are consistent with the Coder narrative; final evidence is clean.

### 2. Gate checklist

| Gate | Verdict | Evidence |
| --- | --- | --- |
| UI/agent lifecycle proven on signed build | **PASS** | Developer ID signed app embeds agent+plist; `lifecycle_test.sh` register → RunAtLoad spawn → XPC hello/health/increment/get → shutdown → on-demand hello → unregister (30/30). Reviewer re-build green. |
| Agent does not require root | **PASS** | User-domain LaunchAgent (`gui/$UID`); state under `~/Library/Application Support/com.torrentino.app/Engine` (0700); empty entitlements; no setuid/privilege elevation in code or scripts (`lifecycle_test.sh` must-not root). |
| No second instance | **PASS** | `flock(LOCK_EX\|LOCK_NB)` on engine dir lock (`AgentRuntime.takeInstanceLock`); duplicate direct launch exits 0 while original stays (`lock.duplicate_instance_exit0`, `lock.original_still_running`). |
| Reconnect returns authoritative state | **PASS** | After `kill -9`, counter remains 3 via XPC get (`crash.counter_survived_sigkill`); `EngineClient` max 5 attempts + backoff; agent is SoT (client must-not cache engine state). |
| Helper correctly unregisters | **PASS** | `--cli unregister` → `status=notRegistered`; `launchctl print` fails (job removed) — `unregister.not_registered`, `unregister.job_removed_from_launchd`. |
| KeepAlive, exit codes, idle policy confirmed | **PASS** | Plist: `KeepAlive.SuccessfulExit=false`, `ExitTimeOut=30`, `ThrottleInterval=10`. XPC shutdown & SIGTERM → `last exit code = 0`; SIGKILL records terminating signal / non-zero; clean exit does not auto-restart until on-demand Mach (`ondemand.hello_after_clean_exit`). |
| Denial does not include in-process fallback | **PASS** | `ServiceRegistration` / `TorrentinoApp` / `EngineViewModel` / `ContentView`: denied or non-enabled → `degraded` banner only; no in-process engine path anywhere in WP-02 surface. Contract §10. |
| N-1 / N / downgrade semantics proven | **PASS** | `update_test.sh` 26/26: v1 writes `TTC1`; v2 preserves value and migrates to `TTC2`; v1 on v2 store exits **78** + “Downgrade blocked”; corrupt checksum exits **1** + “counter store corrupt”; no listener on fault paths. |

### 3. Code quality

**Swift 6 / concurrency:**  
`SWIFT_STRICT_CONCURRENCY = complete`, warnings-as-errors in `Shared.xcconfig`; both targets compile clean. `EngineClient` is an actor; `CounterStore` is an actor; UI view model is `@MainActor` with async-only XPC/launchd work. No MainActor abuse for IO. XPC reply bridges use `ResumeGuard` for exactly-once continuation resume.

**XPC security:**  
`@objc` protocol, reply-block style; `setCodeSigningRequirement` before `resume` on both sides; `healthReplyClasses` allowlist includes **`NSDictionary` + `NSString` + `NSNumber`** (documented why-comment — top-level container validation). Frozen identifiers in `TorrentinoXPCSecurity` (single file membership in both targets).

**Atomic writes:**  
`AtomicFile.write`: write-tmp → `fsync(file)` → `rename` → `fsync(dir)`; mode 0600; FNV-1a64 on v2; downgrade/corrupt never silent-overwrite.

**EngineClient:**  
Bounded reconnect (5 attempts, backoff `[0.25,0.5,1,2,4]` s); interruption/invalidation handlers use `[weak self]` → actor Task; no retain cycle on connection.

**AgentRuntime:**  
`XPC_SERVICE_NAME` launchd-only guard (fail loud exit 1); SIGTERM/SIGINT → shared `initiateStop` (flush + exit 0); dual-instance clean exit 0; ListenerDelegate holds strong ref while `NSXPCListener.delegate` is weak.

**Comments / role headers:**  
Present on all product files (Layer / Role / Must-not / Invariants). Why-comments at non-obvious sites: LaunchAgents path, NSDictionary allowlist, launchd-only Mach, KeepAlive.SuccessfulExit, shutdown ack-before-exit, atomic rename, ResumeGuard.

**Minor non-blocking nits (do not block APPROVED):**
1. **Contract vs code lock filename:** `LIFECYCLE_CONTRACT.md` documents `<engine dir>/agent.lock`; implementation uses `instance.lock` (`AgentRuntime.swift` ~L159). Behavior is proven; doc should align in a follow-up.
2. **Migration timing wording:** contract §8 says v1→v2 rewrite “on the next persist”; `CounterStore.loadOrMigrate` rewrites on load. Functional tests pass; wording could match code.

### 4. Architecture compliance

| Check | Verdict |
| --- | --- |
| Target scope (WP-02 only) | **PASS** — app, agent, Config, xcodeproj; no libtorrent facade, no WP-03+ surfaces |
| `Legacy/` untouched | **PASS** — no Legacy paths in `f9936e9` file list |
| No root requirement | **PASS** |
| No App Sandbox / no get-task-allow | **PASS** — empty entitlements, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` |
| No in-process engine fallback | **PASS** |
| Contract complete vs evidence | **PASS** — verification matrix rows map to script checks; three empirical OS constraints documented (LaunchAgents path, NSDictionary allowlist, launchd-only Mach) |
| Test harness quality | **PASS** — cleanup traps preserve `$?`; verdict not masked; deterministic OUT_DIR evidence |

### 5. If CHANGES_REQUESTED — concrete list

None. **APPROVED.**

Optional follow-ups (non-blocking): rename contract lock file to `instance.lock` (or code to `agent.lock`); align “migrate on load” wording in §8.

---

# FEEDBACK — WP-02: signed SMAppService lifecycle spike

**Role:** Implementation + verification (lifecycle & update evidence)  
**Date:** 2026-08-02

### 1. Verification results
- `Native/Config/lifecycle_test.sh` → **30 PASS / 0 FAIL**, exit code **0**.
  Evidence: `Native/test-results/lifecycle-20260802-100703/` (`EVIDENCE.md` + `evidence.log`).
  Covers: signing + hardened-runtime requirement checks, SMAppService
  register/unregister, RunAtLoad spawn, on-demand Mach respawn after SIGKILL,
  XPC round-trips (hello/health/increment/get/shutdown), counter durability
  across `kill -9`, KeepAlive crash-respawn, graceful-stop exit codes (XPC
  shutdown and SIGTERM → `last exit code = 0`), duplicate-instance flock
  bail-out.
- `Native/Config/update_test.sh` → **26 PASS / 0 FAIL**, exit code **0**.
  Evidence: `Native/test-results/update-20260802-100559/`.
  Covers: v1 (`COUNTER_FORMAT_V1`) writes `TTC1`; v2 loads + migrates the v1
  store transparently preserving the value (counter=2 → `TTC2` on next
  persist); downgrade block (v1 binary on v2 file → exit `78` + fatal log, no
  listener started); checksum corruption (flipped byte → exit `1` + "counter
  store corrupt"); SIGTERM → `last exit code = 0` for both versions.
- Post-test state clean: no loaded `com.torrentino.app.engine-agent` job, no
  stray agent process, engine dir removed.

### 2. Root causes found during verification (and fixes)
1. **SMAppService agent plist location — registration `Code=108`.**
   `SMAppService.agent(plistName:).register()` threw `SMAppServiceErrorDomain
   Code=108` ("Unable to read plist…") although the plist was embedded and
   readable. Root cause: SMAppService resolves agent plists ONLY under
   `Contents/Library/LaunchAgents/`; the project embedded under
   `Contents/Library/LaunchServices/`. Fix: embed phase, `BundleProgram`, and
   all references moved to `LaunchAgents` (`project.pbxproj`,
   `com.torrentino.app.engine-agent.plist`, `ServiceRegistration.swift`,
   `LIFECYCLE_CONTRACT.md`). Verified empirically on macOS 26.5.
2. **XPC health reply decode failure.** `--cli health` failed with "not
   allowed class" although every value was `NSString`/`NSNumber`. Root cause:
   `NSXPCInterface` secure decoding validates the TOP-LEVEL reply container;
   `NSDictionary` itself was missing from the allowlist. Fix: added
   `NSDictionary` to `TorrentinoXPCSecurity.healthReplyClasses`
   (`TorrentinoEngineXPCProtocol.swift`).
3. **Mach check-in is launchd-only (update_test design flaw).** Directly
   launched agents ran and exited cleanly but no XPC call could reach them
   (lookup error 3 / ESRCH); unified log: `listener failed to activate:
   xpc_error=[1: Operation not permitted]`. Root cause: macOS 26.5 rejects
   legacy bootstrap registration of named Mach services from non-launchd
   processes; the agent silently became a zombie. Fix: (a)
   `AgentRuntime.beginServing()` now exits `1` with a fatal stderr message
   when `XPC_SERVICE_NAME` is unset (launchd always sets it to the job label)
   — fail loud instead of silent zombie; (b) `update_test.sh` serving phases
   now run v1/v2 through temporary `launchctl bootstrap gui/$UID` jobs
   mirroring the production plist (same label, MachServices, RunAtLoad,
   KeepAlive.SuccessfulExit), bootout between phases and at exit. Fault phases
   (downgrade/corruption) still run the binary directly — they exit during
   bootstrap BEFORE the Mach check-in.
4. **Test-harness verdict masking.** The `EXIT` cleanup traps exited with the
   cleanup status, clobbering the verdict. Fix: both scripts capture `$?` at
   trap entry and re-exit with it. Additionally `lifecycle_test.sh` accepts
   launchd's `last terminating signal = Killed: 9` as SIGKILL evidence
   (launchd does not always record a non-zero `last exit code` for
   signal-kills) and runs single-instance lock checks before agent shutdown.

### 3. Files changed this round
- `Native/TorrentinoEngineAgent/XPC/TorrentinoEngineXPCProtocol.swift` — `NSDictionary` in health reply allowlist.
- `Native/TorrentinoEngineAgent/Agent/AgentRuntime.swift` — launchd-only serving guard (`XPC_SERVICE_NAME`).
- `Native/Config/lifecycle_test.sh`, `Native/Config/update_test.sh` — verdict preservation, SIGKILL evidence, temporary-launchd-job redesign.
- `Native/Config/LIFECYCLE_CONTRACT.md` — LaunchAgents discovery note, NSDictionary note, launchd-only Mach check-in constraint, verification matrix.
- `LaunchServices` → `LaunchAgents`: `project.pbxproj`, `com.torrentino.app.engine-agent.plist`, `ServiceRegistration.swift`.

### 4. Checklist
- [x] lifecycle_test.sh 30/30, exit 0
- [x] update_test.sh 26/26, exit 0
- [x] No residual launchd job / agent process / engine dir after tests
- [x] Contract doc updated with the three empirically-proven OS constraints
- [x] Legacy/ untouched

---
**RESULT:** [WP-02 VERIFIED]

---

# FEEDBACK — WP-01: arm64 macOS libtorrent proof-of-build

**Reviewer:** Verification Engineer (attempt 3 re-review)  
**Reviewed commit:** `4fb2def` — `fix(torrentino): WP-01 soak root cause — flush_cache barrier before digest`  
**Date:** 2026-08-02

### 1. Build & tests
- Builds/tests after changes? **Yes**
- Commands run:
  * `graphify query "soak.cpp flush_cache barrier, cache_flushed_alert, harness architecture"` → graph context (168h Soak Test / FOUNDATION track) loaded first.
  * `bash Native/TorrentinoEngineBridge/scripts/run_tests.sh` → **PASS**: **11 passed, 0 failed** (total 2.423s). Log: `runs/tests-2.1.0-release-20260802T022321Z/scenarios.log`.
  * `bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh` → **PASS**: **11 passed, 0 failed, 0 sanitizer reports** (ASan/UBSan clean, 2.662s). Log: `runs/sanitizers-2.1.0-20260802T022332Z/sanitizers.log`.
  * `bash Native/TorrentinoEngineBridge/scripts/run_soak.sh status` → **RUNNING** (pid 34809, elapsed ~7h32m, RSS ~28 000 KiB ≈ 27 MiB).
  * Soak evidence (live process + log):
    * Started `2026-08-01T18:51:17Z` / local `Sun Aug 2 00:21:17 2026` on binary mtime `00:21:16` (matches fixed `soak.cpp` mtime `00:20:35`).
    * Binary strings include `cache_flushed_alert (disk I/O drained)`, `payload digest mismatch | expected=`, `last_write_ms_since_epoch=` — **running binary is the fixed build**.
    * Progress: **25800+ iterations**, **~101 GB** transferred, **rss=26 MiB peak=29 MiB**, slowest=5.006s.
    * **0 errors** (`run_soak.sh status` error count = 0; no ERROR/mismatch/FAIL lines in active `soak.log`).
    * Past historical failure points (iter ~2240 @~39 min, iter 2594 @~45 min) by **~10×** margin; **>6000-iter / 2h gate cleared** long ago.
*Comment:* Unit/integration and sanitizer gates are green. Live soak is healthy well past the previous crash window with flat RSS — root-cause fix is empirically validated under load.

### 2. WP compliance
- All requirements of current WP met? **Yes**
  * arm64 harness + core ops covered by 11 scenarios.
  * ASan/UBSan clean.
  * 24h soak detached and running clean (0 errors, RSS not growing).
  * Soak race root cause fixed with deterministic libtorrent disk barrier (not a timing/sleep patch).
- No work from future WPs? **Yes** — no Swift, no ObjC++ facade, no `EngineCoordinator`, no XPC, no UI.
- `target_files` only? **Yes** for product code:
  * Code delta in `4fb2def`: **`Native/TorrentinoEngineBridge/harness/src/soak.cpp` only**.
  * Also updated workflow docs `AI_Workflow_Kit/docs/AI/FEEDBACK.md` + `STATE.yaml` (expected for handoff; not product surface).
  * `Legacy/Tauri/` untouched (no diff under `Legacy/`).
*Comment:* Scope is correct. The only behavioral change is the soak disk barrier + diagnostics.

### 3. Architecture invariants
- C++ exceptions contained? **Yes** — soak still runs under `run_guarded`; mismatch path throws `AssertionFailure` after structured `log_error` (still inside the firewall).
- No Homebrew runtime links? **Yes** (previously verified; no link-line change in this commit).
- Dependency lock precise? **Yes** — no changes to `versions.lock` / ThirdParty pins.
- Legacy untouched? **Yes**.
- Disk barrier correctness:
  * `session_fixture.cpp` enables `alert_category::storage` in `kAlertMask` → `cache_flushed_alert` is deliverable.
  * `flush_torrent_to_disk()`: `handle.flush_cache()` then `wait_for_alert` filtered on `lt::cache_flushed_alert` **and** matching `handle` — deterministic, handle-scoped barrier.
  * Call order in `run_cycle`: `wait_until_finished` → **`flush_torrent_to_disk`** → `save_resume_data` (resume round-trip only) → `sha256_file_hex` — correct: digest cannot race in-flight `pwrite()`.
  * Why-comments correctly document that `save_resume_data(flush_disk_cache)` is **not** a data-write barrier (timestamp/resume-buffer semantics only).
- Mismatch diagnostics present? **Yes** — expected/actual sha256, path, on-disk size vs `expected_size`, `last_write_ms_since_epoch` before throw.
*Comment:* Architecture and libtorrent alert plumbing line up with the documented barrier. This is the right API surface (`flush_cache` + `cache_flushed_alert`), not the ineffective attempt-2 flag.

### 4. Comments & readability
- Module role header present? **Yes**.
- Non-obvious logic explained with **why**? **Yes**:
  * Helper header (lines 57–61): points to call site; notes why not `save_resume_data(flush_disk_cache)`; notes `alert_category::storage` already enabled.
  * Call site (lines 105–116): explains `is_finished` vs async disk thread race, documents libtorrent guarantee, explains failure of the previous “fix”.
  * Diagnostics block (lines 126–129): explains post-barrier mismatch ⇒ real corruption, so capture size/mtime for post-mortem.
- No noisy/outdated comments? **Yes** — old incorrect claim that `save_resume_data` flushes piece data was removed.
*Comment:* Comments match the actual root cause and will prevent reintroducing the attempt-2 mistake.

### 5. If changes_requested — concrete list
None.

**Checklist (acceptance criteria):**
- [x] 11/11 tests green
- [x] ASan/UBSan clean
- [x] Soak RUNNING, 0 errors, >6000 iterations, RSS not growing (26–29 MiB, 25800+ iter, ~7.5 h)
- [x] `flush_cache()` + `cache_flushed_alert` = deterministic barrier
- [x] Why-comments: why `save_resume_data` fails as barrier; why `flush_cache` works
- [x] Mismatch diagnostics present
- [x] Product-code diff only in `soak.cpp`
- [x] Legacy untouched

---
**RESULT:** [APPROVED]
