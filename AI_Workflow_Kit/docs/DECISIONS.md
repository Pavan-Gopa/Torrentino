# DialGent — DECISIONS (ADR log)

## 2026-07-22 — KiTiX protocol adapted for DialGent

- **Decision:** Use the battle-tested KiTiX workflow protocol (from ZerdaProject) adapted for DialGent's TypeScript+Python stack. Tracks: F/E/M/U/R instead of Z/A/V/O/U/M. Tags: `dialgent/pre-*`, `dialgent/*-done`.
- **Status:** Accepted at bootstrap.

## 2026-07-22 — Event-log as source of truth

- **Decision:** Append-only event log is the single source of truth. STATE = projection (fold). Frontend reads tail via WebSocket. No concurrent state overwrites.
- **Status:** Accepted (from chat-export.json design session).

## 2026-07-22 — Role = string id, not enum

- **Decision:** `Role` is `RoleId = str`, loaded from `agents/*.md` config files. Built-in roles are default templates. Custom agents = new files. `CyclePosition` and `RolePermissions` are data-driven.
- **Status:** Accepted (delta from chat-export.json).

## 2026-07-22 — Frontend is working base, not mockup

- **Decision:** The React prototype in `dialgent_frontend/` is a working base. Backend feeds real data via IPC contract. Do not rewrite layout — extend and connect.
- **Status:** Accepted.

## 2026-07-22 — Packet protocol: JSON envelope + Markdown body

- **Decision:** Hybrid packet format. Envelope = Pydantic model (id, from, to, round, context_slice, constraints, skill_set, model_hint). Body = free Markdown. Report = same schema + verdict (GREEN/YELLOW/RED) + evidence.
- **Status:** Accepted.

## 2026-07-22 — Well-commented code required

- **Decision:** Coder must document non-trivial code (headers, why-notes, async/ownership, API types). Verifier enforces. See TEAM_CONTRACT § Comments.
- **Status:** Accepted.

## 2026-07-23 — Nested git root at DialGent/

- **Decision:** Product git root is `DialGent/` (nested repo under AI Projects workspace). Checkpoints use tags `dialgent/pre-*` / `dialgent/*-done` only inside this root. Parent monorepo is never the checkpoint scope.
- **Context:** At F0 open, DialGent had no `.git`; `checkpoint.sh` correctly refused (scope-guard). Orchestrator ran `git init -b main` and created `dialgent/pre-F0`.
- **Status:** Accepted.

## 2026-07-23 — F0 closed; QA waived for docs-only bootstrap

- **Decision:** F0 APPROVED by Verifier. POST tag `dialgent/F0-done`. Feature-track QA (`QA/`) waived for F0 because there was no product surface — only kit docs + frontend build proof. QA suite begins when product code exists (F1+ / E-track).
- **Status:** Accepted.

## 2026-07-23 — Graphify for DialGent *development* (not product M2)

- **Decision:** Use local Graphify as a **dev-workflow** tool to save agent tokens while building DialGent: `graphify-out/`, `AI_Workflow_Kit/script/graphify_rebuild.sh`, TEAM_CONTRACT rule 15, coder/verifier prompts. This is **not** product step M2 (in-app MCP Graphify for end-user projects).
- **Status:** Accepted.

## 2026-07-23 — QA Script Engineer starts after E5

- **Decision:** Feature-track **QA Script Engineer** (`QA/` scripts, `run_all.sh`, BUG_REPORT) was waived for F0–E4 (docs/contract suite = pytest only). Starting **after E5 APPROVED + POST**, Orchestrator will **call QA** before the next coding step (M0 or otherwise). First QA task: bootstrap `QA/` + smoke suite (health, commands, state/events, pytest gate) over the live ENGINE surface.
- **Rationale:** E4 already has live HTTP/WS; E5 completes ENGINE (agent shell). Meaningful black-box smoke without UI dogfood.
- **Status:** Accepted (Human + Orchestrator).

## 2026-07-23 — QA must full-cover current app (design then run)

- **Decision:** QA Script Engineer does **not** only smoke. Process is mandatory two-phase: **(A)** generate suite + `QA/COVERAGE.md` matrix covering at least Frontend, Backend, API, Engine branches, Critical paths (and more as needed); **(B)** only then `run_all.sh`. Green requires every matrix row Pass or explicit **N/A + reason** (e.g. Frontend↔API live waits for U0). No silent gaps. Product code still off-limits for QA.
- **Status:** Accepted (Human request + Orchestrator).

## 2026-07-23 — First QA suite accepted; M0 after QA (not U0)

