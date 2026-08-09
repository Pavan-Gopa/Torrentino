# ADR Log — Torrentino

> Architecture Decision Records. Format: ADR-NNN — Title.

---

## ADR-001 — Только Apple Silicon и macOS 13+

**Status:** Accepted (from plan)
**Decision:** arm64 only, macOS 13.0+, no Intel/universal binary.
**Rationale:** SMAppService, modern Swift Concurrency, reduced matrix.

---

## ADR-002 — SwiftUI + AppKit, без WebView

**Status:** Accepted (from plan)
**Decision:** SwiftUI for composition, AppKit for NSTableView central list.
**Rationale:** Virtualization, multi-selection, keyboard nav.

---

## ADR-003 — libtorrent 2.x как production engine

**Status:** Accepted (from plan)
**Decision:** Pinned stable 2.x, self-contained build, no Homebrew runtime.
**Rationale:** Mature, feature-complete, v1/v2/hybrid.

---

## ADR-004 — Отдельный TorrentinoEngineAgent

**Status:** Accepted (from plan)
**Decision:** Bundled LaunchAgent via SMAppService, Mach XPC, no root.
**Rationale:** Process isolation, survives UI crash, launchd restart.

---

## ADR-005 — Узкий ObjC++/C++ facade (PIMPL)

**Status:** Accepted (from plan)
**Decision:** PIMPL, catch-all exceptions, value DTO, no C++ types in Swift.

---

## ADR-006 — Versioned XPC через Codable Data

**Status:** Accepted (from plan)
**Decision:** ProtocolEnvelope with version, instanceID, requestID, idempotencyKey.

---

## ADR-007 — SQLite WAL + atomic generation files

**Status:** Accepted (from plan)
**Decision:** WAL, foreign keys, busy timeout, versioned migrations, atomic file generations.

---

## ADR-008 — Direct distribution, Hardened Runtime, без App Sandbox

**Status:** Accepted (from plan)
**Decision:** Developer ID, no sandbox v1, agent runs as current user.

---

## ADR-009 — Metal только как опциональный HashingBackend

**Status:** Accepted (from plan)
**Decision:** CPU always present, Metal research-only with ADOPT/REJECT gate.

---

## ADR-010 — Никаких необратимых удалений в 1.0

**Status:** Accepted (from plan)
**Decision:** keepData or moveManagedFilesToTrash only. Two-phase manifest/token.

---

## ADR-011 — Build integration strategy (PROPOSED)

**Status:** Proposed (pending owner approval)
**Decision:** libtorrent built via CMake → static library → XCFramework → SPM binary target. Internal modules (Domain, IPC, Hashing) as local SPM packages. Main app/agent as Xcode project.
**Rationale:** Reproducible builds, no Homebrew, clean module boundaries, `swift test` support.
**Alternatives considered:** Direct Xcode C++ target (tight coupling), pure CMake (poor Xcode integration).

---

## ADR-012 — Phased soak testing (PROPOSED)

**Status:** Proposed (pending owner approval)
**Decision:** 24h (WP-01) → 72h (after WP-09) → 168h (WP-15). Failure at 72h restarts from last green phase, not from zero.
**Rationale:** 168h single-shot is high-risk; phased approach catches regressions earlier.

## ADR-010 — Стратегия тестирования: multi-level coverage

**Дата:** 2026-08-02
**Статус:** approved
**Контекст:** WP-01/02 используют bash-скрипты (integration). Smoke-тесты допустимы только для wall-clock gates (24h soak). Необходима глубокая multi-level стратегия.

**Решение:**

Уровни покрытия (каждый WP добавляет все применимые):

1. **Unit (XCTest)** — с WP-03 обязательно. Каждый публичный метод нового API: happy path, error path, edge case. Изолированные, быстрые (<1s каждый). TestProfile (не production Application Support).
2. **Integration (bash/XCTest)** — lifecycle, XPC round-trip, persistence across kill. То, что требует launchd/SMAppService/реального IPC.
3. **Concurrency stress** — с WP-03 обязательно для каждого actor/shared state. N параллельных клиентов, гонки при reconnect, параллельные writes.
4. **Negative/fuzz** — мусор в XPC, обрезанный/corrupted файл, disk full, permissions denied, symlink attack. Для каждого parser/reader.
5. **Property-based** — инварианты (counter монотонен, atomic write не оставляет partial, format version не регрессирует).
6. **Endurance (soak)** — 24h/72h/168h. Только wall-clock, не в CI-цикле.

