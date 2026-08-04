### 1. Build & tests

- Range reviewed: `torrentino/pre-WP-09..HEAD`; focus commit `0918a3d`; WP-09 native paths only.
- `git diff --stat torrentino/pre-WP-09..HEAD -- Legacy/`: empty. Legacy was not read or modified.
- `git diff --check torrentino/pre-WP-09..HEAD -- Native`: PASS.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp09_fault_matrix.sh`: PASS; 6 selected tests pass.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS; Swift 6 strict-concurrency bridge harness passes.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: 100/101 PASS. The only failure is `test_wp03_legacy_untouched.sh`; this is the permitted environmental Legacy dirt and is not used as a product finding.

### 2. WP compliance

| Axis | Result | Evidence |
|---|---|---|
| Network offline/online; no busy-loop; safe resume | PARTIAL | `canAttemptNetworkWork` gates offline work and the selected test checks desired-state preservation, but the test does not assert engine-call count/backoff or actual resume. Failed re-adds have no per-record backoff. |
| Wi-Fi/Ethernet/VPN path change | PARTIAL | `networkGeneration` changes from a signature of status/interface types/flags only; same-interface route/address changes are not represented, and there is no monitor integration test. |
| Sleep/wake recovery | PARTIAL | Sleep gating and wake-triggered pump exist, but there is no sleep/wake fault-injection or notification integration test. |
| Memory/thermal/Low Power pressure | FAIL | The policy sets `acceptsHeavyWork = false` and lower limits, but `pumpOnce` and `handleCommitAdd` never honor that flag; active-download, peer-connection, and cache-byte limits are not applied to the bridge. |
| Disk full / permissions; typed faults; no hang/data loss | PARTIAL | Pure storage classification and fault round-trip pass. Filesystem free-space lookup failure is treated as `.available`, and no persistence/engine disk-full or permission injection proves commit behavior. |
| External volume detach/attach; no auto-create | PARTIAL | Missing paths are not created and mount notifications re-probe records, but `volumeIdentifier` is never validated against the mounted volume, so a replacement directory at the same path can be accepted as the wrong volume. |
| Bounded queues/cache/connections | FAIL | Event pending count and normal idempotency insertion are bounded, but duplicate-add writes bypass eviction; pending inspections can retain up to 256 x 10 MiB source payloads; `cacheBytes` and most connection limits are unused. |
| Crash-loop safe recovery; backoff; no restart storm | FAIL | Agent-start history enters permanent safe mode, but `restartEngineSafely` is an unconditional `.ack` and does not clear/restart safe recovery. Re-add failures also retry every pump without backoff. No crash-loop test exists. |
| Distinct health lane | PASS | Lock-backed `AgentHealthLane` is separate from coordinator work, exposes condition/counter/queue state, and health does not perform engine or persistence health scans. |
| Conservative watchdog | PASS | Health explicitly reports `watchdog: "disabled"`; no false-restart watchdog path was added. |
| One bad task does not globally stop engine | PASS | Pump add/status failures are caught and record health is localized; a failed record does not invoke global stop. |
| Understandable recovery actions/states | PARTIAL | Typed health/fault states and recovery action arrays exist, but UI command localization handles only a small subset of WP-09 fault codes and `restart_engine_safely` is not executable. |
| UI projection is not source of truth | PASS | `TransferCoordinator` owns records/revisions/persistence; `TorrentListViewModel` consumes snapshots/events and only projects `systemConditions`. |
| Swift 6 / PIMPL / Sendable DTOs / typed faults | PARTIAL | Build and bridge checks pass and PIMPL/DTO boundaries hold, but `engineFault` collapses several unmapped `EngineCoordinatorError` cases to generic `.engineBusy`, and storage text mapping does not classify volume-unavailable errors. |
| Real fault-matrix tests | FAIL | The six WP-09 tests are mostly pure policy/factory/queue assertions. They do not exercise `SystemConditionMonitor`, sleep/wake, path changes, crash-loop recovery, pressure gating, re-add backoff, volume identity, or persistence/engine disk faults. |

### 3. Architecture invariants

- Swift 6 compilation, native build, C++ PIMPL boundary, and bridge smoke tests are green.
- The coordinator remains the authoritative record/revision owner and does not use UI state as recovery authority.
- The implementation is not yet a complete resource-control engine: `EngineResourceBudget` is partly declarative, while the production bridge remains configured from `EngineSettings` and the bounded event/cache mechanisms do not cover all retained data.
- The range adds no product Legacy/Tauri changes; the allowed Legacy diff-stat is empty.

### 4. Comments & readability

- Comments clearly state the intended invariants and the health/watchdog split.
- The comments overstate enforcement: the budget is described as bounded policy although several fields have no consumer, and the re-add loop is described as recovery without a retry backoff.
- The WP-09 QA script is useful as a narrow gate, but its passing tests do not provide the claimed fault-matrix depth.

### 5. If changes_requested — concrete file:line list only

- `Native/TorrentinoIPC/SystemConditions.swift:124-167` — budget fields are declared, but active/peer/cache limits and `acceptsHeavyWork` are not wired to engine policy.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:343-346` — `restartEngineSafely` is acknowledged without performing recovery.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:395-433` — pending inspections are count-bounded only while each inspection may retain a 10 MiB source payload.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:443-448` — duplicate-add idempotency results bypass `rememberIdempotency` and its eviction queue.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:501-529` — commit-add performs heavy engine work while resource pressure says heavy work is disabled.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:800-853` — pump ignores `acceptsHeavyWork` and retries failed re-adds without per-record backoff.
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift:1101-1106` — persistence failures are mapped through text storage classification without a volume-unavailable mapping.
- `Native/TorrentinoEngineAgent/Agent/AgentRuntime.swift:353-386` — crash-loop safe mode has no executable safe restart/clear path and its history is not tested.
- `Native/TorrentinoEngineAgent/Agent/SystemConditionMonitor.swift:146-159` — path signature omits route/address identity, so some Wi-Fi/VPN path changes can be missed.
- `Native/TorrentinoEngineAgent/Transfer/Preflight.swift:96-117` — existing `volumeIdentifier` is not checked and unknown free-space metadata fails open as available.
- `Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift:99-131` — cache is count-bounded only; the declared byte budget is not enforced.
- `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift:1362-1431` — WP-09 tests do not exercise the monitor, pressure gate, crash loop, volume identity, or engine/persistence fault injection.
- `Native/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift:883-932` — budget/fault tests validate pure values and serialization, not production enforcement.

--------------------------------------------------------------------------------
RESULT: CHANGES_REQUESTED