- **Decision:** Accept first QA Script Engineer suite (9/9 green, COVERAGE.md complete). Orchestrator re-ran `QA/run_all.sh` successfully. Next coding step is **M0** (MODEL track), not U0 — U0 comes after MODEL per DIALGENT_STEPS. PD-1 (test isolation leak) is low-severity optional hygiene for a later tiny fix step.
- **Protocol fix:** QA PASS still requires Human → Orchestrator ("QA green — зови оркестратора"). Only FAIL uses BUG_REPORT path; PASS is not "orchestrator not needed."
- **Status:** Accepted.

## 2026-07-23 — QA max-coverage (no +1-script-only turns)

- **Decision:** QA Script Engineer must **not** treat each post-step turn as “add one script and stop.” Each QA turn requires a **gap hunt** and may add **many** scripts/cases in one run to maximize bug detection (delta of the step + full regression). Goal is catch bugs, not minimize suite size. Documented in `QA_ENGINEER.md`.
- **Status:** Accepted (Human request + Orchestrator).

## 2026-07-23 — Graphify first for all dev agents (skill + MCP)

- **Decision:** Coder, Verifier, QA, Orchestrator use Graphify **before bulk file reads** to save tokens. Layers: (1) Cline MCP server `graphify` serving `graphify-out/graph.json`; (2) project skill `.agents/skills/graphify/SKILL.md` via `graphify install --project --platform agents`; (3) CLI fallback. Orchestrator appends Graphify-first footer to every short kick. Not a substitute for STATE/target_files.
- **Status:** Accepted (Human + Orchestrator).

## 2026-07-23 — agents/ disk pollution from config create tests

