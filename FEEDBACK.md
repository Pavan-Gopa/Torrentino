# WP-04 Implementation Feedback

## RESULT: waiting_review

## Summary
Torrentino Engine Bridge (WP-04) implemented and now fully green, including the flaky sanitizer crash (`mutex lock failed: Invalid argument`) fixed at the root cause.

## Files Created/Modified

### Native/TorrentinoEngineBridge/bridge/ (C++ PIMPL Facade)
- **EngineBridge.h** — Public C++ facade with PIMPL boundary, value DTOs, Result<T> pattern, exception firewall
- **EngineBridge.cpp** — Implementation owning libtorrent session, torrent primitives, alert batching, deterministic shutdown
- **bridge_smoke.cpp** — Headless smoke test (start/add/check/pause/resume/recheck/remove/shutdown + deadline/cancellation)

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

### Native/ThirdParty/libtorrent/patches/libtorrent-2.1.0/ (third-party patch, root-cause fix)
- **0001-fix-pread-disk-io-fence-flush-destruction-order.patch** — fixes a libtorrent
  teardown-order bug that crashed shutdown whenever a session was aborted while a
  fence flush (e.g. `save_resume_data(flush_disk_cache)`) was still in flight.

## Gates Verified

| Gate | Status |
|------|--------|
| C++ types not visible in Swift API | ✅ PIMPL + ObjC adapter with JSON |
| add/pause/resume/recheck work headless | ✅ test_bridge_headless.sh PASS |
| ASan/UBSan/TSan runs clean (x6) | ✅ run_bridge_sanitizers.sh PASS, status 0, reports 0 |
| No race/uncaught exception | ✅ Exception firewall + joined threads before Impl teardown |
| Cancellation/deadline tested | ✅ Bounded waits; shutdown unblocks in-flight requestResumeData → BridgeError::stopped |
| QA regression | ✅ run_qa_suite.sh SUITE RESULT: GREEN (33/33) |

## Test Results

```
# Headless test
bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh
RESULT: PASS — bridge headless lifecycle clean

# Sanitizers (repeated 6x — crash was flaky, so repetition is the verification)
bash Native/TorrentinoEngineBridge/scripts/run_bridge_sanitizers.sh
RESULT: PASS — bridge clean under ASan/UBSan + TSan (asan status 0, reports 0; tsan status 0, reports 0)

# QA Regression
bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
SUITE RESULT: GREEN (33/33 pass)
```

## WP-04 FIX (attempt 3): sanitizer crash root cause

### Symptom
`run_bridge_sanitizers.sh` ASan/UBSan pass aborted (SIGABRT, exit 134):
```
libc++abi: terminating due to uncaught exception of type
std::__1::system_error: mutex lock failed: Invalid argument
```
TSan passed. Crash was **flaky** (passed in earlier runs, ~1/3 of direct runs crashed).

### Diagnosis (lldb backtrace of the abort)
The exception was thrown from `libtorrent::aux::pread_storage::~pread_storage()`
(`pread_storage.cpp:63`, `m_pool.release(storage_index())`) during
`session_impl::~session_impl → pread_disk_io::~pread_disk_io`. The uncaught
`std::system_error` came from `pthread_mutex_lock` returning EINVAL — the
file_pool's internal mutex was **already destroyed** when the storage destructor
tried to lock it.

Root cause (libtorrent 2.1.0, not our bridge mutex):
- `pread_disk_io` declares `m_fence_flush` (`std::vector<std::shared_ptr<pread_storage>>`)
  **before** `m_file_pool`.
- C++ destroys members in **reverse** declaration order, so `m_fence_flush` was
  destroyed **after** `m_file_pool`.
- When a session is aborted while a fence flush is in flight (exactly what the
  cancellation test's `save_resume_data(flush_disk_cache)` on a 4 MiB torrent
  + immediate `shutdown()` does), a storage can still be queued in
  `m_fence_flush`. Its destructor then called `m_pool.release()` on the
  already-destroyed file pool → destroyed-mutex lock → EINVAL → abort.

Our bridge mutex/threading was verified correct: `shutdown()` is idempotent and
noexcept, `~Impl()` calls `shutdown()`, and every background thread (incl. the
cancellation waiter) is joined before `Impl` destruction — `std::mutex` is never
used after destruction in `EngineBridge.cpp`.

### Fix
Patched the pinned libtorrent (the project's patch mechanism,
`Native/ThirdParty/libtorrent/patches/<version>/*.patch`, applied by
`build.sh` after extraction): `m_fence_flush` is now declared **after**
`m_file_pool`, so any storage still queued at teardown is destroyed while the
pool is alive. `release()` on the alive pool is a safe no-op for an already
released pool. Rebuilt both pinned flavors (`release` + `asan`) from the
verified tarball; the fix is reproducible for any clean checkout.

### Verification of the fix
- `run_bridge_sanitizers.sh` × 6 consecutive runs: RESULT: PASS each time
  (before the fix it crashed within the first 1–2 runs).
- Direct ASan binary × 3: PASS.
- `test_bridge_headless.sh`: RESULT: PASS.
- `run_qa_suite.sh`: GREEN 33/33 (includes the WP-04 bridge tests).

## Earlier Key Fix During Implementation
The `drainLocked()` function in `EngineBridge.cpp` was missing a `pumpLocked()`
call before draining the pending alert queue. Without it, alerts posted after
startup (add_torrent_alert, state_changed_alert, torrent_checked_alert, etc.)
were never fetched from the libtorrent session. Added the pump call at the start
of `drainLocked()` — now alerts flow correctly.

## Architecture Compliance
- ✅ ADR-005: PIMPL facade, exception firewall, immutable DTOs, deterministic shutdown
- ✅ ADR-010: Two-phase removal (prepareRemoval/commitRemoval)
- ✅ Swift 6 strict concurrency: actor isolation, Sendable DTOs, no C++ pointers across boundary
- ✅ No Homebrew runtime dependencies (pinned static libs)
- ✅ Headless operation verified (loopback-only, ephemeral port)
- ✅ Third-party changes go through the lock/patch mechanism (reproducible build)
