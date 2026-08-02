# FEEDBACK — WP-04 Re-Review (attempt 2)

**Reviewer:** Verification Engineer
**Date:** 2026-08-02
**RESULT:** APPROVED

### 1. Build & tests
- Headless script `test_bridge_headless.sh`: PASS
- Sanitizers script `run_bridge_sanitizers.sh`: PASS (ASan: 0, UBSan: 0, TSan: 0)
- Xcode build `xcodebuild -scheme TorrentinoEngineAgent`: BUILD SUCCEEDED
- QA suite `run_qa_suite.sh`: PASS (8/8 passed)

### 2. Gate checklist
- [x] C++ types not visible to Swift API — Evidence: `TorrentinoEngineAgent-Bridging-Header.h` imports only `EngineBridgeAdapter.h`. Swift actor uses JSON envelopes and `TorrentinoEngineBridgeAdapter`.
- [x] add/pause/resume/recheck work headless — Evidence: `test_bridge_headless.sh` and `test_wp04_bridge_swift.sh` verified full lifecycle without GUI/XPC.
- [x] ASan/UBSan/TSan runs clean — Evidence: `run_bridge_sanitizers.sh` completed with 0 ASan/UBSan reports and 0 TSan reports.
- [x] No race/uncaught exception — Evidence: Exception firewall test `test_wp01_exception_firewall.sh` and nested C++ `try/catch` inside `@try` in `EngineBridgeAdapter.mm` guarantee no exception leaks across boundaries.
- [x] Cancellation/deadline tested — Evidence: `bridge_smoke.cpp` tests `setOperationTimeout(1)` deadline mapping to `BridgeError::timeout` and `shutdown()` unblocking an in-flight `requestResumeData` waiter returning `BridgeError::stopped`.

### 3. Previous issues — all 7 fixed?
1. **HARD: EngineBridgeAdapter.mm compiles (base64 syntax, try/catch instead of @catch)** — FIXED. `base64ToBytes`/`bytesToBase64` corrected; nested C++ `try/catch` inside `@try` correctly handles C++ and ObjC exceptions.
2. **HARD: WP-04 integrated into xcodeproj (bridging header, files in target)** — FIXED. Target `TorrentinoEngineAgent` compiles cleanly with `EngineBridgeAdapter.mm`, `EngineCoordinator.swift`, `EngineBridgeDTOs.swift`, and bridging header.
3. **HIGH: pause/resume/recheck pass torrentID** — FIXED. `EngineCoordinator.swift` encodes `TorrentIDPayload(torrentID:)` and `EngineBridgeAdapter.mm` extracts `torrent-id`.
4. **MEDIUM: boot report peer-id from config** — FIXED. `EngineBridge.cpp` assigns `last_peer_id_ = config.peer_id_prefix` and returns it in `BootReport`.
5. **MEDIUM: deadline/cancellation tests (timeout + shutdown-during-wait)** — FIXED. Verified in `bridge_smoke.cpp`.
6. **LOW: alert_dump.cpp deleted** — FIXED. File removed.
7. **LOW: classify(), let, progress, двойное started** — FIXED. `EngineBridgeDTOs.swift` properties use `let`, `progress` populated, `started` state logic clean.
- **Plus: Mutex crash fix** — FIXED. `EngineBridgeAdapter.mm` `dealloc` and `Impl::~Impl()` perform idempotent `shutdown()` joining threads before destruction.

### 4. Architecture compliance
- Pure PIMPL isolation maintained between C++ libtorrent 2.x and Swift actor layer.
- ObjC++ Adapter bridges C++ facade to Swift via JSON envelopes and `NSError` mapping.
- All gate checklist requirements met with full QA suite regression pass.

### 5. If CHANGES_REQUESTED — concrete list
N/A — APPROVED.
