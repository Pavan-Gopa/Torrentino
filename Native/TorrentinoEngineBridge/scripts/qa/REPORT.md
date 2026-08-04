# QA Verification Report — WP-09 Fault Recovery and Resource Control (+ security)

**Date:** 2026-08-04
**Role:** Test Engineer (test code and defect detection only; ADR-014 security pass)
**Verdict:** **PRODUCT GREEN / ENVIRONMENTAL LEGACY FAIL WAIVED**

---

## Executive Summary

WP-09 (fault recovery and resource control) is product-green. All product
checks pass; the only non-zero result is the pre-existing tracked working-tree
dirt reported by `test_wp03_legacy_untouched.sh` under `Legacy/Tauri`. It is
Human research dirt and was not read, edited, restored, staged, or committed by
QA (ADR-013 HARD BAN).

Review was APPROVED (e196b40) on the product fix round (3383abb). This run
re-ran the entire WP-09 fault matrix and full regression, then added
gap-filling coverage for the one functional axis that was only structurally
covered (axis 12 — health lane / watchdog disabled) plus invalid-input /
bounds / source-contract tests for volume-identity spoofing and secret
non-leakage in renderable projections.

No product bugs found this cycle.

> **Process note (for Orchestrator):** This KICK prompt referenced ADR-014
> (Tester security pass each WP + `SECURITY_FINDINGS.md`). The project state
> now carries **ADR-015** (accepted; supersedes ADR-014 operational practice):
> Test Engineer stays functional; a separate on-demand **Security Engineer**
> owns `SECURITY_FINDINGS.md`, invoked periodically / near release, not each
> WP. Per ADR-015, QA did **not** write `SECURITY_FINDINGS.md` (it remains
> untouched on disk; git confirms). The new tests below are ordinary
> invalid-input / bounds / source-contract tests (explicitly allowed for
> Tester under ADR-015). If a dedicated WP-09 security audit is desired,
> invoke the Security Engineer role. QA did not patch product code for any
> finding (ADR-013/015 invariant).

| Layer | Previous baseline | This run | Result |
| --- | --- | --- | --- |
| Full scheme XCTest | 225/225 | **227/227 PASS, 0 FAIL** | PASS |
| WP-09 fault matrix (`test_wp09_fault_matrix.sh`) | 24/24 | 24/24 PASS | PASS |
| WP-09 QA bucket (functional + security) | 1 script | 4/4 PASS | PASS |
| Full QA suite | 102/103 (1 env Legacy) | **103/104; 1 environmental Legacy FAIL** | PRODUCT GREEN / waiver |
| Headless bridge | PASS | PASS | PASS |
| Swift bridge | PASS | PASS | PASS |
| Product changes by QA | none | none | scope PASS |

## New Coverage This Cycle

| Deliverable | What it detects | Result |
| --- | --- | --- |
| `testWP09SecurityNoSecretLeakageInSnapshotsAndEvents` (XCTest, bounds/contract) | Encodes `EngineSnapshot`, `TorrentDelta`, `SettingsChangedEvent`, `SystemConditionEvent`; asserts no `password`/`secret`/`proxy` keys leak into renderable projections; negative control confirms `ProxyConfiguration` does carry the password on the command wire. | PASS |
| `testWP09SecuritySymlinkedSaveLocationVolumeSpoofingRejected` (XCTest, invalid-input) | A symlinked save location whose pinned `volumeIdentifier` does not match the resolved volume is rejected as `volumeUnavailable` (no silent foreign-volume acceptance); a missing path is never auto-created. | PASS |
| `test_wp09_sec_matrix.sh` | Runs the two runtime bounds/invalid-input XCTest cases above. | PASS |
| `test_wp09_sec_secret_hygiene.sh` (source-contract) | Renderable projections declare no secret fields; `ProxyConfiguration` is not embedded in any snapshot/event; health payload keys exclude secret/proxy; no product `print`/`os_log`/`Logger` references a secret. | PASS |
| `test_wp09_health_lane_watchdog.sh` (source-contract) | Functional axis 12: health snapshot pins `watchdog = disabled` and `healthLane = liveness`; `AgentHealthLane` is a distinct class with command-lane admission (`tryBeginCommand`/`commandLimit`) separate from engine tick/failure accounting; no watchdog restart/kill code path; `restartEngineSafely` is the crash-loop-guarded recovery path that clears `safeRecovery` and is UI-invokable. | PASS |

## WP-09 Functional Axis Coverage (15 axes)

