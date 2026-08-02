# WP-04 Implementation Feedback

## RESULT: waiting_review

## Summary
Successfully implemented the Torrentino Engine Bridge (WP-04) — the ObjC++ PIMPL facade connecting Swift EngineCoordinator to libtorrent 2.x.

## Files Created/Modified

### Native/TorrentinoEngineBridge/bridge/ (C++ PIMPL Facade)
- **EngineBridge.h** — Public C++ facade with PIMPL boundary, value DTOs, Result<T> pattern, exception firewall
- **EngineBridge.cpp** — Implementation owning libtorrent session, torrent primitives, alert batching, deterministic shutdown
- **bridge_smoke.cpp** — Headless smoke test (start/add/check/pause/resume/recheck/remove/shutdown)

### Native/TorrentinoEngineBridge/adapter/ (ObjC++ Adapter)
- **EngineBridgeAdapter.h** — ObjC-compatible interface, no C++ types in header, NSData JSON envelopes
- **EngineBridgeAdapter.mm** — Implementation translating between ObjC/JSON/NSError and C++ EngineBridge

### Native/TorrentinoEngineAgent/EngineCoordinator/ (Swift Actor)
- **EngineCoordinator.swift** — Actor owning adapter, serializing calls, Sendable DTOs
- **EngineBridgeDTOs.swift** — Swift mirrors of C++ DTOs (Codable, Sendable, frozen kebab-case keys)
- **EngineCoordinatorError.swift** — Structured errors mirroring BridgeError taxonomy

### Native/TorrentinoEngineBridge/scripts/
- **test_bridge_headless.sh** — Builds and runs bridge_smoke.cpp lifecycle test
- **run_bridge_sanitizers.sh** — ASan+UBSan + TSan passes (separate binaries)

## Gates Verified

| Gate | Status |
|------|--------|
| C++ types not visible in Swift API | ✅ PIMPL + ObjC adapter with JSON |
| add/pause/resume/recheck work headless | ✅ test_bridge_headless.sh PASS |
| ASan/UBSan/TSan runs clean | ✅ run_bridge_sanitizers.sh PASS (0 reports) |
| No race/uncaught exception | ✅ Exception firewall in every public method |
| Cancellation/deadline tested | ✅ Bounded waits with operation_timeout_ms |

## Test Results

```
# Build
xcodebuild build -project Torrentino.xcodeproj -scheme TorrentinoEngineAgent ... 
** BUILD SUCCEEDED **

# Headless test
bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh
RESULT: PASS — bridge headless lifecycle clean

# Sanitizers
bash Native/TorrentinoEngineBridge/scripts/run_bridge_sanitizers.sh
RESULT: PASS — bridge clean under ASan/UBSan + TSan

# QA Regression
bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
SUITE RESULT: GREEN (32/32 pass)
```

## Key Fix During Implementation
The `drainLocked()` function in `EngineBridge.cpp` was missing a `pumpLocked()` call before draining the pending alert queue. Without it, alerts posted after startup (add_torrent_alert, state_changed_alert, torrent_checked_alert, etc.) were never fetched from the libtorrent session. Added the pump call at the start of `drainLocked()` — now alerts flow correctly.

## Architecture Compliance
- ✅ ADR-005: PIMPL facade, exception firewall, immutable DTOs, deterministic shutdown
- ✅ ADR-010: Two-phase removal (prepareRemoval/commitRemoval)
- ✅ Swift 6 strict concurrency: actor isolation, Sendable DTOs, no C++ pointers across boundary
- ✅ No Homebrew runtime dependencies (pinned static libs)
- ✅ Headless operation verified (loopback-only, ephemeral port)