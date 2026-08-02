# FEEDBACK — WP-01: arm64 macOS libtorrent proof-of-build

**Reviewer:** Verification Engineer (attempt 3 re-review)  
**Reviewed commit:** `4fb2def` — `fix(torrentino): WP-01 soak root cause — flush_cache barrier before digest`  
**Date:** 2026-08-02

### 1. Build & tests
- Builds/tests after changes? **Yes**
- Commands run:
  * `graphify query "soak.cpp flush_cache barrier, cache_flushed_alert, harness architecture"` → graph context (168h Soak Test / FOUNDATION track) loaded first.
  * `bash Native/TorrentinoEngineBridge/scripts/run_tests.sh` → **PASS**: **11 passed, 0 failed** (total 2.423s). Log: `runs/tests-2.1.0-release-20260802T022321Z/scenarios.log`.
  * `bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh` → **PASS**: **11 passed, 0 failed, 0 sanitizer reports** (ASan/UBSan clean, 2.662s). Log: `runs/sanitizers-2.1.0-20260802T022332Z/sanitizers.log`.
  * `bash Native/TorrentinoEngineBridge/scripts/run_soak.sh status` → **RUNNING** (pid 34809, elapsed ~7h32m, RSS ~28 000 KiB ≈ 27 MiB).
  * Soak evidence (live process + log):
    * Started `2026-08-01T18:51:17Z` / local `Sun Aug 2 00:21:17 2026` on binary mtime `00:21:16` (matches fixed `soak.cpp` mtime `00:20:35`).
    * Binary strings include `cache_flushed_alert (disk I/O drained)`, `payload digest mismatch | expected=`, `last_write_ms_since_epoch=` — **running binary is the fixed build**.
    * Progress: **25800+ iterations**, **~101 GB** transferred, **rss=26 MiB peak=29 MiB**, slowest=5.006s.
    * **0 errors** (`run_soak.sh status` error count = 0; no ERROR/mismatch/FAIL lines in active `soak.log`).
    * Past historical failure points (iter ~2240 @~39 min, iter 2594 @~45 min) by **~10×** margin; **>6000-iter / 2h gate cleared** long ago.
*Comment:* Unit/integration and sanitizer gates are green. Live soak is healthy well past the previous crash window with flat RSS — root-cause fix is empirically validated under load.

### 2. WP compliance
- All requirements of current WP met? **Yes**
  * arm64 harness + core ops covered by 11 scenarios.
  * ASan/UBSan clean.
  * 24h soak detached and running clean (0 errors, RSS not growing).
  * Soak race root cause fixed with deterministic libtorrent disk barrier (not a timing/sleep patch).
- No work from future WPs? **Yes** — no Swift, no ObjC++ facade, no `EngineCoordinator`, no XPC, no UI.
- `target_files` only? **Yes** for product code:
  * Code delta in `4fb2def`: **`Native/TorrentinoEngineBridge/harness/src/soak.cpp` only**.
  * Also updated workflow docs `AI_Workflow_Kit/docs/AI/FEEDBACK.md` + `STATE.yaml` (expected for handoff; not product surface).
  * `Legacy/Tauri/` untouched (no diff under `Legacy/`).
*Comment:* Scope is correct. The only behavioral change is the soak disk barrier + diagnostics.

### 3. Architecture invariants
- C++ exceptions contained? **Yes** — soak still runs under `run_guarded`; mismatch path throws `AssertionFailure` after structured `log_error` (still inside the firewall).
- No Homebrew runtime links? **Yes** (previously verified; no link-line change in this commit).
- Dependency lock precise? **Yes** — no changes to `versions.lock` / ThirdParty pins.
- Legacy untouched? **Yes**.
- Disk barrier correctness:
  * `session_fixture.cpp` enables `alert_category::storage` in `kAlertMask` → `cache_flushed_alert` is deliverable.
  * `flush_torrent_to_disk()`: `handle.flush_cache()` then `wait_for_alert` filtered on `lt::cache_flushed_alert` **and** matching `handle` — deterministic, handle-scoped barrier.
  * Call order in `run_cycle`: `wait_until_finished` → **`flush_torrent_to_disk`** → `save_resume_data` (resume round-trip only) → `sha256_file_hex` — correct: digest cannot race in-flight `pwrite()`.
  * Why-comments correctly document that `save_resume_data(flush_disk_cache)` is **not** a data-write barrier (timestamp/resume-buffer semantics only).
- Mismatch diagnostics present? **Yes** — expected/actual sha256, path, on-disk size vs `expected_size`, `last_write_ms_since_epoch` before throw.
*Comment:* Architecture and libtorrent alert plumbing line up with the documented barrier. This is the right API surface (`flush_cache` + `cache_flushed_alert`), not the ineffective attempt-2 flag.

### 4. Comments & readability
- Module role header present? **Yes**.
- Non-obvious logic explained with **why**? **Yes**:
  * Helper header (lines 57–61): points to call site; notes why not `save_resume_data(flush_disk_cache)`; notes `alert_category::storage` already enabled.
  * Call site (lines 105–116): explains `is_finished` vs async disk thread race, documents libtorrent guarantee, explains failure of the previous “fix”.
  * Diagnostics block (lines 126–129): explains post-barrier mismatch ⇒ real corruption, so capture size/mtime for post-mortem.
- No noisy/outdated comments? **Yes** — old incorrect claim that `save_resume_data` flushes piece data was removed.
*Comment:* Comments match the actual root cause and will prevent reintroducing the attempt-2 mistake.

### 5. If changes_requested — concrete list
None.

**Checklist (acceptance criteria):**
- [x] 11/11 tests green
- [x] ASan/UBSan clean
- [x] Soak RUNNING, 0 errors, >6000 iterations, RSS not growing (26–29 MiB, 25800+ iter, ~7.5 h)
- [x] `flush_cache()` + `cache_flushed_alert` = deterministic barrier
- [x] Why-comments: why `save_resume_data` fails as barrier; why `flush_cache` works
- [x] Mismatch diagnostics present
- [x] Product-code diff only in `soak.cpp`
- [x] Legacy untouched

---
**RESULT:** [APPROVED]