**Правила:**
- Smoke допустим ТОЛЬКО для wall-clock gates (soak). Всё остальное — полная глубина.
- Каждый новый публичный API = минимум 3 unit-теста (happy/error/edge).
- Каждый actor = минимум 1 concurrency stress test.
- Каждый parser/reader = минимум 1 negative/fuzz test.
- Покрытие монотонно растёт. Старые тесты не удаляются.
- Tester kick обязан содержать секцию «Новые фичи» с явным указанием уровня тестов для каждой.

**Не допускается:**
- Объявлять WP green без unit-тестов (с WP-03).
- Заменять integration-тест smoke-проверкой.
- Пропускать concurrency stress для shared mutable state.

---

## ADR-013 — Legacy/Tauri HARD BAN for all agents

**Date:** 2026-08-04
**Status:** Accepted (Human directive)
**Context:** Human researches Legacy/Tauri independently offline. Agents previously risked dirtying or "fixing" that tree; `test_wp03_legacy_untouched` then failed.

**Decision:**
- `Legacy/` (including `Legacy/Tauri/`) is **out of scope for every agent role** (Coder, Reviewer, Tester, Architect, Orchestrator product work).
- Agents must **not** read Legacy for implementation guidance, copy code from it, edit it, stage it, or "help" with Human research changes.
- Orchestrator may only `git checkout -- Legacy/` to undo **accidental** agent dirt; never commit Legacy product changes.
- Reviewer/Tester may only **detect** Legacy path drift via git; never modify Legacy files.
- Authoritative sources for Native work: plan, DECISIONS, STATE, Native tree only.

**Consequences:**
- All kick templates restate the ban.
- Product commits must show empty `git diff -- Legacy/` for agent work.
- Human Legacy research dirt is ignored by agents and reported to Orchestrator if it confuses gates.

---

## ADR-014 — Tester security pass on every WP

**Date:** 2026-08-04
**Status:** Accepted (Human directive)
**Context:** Torrentino is network- and filesystem-facing. Functional regression alone is insufficient; security issues must be hunted continuously and fixed only via Orchestrator→Coder.

**Decision:**
- Every Tester turn includes a WP-scoped **security pass** (threat model new surfaces + negative/abuse tests where practical).
- Findings go to `Native/TorrentinoEngineBridge/scripts/qa/SECURITY_FINDINGS.md`.
- Tester never patches product code for security or functional bugs.
- Orchestrator merges High/Critical findings into Coder fix kicks; Low/Info may residual-forward.
- Critical/High product-reachable findings block WP close even if functional suite is green.
- Engagement limited to local TestProfile/mktemp fixtures — no external offensive testing.

**Consequences:**
- `KICK_TESTER.md`, `TEAM_CONTRACT.md`, `ORCHESTRATOR.md` updated.
- COVERAGE.md should track security scripts alongside functional ones.

---

## ADR-015 — Separate Security Engineer (on-demand); Tester stays functional

**Date:** 2026-08-04
**Status:** Accepted (Human directive; supersedes ADR-014 operational practice)
**Context:** Combining full security audit into every Tester turn burns tokens and is unnecessary cadence. Functional QA must stay cheap and frequent.

**Decision:**
- **Test Engineer** = functional regression + new feature tests every WP. Ordinary invalid-input/bounds tests OK. No mandatory deep security audit. Does not own `SECURITY_FINDINGS.md`.
- **Security Engineer** = separate role (`KICK_SECURITY.md`). Invoked **periodically / near release** (or after large trust-boundary WPs), not each WP.
- Findings still flow: Security → Orchestrator → Coder fix → Reviewer → Tester regression.
- ADR-014 intent (security matters; Tester never patches) remains; **cadence and role split** change per this ADR.

**Consequences:**
- Default pipeline: Coder → Reviewer → Tester only.
- Human may say «зови security» when ready for an engagement.

---

## ADR-016 — WP-11 Creator commit is option-bound, descriptor-anchored, and independently verified

**Date:** 2026-08-05
**Status:** Accepted (Architectural WP-11 retry)

**Context:** WP-11’s third review is `CHANGES_REQUESTED` although the suite is green. The existing opaque `CreatorPlanToken` can commit an obsolete inspected option set; an allowed output inside the source tree changes a directory mtime used as source generation; temp creation and verification still use destination paths after a directory FD is acquired; and the claimed independent verification neither establishes both exact info hashes nor uses libtorrent for the generated creator output. The IPC already carries detailed creator progress, but the sheet does not project it completely.

