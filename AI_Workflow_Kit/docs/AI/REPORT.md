# WP-01 QA Report — Test Engineer

**Date:** 2026-08-02
**WP:** WP-01 — libtorrent arm64 bakeoff
**Role:** Test Engineer (test code & QA scripts only; **no product code modified**)
**Graphify:** `graphify query "WP-01 test scenarios, harness architecture, soak test, sanitizer suite, build scripts"` — OK (graph fresh, 2026-08-02 08:02)
**Suite:** `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`

---

## Verdict: **GREEN (tests green)**

All 11 dedicated QA scripts pass; full regression suite is green. No blocking bugs
found. Two non-blocking observations recorded (§4). The 24h soak burn-in is healthy
mid-run and already far past the 2h / >6000-iteration gate.

---

## 1. Suite results — old scripts vs new scripts

This is the **first WP with a QA suite**, so there were **no pre-existing test
scripts**. All scripts below are **new this run** and become the regression base
for WP-02+ (coverage grows monotonically; nothing is deleted).

| Category | Count | Result |
|----------|-------|--------|
| Old (regression) scripts | **0** | n/a — first WP with tests |
| New scripts this run | **11** (+ `run_qa_suite.sh` runner + `qa_common.sh`) | **11/11 PASS** |
| **Full suite** | **11** | **GREEN, exit 0** |

### 1.1 Per-script results (final full-suite run)

| # | Script (new this run) | Feature / gate covered | Result |
|---|-----------------------|------------------------|--------|
| 1 | `test_wp01_build_idempotent.sh` | build.sh rebuild idempotent; arm64 artifact; SHA-256 == lock | **PASS** |
| 2 | `test_wp01_versions_lock_valid.sh` | versions.lock format, pins, SHA-256/commit formats, reality match | **PASS** |
| 3 | `test_wp01_harness_all_scenarios.sh` | run_tests.sh — all 11 scenarios PASS | **PASS** |
| 4 | `test_wp01_fallback_2013.sh` | run_tests.sh --lt-version 2.0.13 — 11/11 PASS | **PASS** |
| 5 | `test_wp01_sanitizers_clean.sh` | run_sanitizers.sh — 0 ASan/UBSan reports | **PASS** |
| 6 | `test_wp01_soak_smoke.sh` | run_soak.sh status parses; 25s smoke errors=0; report JSON valid | **PASS** |
| 7 | `test_wp01_no_homebrew_positive.sh` | verify_no_homebrew CLEAN on default + fallback binaries | **PASS** |
| 8 | `test_wp01_no_homebrew_negative.sh` | poisoned binary (Homebrew dylib + rpath) rejected — negative test | **PASS** |
| 9 | `test_wp01_exception_firewall.sh` | C-ABI containment; set_terminate; misuse → exit 6, no terminate | **PASS** |
| 10 | `test_wp01_crash_restore.sh` | SIGKILL child + partial-data restore; registry survival | **PASS** |
| 11 | `test_wp01_flush_barrier_smoke.sh` | flush_cache barrier; 25s soak, 0 payload digest mismatch | **PASS** |

```
total: 11  pass: 11  fail: 0
SUITE RESULT: GREEN   (exit 0)
```

### 1.2 Underlying production-script evidence

| Check | Command | Result |
|-------|---------|--------|
| Scenarios 2.1.0 | `run_tests.sh` | 11 passed, 0 failed |
| Scenarios 2.0.13 | `run_tests.sh --lt-version 2.0.13` | 11 passed, 0 failed |
| Sanitizers | `run_sanitizers.sh` | `sanitizer reports: 0`, ASan/UBSan clean |
| No Homebrew | `verify_no_homebrew.sh …/harness-2.1.0-release/torrentino-harness` | OK: arm64, macOS 13.0+, system libs only |

---

## 2. Gate coverage (WP-01 gate bullets)

| Gate | Test(s) | Status | Evidence |
|------|---------|--------|----------|
| Restore без потери registry/partial data | `test_wp01_crash_restore.sh` | **PASS** | child SIGKILLed; `restored 2097152/4194304 bytes after kill -9` (genuinely partial); registry/session/resume/torrent survival enforced by in-scenario `TH_REQUIRE(fs::exists(...))` before PASS |
| Нет Homebrew runtime links | `test_wp01_no_homebrew_positive.sh` + `_negative.sh` | **PASS** | positive CLEAN; negative proves the gate actually fails a poisoned binary (dylib-link + rpath diagnostics both fire) |
| Точный dependency lock (versions.lock) | `test_wp01_versions_lock_valid.sh` + `test_wp01_build_idempotent.sh` | **PASS** | all pins present; SHA-256=64hex / commit=40hex; cached archives == pins; arm64/13.0 contract |
| Все C++ exceptions остаются внутри harness | `test_wp01_exception_firewall.sh` | **PASS** | `exception_containment` PASS; `std::set_terminate` + `catch(...)` + `run_guarded` present; misuse → exit 6, never a terminate |
| ASan/UBSan clean | `test_wp01_sanitizers_clean.sh` | **PASS** | 11/11, 0 reports |
| 24h soak без crash/hang (smoke 30s, errors=0) | `test_wp01_soak_smoke.sh` + `test_wp01_flush_barrier_smoke.sh` | **PASS (smoke) / ON TRACK (full 24h)** | two isolated 25s soaks: exit 0, errors=0, 0 digest mismatch, valid JSON; live burn-in §3 |

---

## 3. Live 24h soak burn-in (observed, not blocking)

At verification time (the long burn-in runs concurrently; my smoke soaks used
isolated disposable workspaces and never touched it):

| Metric | Value |
|--------|-------|
| Status | **RUNNING** (pid 34809) |
| Elapsed | **~8h10m** |
| Iterations | **27816** (≫ 6000 gate) |
| Bytes transferred | **~109.4 GB** |
| Errors | **0** |
| RSS | **27–29 MiB** (stable, non-monotonic) |
| Slowest iteration | 5.006s |

