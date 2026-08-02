# WP-01 Final Verification Report — Test Engineer

**Date:** 2026-08-02  
**Branch:** `native-macos`  
**WP:** WP-01 — libtorrent arm64 bakeoff  
**Role:** Test Engineer (final verification; product code not modified)  
**Graphify:** `graphify query "WP-01 test scenarios, harness architecture, soak test, sanitizer suite"` — OK (BFS; soak/No Homebrew/Test Engineer nodes present)

---

## Verdict: **GREEN**

All mandatory verification steps passed. Soak is healthy mid-run toward the 24h gate (not yet finished; no failures).

---

## 1. Suite results

| # | Check | Command / evidence | Result |
|---|--------|-------------------|--------|
| 1 | Unit/Integration | `bash Native/TorrentinoEngineBridge/scripts/run_tests.sh` | **11/11 PASS** (2.397s) |
| 2 | ASan + UBSan | `bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh` | **11/11 PASS**, **0 sanitizer reports** |
| 3 | Soak status | `bash Native/TorrentinoEngineBridge/scripts/run_soak.sh status` | **RUNNING**, 0 errors, 26086+ iters, RSS stable |
| 4 | No Homebrew links | `verify_no_homebrew.sh …/harness-2.1.0-release/torrentino-harness` | **CLEAN** (system libs only) |
| 5 | Dependency lock | `Native/ThirdParty/versions.lock` | **PASS** — pins + SHA-256 |
| 6 | Build reproducibility | `bash Native/ThirdParty/libtorrent/build.sh --flavor release` | **PASS** — `libtorrent-rasterbar.a` arm64 |
| 7 | Fallback 2.0.13 | `run_tests.sh --lt-version 2.0.13` | **11/11 PASS** (2.427s) |
| 8 | Crash restore | `crash_restore` in scenarios.log | **PASS** (SIGKILL + restore) |
| 9 | C-ABI firewall | `harness_api.h` + `harness_api.cpp` / `support.cpp` | **PASS** |
| 10 | Legacy untouched | `git diff --name-only HEAD~5 -- Legacy/` | **empty** (0 files) |

### 1.1 Unit/Integration (2.1.0/release)

Log: `Native/TorrentinoEngineBridge/runs/tests-2.1.0-release-20260802T022719Z/scenarios.log`

| Scenario | Result |
|----------|--------|
| `session_lifecycle` | PASS |
| `torrent_creation` | PASS |
| `add_torrent_file` | PASS |
| `info_hash_recognition` | PASS |
| `pause_resume` | PASS |
| `resume_data` | PASS |
| `session_state` | PASS |
| `exception_containment` | PASS |
| `magnet_metadata` | PASS |
| `data_transfer` | PASS |
| `crash_restore` | PASS |

**Summary:** `11 passed, 0 failed, total 2.397s` → `RESULT: PASS`

### 1.2 Sanitizer suite (ASan + UBSan, 2.1.0)

Log: `Native/TorrentinoEngineBridge/runs/sanitizers-2.1.0-20260802T022728Z/sanitizers.log`

- All 11 scenarios PASS (total 2.665s)
- `sanitizer reports: 0`
- `RESULT: PASS — ASan/UBSan clean`

### 1.3 Soak (live)

At verification time:

| Metric | Value |
|--------|-------|
| Status | **RUNNING** (pid 34809) |
| Elapsed | **~7h36m** |
| Iterations | **26086+** (>> 6000) |
| Bytes transferred | **~102.6 GB** |
| Errors | **0** |
| RSS (sampled) | **26–29 MiB** |
| Peak RSS | **29 MiB** (stable across run) |
| Slowest iteration | 5.006s |

RSS distribution across progress samples (not monotonic growth):

- early: rss=28–29 MiB
- mid/late: predominantly rss=26 MiB (73 samples), peak capped at 29 MiB
- late sample: `rss=27MiB peak=29MiB` at 7h35m