| # | Axis | Test(s) | Status |
| --- | --- | --- | --- |
| 1 | Network offline/online; no busy-loop; resume | `testWP09OfflinePreservesDesiredStateAndRecoversWithoutSpin` | PASS |
| 2 | Path change identity (route/address → networkGeneration) | `testWP09MonitorGenerationIncludesRouteIdentity` | PASS |
| 3 | Sleep/wake gating + recovery pump | `testWP09SleepGatesWorkAndWakeRecovers`, `testWP09PumpOnceNoOpDuringSafeRecovery` | PASS |
| 4 | acceptsHeavyWork blocks heavy work (commit-add + pump) | `testWP09PressureGateBlocksHeavyWorkUntilRecovery`, `testWP09LowPowerAloneBlocksHeavyWork` | PASS |
| 5 | Disk full / permissions typed faults | `testWP09DiskFullHealthSurfacesAtCoordinatorLevel`, `testWP09PersistenceVolumeFaultCrossesCommitBoundary`, IPC storage fault test | PASS |
| 6 | Volume detach/attach; no auto-create; mismatch rejected | `testWP09StorageProbeNeverCreatesMissingVolumePath`, `testWP09VolumeIdentityAndUnknownFreeSpaceAreConservative`, `testWP09SecuritySymlinkedSaveLocationVolumeSpoofingRejected` | PASS |
| 7 | Free-space unknown does not fail-open | `testWP09VolumeIdentityAndUnknownFreeSpaceAreConservative` | PASS |
| 8 | Bounded queues: events, idempotency, inspection bytes, StatusCache | `testWP09EventBusOverflowRequestsSnapshotAndStaysBounded`, `testWP09IdempotencyTrackerEvictsOldestEntry`, `testWP09PendingInspectionBytesAreBounded`, `testWP09BridgeStatusCacheEnforcesByteBudget` | PASS |
| 9 | Bridge/engine active/peer/cache limits from budget | IPC `testWP09ResourceBudgetIsBoundedAndShrinksUnderPressure`, `testWP09BudgetConstrainedVsBalancedLimitsApplied` | PASS |
| 10 | Crash-loop safe mode + restartEngineSafely | `testWP09CrashLoopSafeModeRestartClearsAndReconciles`, `testWP09CrashLoopGuardCanBeExplicitlyCleared`, `testWP09PumpOnceNoOpDuringSafeRecovery` | PASS |
| 11 | Per-record re-add backoff | `testWP09ReaddUsesPerRecordBackoff` | PASS |
| 12 | Health lane distinct; watchdog disabled | `test_wp09_health_lane_watchdog.sh` (source-contract) + budget/safe-recovery runtime tests | PASS |
| 13 | One bad task does not global-stop | `testWP09OneBadEngineAddDoesNotBlockOtherRecords`, `testWP09TypedEngineFailureIsNotCollapsedToBusy` | PASS |
| 14 | UI surfaces key faults; restart_engine_safely invokable | `testWP09FaultRecoveryActionsContractForUISurfacing`, `test_wp09_health_lane_watchdog.sh` (UI invokable) | PASS |
| 15 | Typed faults not collapsed to engineBusy | `testWP09TypedEngineFailureIsNotCollapsedToBusy` | PASS |

## Bounds / Invalid-Input / Source-Contract Coverage This Cycle

The tests below are ordinary functional bounds/invalid-input/source-contract
tests (allowed for Tester under ADR-015). A dedicated WP-09 security audit is
the Security Engineer role's remit (ADR-015); `SECURITY_FINDINGS.md` was not
written by QA.

| Surface | Result |
| --- | --- |
| Secret non-leakage in renderable projections (bounds/contract) | PASS — runtime + source-contract gates |
| Path / volumeIdentifier spoofing via symlink (invalid-input) | PASS — pinned-volume mismatch rejected, no auto-create |
| Untrusted XPC / oversized payloads (bounds, regression) | PASS (WP-05 envelope + WP-09 bounded queues/caches) |
| Network scheme allowlist (bounds, regression) | PASS (WP-07 http_source) |
| Resource exhaustion (re-add storms, caches, queues) | PASS (per-record backoff + `acceptsHeavyWork` gate) |
| Disk-full / permission → inconsistent durable state (typed faults) | PASS — typed faults cross commit boundary |
| Restart path uses validated settings + re-probes (contract) | PASS — `restartEngineSafely` clears safeRecovery, no false-restart watchdog |

## Gate Matrix