**Decision:**
- An inspect result is a one-shot, agent-owned immutable plan binding the source path, canonical complete `CreateOptions` snapshot (including ordered tracker tiers), resolved output leaf, source generation, and inspected destination-directory identity. `commitCreate` carries the caller's complete immutable asserted `CreateOptions`; the agent requires canonical structural equality with the snapshot stored by the token before it hashes or writes. The token is opaque; cryptographic self-description is not required because the agent is the sole authority mapping it to that immutable record. Every creator-form mutation invalidates the locally held token before an asynchronous re-inspection begins. A response may become the current token only if its request revision still equals the current complete form snapshot.
- Source generation compares source-root identity and the complete includable input manifest (relative path, file identity, size, high-resolution mtime and relevant scan policy), not source-directory mtimes. Only the exact canonical output leaf recorded in the plan is excluded. Consequently, an expected output mutation does not self-invalidate the plan, while included-file additions, removals, replacement, content/metadata drift, or root identity drift fail closed at every required rescan.
- The destination parent must already exist and be safely descriptor-resolvable at inspection. It is walked component-by-component without following symlinks and recorded by `st_dev`/`st_ino`; commit reopens it the same way and rejects identity drift. Once accepted, all output-leaf operations use that directory FD: no-replace existence check, unique temp create, writes, file sync/close, final rename, final read/verification, rollback unlink, and directory durability barrier. A pathname is not used again for those operations. If macOS/filesystem cannot provide `F_FULLFSYNC`, the documented supported equivalent must succeed; otherwise the operation fails closed. Failure after publication triggers descriptor-anchored rollback and durability confirmation; an OS refusal to confirm cleanup is an explicit unresolved-cleanup storage failure, never success or seeding.
- `HashingResult` contains only source-content hashing artifacts; it does not claim to contain an info hash. Exact expected v1 SHA-1 and v2 SHA-256 info hashes are derived from the raw bencoded `info` byte span after metadata construction. The final FD-anchored bytes are independently parsed by the pinned libtorrent bridge and its returned v1/v2 identities must exactly match the expected identities and requested v1/v2/hybrid shape. Existing Domain semantic/piece/root/layer checks remain additional checks, not the independent verifier.
- The Creator UI projects the authoritative matching-operation detail: stage, backend, processed/total bytes, processed/total files, ETA (or explicit unavailable state), and cancellation requested/terminal state. Events for any other operation ID may change none of those fields.

**Rationale:** These boundaries implement plan §15.3–§15.5 without trusting transient UI state, a path after its destination directory has been selected, or the same Swift parser as both writer-side and verifier-side authority. They retain the CPU-only creator and use the existing pinned libtorrent integration rather than adding a runtime dependency.

**Consequences:**
- A caller selects an existing, non-symlink destination directory; this is an intentional safety tradeoff. The normal Save-panel and default source-parent flows satisfy it. Directory creation through an unanchored path is not part of Creator commit. The asserted-options field changes the versioned v1 command payload, but it adds no new product capability and makes the inspect → commit contract enforceable across XPC.
- The system guarantees that its transaction writes and cleanup address the frozen directory identity. No application can guarantee that a separately privileged/concurrent process will not alter a completed final name after the creator has released the directory; such post-completion external tampering is not reported as creator success and is not hidden by path-based cleanup.
- Cancellation is honored through the reversible stages, including the pre-seed admission boundary. If cancellation wins before admission, rollback leaves no final/temp artifact and no seed record. Once seeding admission has durably succeeded, the operation has crossed its success linearization point and completes successfully rather than claiming a cancellable partial state.
- Tests must use deterministic stage/failure controls and a real libtorrent parse/recheck path. A Swift `MetainfoParser` round trip alone is never gate evidence. Code comments must describe the actual FD/path boundary and must not say `v1InfoHash` is computed when it is absent.

---

## ADR-017 — WP-11 structured tracker topology is the lifecycle authority

**Date:** 2026-08-05
**Status:** Accepted (Architecture escalation for WP-11)