**RSS does not grow monotonically** — memory is stable within a 26–29 MiB band for 7.5+ hours.

**Note:** `Native/TorrentinoEngineBridge/runs/soak/soak-report.json` still holds a **stale** prior run (`status: assertion_failed`, iteration 2594, ~45 min, timestamp 2026-08-01T18:29). That artifact is **not** from the current process. Live `run_soak.sh status` reports **0 errors**. Recommend orchestrator/coder treat report.json as last-finished-run only; live status is authoritative while RUNNING.

**24h gate:** **ON TRACK, not yet complete** (~7.5h / 24h). Acceptance for this verification pass matches the stated criteria (RUNNING, 0 errors, >6000 iters, RSS stable). Full gate closure requires soak to finish 24h with the same invariants.

### 1.4 No Homebrew runtime links

Binary: `Native/TorrentinoEngineBridge/.build/harness-2.1.0-release/torrentino-harness`

- Mach-O arm64, minOS 13.0
- Linked: CoreFoundation, SystemConfiguration, `libc++.1.dylib`, `libSystem.B.dylib` — all under `/System` or `/usr/lib`
- rpaths: none
- Result: `OK: arm64, macOS 13.0+, system libraries only`

### 1.5 Dependency lock (`Native/ThirdParty/versions.lock`)

| Dep | Version | SHA-256 present |
|-----|---------|-----------------|
| libtorrent primary | **2.1.0** (tag v2.1.0, commit `578e068…`) | yes |
| libtorrent fallback | **2.0.13** (tag v2.0.13, commit `7d7fc38…`) | yes |
| Boost | **1.91.0** | yes |
| OpenSSL | **3.5.7** | yes |
| Platform | arm64, minOS 13.0, C++17 | yes |

### 1.6 Build reproducibility

`bash Native/ThirdParty/libtorrent/build.sh --flavor release` completed without error:

- Archive SHA-256 checks OK (openssl, boost, libtorrent)
- Install prefix: `…/prefix/libtorrent-2.1.0-release`
- Artifact: `lib/libtorrent-rasterbar.a` — **arm64** ar archive
- Linked static deps: libcrypto.a / libssl.a arm64, minOS 13.0
- `artifact verification passed`

### 1.7 Fallback version 2.0.13

Log: `Native/TorrentinoEngineBridge/runs/tests-2.0.13-release-20260802T022728Z/scenarios.log`

- Flag supported: `--lt-version 2.0.13`
- **11 passed, 0 failed**, including `crash_restore` and `exception_containment`
- `RESULT: PASS`

### 1.8 Crash restore scenario

From 2.1.0 scenarios.log:

```
=== crash_restore: kill -9 a child mid-flight and restore registry + partial data
spawned crash child pid=66668
child: state persisted (2097152 bytes verified), killing self
child terminated by SIGKILL as expected
restored 2097152/4194304 bytes after kill -9 (id=e5af4f7afc6ef3a69c32fd0669ffa756f41e6f95)
--- PASS crash_restore (0.143s)
```

Asserts covered: registry, session state, resume data, torrent metadata survive SIGKILL; partial verified bytes restored without loss.

### 1.9 C-ABI exception firewall

**Header contract** (`harness/include/torrentino/harness/harness_api.h`):

- Documents exception firewall: C ABI, no throw through boundary, status codes only
- `torrentino_harness_main` is the single entry point

**Implementation** (verified in source; not only header):

| Layer | Location | Behavior |
|-------|----------|----------|
| Per-scenario | `support.cpp` → `run_guarded` | catch chain incl. `catch (...)`; maps to `Outcome` / status |
| C ABI boundary | `harness_api.cpp` → `torrentino_harness_main` | outer `try/catch` incl. `catch (...)` |
| Last resort | `harness_api.cpp` → `std::set_terminate(&on_terminate)` | logs FATAL if unwind escapes; `_Exit` with unknown_exception |
| Scenario proof | `exception_containment` | injects garbage bdecode, empty magnet, `throw 42` — all contained |