| Gate | Evidence | Status |
| --- | --- | --- |
| Полная fault matrix зелёная | `test_wp09_fault_matrix.sh` 24/24 PASS | ✅ PASS |
| Нет busy-loop | `testWP09PumpOnceNoOpDuringSafeRecovery`, sleep/wake no-op pump | ✅ PASS |
| Нет глобального stop из-за одной задачи | `testWP09OneBadEngineAddDoesNotBlockOtherRecords` | ✅ PASS |
| Recovery actions понятны | `testWP09FaultRecoveryActionsContractForUISurfacing` (7 faults, all localized keys + actions) | ✅ PASS |
| No unexpected folder creation for missing volume | `testWP09StorageProbeNeverCreatesMissingVolumePath`, `testWP09SecuritySymlinkedSaveLocationVolumeSpoofingRejected` | ✅ PASS |
| Legacy product history clean; working-tree Legacy dirt environmental waived | `test_wp03_legacy_untouched.sh` (Legacy dirt only) | ✅ PASS (waiver) |
| Bounds/invalid-input/source-contract coverage added (ADR-015) | new XCTest + 3 QA scripts | ✅ PASS |

## Build / Configuration Evidence

| Check | Command | Result |
| --- | --- | --- |
| Full scheme build (Developer ID signed) | `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino` | **BUILD SUCCEEDED** |
| Full scheme tests | `xcodebuild test ...` | **227/227 PASS, 0 FAIL** |
| Headless bridge | `test_bridge_headless.sh` | PASS |
| Swift bridge | `test_bridge_swift.sh` | PASS |
| WP-09 fault matrix | `test_wp09_fault_matrix.sh` | 24/24 PASS |
| QA suite | `run_qa_suite.sh` | 103/104; 1 environmental Legacy FAIL |

## Environmental Waiver

`test_wp03_legacy_untouched.sh` reports tracked changes in `Legacy/Tauri`
(`README.md`, `Cargo.lock`, `Cargo.toml`, `engine.rs`, `gui.rs`,
`gui.rs.fixed`, `app.js`, `styles.css`) and untracked `Torrentino.command`,
`build-macos.sh`, `run-dev.sh`. These are pre-existing Human research changes
(ADR-013 HARD BAN). QA never read, edited, restored, staged, or committed any
Legacy file. Per the Orchestrator waiver, this failure alone does not make
WP-09 product red.

## Observations (non-blocking)

1. **`test_wp02_smappservice_register.sh` is launchd-timing sensitive.** It
   FAILed once under the full-suite parallel run ("final unregister: missing
   `status=notRegistered`") but PASSES in isolation and in a subsequent
   full-suite run (wp02: 13/13). SMAppService unregister can lag launchd under
   load; this is environmental/transient, not a product regression. Re-running
   it is the documented remediation.
2. **Low/Info observation:** `ProxyConfiguration` is `Codable` without a
   redacted `CustomStringConvertible` description; no product path stringifies
   it today (verified by `test_wp09_sec_secret_hygiene.sh`). Forward hardening
   suggested; flagged for a Security Engineer engagement, not a Tester
   deliverable.
3. Real-machine SIGKILL of the agent against the WP-06 store is not yet
   end-to-end reachable via XPC (persistence XPC surface not wired; carried
   forward from prior COVERAGE.md open gaps).
4. **ADR-014 ↔ ADR-015 conflict:** the KICK prompt referenced ADR-014
   (Tester security pass each WP + `SECURITY_FINDINGS.md`), but the project
   now carries ADR-015 (Tester stays functional; Security Engineer is a
   separate on-demand role). QA followed ADR-015 (the newer, accepted
   directive) and did not write `SECURITY_FINDINGS.md`. Orchestrator should
   reconcile the KICK template with ADR-015 and, if a WP-09 security audit is
   wanted, invoke the Security Engineer role.

## Overall Summary

- **Total QA scripts:** 104 (100 regression + **4 WP-09**) — 103 PASS, 1
  environmental Legacy FAIL (waived).
- **XCTest:** 227/227 PASS (IPC, App, Domain, EngineAgentPersistence,
  TransferSmokeTests).
- **New tests this cycle:** 2 runtime bounds/invalid-input XCTest methods +
  3 QA scripts (`test_wp09_sec_matrix.sh`, `test_wp09_sec_secret_hygiene.sh`,
  `test_wp09_health_lane_watchdog.sh`).
- **Bugs found this cycle:** 0 product bugs. 1 Low/Info observation for
  forward hardening.
- **Coverage matrix:** `AI_Workflow_Kit/docs/AI/COVERAGE.md` (functional +
  bounds/source-contract).
- **Security audit:** not performed by QA per ADR-015 (Security Engineer is
  a separate on-demand role); `SECURITY_FINDINGS.md` untouched.