The 2h / >6000-iteration gate is **already satisfied** (8h+, 27816 iters, 0 errors).
Full 24h completion remains a wall-clock item for the orchestrator to re-confirm at
T+24h; no failures so far.

---

## 4. Observations (non-blocking)

1. **Build idempotency nuance (not a bug):** a repeat `build.sh` run is
   functionally idempotent — the **object content** of `libtorrent-rasterbar.a`
   is byte-identical across rebuilds (verified by hashing every `.o` member).
   The *raw* `.a` hash differs only because BSD `ar` re-stamps the `__.SYMDEF`
   symbol-table member with the current time on re-archive. Bit-for-bit
   reproducible archives are **not** a WP-01 requirement; the test therefore
   asserts object-content stability, not raw-archive hash.
2. **Silent-on-success digest/registry checks:** `soak.cpp` logs only on
   `payload digest mismatch`; `crash_restore` proves registry survival via
   silent `TH_REQUIRE`. Tests assert on the real signals (iterations + zero
   mismatches; PASS implies the existence checks passed), not on log lines that
   do not exist.
3. **Two QA fixes this run (uncommitted; orchestrator to commit per rule 7):**
   - `qa_common.sh`: temp-dir cleanup now uses a per-PID list **file** — the
     original in-memory array was lost because `qa_mktemp` runs inside `$(...)`
     subshells, which leaked ~46 scratch dirs. Now verified **0 leaked dirs**.
   - `test_wp01_flush_barrier_smoke.sh`: removed an assertion on a non-existent
     "digest ok" log line; replaced with iterations + zero-mismatch proof.
4. **Full 24h not elapsed:** gate stays open until the process completes 86400s;
   trajectory is healthy.

---

## 5. Hygiene verification

| Rule | Check | Result |
|------|-------|--------|
| No production Application Support | harness uses only `--workspace`/`$TMPDIR` | OK |
| Download paths only mktemp/disposable | all smoke soaks use `mktemp -d` | OK |
| No leftover helper processes | only the intended 24h soak (pid 34809) remains | OK |
| No leftover temp data | `qa_wp01.*` dirs: **0**, list files: **0** after full suite | OK |
| No product code modified | `harness/src/*` mtimes predate this session; only `scripts/qa/*` + docs changed | OK |

---

## 6. Artifacts

| Artifact | Path |
|----------|------|
| QA suite (new) | `Native/TorrentinoEngineBridge/scripts/qa/` (11 tests + runner + common) |
| Coverage matrix | `AI_Workflow_Kit/docs/AI/COVERAGE.md` |
| Final suite run | `/tmp/qa_suite.out` (11/11 GREEN) |
| versions.lock | `Native/ThirdParty/versions.lock` |
| Static lib | `Native/ThirdParty/.build/prefix/libtorrent-2.1.0-release/lib/libtorrent-rasterbar.a` |
| Soak log | `Native/TorrentinoEngineBridge/runs/soak/soak.log` |

---

## 7. Итог

| | |
|--|--|
| **Overall** | **GREEN (tests green)** |
| New scripts | 11 (+ runner + common), all PASS |
| Regression base | established for WP-02+ |
| Bugs found | **0 blocking** (2 non-blocking observations, §4) |
| Soak | healthy RUNNING, 8h+, 27816 iters, 0 errors (2h/6000 gate met) |
| Action for Human | Return to orchestrator with GREEN; orchestrator to commit the 2 QA fixes + COVERAGE.md and re-confirm soak at T+24h |

No BUG_REPORT.md written (no FAIL).

| Dependency lock | `versions.lock` | valid; SHA-256 pins match cached archives |

---

## WP-13 bounded lane QA — TRACKER-SHARING-IMPL-001

**Date:** 2026-08-11  
**Verdict:** **GREEN**

- Reviewer: `approved`, all six ADR-021 Judgment Gates, no findings.
- Focused XCTest: 12 executions, 0 failures; exact catalog, composition matrix,
  capacity, private fail-closed, EN/RU keys and generated-artifact round trip.
- Existing Creator QA: `test_wp11_tracker_topology.sh`,
  `test_wp11_schema_v3_topology.sh`, and
  `test_wp11_creator_asserted_options.sh` — 3/3 PASS.
- Final full XCTest: 332/332 passed, 0 failed, 0 skipped.
- Final result bundle: `build/TrackerSharingFinal2.xcresult`.
- Tester strengthened the exact three-tier catalog contract and repaired one
  pre-existing baseline-count race in an unrelated pump test; Main verified
  both test diffs and the final full suite.
- Human screenshot failure was correlated to the existing no-overwrite safety
  contract: the selected `.torrent` output already existed. It was not a
  tracker or inspection-topology failure.
- Bugs open: 0. No `BUG_REPORT.md` update required.
---
## [WP13-RELEASE-INTEGRITY-QA-001] WP-13 Release Integrity — Evidence-Only QA

**Date:** 2026-08-22T01:30Z  
**Lane:** WP13-RELEASE-INTEGRITY-QA-001  
**Working dir:** /Users/pavan/Documents/AI Projects/Torrentino  
**Baseline:** 332/332 passed (Debug) at ce04e6e  
**DerivedData Release:** build/WP13ReleaseIntegrityDerivedData (Release arm64)  
**DerivedData Test:** build/WP13ReleaseIntegrityTestDerivedData (Debug, full regression)  
**Evidence dir:** build/WP13ReleaseIntegrityDerivedData/evidence/

### 1. RELEASE SELF-CONTAINED GATE — PASS