### 1.10 Legacy untouched

```
git diff --name-only HEAD~5 -- Legacy/
```

Empty output → **no Legacy/ changes** in last 5 commits.

---

## 2. Gap hunt — WP-01 gates (`TORRENTINO_STEPS.md`)

| Gate | Covered by | Status | Evidence |
|------|------------|--------|----------|
| Restore без потери registry/partial data | `crash_restore` scenario in `run_tests.sh` | **PASS** | SIGKILL child; 2097152/4194304 bytes restored; registry/session/resume files present |
| Нет Homebrew runtime links | `verify_no_homebrew.sh` | **PASS** | only `/System` + `/usr/lib`; no Homebrew paths |
| Точный dependency lock | `Native/ThirdParty/versions.lock` | **PASS** | LT 2.1.0/2.0.13, Boost 1.91.0, OpenSSL 3.5.7 + SHA-256 |
| Все C++ exceptions остаются внутри harness | `run_guarded` + C ABI try/catch + `set_terminate`; `exception_containment` | **PASS** | scenario PASS; firewall code present |
| ASan/UBSan clean | `run_sanitizers.sh` | **PASS** | 11/11, 0 reports |
| 24h soak без crash/hang | `run_soak.sh status` | **ON TRACK** | RUNNING 7.5h+, 26086+ iters, 0 errors, RSS non-monotonic 26–29 MiB; **full 24h not yet elapsed** |

### Additional task coverage (WP-01 tasks, not only gate bullets)

| Task | Status |
|------|--------|
| Stable libtorrent 2.x pin | PASS (2.1.0 default) |
| Boost/TLS fixed | PASS (Boost 1.91.0, OpenSSL 3.5.7) |
| Headless arm64 harness | PASS |
| Scenario matrix (add, magnet, pause/resume, IDs, resume, session, shutdown, crash, create) | PASS (all 11) |
| ASan/UBSan | PASS |
| file / lipo / otool / rpaths / minOS | PASS via verify_no_homebrew |
| License/SBOM draft | **N/A this run** — not re-audited; no regression signal from builds/tests |

---

## 3. Observations (non-blocking)

1. **Soak mid-flight:** Gate “24h without crash/hang” remains open until the process completes 86400s. Current trajectory is healthy (0 errors, stable RSS). Orchestrator should re-check at T+24h or on soak exit.
2. **Stale `soak-report.json`:** Previous failed soak left assertion_failed report on disk; do not confuse with live run.
3. **Firewall split:** Contract lives in `harness_api.h`; `run_guarded` / `set_terminate` live in `.cpp` — correct for C ABI. Header alone is not the full firewall; implementation confirmed.

---

## 4. Artifacts

| Artifact | Path |
|----------|------|
| Tests 2.1.0 | `Native/TorrentinoEngineBridge/runs/tests-2.1.0-release-20260802T022719Z/scenarios.log` |
| Tests 2.0.13 | `Native/TorrentinoEngineBridge/runs/tests-2.0.13-release-20260802T022728Z/scenarios.log` |
| Sanitizers | `Native/TorrentinoEngineBridge/runs/sanitizers-2.1.0-20260802T022728Z/sanitizers.log` |
| Soak log | `Native/TorrentinoEngineBridge/runs/soak/soak.log` |
| versions.lock | `Native/ThirdParty/versions.lock` |
| Static lib | `Native/ThirdParty/.build/prefix/libtorrent-2.1.0-release/lib/libtorrent-rasterbar.a` |

---

## 5. Итог

| | |
|--|--|
| **Overall** | **GREEN** |
| Suites | All executable gates PASS |
| Soak | Healthy RUNNING (partial 24h) |
| Bugs found | **None** blocking WP-01 final verification |
| Action for Human | Return to orchestrator with GREEN status; schedule soak completion re-check at 24h |

No BUG_REPORT.md written (no FAIL).