**Context:** ADR-016 makes ordered tracker tiers part of the immutable
`CreateOptions` snapshot, but it does not explicitly assign ownership after
metainfo generation. The current retry still persists a flat `[String]`, feeds a
flat value through Creator admission/restart, and exposes a flat live engine
edit API. A flat projection preserves URL sequence in some cases while losing
tier boundaries and cannot be used to prove the exact ordered `[[String]]`
contract. The legacy persistence value also cannot recover tier boundaries after
restart.

**Decision:**
- The concrete canonical tracker topology value is immutable, ordered
  `[[String]]`. Tier order, URL order and repeated valid URLs are significant.
  `[]` is the only valid empty topology; empty inner tiers are invalid; private
  torrents require a non-empty topology; the existing URL policy and total
  tracker bound remain in force. No deduplication, sorting, trimming or scalar
  reconstruction is allowed after validation.
- The structured value remains authoritative from `CreateOptions` through
  generated `announce-list`, parser, Creator admission, restart, fetch and
  structured edit. Any `Metainfo.trackers` or `TransferRecord.trackers` flat
  field is a derived read-only compatibility projection only.
- Persistence schema v3 adds `torrent_tracker_topology` with versioned JSON
  `{"version":1,"tiers":[...]}`, checksum and generation. Existing flat
  `session_state` values are migration input only. Valid metainfo may backfill
  the structured row; a flat-only record is unsupported and fails closed rather
  than being reconstructed as singleton tiers. Structured data and metainfo
  must agree exactly on restore.
- The accepted engine edit payload is nested JSON under `tracker-tiers`; the
  Swift coordinator and ObjC++ adapter carry `[[String]]`, and the C++ bridge
  preserves the nested tier index and URL repetition when constructing engine
  announce entries. The scalar edit API is removed or reject-only.

**Rationale:** This gives the Creator lifecycle one lossless source of truth,
keeps persistence/restart deterministic, and makes the bridge acceptance
observable without exposing C++ types to Swift. Fail-closed handling is safer
than inventing tier boundaries that were not present in a legacy flat value.

**Consequences:**
- The existing persistence schema requires a v3 migration and explicit typed
  handling for corrupt, unsupported or irreconcilable topology data.
- The versioned command/bridge edit payload changes from scalar `trackers` to
  structured `tracker-tiers`; callers must submit a complete replacement and
  idempotency applies to the complete topology.
- Fetch rows remain linear for pagination, but every row carries zero-based
  `tierIndex` and `urlIndex`; repeated URLs are never UI identities.
- This is a narrow WP-11 ownership clarification, not a tracker redesign,
  magnet capability expansion, engine rewrite or new Work Package. No separate
  ADR is needed for the standalone Domain fault fallback because production IPC
  remains the sole wire fault authority and the fallback is only a compile-time
  API mirror.

---

## ADR-018 — WP-12 Metal hashing experiment: REJECT_METAL

**Date:** 2026-08-06
**Status:** Accepted (research outcome)

**Context:** WP-12 ran a controlled experiment (plan §12.1–§12.8) to decide
`ADOPT_METAL` vs `REJECT_METAL` for Creator piece hashing, with a research-only
Metal backend in `Native/TorrentinoHashing`, a CPU reference, and an independent
libtorrent 2.0.13 baseline + validator. Correctness and benchmarks were run per
§12.7 on an M4/32 GiB machine (4 GiB corpus measured, which is the eligibility
line; 10 GiB/50–100 GiB/external-SSD/M1/LPM rows are N/A — storage/hardware).

**Decision:**
- **REJECT_METAL.** The Metal backend is correct (bit-for-bit vs CPU reference
  on known vectors, 100+100 randomized cases, 1000 stress iterations; v1 pieces,
  v2 roots and piece-layer content byte-equal to libtorrent 2.0.13 on an 18-cell
  cross-format battery) but loses every §12.7 performance gate on eligible
  >= 4 GiB workloads: 0.26x–0.48x of CPU wall-clock (G6 FAIL), p95 regression
  0.26–0.49 (G7 FAIL), peak RSS 22–38x CPU (G8 FAIL), ~2x CPU-seconds per MiB
  (G9 FAIL). Only the no-harm gates pass (G10 thermal, G11 fallbacks=0).
- Metal remains research-only behind `TORRENTINO_METAL_EXPERIMENTAL=1` with the
  §12.8 fallback chain; it is never selected automatically and never touches
  production hashing (Creator stays CPU-only on libtorrent, WP-11 unchanged).