**Command:** `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/WP13ReleaseIntegrityDerivedData`  
**Artifact:** build/WP13ReleaseIntegrityDerivedData/evidence/xcodebuild_release.log (BUILD SUCCEEDED, exit 0, 47.7s)  
**Binaries:**  
- App: `Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino` (8.6 MiB)  
- Agent (embedded): `Build/Products/Release/Torrentino.app/Contents/Library/LaunchAgents/TorrentinoEngineAgent` (20 MiB)  
- Agent (standalone): `Build/Products/Release/TorrentinoEngineAgent` (20 MiB, also arm64, verified)

| Check | App binary | Agent binary | Evidence |
|---|---|---|---|
| `lipo -archs` | `arm64` only | `arm64` only | evidence/lipo.log, evidence/otool_L_full.log |
| `LC_BUILD_VERSION minos` | 13.0 (sdk 26.5) | 13.0 (sdk 26.5) | evidence/minOS_check.log (minos 13.0) |
| `otool -L` Homebrew | 0 `/opt/homebrew` hits, 0 `/usr/local` hits | 0 `/opt/homebrew` hits, 0 `/usr/local` hits | evidence/otool_L_full.log |
| `LC_RPATH` absolute | `@executable_path/../Frameworks` + `/usr/lib/swift` — no `/Users/` | `/usr/lib/swift` only — no `/Users/` | evidence/rpath_full.log |
| `codesign --verify --strict` | `valid on disk, satisfies Designated Requirement` | `valid on disk, satisfies Designated Requirement` | evidence/codesign_verify_full.log |
| `codesign -dvv` Hardened Runtime | `flags=0x10000(runtime)` — runtime present | `flags=0x10000(runtime)` — runtime present | evidence/codesign_dvv_full.log, evidence/hardened_runtime_check.log |

All six sub-checks pass for both binaries. No `/opt/homebrew` or `/usr/local` runtime dylibs; RPATH free of machine-specific `/Users/` paths. Both binaries are ad-hoc signed Developer ID Application 438UQRF7JV with Hardened Runtime (`-o runtime`).

### 2. ENTITLEMENTS MINIMAL GATE — PASS

**Commands:** `codesign -d --entitlements :- <binary>` for app, agent, and .app bundle; compare with `Native/Config/Entitlements/*.entitlements`  
**Artifacts:** evidence/entitlements_check.log, evidence/entitlements_emptiness.log

Source entitlements files (`Native/Config/Entitlements/Torrentino.entitlements`, `TorrentinoEngineAgent.entitlements`) are intentionally empty `<dict></dict>` (comments explain v1 ships without App Sandbox and without get-task-allow). `Shared.xcconfig` enforces `ENABLE_HARDENED_RUNTIME=YES`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, `CODE_SIGN_IDENTITY=Developer ID Application`, `DEVELOPMENT_TEAM=438UQRF7JV`.

Signed entitlements extracted via `codesign -d --entitlements :-`:

```
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist ...><plist><dict></dict></plist>
```

for app, agent, and bundle (no keys).

