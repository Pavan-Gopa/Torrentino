# QA Verification Report — WP-13 ADR-020 Stabilization Campaign

**Date:** 2026-08-10
**Lane:** `[WP13-STABILITY-TEST-CAMPAIGN-002]`
**Role:** Test Engineer (functional QA; test code and defect detection only)
**Scope:** ADR-019 / ADR-020 engine stabilization matrix under feature freeze
**Verdict:** **PRODUCT GREEN** / **ENVIRONMENTAL: 13 WP-02 BLOCKED + 1 Legacy WAIVED**

---

## Executive Summary

Campaign-002 gap-fill completed. Six new deterministic XCTests added to `TransferSmokeTests` covering cells I3 (restore summary field consistency) and I8 (TransferEventBus register/unregister contract). Two new QA scripts add a campaign-002 stability matrix (`test_wp13_stability_campaign002.sh`) and I7/I9 source-contract proofs (`test_wp13_stability_i7i9.sh`).

- Full XCTest scheme: **323/323 PASS** (was 317; +6 new campaign-002 tests).
- Campaign-002 focused matrix: **6/6 PASS** via `test_wp13_stability_campaign002.sh`.
- I7/I9 source-contract proofs: **9/9 PASS** via `test_wp13_stability_i7i9.sh`.
- Cumulative QA suite: **123 scripts** → **109 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED**.
- No deterministic product-functional failures.
- No product source changed (`git diff --stat -- Native` = Tests/TransferSmokeTests.swift + scripts/qa only).

BLOCKED-seam documented: `AgentService`, `AgentHealthLane`, `CounterStore`, `DiagnosticsLogging`, and `RedactedLogFileManager` are compiled only into the TorrentinoEngineAgent executable target (not the XCTest bundle). Adding them to the test target's pbxproj Sources is forbidden under ADR-020 feature freeze. I7 and I9 live cells remain BLOCKED; source-contract proofs substitute deterministically and are included in the QA suite.

---

## Result Matrix

| Layer | Result |
| --- | --- |
| Full scheme XCTest | **323/323 PASS, 0 FAIL** (`build/WP13StabilityTester002DerivedData`) |
| New XCTest (campaign-002) | **6/6 PASS** (I3 ×3, I8 ×3 in `TransferSmokeTests`) |
| Campaign-002 stability script | **6/6 PASS** (`test_wp13_stability_campaign002.sh`) |
| I7/I9 source-contract script | **9/9 PASS** (`test_wp13_stability_i7i9.sh`) |
| Campaign-001 stability matrix | **30/30 PASS** (`test_wp13_stability_matrix.sh`) |
| Full QA suite | **109 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED** (exit 1 solely from environmental WP-02 blocks) |
| Product changes by QA | **none** |
| Product bugs opened | **0** |

### QA suite totals

```
total: 123  pass: 109  fail: 0  blocked: 13  waived: 1
(wp01: 11  wp02: 13  wp03: 8  wp04: 13  wp05: 12  wp06: 14
 wp07: 13  wp08: 16  wp09: 4  wp10: 8  wp11: 4  wp12: 4  wp13: 3)
```

---

## New Evidence This Run (Campaign-002)

| Artifact | Contract |
| --- | --- |
| `TransferSmokeTests.testWP13C002I3RestoreSummarySuccessFieldsConsistent` | I3: RestoreSummary.stored/rebuilt/skipped/failure + coordinator.sessionPhase/degradedReason/restoreRebuiltCount/restoreSkippedCount consistent on clean restore |
| `TransferSmokeTests.testWP13C002I3RestoreSummaryAnomalyFieldsConsistent` | I3: anomaly sets failure="restoreAnomaly", phase=.degraded, degradedReason matches, counts correct |
| `TransferSmokeTests.testWP13C002I3RestoreSummaryCountsAreConsistent` | I3: stored == rebuilt + skipped invariant holds after any restore |
| `TransferSmokeTests.testWP13C002I8EventBusRegisterAndUnregisterMaintainsCount` | I8: sinkCount accurately tracks register (add) and unregister (remove) across multiple sinks |
| `TransferSmokeTests.testWP13C002I8EventBusSameIDReplacesExistingSink` | I8: registering same UUID twice replaces prior sink, count stays 1 |
| `TransferSmokeTests.testWP13C002I8EventBusUnregisterNeverRegisteredIsNoop` | I8: unregistering an unknown UUID is a no-op, count stays 0 |
| `scripts/qa/test_wp13_stability_campaign002.sh` | Deterministic 6-test matrix; build-prime + focused run + xcresult assertion (6/6) |
| `scripts/qa/test_wp13_stability_i7i9.sh` | I7: 4 source-contract assertions (auth var, guard, reply(false), order); I9: 6 source-contract assertions (env override, markers, last-line proof, degraded flag, redact function, record path); BLOCKED-seam documented |

### BLOCKED-seam documentation

