# QA Verification Report — WP-13 ADR-020 Stabilization Campaign

**Date:** 2026-08-10  
**Lane:** `[WP13-STABILITY-TEST-CAMPAIGN-001]`  
**Role:** Test Engineer (functional QA; test code and defect detection only)  
**Scope:** ADR-019 / ADR-020 engine stabilization matrix under feature freeze  
**Verdict:** **PRODUCT GREEN** / **ENVIRONMENTAL: 13 WP-02 BLOCKED + 1 Legacy WAIVED**

---

## Executive Summary

Stabilization campaign inventory + gap fill completed without product edits.

- Full XCTest scheme: **317/317 PASS** (was 315; +2 new WP-13 stability tests).
- Focused stability matrix harness: **30/30 PASS** via `test_wp13_stability_matrix.sh`.
- Cumulative QA suite: **121 scripts** → **107 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED**.
- No deterministic product-functional failures.
- No product source changed (`git diff --stat -- Native` = Tests + `scripts/qa` only).

WP-02 live launchd scripts were intentionally **BLOCKED** because a pre-existing Human `com.torrentino.app.engine-agent` session was present. Per ADR-020 they must not touch Human Engine/launchd state. Legacy check was **WAIVED** (Legacy tree removed / HARD BAN).

---

## Result Matrix

| Layer | Result |
| --- | --- |
| Full scheme XCTest | **317/317 PASS, 0 FAIL** (`build/WP13StabilityTesterDerivedData` result bundle) |
| New XCTest | **2/2 PASS** (`testWP13StabilityR0DegradesAndFailsSnapshotClosed`, `testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation`) |
| Stability matrix script | **30/30 PASS** (`test_wp13_stability_matrix.sh`) |
| Full QA suite | **107 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED** (exit 1 solely from environmental WP-02 blocks) |
| Product changes by QA | **none** |
| Product bugs opened | **0** |

### QA suite totals

```
total: 121  pass: 107  fail: 0  blocked: 13  waived: 1
(wp01: 11  wp02: 13  wp03: 8  wp04: 13  wp05: 12  wp06: 14
 wp07: 13  wp08: 16  wp09: 4  wp10: 8  wp11: 4  wp12: 4  wp13: 1)
```

---

## New evidence this run

| Artifact | Contract |
| --- | --- |
| `TransferSmokeTests.testWP13StabilityR0DegradesAndFailsSnapshotClosed` | I1 R0: invalid core identity → `sessionPhase=degraded(restoreAnomaly)`, snapshot fail-closed with correlated `internalError`, empty snapshot not published |
| `TransferSmokeTests.testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation` | Diagnostics redaction keeps request-ID correlation, strips home paths / password / bearer token |
| `scripts/qa/test_wp13_stability_matrix.sh` | Deterministic 30-test matrix across admission, restore, health/rates, XPC-ish event continuity, persistence/WAL, removal, app projection, IPC reconnect — TestProfile only |
| `run_qa_suite.sh` | Includes `test_wp13_stability_*.sh`; blocks live WP-02 when Human agent present; waives Legacy |

### Stale QA script realignments (not product bugs)

| Script | Change |
| --- | --- |
| `test_wp03_empty_state.sh` | Empty state now uses branded `AppLogo` + add action |
| `test_wp03_domain_types.sh` / `test_wp03_ipc_envelope.sh` | Prime app product before cold focused targets (known dependency-order hygiene) |
| `test_wp03_strict_concurrency.sh` | Ignore Xcode 26 AppIntents metadata tool warning only |
| `test_wp08_dnd_association.sh` | Match accepted `TorrentDropRouting` drop gate |

---

## ADR-020 / I1–I11 matrix mapping

| Cell | Evidence | Status |
| --- | --- | --- |
| Lifecycle / launchd contract inventory | existing `test_wp02_*` suite | **BLOCKED this host** (Human agent present); not product fail |
| Shutdown veto (I7 live) | requires disposable agent/UI | **BLOCKED / deferred disposable** |
| Cold/unclean boot + monotonic lifecycle | wp06 crash cycles + TransferSmoke restore/admission tests + matrix | **PASS (in-process)** |
| Persistence/WAL/schema/generation + R0 (I1/I2) | persistence XCTest + new R0 test + wp06 scripts | **PASS** |
| Unified admission / no idle limbo (I4) | `testCommitAddImmediateStartRunningNotIdle`, multi-file offline recovery, restore warning clear | **PASS** |
| Health/activity/rates/progress (I5/I6) | StatusCache merge/clear, rates/progress projection, HealthPolicy-covered faults in wp09 | **PASS** |
| XPC races / event ordering / reconnect | IPC revision/dropped-delta/reconnect/concurrent encode + event bus coalescing/continuity | **PASS (contract)**; live multi-client still environmental |
| Bridge priorities/status/alerts | file selection priorities round-trip + wp04 alert/batching/bridge scripts | **PASS** |
| Removal keep/delete + recovery (I11 subset) | WPSafeFileOperations keep/trash/partial/move + wp10 scripts | **PASS** |
| Diagnostics bootstrap/rotation/redaction (I9) | redacted sink rotate test + new redaction correlation test + `test_wp13_diagnostics_security.sh` | **PASS (in-process)**; live first-boot marker proof remains disposable/live gate |
| App snapshot/event projection (I10) | AppTests list projection + ETA/health gating | **PASS** |
| Deterministic stress | concurrent mixed commands, 100-row fixture, envelope concurrent stress, wp09 fault matrix | **PASS** |
| Soak preparation | wp01 soak smoke + flush barrier smoke green; multi-hour soak **not** claimed | **PREP ONLY** |

---

## Environmental notes (not product bugs)

1. **WP-02 ×13 BLOCKED** — `launchctl` job / `TorrentinoEngineAgent` process already owned by Human. Suite refuses to mutate it.
2. **Legacy WAIVED** — `test_wp03_legacy_untouched.sh` skipped under HARD BAN / removed Legacy tree.
3. **Cold focused AgentTests dependency** — pre-existing scheme hygiene; mitigated by build-prime in affected scripts and full-suite path.
4. **Disposable live I1/I7/I9** — still require explicit Human authorization to stop/replace live agent or a dedicated disposable identity; not executed this run by design.

---

## Commands

```bash
xcodebuild test \
  -project Native/Torrentino.xcodeproj \
  -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13StabilityTesterDerivedData
# → 317 passed, 0 failed

bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
# → 107 PASS / 0 FAIL / 13 BLOCKED / 1 WAIVED
```

---

## Orchestrator routing recommendation

- **No Coder fix lane** (zero product failures).
- Feature freeze remains until Human lifts ADR-020.
- Optional follow-up (Human-authorized only): disposable launchd proofs for I7 + live I1/I9 markers with sterile Engine dir.
- Queued product lane `WP13-LIVE-REMOVE-FILES-001` stays deferred under freeze.
- WP-13 not closed; stabilization automated evidence is green.
