# WP-14 Performance Qualification Report

Lane: `WP14-PERF-CAMPAIGN-001`

Verdict: **FINDINGS OPEN / PARTIAL**. All campaign items reachable without the Human's live app/LaunchAgent or Instruments GUI were measured in isolated Release-mode fixtures. One deterministic event-bus overload defect blocks the WP-14 bounded-queue/authoritative-state gate. Human-gated live-process and long-duration measurements remain explicitly open.

## Hardware and protocol

- Actual machine: Apple M4, 32 GiB, 10 logical CPUs, arm64; macOS 26.5.2 (25F84).
- Plan comparison baseline: Apple M1, 8 GiB.
- Delta: the campaign machine has a newer CPU and 4× the plan-baseline RAM. Results below are actual M4/32 GiB observations; no M1 values are inferred or fabricated.
- Build: Release (`-O`), no debugger. XCTest dependencies were built with `ENABLE_TESTABILITY=YES`; product optimization remained Release.
- State: disposable `TestProfile`/temporary corpus only. The live app, `com.torrentino.app.engine-agent`, production Application Support, Legacy, and external network were not used.
- Primary engine: app-linked/headless libtorrent 2.1.1. Fallback reference: libtorrent 2.0.14.

Environment evidence: `environment-20260822-153133.txt`.

## Headless libtorrent reference

Corpus: deterministic 256 MiB, 1 MiB pieces, seven measured repetitions per cell after one warm-up. Throughput medians are the middle of seven raw observations.

| Engine | Format | Median wall | Median throughput | Observed peak RSS range | Result |
|---|---:|---:|---:|---:|---|
| libtorrent 2.1.1 primary | hybrid | 0.204292 s | 1253.11 MiB/s | 12.17–12.31 MiB | baseline captured |
| libtorrent 2.1.1 primary | v2 | 0.110244 s | 2322.13 MiB/s | 12.14–12.30 MiB | baseline captured |
| libtorrent 2.0.14 fallback | hybrid | 0.202404 s | 1264.80 MiB/s | 264.80–264.89 MiB | baseline captured |
| libtorrent 2.0.14 fallback | v2 | 0.106813 s | 2396.70 MiB/s | 264.75–264.91 MiB | baseline captured |

Raw evidence: `headless-20260822-153133.csv`. The UI-overhead ≤5% comparison remains open because the constraints prohibit launching the Human's app/agent identity and no sterile parallel live run was authorized.

## In-process Release measurements

`phys_footprint` is sampled with `TASK_VM_INFO`; FD/thread counts use `proc_pidinfo`. The test process includes XCTest/framework overhead. The 100-record database and 2 GiB sparse creator input are isolated and disposable.

| Measurement | Value | §11.3 / WP-14 target | Result | Basis |
|---|---:|---:|---|---|
| Authoritative restore, 100 records | 24.876292 ms | ≤5000 ms | PASS | isolated SQLite + production restore path |
| Authoritative 100-record snapshot p95 | 4.043125 ms | ≤5000 ms | PASS | 50 measured command-lane snapshots after 10 warm-ups |
| 100 idle record `phys_footprint` | 12.547516 MiB | ≤350 MiB | PASS | in-process XCTest surrogate |
| 100 records / 10 active checking transfers `phys_footprint` | 12.641266 MiB | ≤750 MiB | PASS | one production coordinator; synthetic engine seam |
| Recheck dispatch p95 | 0.468500 ms | command ack ≤200 ms | PASS (in-process) | 50 engine-mapped stub acknowledgements; not full large recheck completion |
| 2 GiB sparse creator scan | 0.230625 ms | observational | PASS | production `SourceScanner` |
| 2 GiB creator cancellation reaction | 0.380000 ms | ≤1000 ms | PASS | real CPUHasher, 64 KiB cancellation checkpoints |
| 500-row projection p50 | 8.223375 ms | observational | PASS | 200 Release repetitions |
| 500-row projection p95 | 10.730916 ms | no normal-scenario stall >250 ms | PASS (projection path) | `TorrentListProjection` + all 500 `TorrentListRowProjection`s |
| Mutation ack p95 with stalled consumer | 0.724125 ms | ≤200 ms | PASS | 50 pause/resume commands |
| Health-lane p95 under telemetry overload | 0.001334 ms | ≤200 ms | PASS | 100 independent lock-backed snapshots |
| 100,000 mixed-event enqueue | 0.007375 ms | observational | PASS | one bounded publish, Release |
| Event queue depth after burst/tail | 1 event | ≤256 | PASS | pending + queued slow-consumer batch |
| Slow-consumer overflow recovery marker | 0 delivered | must preserve authoritative recovery | **FAIL** | deterministic queued-batch replacement defect |
| Disconnect/burst resync seam | true | authoritative state recoverable | PASS (in-process seam) | unregister + unknown-revision full snapshot; 100 records retained |
| Quiescent `phys_footprint` after | 38.500664 MiB | ≤350 MiB and ≤baseline+64 MiB | PASS | 1 s after close/release; allocator pages retained but within budget |
| FD baseline / during / after | 120 / 120 / 120 | no monotonic growth; after ≤baseline+4 | PASS (campaign window) | `PROC_PIDLISTFDS` |
| Threads baseline / during / after | 5 / 6 / 5 | no monotonic growth; after ≤baseline+8 | PASS (campaign window) | `PROC_PIDTASKINFO` |
| Quiescent idle CPU median | 0.123043% of one core | ≤2% | PASS (in-process surrogate) | 30 × 100 ms samples |
| Quiescent idle CPU p95 | 0.185819% of one core | ≤5% | PASS (in-process surrogate) | 30 × 100 ms samples |

Raw evidence: `inprocess-latest.csv`, `projection-latest.csv`, `xctest-20260822-154136.log`, `xctest-20260822-154136.xcresult`.