- **Finding:** POST /config/role and QA/create tests can leave `dialgent_backend/agents/new_agent.md` and mutate `orchestrator.md` on disk, causing subsequent `pytest` (unit gate) to fail (409 / unexpected role count).
- **Mitigation now:** Orchestrator deletes leftover files and restores agents/*.md after QA re-verify.
- **Follow-up:** Product tests must use tmp agents dir or cleanup fixtures (not block U3).
- **Status:** Noted.

---

# Phase 5+ track ADRs (accepted design — ARCHITECTURE.md §19–§24)

> These ADRs govern the not-yet-implemented tracks. Each cites the ARCHITECTURE.md
> section it realizes and the step cards in DIALGENT_STEPS.md. Tags:
> `dialgent/pre-<STEP>` / `dialgent/<STEP>-done`.

## 2026-07-24 — CL-1: Context reset only at boundaries; executors fresh-per-dispatch

- **Decision:** Context-reset decisions are evaluated **only at loop/step
  boundaries** (after `round_finished`, on `model_changed`), never mid-turn and
  never inside a role's tool execution. Executor roles (implementer, planner,
  reviewer, tester) are **stateless across rounds**: each `dispatch_packet` builds
  a brand-new agent instance, discarded on `report_received` — no `context_reset`
  event needed, freshness is the default. Long-lived specialist (architect) resets
  `on_model_change`; coordinator (orchestrator) resets `every_n_rounds`.
- **Rationale:** Resets mid-turn would corrupt an in-flight tool call and break the
  one-packet/one-report contract. Fresh-per-dispatch is the cheapest, strongest
  defence against context rot and needs no new event for the common case.
- **Implements:** ARCHITECTURE.md §19.2, §19.5, §19.7. Cards CL0–CL1.
- **Confidence:** `[high]`
- **Status:** Accepted (design).

## 2026-07-24 — CL-2: Bootstrap slice is summaries, never transcript replay

- **Decision:** A fresh/reset role is oriented via the `ContextSlice` bootstrap
  fields (`state_summary`, `graphify_summary`, `recent_verdicts`) — all **bounded
  summaries** built from the fold and a *scoped* Graphify query over `target_files`.
  We never replay the prior conversation, never dump the whole code tree, never grep
  the repo. For a reset, the bootstrap also carries the handoff summary from the
  triggering `context_reset` event.
- **Rationale:** Replaying history re-introduces the very rot we reset to escape;
  summaries keep orientation cheap and bounded (Principle 10).
- **Implements:** ARCHITECTURE.md §5.1, §19.4. Cards CL1–CL2.
- **Confidence:** `[med]` — bootstrap size caps to be fixed in CL1 review.
- **Status:** Accepted (design).

## 2026-07-24 — CL-3: Pre-reset ritual requires human approval

- **Decision:** Before an `every_n_rounds` (orchestrator) reset, the automaton
  appends a `pre_reset_ritual` event and **pauses** for a confirmation chat with the
  human. The reset proceeds only on `human_approve`, which appends a `context_reset`
  event carrying the agreed handoff summary. The human sees/edits what is carried
  forward before the old context is dropped.
- **Rationale:** Principle 4 (human ↔ orchestrator only) — dropping the
  coordinator's context is consequential and must stay under human oversight.
- **Implements:** ARCHITECTURE.md §7.5, §19.6. Card CL2.
- **Confidence:** `[high]`
- **Status:** Accepted (design).

## 2026-07-24 — T-1: PTY via stdlib `pty` (dev) / Rust `portable-pty` sidecar (prod)

- **Decision:** The PTY manager emits `agent_pty_chunk` events (stream id, byte
  chunk, seq) over the existing WS. **Dev backend** uses Python stdlib `pty`
  (zero-dep MVP); the **production Tauri build** uses a Rust `portable-pty` sidecar
  in `dialgent_terminal/`, sharing PTY code with the desktop track (D). Both speak
  the identical `agent_pty_chunk` contract, so the frontend is agnostic to which
  implementation produced the bytes.
- **Rationale:** stdlib `pty` unblocks the feature with no new dependency; the Rust
  path is required for cross-platform desktop anyway (D), so we converge on one
  contract rather than two terminal stacks.
- **Implements:** ARCHITECTURE.md §20.2, §20.3. Cards T0–T1.
- **Confidence:** `[med]` — stdlib/Rust parity to be proven in T1.
- **Status:** Accepted (design).

## 2026-07-24 — T-2: External terminal is a CLI client, not a forwarded PTY

- **Decision:** "Open in terminal" launches the user's terminal running our CLI
  client (`dialgent attach <agent-id>` / `dialgent logs <id> --follow`), which
  subscribes to the **same** `agent_pty_chunk` stream over the **same WS** as the
  frontend. We do **not** forward or fork a PTY to the external terminal.
- **Rationale:** Principle 11 (one event source, many live projections) — a client
  of the event source can never diverge from the embedded xterm.js view, and closing
  the app cleanly detaches it. Forwarding a PTY would create two sources of truth.
- **Implements:** ARCHITECTURE.md §20.5, §20.6. Cards T2–T3.
- **Confidence:** `[high]` (concept) / `[med]` (per-terminal launch flags).
- **Status:** Accepted (design).

## 2026-07-24 — EV-1: The project seed is an event-log artifact

- **Decision:** The Ouroboros interview→seed output is stored as **events**
  (`seed_interview_*`, `seed_generated`) and folds into `StateProjection.seed` —
  not a separate database or file store. The seed rides in the bootstrap
  `state_summary` so every fresh role sees the project "DNA".
- **Rationale:** Invariant I1 (state = fold of the log). A separate seed store
  would create a second source of truth and break replay/time-travel.
- **Implements:** ARCHITECTURE.md §24.1. Cards EV0–EV1.
- **Confidence:** `[med]` — seed schema stability to be fixed in EV1 review.
- **Status:** Accepted (design).

## 2026-07-24 — EV-2: Critics are roles that emit patches, not regenerations

- **Decision:** Hyperresearch-style adversarial critics are implemented as **roles**
  with `cycle_position: critic_before_green` and `can_verdict: true` — not a new
  subsystem. A critic runs before GREEN; a RED critic verdict routes back like any
  RED. Critics emit **patches / change requests**, never full artifact regenerations.
- **Rationale:** Reuses the existing cycle/routing/verdict machinery (no new
  subsystem); patch-not-regenerate keeps the critic cheap and reviewable.
- **Implements:** ARCHITECTURE.md §6.1, §8, §24.1. Cards EV2–EV3.
- **Confidence:** `[med]`
- **Status:** Accepted (design).

## 2026-07-24 — V-1: Voice is an orchestrator-only, local-STT input channel

- **Decision:** Voice input transcribes locally (whisper.cpp) and produces a
  `human_message`/`human_inject` to the **orchestrator only** — it is an input
  channel, not a new interaction surface and never a direct agent command. Audio
  stays local; an optional `voice_transcript` event records confidence + an audio
  ref for replay.
- **Rationale:** Principle 4 (human ↔ orchestrator only); privacy requires audio to
  never leave the process.
- **Implements:** ARCHITECTURE.md §11, §24.2. Cards V0–V2.
- **Confidence:** `[high]` (privacy) / `[med]` (STT accuracy/latency).
- **Status:** Accepted (design).

## 2026-07-24 — P-1: AppRuntime singleton → ProjectRegistry keyed by project id

- **Decision:** The current `AppRuntime` singleton (`engine/runtime.py`) becomes a
  **`ProjectRegistry`** mapping project id → isolated runtime (own event-log path
  `<projects>/<id>/events.jsonl`, own `OrchestratorAutomaton`, own `agents/` dir,
  own git root). `state`/`events`/`commands`/`config`/`files` become project-scoped;
  the WS carries a `project_id`.
- **Rationale:** Multi-project requires per-project isolation of the authoritative
  log and automaton; a registry is the minimal refactor that preserves all
  invariants per project.
- **Implements:** ARCHITECTURE.md §24.3. Cards P0–P2.
- **Confidence:** `[high]` (direction) — refactor is broad; see risk register #11.
- **Status:** Accepted (design).

## 2026-07-24 — P-2: Default project absorbs the existing events.jsonl

- **Decision:** On first run under multi-project, the existing `events.jsonl` is
  migrated into a **default project**, so single-project installs keep working with
  no manual migration. New projects are created explicitly via `/projects`.
- **Rationale:** Backward compatibility — existing users must not lose history or be
  forced to migrate by hand.
- **Implements:** ARCHITECTURE.md §24.3. Card P1.
- **Confidence:** `[med]` — migration mechanics verified in P1.
- **Status:** Accepted (design).

## 2026-07-24 — D-1: Tauri over Electron for desktop packaging

- **Decision:** Package DialGent as a **Tauri** app, not Electron.
- **Rationale:** Smaller native bundle and, decisively, **Rust synergy** with the
  §20 PTY manager (`portable-pty`) and `TerminalLauncher` — one Rust codebase serves
  both the terminal sidecar and the desktop shell.
- **Implements:** ARCHITECTURE.md §24.4. Card D0.
- **Confidence:** `[med]`
- **Status:** Accepted (design).

## 2026-07-24 — D-2: Python backend as a PyInstaller sidecar; same localhost IPC

- **Decision:** The FastAPI backend is bundled as a **PyInstaller sidecar**, spawned
  on launch and gated by `/health`; the webview then connects over the **same
  localhost IPC** (REST + WS) as today. No protocol change is introduced by
  packaging.
- **Rationale:** Keeps the backend identical between dev and packaged builds; the
  sidecar only manages process lifecycle (spawn, single-instance, graceful shutdown).
- **Implements:** ARCHITECTURE.md §24.4. Cards D1–D2.
- **Confidence:** `[high]` (no protocol change) / `[med]` (cross-platform bundling,
  PyInstaller GPL-2.0+exception — risk register #13, #15).
- **Status:** Accepted (design).

## 2026-07-24 — D-3: Signing/notarization and auto-update deferred

- **Decision:** macOS code-signing/notarization and auto-update are **out of scope**
  for the initial desktop milestone; ship unsigned/dev-signed first and add them as
  a later step.
- **Rationale:** They are distribution concerns that should not block a working
  desktop build; deferring keeps D0–D2 focused.
- **Implements:** ARCHITECTURE.md §24.4. (post-D2 follow-up)
- **Confidence:** `[med]`
- **Status:** Accepted (design).

## 2026-07-26 — OCR-1: Optional OCR assistant as a reviewer add-on (user-controlled, provider-selectable)

- **Decision:** Add an **optional OCR assistant** that augments the built-in
  `reviewer` role. It is a **per-role add-on** (not a new role, not a new
  subsystem): a toggle in the reviewer's settings panel, a dedicated
  `model_hint` for provider/model selection (reusing the existing `ModelHint`
  schema: `source ∈ {api, proxy, local, mock}` + `model` + `fallback`), and an
  API-key input field. When enabled, the reviewer's dispatch pipeline calls the
  OCR assistant **before** the main LLM review; the OCR output is injected into
  the reviewer's context as an additional evidence section. When disabled (the
  default), the reviewer works exactly as today — zero cost, zero latency.
- **Rationale:**
  - Users control cost: the assistant is off by default; enabling it is an
    explicit opt-in with a visible API-key field.
  - Provider freedom: `model_hint` reuse means Claude, Qwen, Ollama, or any
    proxy-routed model works without new routing code.
  - No new role / no new `CyclePosition` — the reviewer remains the single
    verdict authority; the OCR assistant is an internal enrichment step.
  - Scales with repo size: cheap single-reviewer for small projects;
    OCR-augmented (or multi-critic via EV-track) for large repos.
- **Key storage:** API key stored in a local `secrets.json`
  (`~/.dialgent/secrets.json`, chmod 600), never in `agents/*.md` or the event
  log. Backend reads it at dispatch time; frontend never receives the raw key
  (only a `has_key: bool` flag via `/config/role/{id}/ocr`).
- **UI:** In `RoleEditor` (reviewer only): an "OCR Assistant" section with
  (1) enable/disable toggle, (2) provider select (source dropdown: API / Proxy
  / Local / Mock), (3) model text input, (4) API-key password input,
  (5) info link to the OCR assistant docs. Collapsed by default.
- **Event log:** `config_changed` event when OCR settings change (payload:
  `role_id`, `ocr_enabled`, `ocr_source`, `ocr_model` — no key material).
  No new event type needed.
- **Implements:** ARCHITECTURE.md §6.2 (reviewer add-on), §10 (model routing
  reuse), §13 (new config sub-endpoint). Cards OCR0–OCR2.
- **Confidence:** `[high]` (toggle + model_hint reuse) / `[med]` (OCR quality
  depends on chosen provider/model).
- **Status:** Accepted (design).