`AgentService`, `AgentHealthLane`, `CounterStore`, `DiagnosticsLogging`, and `RedactedLogFileManager` are compiled only into the `TorrentinoEngineAgent` executable target. The `TorrentinoEngineAgentTests.xctest` bundle's pbxproj Sources list does not include these files, and the pbxproj is frozen under ADR-020. Therefore:
- **I7 in-process**: cannot instantiate `AgentService` from the XCTest bundle → `BLOCKED-seam`
- **I9 in-process**: cannot call `TorrentinoLog.bootstrap()` from the XCTest bundle → `BLOCKED-seam`
- Source-contract static assertions substitute and are deterministic and green.

---

## ADR-020 / I1–I11 matrix mapping (campaign-002 update)

| Cell | Evidence | Status |
| --- | --- | --- |
| Lifecycle / launchd contract inventory | existing `test_wp02_*` suite | **BLOCKED this host** (Human agent present); not product fail |
| Shutdown veto (I7 in-process) | `AgentService`/`AgentHealthLane` not in test target → BLOCKED-seam; source-contract 4/4 PASS | **SOURCE-CONTRACT; BLOCKED-seam for live** |
| Shutdown veto (I7 live) | requires disposable agent/UI | **BLOCKED / deferred disposable** |
| Cold/unclean boot + monotonic lifecycle | wp06 crash cycles + TransferSmoke restore/admission tests + matrix | **PASS (in-process)** |
| Persistence/WAL/schema/generation + R0 (I1/I2) | persistence XCTest + R0 test + wp06 scripts | **PASS** |
| Restore summary fields consistent (I3) | 3 new campaign-002 XCTests cover success, anomaly, count-identity | **CLOSED** |
| Unified admission / no idle limbo (I4) | `testCommitAddImmediateStartRunningNotIdle`, multi-file offline recovery, restore warning clear | **PASS** |
| Health/activity/rates/progress (I5/I6) | StatusCache merge/clear, rates/progress projection, HealthPolicy-covered faults in wp09 | **PASS** |
| XPC races / event ordering / reconnect | IPC revision/dropped-delta/reconnect/concurrent encode + event bus coalescing/continuity | **PASS (contract)**; live multi-client still environmental |
| Bridge priorities/status/alerts | file selection priorities round-trip + wp04 alert/batching/bridge scripts | **PASS** |
| Removal keep/delete + recovery (I11 subset) | WPSafeFileOperations keep/trash/partial/move + wp10 scripts | **PASS** |
| subscribeEvents independent of coordinator (I8) | 3 new campaign-002 TransferEventBus tests (register/unregister/sinkCount in-process) | **CLOSED** |
| Diagnostics bootstrap/rotation/redaction (I9) | I9 source-contract 6/6 PASS; live first-boot marker proof remains BLOCKED-seam | **SOURCE-CONTRACT; BLOCKED-seam for live** |
| App snapshot/event projection (I10) | AppTests list projection + ETA/health gating | **PASS** |
| Deterministic stress | concurrent mixed commands, 100-row fixture, envelope concurrent stress, wp09 fault matrix | **PASS** |
| Soak preparation | wp01 soak smoke + flush barrier smoke green; multi-hour soak **not** claimed | **PREP ONLY** |

---

## Environmental notes (not product bugs)

1. **WP-02 ×13 BLOCKED** — `launchctl` job / `TorrentinoEngineAgent` process already owned by Human. Suite refuses to mutate it.
2. **Legacy WAIVED** — `test_wp03_legacy_untouched.sh` skipped under HARD BAN / removed Legacy tree.
3. **Cold focused AgentTests dependency** — pre-existing scheme hygiene; mitigated by build-prime in affected scripts and full-suite path.
4. **Disposable live I7/I9** — still require explicit Human authorization to stop/replace live agent or a dedicated disposable identity; not executed this run by design.
5. **BLOCKED-seam I7/I9 in-process** — `AgentService`, `AgentHealthLane`, `RedactedLogFileManager`, `DiagnosticsLogging` not in test target Sources (pbxproj frozen under ADR-020). Source-contract assertions substitute.

---

## Commands

```bash
xcodebuild test \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13StabilityTester002DerivedData
# → 323 passed, 0 failed

bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
# → 109 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED

git diff --stat -- Native
# → Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift | 161 +++++++++++++++++++++
#    1 file changed, 161 insertions(+)
# (new scripts/qa files are untracked; no product source changed)
```

---

## Orchestrator routing recommendation

- **No Coder fix lane** (zero product failures).
- Feature freeze remains until Human lifts ADR-020.
- Optional follow-up (Human-authorized only): disposable launchd proofs for I7 live + live I1/I9 markers with sterile Engine dir, and pbxproj update to add `AgentService`/`AgentHealthLane`/`DiagnosticsLogging`/`RedactedLogFileManager` to test target Sources.
- Queued product lane `WP13-LIVE-REMOVE-FILES-001` stays deferred under freeze.
- WP-13 not closed; stabilization automated evidence is green with 323 XCTests and 109 QA scripts PASS.
