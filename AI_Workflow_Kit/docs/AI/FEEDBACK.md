# FEEDBACK — WP-01: arm64 macOS libtorrent proof-of-build

### 1. Build & tests
- Builds/tests after changes? **Yes** — reproducible, Homebrew-free, static arm64.
- Commands run:
  * `bash Native/ThirdParty/libtorrent/build.sh --flavor release` → `libtorrent-rasterbar.a` (17 107 520 B, arm64, minOS 13.0). Same for `--flavor asan` and `--lt-version 2.0.13`.
  * `bash Native/TorrentinoEngineBridge/scripts/run_tests.sh` → 2.1.0-release **11 passed, 0 failed**; `--lt-version 2.0.13` also **11/11**.
  * `bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh` → 2.1.0-asan suite **11/11 PASS, ASan/UBSan clean** (binary links `libclang_rt.asan_osx_dynamic.dylib`, zero reports).
  * `bash Native/TorrentinoEngineBridge/scripts/verify_no_homebrew.sh <bin>` → arm64, macOS 13.0+, system frameworks only, **no `/opt/homebrew`, no `/usr/local`, no rpath** for the release binary.
  * `bash Native/TorrentinoEngineBridge/scripts/run_soak.sh start --duration 86400` → detached pid 1381 as of 2026-08-01; 0 errors, ~27 MB RSS after 5 min. Completes 2026-08-02 22:01 IST.
- Evidence logs: `Native/TorrentinoEngineBridge/runs/{tests,sanitizers,soak}-*/`.

*Comment:* Full build matrix (4 configs) and both scenario suites pass; sanitizer flavor is clean. The only thing not yet *complete* is the 24h soak — it is launched and green, but must run its duration before final sign-off.

### 2. WP compliance
- All requirements of current WP met?
  - [x] Pin libtorrent 2.1.0 (+ 2.0.13 fallback), Boost 1.91.0, OpenSSL 3.5.7 with SHA-256 (`versions.lock`).
  - [x] Headless C++ harness covering all required engine behaviours (11 scenarios + soak + C-ABI firewall).
  - [x] Reproducible static arm64 build, no Homebrew links, manifest output (`build.sh`).
  - [x] Build/verify/run scripts and the Homebrew-free gate.
  - [x] Sanitizer-clean and crash-restore-via-SIGKILL proven.
- No work from future WPs? **Yes.** No Swift, no ObjC++ facade, no `EngineCoordinator`, no XPC — only Native/ C++ + scripts, exactly the WP-01 scope.
- `target_files` only? **Yes.** Changes confined to `Native/` (new, untracked) and this `FEEDBACK.md`. No UI/Legacy/Tauri files touched.
*Comment:* WP delivered. The single open item is qualitative (soak duration), not a scope gap.

### 3. Architecture invariants
- Swift 6 strict concurrency Complete? N/A — no Swift in WP-01.
- No disk/network/DB/hash on MainActor? N/A (no Swift). On the C++ side, all heavy work is hermetic loopback; no public network use in tests.
- C++ hidden behind PIMPL? Established the pattern the PIMPL will wrap: a plain-C `harness_api.h` ABI with a single `catch(...)` firewall (`run_guarded`) and `std::terminate` last-resort handler. No libtorrent type crosses the boundary.
- DTO immutable/Sendable? N/A.
- UI not source of truth? N/A — no UI.
- Legacy/Tauri/ untouched? **Yes**, untouched.
- No Homebrew runtime links? **Yes, proven.** `otool -L` shows only `/System/...`, `/usr/lib/libc++`, `/usr/lib/libSystem`; `verify_no_homebrew.sh` confirms no rpath for release; `CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local` enforced at build time. (The `asan` binary legitimately links the toolchain sanitizer dylib and the script now flags that explicitly as non-shippable.)
*Comment:* The boundary discipline WP-04 needs is already in place and exercised by the C-ABI firewall scenario.

### 4. Comments & readability
- New modules/types have role header? **Yes.** `README.md` (harness), `DEPENDENCIES.md`, `LICENSES.md`, `patches/README.md` written; scenario/registry/digest headers self-document.
- Non-obvious logic explained with why? **Yes** — `apply_deterministic_flags` (why `paused`/`auto_managed` must be cleared), `Session::shutdown` (why `session_proxy` must go out of scope), `wait_for_alert` (why alert pointers can't be retained), atomic rename in the crash child.
- Actor/concurrency notes where relevant? N/A (no actors). Concurrency notes present where the harness spawns/awaits.
- XPC protocol documented? N/A — no XPC in WP-01.
- No noisy or outdated comments? Comments reflect final behaviour; no leftover TODO/placeholder.
*Comment:* Docs are WP-01-grade; the release `Credits` panel and SBOM-assembly step are deferred to packaging (noted in `LICENSES.md` §5–6).

---

**RESULT: waiting_review**

Open item for the reviewer / orchestrator:
1. Let the 24h soak run; check `run_soak.sh status` before final sign-off (errors must stay 0 and RSS must not climb).
2. WP-01 is otherwise done and can unblock WP-04 (ObjC++ PIMPL + `EngineCoordinator`) — the proven boundary (`harness_api.h`, `engine_ops`, the failure-injection pattern) is the contract the real bridge implements.
3. Prefer 2.1.0 as the shipping version; keep 2.0.13 pinned as the fallback (`LT_DEFAULT_VERSION` flip).