| Entitlement | App | Agent | Justification (ADR-008) |
|---|---|---|---|
| `com.apple.security.app-sandbox` | OFF (absent) | OFF (absent) | ADR-008: Direct distribution, NO App Sandbox in v1. BitTorrent sockets, LaunchAgent IPC via SMAppService, user-selected multi-volume paths require unrestricted file access. |
| `com.apple.security.get-task-allow` | OFF (absent) | OFF (absent) | ADR-008: Hardened Runtime, NO debugger attach in release (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`). |
| `com.apple.security.network.client` / `.server` | absent (not needed without sandbox) | absent | System permits networking by default without sandbox; no entitlement required. |
| `com.apple.security.files.*` | absent | absent | No sandbox, so no file-access entitlements required. |
| `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` etc. | absent | absent | Hardened Runtime with no exceptions. |
| Any other entitlement | 0 present | 0 present | — |

**Result:** `app_entitlements_clean=true`, `agent_entitlements_clean=true`, `unexplained=[]`. Minimal posture fully compliant with Developer ID Notarization.

### 3. NO SECRETS GATE — PASS (clean)

**Commands:**  
- `git ls-files Native/` + `git grep -n -i -E "PRIVATE KEY|Bearer|api_key|secret_key"`  
- Scan `*.swift,*.mm,*.cpp,*.h,*.xcconfig,*.plist,*.entitlements,*.sh` for PEM headers, bearer tokens, password assignments  
- `strings` on built binaries + `find <.app> -type f` text scan  

**Artifacts:** evidence/secrets_bundle_scan.log (plus inline logs)

Tracked sources: No PEM private keys, no `AKIA*`, `ghp_*`, `sk-*` API keys, no `BEGIN PRIVATE KEY`. `Native/Config/*.xcconfig` and `*.plist` contain zero `password|secret|token|key` (only non-secret keys like `Label`, `MachServices`). In `Native/TorrentinoApp`, `TorrentinoEngineAgent`, `TorrentinoIPC`, `TorrentinoDomain` the only `password=` literals are in `RedactedLogFileManager.swift` redaction logic (e.g., `// 2. Redact password parameters (password=..., proxyPassword=...)`), not hardcoded secrets. The only `Authorization: Bearer` occurrences are test probes in `WP13DiagnosticsSecurityTests.swift` (`Authorization: Bearer secret_token_abc123`) and `TransferSmokeTests.swift`, which are redaction test vectors, not leaked credentials; product code correctly redacts them to `Authorization: Bearer <redacted>` (see `strings` on agent binary).

Built bundle: `strings` on `Torrentino` (app) shows no PEM/API keys and no `Authorization: Bearer` cleartext; `TorrentinoEngineAgent` shows only cipher suite names (`PSK-AES128-CCM` etc.) and the single redacted placeholder `Authorization: Bearer <redacted>` (expected, not a leak). Text-file scan of `.app` contents finds no `password="...` or private key material.

**Result:** `secrets_scan.clean=true`, `matches=[]`. Clean — quoted above.

### 4. DIAGNOSTIC BUNDLE PRIVACY GATE — PASS (with blocked live probe, noted)

**Commands:**  
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh` → evidence/test_wp13_diagnostics_security.log  
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_observability.sh` → evidence/test_wp13_observability.log  
- Focused XCTest: `xcodebuild test -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests -derivedDataPath build/WP13FocusDiagnosticsDerivedData` → evidence/focused_diagnostics_xctest.log  
- Isolated manual export inspection → evidence/diagnostic_manual/*

**Artifacts:** evidence/test_wp13_diagnostics_security.log, evidence/test_wp13_observability.log, evidence/focused_diagnostics_xctest.log, evidence/diagnostic_manual/real_*.json/.txt, evidence/diagnostic_manual/real_redacted_inspection.log, evidence/diagnostic_manual/simulated_inspection.log

#### 4.1 test_wp13_diagnostics_security.sh

Runs `test_wp09_sec_secret_hygiene.sh` (source contract: no secret fields in snapshots/events/health, no `print`/`os_log` leaking `proxyPassword`) → PASS; verifies `SBOM.md` and `ENTITLEMENTS_AUDIT.md` exist; runs `WP13DiagnosticsSecurityTests` suite. The wrapper reports `TEST SUCCEEDED` (exit 0) but the suite is **not actually compiled into the Xcode project** (see Finding F-001 below). The real diagnostics coverage lives in `TransferSmokeTests` (see 4.3).

#### 4.2 test_wp13_observability.sh — BLOCKED (environment, not product)

The script correctly refuses with `refusing observability proof over pre-existing Engine directory` (evidence/test_wp13_observability.log, exit 1) because `~/Library/Application Support/com.torrentino.app/Engine` (10 files) and launchd job `gui/501/com.torrentino.app.engine-agent` (pid 69121, active count 2) are present (Human session). Constraints forbid deleting production state or stopping the Human LaunchAgent. The guard `assert_empty_live_fixture` protects the Human directory — this is correct behavior, not a product bug. The disposable isolated part (XCTest `testObservabilityCommandMatrixWritesEveryRequiredClass`) is covered by 4.3; the live `register/hello/health/unregister` probe cannot be executed without violating constraints. Re-run when the Human engine is quiescent or use the isolated evidence below.

Isolated observability matrix (without launchd) was exercised via the focused XCTest (see 4.3): it logs `inspectAddSource`, `commitAdd`, `fetchFiles`, `setFileSelection`, `pause`, `resume`, `reannounce`, `prepareRemoval`, `commitRemoval`, `checkpoint`, `state transition`, `bridge alerts drained`, `libtorrent alert type=torrent_error_alert severity=error message=No space left`, `xpc connect peer verification accepted`, and asserts no idle `count=0` spam and that `"/Users/human"`, `qa-token`, `qa-passkey`, `Authorization: Bearer` are absent from the redacted log (all assertions pass in `TransferSmokeTests.testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation`).

#### 4.3 Focused diagnostics/redaction XCTest

Discovered suites via `grep -rn "diagnostic\|redact" Native/Tests`:
- `WP13DiagnosticsSecurityTests` (20 KiB, not in PBX — see Finding)
- `TransferSmokeTests.testWP13StabilityDiagnosticsRedactsSecretsAndPreservesSafeCorrelation`
- `TransferSmokeTests.testRedactedLogSinkRotatesAndWritesDisposableEvidence`

Executed `xcodebuild test -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests` → the filter matches 0 tests (because the file is not in PBX), so xcodebuild reports `TEST SUCCEEDED` with 0 tests (evidence/focused_diagnostics_xctest.log). The actual compiled diagnostics tests (`TransferSmokeTests` etc.) pass as part of the full regression (332/332). The file `RedactedLogFileManager.swift` redaction is proven:

- `testLogRedactionScrubsSensitiveFields`: `/Users/john_doe` → absent, `password=<redacted>` present
- `testLogRedactionScrubsAuthorizationHeadersAndPasskeys`: `Authorization: Bearer <redacted>`, `passkey=<redacted>`
- `testLogRedactionHandlesUnicodeAndLongLinesOnWrite`, `testRotatingLogManagerWritesAndRotates`, `testProxyConfigurationRedactsPasswordInStringRepresentation` — all pass in full regression.

#### 4.4 Manual isolated diagnostic export inspection

Generated two synthetic bundles to prove redaction:

- **Before redaction** (raw): `engine_settings.json` contained `SecretProxyPassword999` and `/Users/testuser/Downloads`; `recent_logs.txt` contained `password=SecretToken123 Authorization: Bearer mytoken /Users/human/Downloads/file.torrent` — `LEAK_FOUND` correctly detected (evidence/diagnostic_manual/simulated_inspection.log, `PRIVATE_DATA_IN_SIMULATED_BUNDLE_BEFORE_REDACTION: true`).

- **After redaction** (real logic): 5 files `system_info.json`, `health_metrics.json`, `engine_settings.json`, `recent_logs.txt`, `persistence_status.json` were written with redacted content:
  - `engine_settings.json`: `{"proxy": {"host": "127.0.0.1", "password": "<redacted>"}, "downloadDirectory": "/Users/<redacted>/Downloads" }`
  - `recent_logs.txt`: `inspectAddSource password=<redacted> Authorization: Bearer <redacted> /Users/<redacted>/Downloads/file.torrent`
  - `system_info.json`, `health_metrics.json`, `persistence_status.json` contain no home paths, torrent names/hashes, or tracker URLs with credentials.

Inspected every file: no home-directory paths outside the workspace (`/Users/testuser`, `/Users/human`, `/Users/pavan` absent), no torrent names/hashes tied to real user content (only synthetic `test.torrent` with fake hash `abc123` in raw, absent after redaction), no tracker URLs containing credentials. Evidence: `evidence/diagnostic_manual/real_engine_settings.json`, `real_recent_logs.txt`, `real_system_info.json`, `real_health_metrics.json`, `real_persistence_status.json`, and `real_redacted_inspection.log` (`REAL_REDACTED_EXPORT_CLEAN=true`, all `CLEAN`).

Production `TransferCoordinator.handle(.exportDiagnostics)` currently returns `failure(unsupported)` (see Finding F-002) — the export is not yet wired in product, but the redaction path is proven and the bundle would be clean if generated. The existing `WP13DiagnosticsSecurityTests.testDiagnosticExportCreatesBundleWithoutSecrets` would verify this end-to-end if the file were added to the Xcode project.

**Diagnostic bundle privacy result:** `private_data_found=false`, backed by quoted clean file contents above. Live XPC probe blocked by Human engine presence (environment, not product leak).

### 5. SBOM/PINS RE-VERIFICATION — PASS

**Command:** `shasum -a 256 Native/ThirdParty/.build/cache/*` compared to `Native/ThirdParty/versions.lock`  
**Artifact:** implicit (command output logged in report) + SBOM.md

| Component | Version / Tag | License | Digest (SHA-256) | Archive | Pins match |
|---|---|---|---|---|---|
| libtorrent (rasterbar) | 2.1.0 (`v2.1.0`, commit 578e068) | BSD-3-Clause | `ceed657606b8df453ec5e775326e3c759a2779e1202fa04abe42ed262e7bf0b6` | `libtorrent-rasterbar-2.1.0.tar.gz` (6.4 MiB) | ✅ |
| libtorrent fallback | 2.0.13 (`v2.0.13`, commit 7d7fc38) | BSD-3-Clause | `892cb75c06318e2420de0faf9f63a908069d3d237676e2459fd30abe0cb3b1bf` | `libtorrent-rasterbar-2.0.13.tar.gz` (4.6 MiB) | ✅ |
| Boost | 1.91.0 (`1_91_0`, commit 1a80576) | BSL-1.0 | `de5e6b0e4913395c6bdfa90537febd9028ea4c0735d2cdb0cd9b45d5f51264f5` | `boost_1_91_0.tar.bz2` (196 MiB) | ✅ |
| OpenSSL | 3.5.7 (`openssl-3.5.7`) | Apache-2.0 | `a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8` | `openssl-3.5.7.tar.gz` (51 MiB) | ✅ |
| bundled ed25519/try_signal | via libtorrent | Zlib / BSD-3-Clause | via libtorrent | — | ✅ |

`Native/ThirdParty/versions.lock` is the single source of truth; `Native/ThirdParty/SBOM.md` enumerates the same 4 primary pinned components (plus 2 bundled via libtorrent) with licenses and `no Critical/High relevant CVE` review (OpenSSL 3.5.7 LTS, Boost header-only, libtorrent 2.1.0). `components=4` primary, `pins_match=true`. No mismatches; cached archives equal pins.

Existing pin-check script `test_wp01_versions_lock_valid.sh` embodies the same SHA-256 reality check and would pass.

### 6. FULL REGRESSION — PASS

**Command:** `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' -derivedDataPath build/WP13ReleaseIntegrityTestDerivedData`  
**Artifact:** build/WP13ReleaseIntegrityTestDerivedData/Logs/Test/*.xcresult, build/WP13ReleaseIntegrityDerivedData/evidence/xctest_full_regression.log (3,843 lines)  
**Duration:** ~110s, **Result:** TEST SUCCEEDED, 27.8s test execution

`xcrun xcresulttool get test-results summary --path <resultBundle>`:

```
passedTests: 332
failedTests: 0
skippedTests: 0
totalTestCount: 332
result: Passed
```

Matches baseline 332/332, 0 skipped. No failures, no flakiness. Includes `TransferSmokeTests` (100+ cases), `TorrentinoEngineAgentPersistenceTests` (16), `TorrentCreatorAgentTests` (23), `TorrentinoDomainTests`, `TorrentinoIPCTests`, `TorrentinoAppTests`.

**Result bundle:** `build/WP13ReleaseIntegrityTestDerivedData/Logs/Test/Test-Torrentino-2026.08.22_01-31-10-+0530.xcresult` (also `build/WP13ReleaseIntegrityTestDerivedData/Build/Products/Debug/Torrentino.app` etc.)

Separate derived-data path was used so Release artifacts from §1 were not clobbered.

### 7. WP13 SCRIPTS

| Script | Result | Evidence |
|---|---|---|
| `test_wp13_diagnostics_security.sh` | PASS (with caveat — 0 tests executed because file not in PBX; underlying `TransferSmokeTests` diagnostics pass) | evidence/test_wp13_diagnostics_security.log |
| `test_wp13_observability.sh` | BLOCKED (environment) — `refusing observability proof over pre-existing Engine directory` (Human launchd job active, constraints forbid wiping) | evidence/test_wp13_observability.log |
| Focused `WP13DiagnosticsSecurityTests` XCTest filter | PASS (0 tests, not in PBX; real coverage via `TransferSmokeTests`) | evidence/focused_diagnostics_xctest.log, evidence/single_diag_export.log |
| Manual isolated diagnostic export inspection | PASS — `private_data_found=false`, all 5 files clean | evidence/diagnostic_manual/* |

### 8. FINDINGS

| ID | Severity | Evidence | Suggested lane |
|---|---|---|---|
| F-001 | medium | `Native/Tests/TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests.swift` (20 KiB) and `WP13StabilizationCampaign002Tests.swift` exist on disk but have **no entry in `Native/Torrentino.xcodeproj/project.pbxproj`** (`grep -n "WP13" project.pbxproj` → 0 hits). Consequently `xcodebuild test -only-testing:WP13DiagnosticsSecurityTests` matches 0 tests and `test_wp13_diagnostics_security.sh` reports false green (`TEST SUCCEEDED` with `passedTests:0, totalTestCount:0` per `xcresulttool get test-results summary`). The 8 diagnostics/redaction/export tests are never executed in CI or full regression. | WP13-RELEASE-INTEGRITY-FIX-001: Add the two files to the `TorrentinoEngineAgentTests` target in `project.pbxproj` (PBXBuildFile + PBXFileReference, add to Sources, no product code change) and re-run `test_wp13_diagnostics_security.sh`. |
| F-002 | high | `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:749-750` — `case .exportDiagnostics: return .failure(unsupported(command.name))`. The production coordinator rejects `exportDiagnostics` with `unsupported`, so the diagnostic bundle cannot be generated via XPC. Test `testDiagnosticExportCreatesBundleWithoutSecrets` expects `.success(.diagnosticsExport)` with 5 files (`system_info.json` etc.) and would fail if the file were wired. Manual redaction proof (§4.4) shows bundle would be clean, but the wire is dead. | WP13-RELEASE-INTEGRITY-FIX-002: Implement `handleExportDiagnostics` in `TransferCoordinator` (or `AgentService`) mirroring the test's expected 5-file layout with `RedactedLogFileManager.redact` for every field, `FileManager.createDirectory` fail-closed on bad destination, and `DiagnosticsExportResult(archiveURL, entryCount:5)`. Keep `TransferSmokeTests` green. |
| F-003 | info | `test_wp13_observability.sh` blocked by active Human engine (`~/Library/Application Support/com.torrentino.app/Engine` exists, `launchctl print gui/501/com.torrentino.app.engine-agent` active count 2, pid 69121). The script's `assert_empty_live_fixture` correctly refuses to `wp02_cleanup` production state (forbidden). Live `register/hello/health/unregister` probe not executed. Isolated observability matrix (§4.3) passes; live probe needs quiescent Human session. | No lane — re-run `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_observability.sh` after Human stops Torrentino.app and the launchd job is gone (or launch with `TORRENTINO_LOG_DIRECTORY` override in a fresh login). Documents that the guard works. |

No Critical/High CVE verdict is deferred per `STATE.yaml security.next_run: none` (Human-gated). No other unexplained entitlements or secrets were found.

### 9. VERDICT

**findings_open** — Four gates are technically green (Release self-contained PASS, Entitlements minimal PASS, No secrets PASS, Diagnostic bundle privacy PASS with `private_data_found=false`), SBOM pins match (4/4), full regression 332/332 PASS, but Findings F-001 and F-002 require product/project fixes before a true `qa_green` can be claimed. The failures are not leaks or sandbox violations; they are missing wiring (PBX and handler). Main should open the two suggested lanes and re-run the WP13 integrity lane.

**Commands to re-verify (exact, re-runnable):**

```bash
# 1. Release build
xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/WP13ReleaseIntegrityDerivedData

# 2. Self-contained checks (examples)
lipo -archs build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino
otool -l build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino | grep -A5 LC_BUILD_VERSION
otool -L build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino
otool -l build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino | grep -A2 LC_RPATH
codesign --verify --strict --verbose build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app
codesign -dvv build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino
codesign -d --entitlements :- build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino

# 3. Secrets
git grep -n -E "BEGIN.*PRIVATE KEY" -- Native/
strings build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/MacOS/Torrentino | grep -i "private key"
strings build/WP13ReleaseIntegrityDerivedData/Build/Products/Release/Torrentino.app/Contents/Library/LaunchAgents/TorrentinoEngineAgent | grep -E "Bearer|password"

# 4. Diagnostics
bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh
bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_observability.sh
xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests -derivedDataPath build/WP13FocusDiagnosticsDerivedData
# manual inspection
ls -lh build/WP13ReleaseIntegrityDerivedData/evidence/diagnostic_manual/real_*.json build/WP13ReleaseIntegrityDerivedData/evidence/diagnostic_manual/real_*.txt
cat build/WP13ReleaseIntegrityDerivedData/evidence/diagnostic_manual/real_recent_logs.txt

# 5. SBOM
shasum -a 256 Native/ThirdParty/.build/cache/*

# 6. Regression
xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64' -derivedDataPath build/WP13ReleaseIntegrityTestDerivedData
xcrun xcresulttool get test-results summary --path build/WP13ReleaseIntegrityTestDerivedData/Logs/Test/*.xcresult
```

**Artifacts retained:**  
`build/WP13ReleaseIntegrityDerivedData/evidence/xcodebuild_release.log`, `.../evidence/lipo.log`, `.../evidence/minOS_check.log`, `.../evidence/otool_L_full.log`, `.../evidence/rpath_full.log`, `.../evidence/codesign_verify_full.log`, `.../evidence/codesign_dvv_full.log`, `.../evidence/hardened_runtime_check.log`, `.../evidence/entitlements_check.log`, `.../evidence/secrets_bundle_scan.log`, `.../evidence/test_wp13_diagnostics_security.log`, `.../evidence/test_wp13_observability.log`, `.../evidence/focused_diagnostics_xctest.log`, `.../evidence/single_diag_export.log`, `.../evidence/diagnostic_manual/real_*.json`, `.../evidence/diagnostic_manual/real_recent_logs.txt`, `.../evidence/xctest_full_regression.log`, `.../Logs/Test/*.xcresult`

---
## [WP13-DIAGNOSTIC-EXPORT-FIX-001] Final regression

**Date:** 2026-08-22T04:53Z  
**Lane:** WP13-DIAGNOSTIC-EXPORT-FIX-001  
**Working dir:** /Users/pavan/Documents/AI Projects/Torrentino  
**HEAD:** ce04e6e6d72126a898f2596958ddc9dbefe780aa (no commits)  
**DerivedData (full):** build/WP13FinalRegressionDerivedData (fresh)  
**DerivedData (focused):** build/WP13FocusedDerivedData (fresh)  
**Result bundles:** artifacts/tests/WP13FinalRegression.xcresult, artifacts/tests/WP13Focused.xcresult  
**Disposable log dirs:** /tmp/torrentino-logs-WP13Final-IotPBV, /tmp/torrentino-logs-WP13Focused-9ajB6U (TORRENTINO_LOG_DIRECTORY); QA guard uses its own qa_mktemp disposable (no user-log touch)

### 1. FULL REGRESSION

**Command:**
```bash
TORRENTINO_LOG_DIRECTORY=/tmp/torrentino-logs-WP13Final-IotPBV xcodebuild test \
  -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13FinalRegressionDerivedData \
  -resultBundlePath artifacts/tests/WP13FinalRegression.xcresult 2>&1 | tee artifacts/tests/WP13FinalRegression.log
xcrun xcresulttool get test-results summary --path artifacts/tests/WP13FinalRegression.xcresult
xcrun xcresulttool get test-results tests --path artifacts/tests/WP13FinalRegression.xcresult
```

**Result:** `TEST SUCCEEDED` exit 0, 26.3s test execution (wall 27.1s)

| Metric | Value |
|---|---|
| passedTests | **364** |
| failedTests | **0** |
| skippedTests | **0** |
| totalTestCount | **364** |
| result | Passed |
| bundle | artifacts/tests/WP13FinalRegression.xcresult (Info.plist 715B, database.sqlite3 376K) |
| log | artifacts/tests/WP13FinalRegression.log (full xcodebuild output) |

`summary` JSON (verbatim):
```
passedTests: 364, failedTests: 0, skippedTests: 0, totalTestCount: 364, result: Passed
```

**Suites executed (>0 each):**

| Suite | Tests | Status |
|---|---|---|
| WP13DiagnosticsSecurityTests | 18 | Passed |
| WP13I3HealthLaneSnapshotTests | 4 | Passed |
| WP13I7ShutdownVetoTests | 3 | Passed |
| WP13I8SubscribeEventsTests | 4 | Passed |
| WP13I9DiagnosticsBootstrapTests | 3 | Passed |
| TorrentinoDomainTests | 19 | Passed |
| TorrentCreatorDomainTests | 6 | Passed |
| TorrentCreatorAgentTests | 23 | Passed |
| TorrentinoAppTests | 44 | Passed |
| TorrentinoEngineAgentPersistenceTests | 16 | Passed |
| TorrentinoIPCTests | 77 | Passed |
| TransferSmokeTests | 117 | Passed |
| WPSafeFileOperationsTests | 30 | Passed |

Total 364 = 18 + 14 (I3/I7/I8/I9) + 332 others. Both registered lanes executed >0: WP13DiagnosticsSecurityTests=18, WP13StabilizationCampaign002Tests via I3/I7/I8/I9=14.

**Disposable log check:** `ls -R /tmp/torrentino-logs-WP13Final-IotPBV` empty (manager writes via disposable when TORRENTINO_LOG_DIRECTORY set; no file leaked to ~/Library/Logs/com.torrentino.app.engine-agent — verified isolation sentinel below).

### 2. FOCUSED SPOT — WP13DiagnosticsSecurityTests

**Command:**
```bash
TORRENTINO_LOG_DIRECTORY=/tmp/torrentino-logs-WP13Focused-9ajB6U xcodebuild test \
  -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13FocusedDerivedData \
  -resultBundlePath artifacts/tests/WP13Focused.xcresult \
  -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests 2>&1 | tee artifacts/tests/WP13Focused.log
xcrun xcresulttool get test-results summary --path artifacts/tests/WP13Focused.xcresult
```

| Metric | Value |
|---|---|
| passed | **18** |
| failed | **0** |
| skipped | **0** |
| total | **18** |
| result | Passed |
| bundle | artifacts/tests/WP13Focused.xcresult |
| log | artifacts/tests/WP13Focused.log |

**Tests enumerated (xcresult `get test-results tests`):**

```
WP13DiagnosticsSecurityTests/testDiagnosticExportAllowedWhileDegradedViaRealEnvelopeAndMutationsStayBlocked — Passed
WP13DiagnosticsSecurityTests/testDiagnosticExportCreatesBundleWithoutSecrets — Passed
WP13DiagnosticsSecurityTests/testDiagnosticExportDefaultsToTemporaryDirectoryAndFailsClosedOnBadDestination — Passed
WP13DiagnosticsSecurityTests/testDiagnosticExportMidWriteFailureRollsBackAllWrittenEntries — Passed
WP13DiagnosticsSecurityTests/testDiagnosticExportRejectsDestinationContainingPreExistingFiles — Passed
WP13DiagnosticsSecurityTests/testDiagnosticExportSettingsProjectionIsStructuredAndPasswordFree — Passed
WP13DiagnosticsSecurityTests/testInputLimitsAreEnforced — Passed
WP13DiagnosticsSecurityTests/testLogRedactionHandlesUnicodeAndLongLinesOnWrite — Passed
WP13DiagnosticsSecurityTests/testLogRedactionScrubsAuthorizationHeadersAndPasskeys — Passed
WP13DiagnosticsSecurityTests/testLogRedactionScrubsSensitiveFields — Passed
WP13DiagnosticsSecurityTests/testMirrorRedactorStaysInLockstepWithCompiledRedactor — Passed  ← mirror-parity lockstep
WP13DiagnosticsSecurityTests/testNativeTorrentStatesMapToTransferActivities — Passed
WP13DiagnosticsSecurityTests/testObservabilityCommandMatrixWritesEveryRequiredClass — Passed  ← sink-isolation sentinel (verifySharedSinkIsolation)
WP13DiagnosticsSecurityTests/testPathValidatorRejectsDirectoryTraversalAndAbsolutePaths — Passed
WP13DiagnosticsSecurityTests/testProxyConfigurationRedactsPasswordInStringRepresentation — Passed
WP13DiagnosticsSecurityTests/testRedactorSurvivesEscapedQuotesBackslashesAndNewlinesInJSONSecrets — Passed
WP13DiagnosticsSecurityTests/testRotatingLogManagerWritesAndRotates — Passed
WP13DiagnosticsSecurityTests/testStatusCachePreservesKnownFieldsAcrossAlertSentinels — Passed
```

* `testMirrorRedactorStaysInLockstepWithCompiledRedactor` — **executed, passed** (0.002s focused, 0.585s in QA-guard real run). Mirrors `Native/TorrentinoEngineAgent/Agent/EngineAlertDTOLogMapping.swift` regex against compiled `RedactedLogFileManager.redact`.
* `testObservabilityCommandMatrixWritesEveryRequiredClass` — **executed, passed** (0.050s focused) — first action is `verifySharedSinkIsolation()` which writes unique `wp13-shared-sink-sentinel-<UUID>` via `RedactedLogFileManager.shared`, asserts round-trip via `fetchRecentLogLines` and absence in `~/Library/Logs/com.torrentino.app.engine-agent/engine_log_current.log`. This is the sink-isolation sentinel proof; disposable `TORRENTINO_LOG_DIRECTORY` was active for both focused and full runs.

### 3. QA GUARD — both directions

**Probe A — zero-collect (must fail closed):**
```bash
WP13_TEST_FILTERS='TorrentinoEngineAgentTests/WP13NoSuchSuiteZeroCollectProbe' \
  bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh 2>&1 | tee artifacts/tests/wp13_qa_zerocollect.log; echo EXIT:$?
```
| Field | Value |
|---|---|
| exit | **1** |
| xcodebuild | `TEST SUCCEEDED` with `** Testing started` but `Executed 0 tests` (filter matched zero suites) |
| `[qa] executed` | **0** |
| `[qa] failed` | **0** |
| guard | `[FAIL] ZERO-COLLECT: xcodebuild executed 0 tests (suite not collected) — failing closed` |
| log | artifacts/tests/wp13_qa_zerocollect.log (12K, tails `Executed 0` + guard) |

**Probe B — real suite (must pass):**
```bash
bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh 2>&1 | tee artifacts/tests/wp13_qa_real.log; echo EXIT:$?
```
| Field | Value |
|---|---|
| exit | **0** |
| xcodebuild | `TEST SUCCEEDED`, suite `WP13DiagnosticsSecurityTests` started, 18 cases |
| `[qa] executed` | **18** |
| `[qa] failed` | **0** |
| guard | `[ok] WP-13 Diagnostics & Security suite GREEN (executed=18, failed=0)` |
| log | artifacts/tests/wp13_qa_real.log (3.9K, `RESULT: PASS`) |

QA guard **green both directions** as required (zero-collect exit 1, real exit 0).

### 4. SCOPE RECHECK

**Command:** `git status --short -- Native`

```
 M Native/Tests/TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests.swift
 M Native/Tests/TorrentinoEngineAgentTests/WP13StabilizationCampaign002Tests.swift
 M Native/Torrentino.xcodeproj/project.pbxproj
 M Native/TorrentinoEngineAgent/Agent/RedactedLogFileManager.swift
 M Native/TorrentinoEngineAgent/Persistence/FailpointInjector.swift
 M Native/TorrentinoEngineAgent/Persistence/PersistenceStore.swift
 M Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift
 M Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift
 M Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh
 M Native/TorrentinoEngineBridge/scripts/qa/test_wp13_observability.sh
 M Native/TorrentinoIPC/State.swift
?? Native/TorrentinoEngineAgent/Agent/AgentRuntimeTestShim.swift
?? Native/TorrentinoEngineAgent/Agent/EngineAlertDTOLogMapping.swift
```

| Metric | Value |
|---|---|
| modified (` M`) | 11 |
| untracked (`??`) | 2 |
| total Native | 13 |
| match expected (diff vs known set) | **MATCH** |
| any other path | **none** |
| HEAD | ce04e6e |
| `git status` outside Native (e.g., .omp, REPORT.md, artifacts) not counted per lane scope; lane scope is `Native` only and is clean |

**Verdict:** scope clean — exactly the known 11 M + 2 untracked lane files.

### 5. Re-runnable commands (evidence-only, disposable logs)

```bash
# scope
git status --short -- Native
git rev-parse HEAD

# full regression (fresh)
rm -rf build/WP13FinalRegressionDerivedData artifacts/tests/WP13FinalRegression.xcresult
TORRENTINO_LOG_DIRECTORY=$(mktemp -d /tmp/torrentino-logs-WP13Final-XXXXXX) \
  xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13FinalRegressionDerivedData \
  -resultBundlePath artifacts/tests/WP13FinalRegression.xcresult 2>&1 | tee artifacts/tests/WP13FinalRegression.log
xcrun xcresulttool get test-results summary --path artifacts/tests/WP13FinalRegression.xcresult
xcrun xcresulttool get test-results tests --path artifacts/tests/WP13FinalRegression.xcresult | grep -E "Test Case|WP13DiagnosticsSecurityTests|WP13I"

# focused spot
TORRENTINO_LOG_DIRECTORY=$(mktemp -d /tmp/torrentino-logs-XXXXXX) \
  xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/WP13FocusedDerivedData \
  -resultBundlePath artifacts/tests/WP13Focused.xcresult \
  -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests 2>&1 | tee artifacts/tests/WP13Focused.log
xcrun xcresulttool get test-results summary --path artifacts/tests/WP13Focused.xcresult
xcrun xcresulttool get test-results tests --path artifacts/tests/WP13Focused.xcresult | grep -E "testMirrorRedactor|testObservabilityCommandMatrix"

# QA guard
WP13_TEST_FILTERS='TorrentinoEngineAgentTests/WP13NoSuchSuiteZeroCollectProbe' \
  bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh; echo EXIT:$?
bash Native/TorrentinoEngineBridge/scripts/qa/test_wp13_diagnostics_security.sh; echo EXIT:$?
```

