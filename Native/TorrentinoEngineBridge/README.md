# TorrentinoEngineBridge — WP-01 headless harness

Proof that the pinned libtorrent build actually works on arm64 macOS **before**
any UI exists, and a working sketch of the boundary the real bridge will have.

What this directory is *not* (yet): the ObjC++ PIMPL facade and the
`EngineCoordinator` actor. Those are WP-04. Everything here is a C++ harness
plus scripts.

## Layout

```
harness/
  include/torrentino/harness/
    harness_api.h        C ABI entry point — the exception firewall
    support.hpp          status codes, assertions, logging, workspaces, digests
    session_fixture.hpp  libtorrent session ownership + bounded waits
    torrent_factory.hpp  deterministic v1/v2/hybrid torrent creation
    engine_ops.hpp       add / check / resume / session state / registry / swarm
    scenario.hpp         scenario registry
    soak.hpp             long-running soak
  src/                   implementations + scenarios_core / scenarios_persistence
scripts/
  build_harness.sh       build against the pinned prefix
  run_tests.sh           build (if needed) + run every scenario
  run_sanitizers.sh      ASan + UBSan run, fails on any report
  run_soak.sh            start / status / stop the 24h soak
  verify_no_homebrew.sh  arch, minOS, otool -L and rpath gate
```

Build output (`.build/`) and run artifacts (`runs/`) are git-ignored.

## Quick start

```bash
# 1. pinned toolchain (libtorrent + Boost + OpenSSL, static, arm64)
bash Native/ThirdParty/libtorrent/build.sh

# 2. harness + full scenario suite
bash Native/TorrentinoEngineBridge/scripts/run_tests.sh

# 3. sanitizers
bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh

# 4. soak (detached; survives closing the terminal)
bash Native/TorrentinoEngineBridge/scripts/run_soak.sh start --duration 86400
bash Native/TorrentinoEngineBridge/scripts/run_soak.sh status
```

The binary itself is usable directly:

```
torrentino-harness list
torrentino-harness run crash_restore --keep-workspace
torrentino-harness version
```

Exit codes are the `torrentino_harness_status` values from `harness_api.h`
(`0` ok, `1` assertion, `2` libtorrent error, `3` std exception, `4` unknown,
`5` timeout, `6` usage, `7` I/O).

## Scenarios

| Scenario | What it proves |
|---|---|
| `session_lifecycle` | session starts, binds loopback, shuts down cleanly inside a deadline |
| `torrent_creation` | v1 / v2 / hybrid creation, correct hash sets, `.torrent` round-trip |
| `add_torrent_file` | add from a real file, existing data verifies to 100 % |
| `info_hash_recognition` | btih/btmh presence per protocol, magnet round-trip, registry id rule |
| `pause_resume` | per-torrent flag and session-wide pause, data intact afterwards |
| `resume_data` | partial data survives save → remove → reload with no re-download |
| `session_state` | settings survive a warm restart through `session_params` |
| `exception_containment` | four injected failures, all converted to status codes |
| `magnet_metadata` | metadata fetched from a local peer over ut_metadata |
| `data_transfer` | real loopback transfer, payload digest matches byte for byte |
| `crash_restore` | child `SIGKILL`ed; registry, session state and partial data all restore |

Everything is hermetic: DHT, LSD, UPnP and NAT-PMP are off, sessions bind
`127.0.0.1:0`, and peers are handed over as explicit loopback endpoints. The
suite never touches the public swarm.

## Design rules this harness establishes for WP-04

1. **Exception firewall at the boundary.** `torrentino_harness_main` is plain C
   and catches everything; `run_guarded` is the only `catch (...)` in the code
   base and maps exceptions to a small status enum. A `std::terminate` handler
   is installed as a last resort and prints the in-flight exception.
2. **No libtorrent type escapes.** Scenarios never keep an `lt::alert*` — alert
   pointers die at the next `pop_alerts()`, so anything needed is copied inside
   the pump callback.
3. **Every wait is bounded.** `wait_for_alert` / `wait_for_status` throw
   `TimeoutFailure`; a hang is a reported failure, never a stuck process.
4. **Desired state is ours, not libtorrent's.** `auto_managed` and `paused` are
   cleared on add (`apply_deterministic_flags`), because the coordinator owns
   the state machine.
5. **Durability is atomic-write + rename**, and it is verified after a real
   `kill -9`, not after a graceful exit.
6. **Clean shutdown lets `session_proxy` leave scope** — see
   `../ThirdParty/libtorrent/DEPENDENCIES.md` §7.