## Finding WP14-PERF-001 — overflow recovery marker can be replaced

Severity: **High (WP-14 release gate blocker)**.

Deterministic reproduction:

1. Register a sink whose delivery stalls for 2 seconds.
2. Start its first delivery.
3. Complete 50 authoritative pause/resume mutations while that delivery is active.
4. Publish 100,000 mixed torrent/progress/health events with `maxPendingEvents=256`; overflow correctly creates `.snapshotRequired(.droppedDelta)`.
5. Publish one health tail update before the slow delivery finishes.
6. Wait for both deliveries. Queue depth remains bounded, but the collector receives no dropped-delta recovery marker.

Observed XCTest failure:

`WP14PerformanceMeasurements.swift:491: XCTAssertTrue failed - overflow recovery marker was replaced for a slow consumer; lost deltas can remain falsely authoritative`

Suspect source: `Native/TorrentinoEngineAgent/Transfer/TransferEventBus.swift:102-105`. The active-sink branch replaces `queuedDeliveries[sink.id]` wholesale. A later non-authoritative tail batch can therefore replace the only `snapshotRequired` marker generated by an earlier overflow. The queue is bounded, but the connected slow consumer is not told to discard missed deltas and refetch authoritative state.

## §11.3 qualification table

| §11.3 SLO | Target | Campaign result |
|---|---:|---|
| Warm UI launch → interactive, p95 | ≤1.5 s | GAP — requires ≥30 cold and ≥50 warm launches of a sterile live identity |
| Registry snapshot available, 100 records, p95 | ≤5 s | PASS in-process: snapshot p95 4.043125 ms; restore 24.876292 ms |
| XPC command acknowledgement, p95 | ≤200 ms | GAP for real XPC; in-process overloaded mutation proxy passes at 0.724125 ms |
| Main-thread stall, normal scenario | none >250 ms | GAP for Instruments/signposts; 500-row projection proxy passes at p95 10.730916 ms |
| Idle CPU median | ≤2% | GAP for live UI+engine pair; in-process surrogate 0.123043% passes |
| Idle CPU p95 | ≤5% | GAP for live UI+engine pair; in-process surrogate 0.185819% passes |
| 100 idle torrents `phys_footprint` | ≤350 MiB | PASS in-process: 12.547516 MiB |
| 10 active torrents `phys_footprint` | ≤750 MiB | PASS in-process synthetic coordinator state: 12.641266 MiB |
| `phys_footprint` slope after 2h warm-up | ≤1 MiB/hour | GAP — long-duration live process run not performed |
| Hash/recheck cancellation reaction | ≤1 s | PARTIAL — creator hash cancellation 0.380000 ms passes; real large recheck cancellation/completion is not exposed by the in-process stub harness |
| Threads/FD/XPC connections non-monotonic | return to baseline tolerance | PASS for in-process FD/thread campaign; GAP for live XPC connections/long duration |
| UI overhead vs headless harness | throughput loss ≤5% | GAP — live app+agent comparison prohibited in this lane |
| Selection/focus/scroll retained | no reset on snapshot updates | GAP — not re-qualified by this performance-only campaign |
| 100–500 rows smooth | smooth | PASS for production 500-row projection; live scroll/frame pacing still needs Instruments/Human observation |
| Soak last-6h median vs first stable 6h | ≤15% increase | GAP — 12h/24h+ soak not performed |

## WP-14 work/gate coverage

| Work / gate | Result |
|---|---|
| Time Profiler | GAP — Human-side Instruments GUI session |
| Allocations | GAP — Human-side Instruments GUI session |
| Energy / thermal | GAP — Human-side Instruments/Power Metrics session |
| FD / thread counts | PASS in-process scoped run; live XPC connection count remains gap |
| 100 records / 10 active | PASS in-process synthetic workload |
| Large creator | PARTIAL PASS — 2 GiB sparse scan + cancellation; full completion remains gap |
| Large recheck | PARTIAL PASS — dispatch p95; real multi-GiB completion/cancellation remains gap |
| UI table 500 rows | PASS |
| Headless reference | PASS — both pinned engines, hybrid/v2 |
| 100k overload, slow consumer, bounded queue | **FAIL** — WP14-PERF-001 |
| Mutation and health lanes under telemetry | PASS in-process |
| Disconnect during burst / resync | PASS at in-process seam; real Mach XPC remains gap |
| Tracker/peer alert storm | GAP — event-bus mix measured, not a real libtorrent alert-drain storm |
| Stalled disk I/O | GAP — no safe in-process fixture reaches the real libtorrent disk lane |
| RSS/`phys_footprint` returns to budget | PASS in-process scoped run |
| Watchdog false restart under slow I/O | GAP — requires sterile live LaunchAgent identity; live Human agent was forbidden |
| Agent relaunch + XPC reconnect p95 ≤10 s / hard ≤30 s | GAP — Human-gated live identity |
| Report saved | PASS — this file and raw evidence |

## Required follow-up gaps

1. Fix WP14-PERF-001 and re-run the slow-consumer/100k overload measurement.
2. Sterile-identity live Release campaign: 30 cold + 50 warm launches, real XPC p95, live UI+engine idle CPU/footprint, XPC connection counts, and headless-vs-UI throughput.
3. Instruments GUI: Time Profiler, Allocations, main-thread signposts/stalls, Energy Log/thermal, and live 500-row frame pacing.
4. Real multi-GiB creator completion and real libtorrent recheck completion/cancellation with a capped fixture.
5. 2h warm-up slope and the first/last stable 6h soak comparison; WP-15 remains the 168h stability gate.
6. Sterile LaunchAgent watchdog/slow-disk and relaunch/reconnect recovery SLO campaign.
