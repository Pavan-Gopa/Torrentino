# FEEDBACK - WP-09 Final Validation Review

Date: 2026-08-04
WP: WP-09 native fault recovery and bounded resources
Role: Verification Engineer (Code Reviewer)
Range: working tree; declared Native WP-09 paths only, Legacy excluded

### 1. Build & tests

- `graphify query "WP-09 ResourceBudget shrinking under pressure EngineResourceBudget max concurrent transfers alerts"`: PASS; completed before source inspection.
- `graphify update .`: PASS; graph rebuilt with 3,551 nodes, 8,342 edges, and 284 communities.
- `xcodebuild build -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS.
- `xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino -destination 'platform=macOS,arch=arm64'`: PASS; all XCTest targets passed.
- `bash Native/TorrentinoEngineBridge/scripts/qa/test_wp09_fault_matrix.sh`: PASS; all 6 WP-09 tests passed.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh`: PASS.
- `bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh`: 100/101 PASS. The sole failure is `test_wp03_legacy_untouched.sh`, caused by pre-existing tracked and untracked `Legacy/Tauri` working-tree dirt.
- `git diff --check -- Native`: PASS.
- Unscoped `git diff --check`: environmental failure from pre-existing Legacy trailing whitespace in `Legacy/Tauri/src-tauri/src/gui.rs` and `Legacy/Tauri/ui/app.js`; Legacy was not touched.

### 2. WP compliance

- System conditions: PASS. Native monitoring covers network reachability/generation, thermal state, memory pressure, Low Power Mode, sleep/wake, and volume mount/unmount signals.
- Bounded resource policy: PASS. `EngineResourceBudget` bounds active work, peers, attempts, cache, alert draining, re-adds, and pump intervals. Critical pressure no longer bypasses the offline network gate.
- Fault taxonomy: PASS. Storage, volume, permission, insufficient-space, network, resource, sleep, and crash-loop faults remain typed and carry affected volume/record context where applicable.
- Safe storage recovery: PASS. Preflight does not create missing volume paths; per-record recovery preserves desired state and avoids reconnect spin.
- Event and command bounds: PASS. Event overflow requests a snapshot; idempotency, bridge cache, alert draining, and agent command lanes remain bounded.
- Health and restart safety: PASS. The liveness health lane exposes queue/condition state, watchdog behavior is explicitly disabled, and durable crash-loop protection prevents repeated unsafe starts.
- UI projection: PASS. System conditions and agent health are surfaced without becoming a second source of truth.
- Legacy scope: PASS for this change. Product edits are confined to Native and the declared WP-09 QA path; existing Legacy dirt remains untouched.

### 3. Architecture

- Swift 6 Complete: PASS. Native and bridge Swift paths compile with strict concurrency.
- C++ PIMPL: PASS. Libtorrent remains behind the existing bridge boundary; no third-party types cross the public adapter surface.
- Authority and persistence: PASS. `TransferCoordinator` remains the record/revision/persistence authority; UI receives authoritative condition and health events.
- Recovery sequencing: PASS. Pressure policy selection is followed by network/sleep gating, bounded backoff, durable locations, and per-torrent fault isolation.
- No Legacy/Tauri compatibility path, in-process fallback engine, or unbounded queue was introduced.

### 4. Comments

- No product findings remain after fixing the pressure-policy early return and updating the frozen event surface test for `systemCondition`.
- The full QA suite is not numerically all-green only because the required Legacy untouched check detects pre-existing Human working-tree changes. This is environmental and must not be fixed in WP-09.
- Xcode emits non-fatal linker warnings because the target minimum is macOS 13 while the local XCTest dylibs are built for macOS 14; the suite passes on the current macOS host.

### 5. If changes_requested — concrete list only

- N/A. No native changes requested.

--------------------------------------------------------------------------------
RESULT: waiting_review