- Evidence is archived under `Measurements/wp12/` (CSV, gate verdicts, report);
  QA coverage lives in `Native/TorrentinoEngineBridge/scripts/qa/test_wp12_*.sh`
  wired into `run_qa_suite.sh`.

**Rationale:** §12.7 requires >= 20% median wall-clock gain on >= 4 GiB
workloads to ADOPT; the measured direction is opposite (Metal 2–4x slower), the
memory cost is an order of magnitude over budget, and the hybrid path still
hashes v2 SHA-256 blocks on CPU. `REJECT_METAL` is the plan's defined normal
outcome for a failed gate, not a dead end.

**Consequences:**
- No production code path changes; Creator hashing remains libtorrent CPU.
- Documented upstream findings: libtorrent 2.0.13 `create_torrent` must not be
  moved by value; `info_hashes().v2` is the info-dict hash, not the merkle root;
  libtorrent's parse re-derives a v2 root that differs from the stored one, and
  its file root uses a two-level piece-root scheme that coincides with strict
  BEP-52 for piece-aligned and sub-piece single files.
- The experimental Swift Metal/CORPUS bench tooling stays in the repo as the
  measurement harness for any future re-evaluation (e.g. M-series with larger
  GPUs), with the same gate criteria.

---

## ADR-019 — Engine session lifecycle: explicit state machine, single-writer health, unified admission, session-scoped shutdown

**Date:** 2026-08-09
**Status:** Accepted (WP-13 architectural escalation, Human decision 2026-08-09)

**Context:** The WP-13 Coder fix cycle for engine behavior produced a systemic
pattern: each live lane fixed one symptom and regressed a neighbor. Forensics
across ENGINE-001/ENGINE-002 established six recurring failures: (1) restore
rebuilt 0 records over a `verified=9` store because strict decode silently
skipped records carrying extra/changed fields from rejected lanes; (2) record
health latched `recoverableError(internalError)` on working torrents and stuck
`waitingForSpace` on seeding ones; (3) idle limbo — admitted records with
`desired=running` showing `activity=idle`; (4) the agent diagnostics sink dead
in fresh binaries (no file entries, empty OSLog) — observability regressing per
lane; (5) agent lifecycle churn — `shutdown requested via xpc` immediately
after bootstrap with no defined keepalive owner; (6) `event_bus_unavailable`
boot-order race on first connect. Structural inspection confirmed the root
causes: `TransferCoordinator.swift` is a 3214-line god actor mixing restore,
admission, command dispatch, health projection, preflight and persistence;
health/activity/rates are projected in at least four places
(`TransferCoordinator`, `BridgeTransferEngine`, `StatusCache`,
`TorrentListViewModel.projectHealth`) with no single-writer rule; there is no
explicit engine session state machine even though `EngineLifecycleState` and
`EngineLifecycleChangedEvent` are already frozen in the IPC vocabulary but
never implemented or emitted; the XPC `shutdown` method is a global, unscoped
agent kill; and the event bus is constructed only after persistence opens, so
early subscriptions are refused by timing. The uncommitted ENGINE-002 diff is
untrusted evidence of the per-lane pattern, not a design input.

**Decision:**
- **One explicit session state machine in the agent**, implemented over the
  already-frozen `EngineLifecycleState` vocabulary (`starting → openingStore →
  restoringSession → reconcilingRecords → ready`, plus `degraded`,
  `checkpointing → stopping → stopped`). Every transition has fail-closed
  semantics; every transition is logged (file + OSLog) and published as
  `EngineLifecycleChangedEvent`. Invariant **R0**: a restore that rebuilds 0
  records over a non-empty verified store is never served silently — the
  session enters `degraded(restoreAnomaly)`, library commands fail closed with
  typed faults, and an empty snapshot is never published as truth.
- **One restore/admission contract.** Tolerant decode is a design rule, not a
  per-lane patch: core identity fields decode strict, everything else is
  `decodeIfPresent`-style with typed fallbacks; partial per-record failures
  produce typed per-record health, never silent skips; a mandatory
  rebuilt/skipped summary is part of the contract (log + health payload). All
  admission paths (commitAdd, restore re-add, resume, pump re-add, safe
  restart) converge into ONE admission function with one gate order and
  postconditions: admitted + `desired=running` ⇒ activity is
  `fetchingMetadata`/`checking` (never `idle`); admitted + paused ⇒
  `idle`+healthy; deferred ⇒ typed non-healthy health. `desired=running ∧
  activity=idle ∧ health=healthy` is an invariant violation by construction.
