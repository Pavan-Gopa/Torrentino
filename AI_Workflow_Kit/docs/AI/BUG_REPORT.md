# BUG REPORT

> Main Orchestrator writes this after verifying a Tester's structured
> functional failure evidence. For security findings use `SECURITY_REPORT.md`.
> Main routes accepted fixes to a fresh Coder. Tester never patches product
> source or writes workflow reports directly.

## Meta

| Field | Value |
|-------|--------|
| Step | WP-14 `[WP14-PERF-CAMPAIGN-001]` |
| Date | 2026-08-22 |
| bugs_open | 0 |

## Bugs

### WP14-PERF-001 (HIGH) — Event-bus overflow recovery marker erased by tail batch

- Surface: `Native/TorrentinoEngineAgent/Transfer/TransferEventBus.swift` flushNow()
  queued-delivery replacement (:102-105).
- Repro (in-process, deterministic): slow sink (~2 s), 50 mutations,
  100,000-event overflow burst, one trailing health event. Queue depth stays
  bounded (1) but ZERO `snapshotRequired(.droppedDelta)` recovery markers are
  delivered — the overflow batch carrying the marker is replaced wholesale by
  the tail batch before delivery.
- Impact: after telemetry overflow the UI may never receive the authoritative
  resync signal → stale rows until an unrelated full snapshot. Violates WP-14
  gate «authoritative state не теряется».
- Main verification: source read 2026-08-22; failing measurement
  `Measurements/wp14/inprocess-latest.csv` (Slow-consumer resync preservation:
  0 markers, target "Recovery signal not lost").
- Fix lane: `[WP14-PERF-001-FIX-001]` — sticky/merged recovery marker per sink
  until delivered; regression = the failing overload scenario must deliver
  exactly one resync signal. IMPLEMENTED (merge-on-replace, three
  GatedBatchCollector regressions, official 387/0). RESOLVED: merge-on-replace
  sticky marker approved by WP14PerfFixReviewer001; final tree 389/389×2 with
  the overload scenario delivering 1/1 resync markers.

### WP14-PERF-002 (MEDIUM-HIGH, test-infra boundary) — Log-isolation order fragility + silent default fallback

- Surface: `RedactedLogFileManager.init` (PersistenceStore.swift:31-59) +
  WP13DiagnosticsSecurityTests setUpClass override mechanism.
- Facts (final-tester + Main source verification): xcodebuild runners do not
  inherit arbitrary shell env; WP13 setUpClass setenv fires too late in
  full-suite ordering; manager init silently falls back to the DEFAULT user
  log directory when resolution/creation fails → test markers written into
  `~/Library/Logs/com.torrentino.app.engine-agent/engine_log_current.log`
  (:19365, two consecutive full runs, unique per-run sentinels).
- Impact: test data leaks into user logs; isolation guarantee is order-
  dependent; user file polluted.
- Fix lane `[WP14-LOGISOLATION-FIX-001]`: fail-closed/loud resolution when an
  explicit/env directory is unusable; order-proof late-setenv support; tests
  for both; acceptance = two consecutive full-suite greens including sentinel.
  RESOLVED: fail-closed mkdtemp isolation + live getenv re-resolution approved
  by WP14LogIsoReviewer001; two consecutive full-suite greens including
  sentinel; user log dir contains zero post-fix sentinels.
