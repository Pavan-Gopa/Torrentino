# WP-09 Verification Feedback

**VERDICT: APPROVED**

### 1. Build & tests

- `git diff --stat 165da59..HEAD -- Legacy/`: Empty (Legacy/ untouched in product commit range `165da59..HEAD`).
- `xcodebuild build`: **PASS** (`Torrentino` scheme built clean for macOS arm64).
- `xcodebuild test`: **PASS** (All unit test suites passed, including 17 new WP-09 specific tests in `TransferSmokeTests` and `TorrentinoIPCTests`).
- `test_wp09_fault_matrix.sh`: **PASS**.
- `test_bridge_headless.sh`: **PASS**.
- `test_bridge_swift.sh`: **PASS**.
- `run_qa_suite.sh`: 100/101 test scripts **PASS** (The only environment failure is `test_wp03_legacy_untouched.sh` due to pre-existing untracked human research files in `Legacy/`, which is ignored per ADR-013 / review guidelines).

### 2. WP compliance (§5 item table PASS/PARTIAL/FAIL + evidence)

| # | WP-09 Requirement Item | Status | Evidence |
|---|---|---|---|
| 1 | `EngineResourceBudget` wired: `acceptsHeavyWork` blocks heavy work in `pumpOnce` + `handleCommitAdd`; limits reach bridge/engine consumers | **PASS** | `TransferCoordinator.swift` checks `resourceBudget.acceptsHeavyWork` in `handleCommitAdd` (lines 551-554) and `pumpOnce` (line 854). `BridgeTransferEngine.swift` passes `resourceBudget` to `EngineCoordinator.sessionConfiguration` where active/peer/cache limits configure the native engine. |
| 2 | `restartEngineSafely` performs real recovery; `CrashLoopGuard`/`AgentRuntime` safe-mode clear/restart executable; not unconditional ack | **PASS** | `TransferCoordinator.swift` calls `engine.restart(configuration:)` (line 1025), resets `safeRecovery = false`, clears `engineID`s, and invokes `clearSafeRecovery()` callback which clears `CrashLoopGuard` start history in `AgentRuntime.swift`. |
| 3 | Pending inspections memory-bounded; duplicate-add via `rememberIdempotency`+eviction; `StatusCache`/bridge cache enforces byte budget | **PASS** | `pendingOperationsLimit` (256) & `pendingInspectionBytesLimit` (64 MB) enforced in `handleInspect` (`TransferCoordinator.swift`). `rememberIdempotency` evicts oldest at 1024 limit. `ByteBoundedStatusCache.swift` calculates UTF-8 string sizes + payload overhead and trims entries exceeding `cacheBytes`. |
| 4 | Re-add per-record backoff; no every-pump storm | **PASS** | `TransferCoordinator.swift` maintains `readdBackoff: [TorrentRecordID: (failures: Int, nextAttemptAt: Date)]` and checks `now < backoff.nextAttemptAt` before attempting engine re-add in `pumpOnce()` (lines 885-887, 918-922). |
| 5 | Volume-unavailable fault mapping; typed faults not collapsed to `engineBusy` when typed exists | **PASS** | `TransferCoordinator.persistenceFault` maps `PersistenceError.volumeUnavailable` to `.volumeUnavailable(recordID:volumeIdentifier:)` (lines 1251-1258). `engineHealth(from:recordID:)` maps typed `EngineFault.code` (.volumeUnavailable, .insufficientSpace, .permissionDenied, .networkUnavailable) directly without collapsing. |
| 6 | `SystemConditionMonitor` path includes route/address identity | **PASS** | `SystemConditionMonitor.swift` incorporates `String(reflecting: path)` (route identity) into `pathSignature` (lines 150-161), incrementing `networkGeneration` on any route or interface address change. |
| 7 | Preflight validates `volumeIdentifier` vs mounted volume; free-space unknown does not fail-open as available | **PASS** | `StorageLocationProbe.assess` in `Preflight.swift` compares `actual` vs `expected` volume identifier (lines 108-118), returning `.volumeUnavailable` on mismatch. Unknown free-space returns `.unknown`, which maps conservatively to `.recoverableError(.storeError)` rather than failing open. |
| 8 | UI can surface key WP-09 faults; `restart_engine_safely` invokable if exposed | **PASS** | Toolbar button `recovery.restart_engine` in `TorrentListView.swift` calls `viewModel.restartEngineSafely()`, which executes `EngineClient.restartEngineSafely()` and updates snapshot state upon completion. Status bar and inspector render typed storage & recovery state. |
| 9 | Tests exercise production paths (pressure gate, backoff, volume mismatch, crash-loop restart, cache bytes, etc.) | **PASS** | 17 comprehensive unit tests in `TransferSmokeTests.swift` and `TorrentinoIPCTests.swift` exercise pressure gating, per-record backoff, volume mismatch, crash-loop restart clearance, status cache byte limits, and typed fault round-trips. |

### 3. Architecture

- **Clean Layering**: Engine agent domain boundaries are strictly preserved (`TransferCoordinator` owns in-memory records and persistence reconciliation; `BridgeTransferEngine` maps Swift DTOs to C++ native calls).
- **Concurrency & Safety**: All mutations on `TransferCoordinator` actor are serialized; Sendable DTOs prevent data races across thread boundaries.
- **Fail-Safe Recovery**: Crash loop recovery and safe-mode mechanics clear cleanly on explicit restart without swallowing errors or inventing state.

### 4. Comments

- Prior review §5 defects have been completely and rigorously fixed in commit `3383abb`.
- Verification suite, fault matrix, bridge headless, bridge swift integration, and full unit test suite are all GREEN.

### 5. If changes_requested — concrete file list only

N/A (APPROVED)