- **Single-writer health ownership.** `TransferCoordinator` is the only writer
  of record `health/activity/rates/progress`, and only through one pure
  `HealthPolicy` (storage→health, engine-error→health, conditions→health,
  transient-suppression, triangle classification). `BridgeTransferEngine`/
  `StatusCache` produce telemetry samples, not record truth: cached fault
  evidence is live-derived with a bounded TTL so a one-shot alert can never
  latch a triangle on a healthy torrent. The UI never writes or rewrites
  health semantics — presentation mapping only; the view-model
  `projectHealth` rewrite is removed and its rule moves into `HealthPolicy`.
  Warning triangles are reserved for truthful actionable faults
  (space/permission/volume/fatal); environment states are status text.
- **Session-scoped agent shutdown and boot-order guarantees.** launchd owns
  the agent process (on-demand Mach spawn, `KeepAlive.SuccessfulExit=false` —
  unchanged); while any UI connection is live, the UI holds a shutdown veto:
  the XPC `shutdown` is honored only when the requesting connection is the
  last active one, otherwise it is refused (`false`) and the agent stays up.
  This eliminates the bootstrap churn (a stale instance's shutdown can no
  longer kill a freshly spawned agent that already serves a new UI). The
  `TransferEventBus` is constructed before the Mach listener resumes, so
  `subscribeEvents` can never be refused for timing; commands arriving before
  the coordinator is wired keep the existing fail-closed typed
  `engineNotReady` fault, covered by the client's bounded retry.
- **Bootstrap-verified diagnostics.** The redacted file sink + OSLog are
  initialized synchronously as the first statement of the agent entry point,
  with a write+readback self-test and mandatory bootstrap marker lines; the
  fresh-build gate asserts those markers in both sinks. The sink physically
  lives in the agent target (`RedactedLogFileManager` behind the
  `TorrentinoLog` facade) and is a bootstrap-verified service, not a lazy
  side effect, so no refactor can silently kill it again.
- **Incremental god-object decomposition, not big-bang.** After the lifecycle
  lane lands, `TransferCoordinator` is decomposed in a fixed minimal sequence
  of behavior-preserving extractions: `HealthPolicy` (pure) →
  `AdmissionController` → `RestorePipeline` → `RecordLedger` → lane handler
  file splits. Each step keeps the full behavioral contract and test suite
  green; no step changes observable behavior.

**Rationale:** The six recurring failures are symptoms of missing ownership
boundaries, not six independent bugs: four health writers, five admission
paths, zero session states, one global kill switch, and a lazy observability
sink. Fixing them per lane provably oscillates (each lane touches the same hot
files and breaks a neighbor). The IPC vocabulary for the state machine already
exists frozen and unused; implementing it is convergence, not invention.
Fail-closed degradation (typed faults + loud `degraded`) is chosen over silent
empty/partial results everywhere because a BitTorrent client that quietly
pretends an empty library or a healthy idle transfer destroys user trust worse
than a visible fault. Session-scoped shutdown is the minimal change that makes
agent lifetime deterministic under launchd without touching the frozen plist
contract (ADR-004 budgets remain).

**Consequences:**
- The agent gains one authoritative session phase, exposed via plist-only
  additive keys in the existing `health()` reply and via
  `EngineLifecycleChangedEvent`; the XPC v1 wire contract is otherwise
  unchanged. `shutdown` may now legitimately reply `false` (refused); callers
  already treat the ack as best-effort (ADR-004: UI terminates within its 5 s
  budget regardless).
- The UI loses two behaviors by design: the demo-fixture fallback when the
  agent is reachable but degraded (fixture remains only for transport-level
  unavailability), and the view-model health rewrite. Both are replaced by
  truthful agent-owned state plus a degraded banner.
- Restore becomes loud: any future schema drift that breaks every record
  surfaces as `degraded(restoreAnomaly)` with evidence, instead of an empty
  library. Tolerant decode is now the standing rule for all persisted
  side-tables (limits, location, topology envelopes, metainfo).
- The untrusted ENGINE-002 diff is evidence only; the implementation lane
  evaluates it against this contract and keeps, rewrites or removes hunks
  accordingly. No commit/tag/branch work is part of the design packet.
- Decomposition is deliberately deferred to a second lane so the lifecycle
  fix lands as one coherent, reviewable unit on the hot files.
