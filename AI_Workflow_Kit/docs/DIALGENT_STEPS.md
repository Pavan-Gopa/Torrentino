# DialGent — Step cards

Authoritative architecture: `ARCHITECTURE.md`.
This file: **executable step cards** for `STATE.yaml`.

## Global quality (every coding step)

- **Well-commented code** per `TEAM_CONTRACT.md` § Comments.
- Verifier may **changes_requested** for missing essential comments.
- Keep project buildable every step (`npm run build` / `pytest`).

---

## F0 — Workflow bootstrap + kit setup

### Goal

AI_Workflow_Kit is live; product repo is identifiable; frontend prototype
still builds. Orchestration protocol files created. No engine logic yet.

### Requirements

1. `AI_Workflow_Kit/` present with all protocol files (STATE, TEAM_CONTRACT,
   ORCHESTRATOR, FEEDBACK, REVIEW_TEMPLATE, role prompts, checkpoint script).
2. Product root `README.md` — identity DialGent / slogan / how to build /
   link to architecture.
3. Frontend prototype builds: `cd dialgent_frontend && npm install && npm run build`.
4. `ARCHITECTURE.md` contains full spec (§1–§18).
5. `DIALGENT_STEPS.md` contains step cards for F-track.
6. `DECISIONS.md` seeded with bootstrap ADRs.
7. No engine code, no backend yet.

### target_files (Coder)

```yaml
target_files:
  - README.md
  - AI_Workflow_Kit/docs/PROJECT_CONTEXT.md
  - AI_Workflow_Kit/docs/ARCHITECTURE.md
  - AI_Workflow_Kit/docs/DIALGENT_STEPS.md
  - AI_Workflow_Kit/docs/DECISIONS.md
  - AI_Workflow_Kit/docs/AI/STATE.yaml
  - AI_Workflow_Kit/docs/AI/TEAM_CONTRACT.md
  - AI_Workflow_Kit/docs/AI/ORCHESTRATOR.md
  - AI_Workflow_Kit/docs/AI/FEEDBACK.md
  - AI_Workflow_Kit/docs/AI/REVIEW_TEMPLATE.md
  - AI_Workflow_Kit/docs/AI/IMPLEMENTATION_ENGINEER.md
  - AI_Workflow_Kit/docs/AI/VERIFICATION_ENGINEER.md
  - AI_Workflow_Kit/docs/AI/QA_ENGINEER.md
  - AI_Workflow_Kit/docs/AI/GIT_CHECKPOINTS.md
  - AI_Workflow_Kit/script/checkpoint.sh
```

### Out of scope

- Backend code (E-track)
- Pydantic schemas as Python code (F1)
- Frontend modifications (U-track)
- Model routing (M-track)

### Done

- [ ] All AI_Workflow_Kit files exist and are consistent
- [ ] `README.md` exists and is accurate
- [ ] `cd dialgent_frontend && npm run build` passes
- [ ] No engine/backend code
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-F0`

---

## F1 — Pydantic contract (schemas only)

### Goal

Create Python package `dialgent_backend/` with Pydantic v2 schemas for the
entire protocol: Event, Packet, Report, StateProjection, RoleConfig,
RolePermissions, CyclePosition, ModelHint, SkillRef, Verdict, EventType,
SupervisionMode. **No logic** — only types, validators, and JSON examples.

### Requirements

1. `dialgent_backend/` package with `pyproject.toml` (Python 3.12+, Pydantic v2).
2. `dialgent/models/events.py` — Event, EventType (all types from §4.1).
3. `dialgent/models/packets.py` — Packet, ContextSlice, Report, Verdict.
4. `dialgent/models/roles.py` — RoleId, RoleConfig, RolePermissions,
   CyclePosition, ModelHint, SkillRef.
5. `dialgent/models/state.py` — StateProjection, SupervisionMode.
6. `dialgent/models/ipc.py` — REST/WS request/response models from §13.
7. Unit tests: schema serialization round-trip (JSON → model → JSON).
8. `pytest` passes.
9. Well-commented: file headers, field docstrings, invariant notes.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/pyproject.toml
  - dialgent_backend/dialgent/__init__.py
  - dialgent_backend/dialgent/models/__init__.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/dialgent/models/packets.py
  - dialgent_backend/dialgent/models/roles.py
  - dialgent_backend/dialgent/models/state.py
  - dialgent_backend/dialgent/models/ipc.py
  - dialgent_backend/tests/test_schemas.py
  - AI_Workflow_Kit/docs/PROJECT_CONTEXT.md
```

### Out of scope

- Engine logic (E-track)
- FastAPI app (E-track)
- Frontend changes (U-track)

### Done

- [ ] All schemas match ARCHITECTURE.md §4–§6
- [ ] `pytest` green (round-trip tests)
- [ ] RoleId = str, NOT enum
- [ ] RolePermissions defaults all False
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-F1`

---

## F2 — IPC contract + FastAPI skeleton

### Goal

FastAPI app skeleton with REST + WebSocket endpoints matching §13.
All endpoints return stub/empty responses. Contract is executable:
frontend can connect and receive well-formed (but empty) data.

### Requirements

1. `dialgent/main.py` — FastAPI app with CORS, health endpoint.
2. `dialgent/api/events.py` — WS `/events` + GET `/events` (stub).
3. `dialgent/api/commands.py` — POST `/command/*` (stub, log to console).
4. `dialgent/api/config.py` — GET/PUT/POST/DELETE `/config/*` (stub).
5. `dialgent/api/files.py` — GET `/files` (stub).
6. `dialgent/api/state.py` — GET `/state` (returns empty StateProjection).
7. Tests: httpx async client hits each endpoint, asserts 200 + schema.
8. `uvicorn dialgent.main:app` starts without error.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/main.py
  - dialgent_backend/dialgent/api/__init__.py
  - dialgent_backend/dialgent/api/events.py
  - dialgent_backend/dialgent/api/commands.py
  - dialgent_backend/dialgent/api/config.py
  - dialgent_backend/dialgent/api/files.py
  - dialgent_backend/dialgent/api/state.py
  - dialgent_backend/tests/test_api_skeleton.py
  - AI_Workflow_Kit/docs/PROJECT_CONTEXT.md
```

### Done

- [ ] All §13 endpoints exist and return valid schema
- [ ] `pytest` green
- [ ] `uvicorn` starts
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-F2`

---

## F3 — Agent config loader + default templates

### Goal

Loader that reads `agents/*.md` (MD+frontmatter) into `RoleConfig` objects.
Default templates for 6 built-in roles created. File watcher stub.

### Requirements

1. `dialgent/agents/loader.py` — parse MD+frontmatter → RoleConfig.
2. `agents/orchestrator.md` — default orchestrator config.
3. `agents/architect.md`, `planner.md`, `implementer.md`, `reviewer.md`,
   `tester.md` — default role configs.
4. Validation: broken frontmatter → error, not crash.
5. Tests: load all defaults, assert fields match §6.2.
6. File watcher stub (polling, no watchdog dependency yet).

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/agents/__init__.py
  - dialgent_backend/dialgent/agents/loader.py
  - dialgent_backend/agents/orchestrator.md
  - dialgent_backend/agents/architect.md
  - dialgent_backend/agents/planner.md
  - dialgent_backend/agents/implementer.md
  - dialgent_backend/agents/reviewer.md
  - dialgent_backend/agents/tester.md
  - dialgent_backend/tests/test_agent_loader.py
  - AI_Workflow_Kit/docs/PROJECT_CONTEXT.md
```

### Done

- [ ] All 6 default configs load without error
- [ ] Broken config → validation error, not crash
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-F3`

---

## E0 — Event log (append-only JSONL)

### Goal

Append-only event store backed by JSONL file. Write event, read tail,
read page. State projection built by folding events.

### Requirements

1. `dialgent/engine/event_log.py` — append, read_tail, read_page, fold.
2. Projection builder: fold events → StateProjection.
3. Tests: append 100 events, fold, assert projection fields.
4. Concurrent safety: file lock or single-writer guarantee.

### Done

- [ ] Append + read + fold work
- [ ] Projection matches §4.2 fields
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E0`

---

## E1 — State machine (orchestrator automaton)

### Goal

Orchestrator state machine: round lifecycle, dispatch → report → verdict
→ route. Supervision modes read at boundaries. Escalation at attempts >= 3.

### Requirements

1. `dialgent/engine/state_machine.py` — OrchestratorAutomaton class.
2. Transitions: pending → dispatched → waiting_review → approved/changes_requested.
3. Verdict routing: GREEN → next, YELLOW → next + risk, RED → back.
4. Supervision mode checked at round/node boundary.
5. Escalation: attempts >= 3 → architect packet event.
6. Tests: full round lifecycle, RED routing, escalation.

### Done

- [ ] Full round lifecycle works
- [ ] All three verdict routes tested
- [ ] Escalation fires at attempts >= 3
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E1`

---

## E2 — Verdict router + bug routing

### Goal

Router that implements: GREEN → next node; YELLOW → next + risk note;
RED → return + reason. Bug routing: QA → Orchestrator → Coder → Verifier → QA.

### Done

- [ ] Router handles all verdict combinations
- [ ] Bug routing chain tested
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E2`

---

## E3 — Checkpoint manager

### Goal

Python checkpoint manager replicating checkpoint.sh semantics: pre/post tags,
idempotent, scope-guard, push-if-remote, commit convention.

### Done

- [ ] Pre/post tags created correctly
- [ ] Idempotent (existing tag → skip)
- [ ] Scope-guard (wrong root → error event)
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E3`

---

## E4 — Human interaction endpoints

### Goal

Wire `/command/*` endpoints to real state machine: start, pause, resume,
force-orchestrator, inject, mode switch. WebSocket pushes real events.

### Done

- [ ] All commands affect state machine
- [ ] WS pushes events on state change
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E4`

---

## E5 — Agent shell (Agno integration)

### Goal

Agno-based agent shell: load RoleConfig → build agent with system prompt,
skills, model hint, permissions-filtered tools. Execute packet → report.

### Done

- [ ] Agent created from RoleConfig
- [ ] Tools filtered by RolePermissions
- [ ] Packet → agent → report round-trip
- [ ] `pytest` green (with mock model)
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-E5`

---

## M0 — Model adapter (unified interface)

### Goal

Thin adapter: one interface, three backends (direct API / proxy / local).
Backend selection from ModelHint. Fallback chain.

### Done

- [ ] Adapter dispatches to correct backend
- [ ] Fallback on error
- [ ] `pytest` green (mock backends)
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-M0`

---

## M1 — Skill loader + SKILL.md parser

### Goal

Parse SKILL.md files into system prompt fragments. Bind to roles via
RoleConfig.skill_set. Stack scanner stub.

### Done

- [ ] SKILL.md parsed and injected into prompt
- [ ] skill_set binding works
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-M1`

---

## M2 — MCP client (Graphify integration)

### Goal

MCP client connecting to Graphify server. `query` tool available to agents.
Auto-rebuild on commit hook.

### Done

- [ ] MCP client connects to Graphify
- [ ] query tool returns results
- [ ] `pytest` green (mock MCP)
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-M2`

---

## M3 — Token compression + local model detection

### Goal

OS autodetect for local models (Nativ, llama.cpp, vLLM, LM Studio).
Token compression via OmniRoute or own light implementation.

### Done

- [ ] Local models detected on macOS
- [ ] Compression reduces token count
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-M3`

---

## U0 — WebSocket connection + event stream

### Goal

Frontend connects to backend WS. Replace hardcoded INITIAL_LOGS with
real event stream. Canvas reacts to real events.

### Done

- [ ] WS connection established
- [ ] Events render in RightPanel
- [ ] Canvas reflects real state
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-U0`

---

## U1 — Dynamic roles from config API

### Goal

Replace hardcoded AGENTS[5] with GET /config/roles. Canvas, Sidebar,
AgentDetailPanel render dynamic roles. CreateAgentWizard stub.

### Done

- [ ] Roles loaded from API
- [ ] Canvas renders dynamic count
- [ ] Toggles affect enabled state
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-U1`

---

## U2 — RoleConfig editor (form + raw)

### Goal

RoleEditor component: form (frontmatter fields) + raw editor (full file).
Save via PUT /config/role/{id}. Validation feedback from server.

### Done

- [ ] Form edits frontmatter fields
- [ ] Raw editor shows full file
- [ ] Save round-trips correctly
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-U2`

---

## U3 — Supervision modes + controls

### Goal

Header: AUTO/GATED/SUPERVISED switcher (replaces Default/Live/Error).
Start/Pause/Resume buttons. Force-orchestrator. Mode changes via REST.

### Done

- [ ] Mode switcher works
- [ ] Controls send commands
- [ ] State reflects mode
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-U3`

---

## U4 — Event log viewer + verdict badges

### Goal

EventLogViewer: scrollable event tape with filtering. VerdictBadge:
GREEN/YELLOW/RED indicators on Canvas nodes. Rework path from RED events.

### Done

- [ ] Event tape renders real events
- [ ] Verdict badges on nodes
- [ ] Rework path from RED events
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-U4`

---

## R0 — Replay from event log

### Goal

"View round N" — replay events of a specific round. Time-travel debugging.

### Done

- [ ] Round replay works
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-R0`

---

## R1 — Global Permission Gate

### Goal

List of dangerous tools requiring human confirmation. SUPERVISED mode
pauses on dangerous tool calls. UI confirmation dialog.

### Done

- [ ] Permission gate blocks dangerous tools
- [ ] Human confirmation flow works
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-R1`

---

## R2 — Real telemetry

### Goal

Replace fake telemetry ("1.4Ghz") with real metrics: token usage, latency,
model info, round duration. Displayed in HUD and AgentDetailPanel.

### Done

- [ ] Real metrics collected
- [ ] Displayed in UI
- [ ] No fake data
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-R2`

---

## R3 — Protocol integration tests

### Goal

End-to-end tests: full round (dispatch → agent → report → verdict → route).
Multi-round scenario with RED → retry → GREEN. Checkpoint verification.

### Done

- [ ] Full round E2E test
- [ ] RED → retry → GREEN scenario
- [ ] Checkpoints verified
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-R3`

---

## Later tracks — Phase 5+ (accepted design, not yet implemented)

> Full step cards for the tracks specified in ARCHITECTURE.md §19–§24 and governed
> by the ADRs in DECISIONS.md (CL-1..3, T-1..2, EV-1..2, V-1, P-1..2, D-1..3).
> Suggested ordering: **CL → T → P → EV → V → D**. Every card keeps the global
> quality bar above and the invariants in ARCHITECTURE.md §18.

---

## CL0 — ContextPolicy model + per-role defaults

### Goal

Add the Context Lifecycle data model so reset behaviour is declarative per role.
No runtime behaviour change yet — this is the schema foundation (ADR CL-1).

### Requirements

1. `dialgent/models/context.py` — `ContextResetMode` enum
   (`every_round | on_model_change | every_n_rounds | never`) and `ContextPolicy`
   model (`mode`, `n: int | None`, `bootstrap: list[str]`).
2. `RoleConfig` gains `context_policy: ContextPolicy | None` (frontmatter
   `context_reset:` + optional `context_reset_n:`).
3. Default policy by role class when absent: executor→`every_round`,
   architect→`on_model_change`, orchestrator→`every_n_rounds` (default `n`).
4. `EventType` gains `context_reset` and `pre_reset_ritual` (reserved; unused yet).
5. Unit tests: policy parse from frontmatter, default resolution, enum validation.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/context.py
  - dialgent_backend/dialgent/models/roles.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/tests/test_context_policy.py
```

### Out of scope

- Bootstrap builder (CL1); runtime reset logic (CL1/CL2); UI.

### Done

- [ ] `ContextPolicy`/`ContextResetMode` exist and parse from frontmatter
- [ ] Per-class defaults resolve correctly
- [ ] Reserved event types added
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-CL0`

---

## CL1 — Bootstrap slice builder + fresh-per-dispatch executors

### Goal

Executor roles become stateless across rounds: each dispatch builds a fresh agent
seeded from a bounded bootstrap slice; the instance is discarded on report
(ADR CL-1, CL-2). Architect resets on `model_changed` with a handoff summary.

### Requirements

1. `ContextSlice` gains bootstrap fields: `state_summary`, `graphify_summary`,
   `recent_verdicts` (ARCHITECTURE.md §5.1).
2. `engine/bootstrap.py` — builds bounded summaries from the fold + a **scoped**
   Graphify query over `target_files` (never a tree dump / grep). Size caps enforced.
3. `dispatch_packet` for executor roles creates a fresh agent instance per round;
   discarded on `report_received`.
4. On `model_changed` for an `on_model_change` role: build handoff summary, append
   `context_reset` event, start fresh with bootstrap.
5. Resets evaluated **only at boundaries**, never mid-turn (ADR CL-1).
6. Unit tests: two consecutive executor rounds share no conversation state;
   bootstrap fields are bounded; architect reset fires on model change.
7. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/packets.py
  - dialgent_backend/dialgent/engine/bootstrap.py
  - dialgent_backend/dialgent/engine/state_machine.py
  - dialgent_backend/dialgent/agents/shell.py
  - dialgent_backend/tests/test_context_lifecycle.py
```

### Out of scope

- Pre-reset ritual / coordinator reset (CL2); UI.

### Done

- [ ] Executor dispatch is fresh-per-round (no shared state)
- [ ] Bootstrap = bounded summaries, scoped Graphify only
- [ ] Architect resets on `model_changed` with handoff
- [ ] No reset occurs mid-turn
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-CL1`

---

## CL2 — Pre-reset ritual + coordinator `every_n_rounds` reset

### Goal

The orchestrator resets every `n` rounds, gated by a human-confirmed pre-reset
ritual (ADR CL-3). The human sees/edits the handoff before the old context drops.

### Requirements

1. When `current_round` crosses a multiple of `n` for an `every_n_rounds` role:
   append `pre_reset_ritual` (rounds covered + proposed handoff) and **pause**.
2. Confirmation chat with the human (orchestrator-only, Principle 4).
3. On `human_approve`: append `context_reset` (final handoff summary), start the
   role fresh bootstrapped from it.
4. Reset evaluated only at boundaries (after `round_finished`).
5. Unit tests: ritual pauses and requires `human_approve`; reset carries handoff;
   no reset without approval.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/state_machine.py
  - dialgent_backend/dialgent/engine/bootstrap.py
  - dialgent_backend/tests/test_pre_reset_ritual.py
```

### Out of scope

- Frontend ritual UI (separate U-step if needed); other tracks.

### Done

- [ ] Orchestrator reset pauses for the ritual
- [ ] Reset requires `human_approve`
- [ ] Handoff summary carried into fresh context
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-CL2`

---

## T0 — PTY manager (stdlib `pty` MVP) + `agent_pty_chunk` events

### Goal

A PTY manager owns one PTY per agent/command process and emits `agent_pty_chunk`
events over the existing WS (ADR T-1). Dev backend uses Python stdlib `pty`
(zero-dep). This is the backend foundation for both terminals.

### Requirements

1. `EventType` gains `agent_pty_chunk` (payload: stream id, byte chunk, seq).
2. `engine/pty_manager.py` — spawn a process under a PTY, read output, reap on exit;
   emit `agent_pty_chunk` events through the event log / WS broadcast.
3. Stream kinds: model stdout, agent command output, engine logs (§20.4).
4. `GET /agents/{id}` returns stream metadata (stream ids, display name, round).
5. Dangerous commands still pass the Permission Gate (§21) before running.
6. Unit tests: PTY output surfaces as ordered chunks; process reaped on exit
   (no orphans).
7. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/pty_manager.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/dialgent/api/agents.py
  - dialgent_backend/tests/test_pty_manager.py
```

### Out of scope

- xterm.js frontend (T1); external terminal/CLI client (T2/T3); Rust sidecar (D).

### Done

- [ ] PTY output streams as ordered `agent_pty_chunk` events
- [ ] Processes reaped on exit (no orphans)
- [ ] `GET /agents/{id}` returns stream metadata
- [ ] Dangerous commands gated
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-T0`

---

## T1 — Embedded terminal (xterm.js TerminalPanel)

### Goal

Frontend `TerminalPanel` renders PTY streams with xterm.js (WebGL renderer), one
instance per stream, disposed on close. Subscribes to `agent_pty_chunk` over WS.

### Requirements

1. Add `xterm` + WebGL addon to `dialgent_frontend`.
2. `TerminalPanel` component: tabs for model stdout / agent command output / engine
   logs; one xterm.js instance per stream; **disposed on tab close** (no leak).
3. Subscribe to `agent_pty_chunk` events for the active stream; write bytes in seq
   order.
4. Settings: `terminal.fontSize`, `terminal.scrollback`.
5. WebGL fallback path for older GPUs/VMs `[low]`.
6. `npm run build` passes.

### target_files (Coder)

```yaml
target_files:
  - dialgent_frontend/package.json
  - dialgent_frontend/src/components/TerminalPanel.tsx
  - dialgent_frontend/src/hooks/usePtyStream.ts
  - dialgent_frontend/src/types.ts
```

### Out of scope

- External terminal (T2/T3); PTY backend (T0).

### Done

- [ ] TerminalPanel renders live PTY chunks
- [ ] One xterm instance per stream, disposed on close
- [ ] Settings applied
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-T1`

---

## T2 — CLI client (`dialgent attach` / `dialgent logs`)

### Goal

A CLI client that connects over the **same WS** and renders a stream's
`agent_pty_chunk` events in the host terminal — the engine behind "Open in
terminal" (ADR T-2). It is a client of the event source, never a forwarded PTY.

### Requirements

1. `dialgent_terminal/` CLI (Rust or Python) with `attach <agent-id>` and
   `logs <id> --follow`.
2. Connects to the backend WS, subscribes to a stream, renders chunks with the host
   terminal's renderer.
3. Clean detach on disconnect / app close.
4. Byte-identical output vs the embedded panel for one stream.
5. Tests: attach renders the same bytes as the embedded view.

### target_files (Coder)

```yaml
target_files:
  - dialgent_terminal/            # CLI client crate/package
  - dialgent_backend/dialgent/api/ws.py
```

### Out of scope

- Launcher / "Open in terminal" button (T3); embedded panel (T1).

### Done

- [ ] `dialgent attach` renders live stream
- [ ] Output byte-identical to embedded panel
- [ ] Clean detach
- [ ] Tests pass
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-T2`

---

## T3 — "Open in terminal" button + cross-platform launcher

### Goal

The **Open in terminal** button launches the user's terminal running the CLI client
(T2). `TerminalLauncher` resolves the terminal (settings override, else OS
auto-detect) and builds the spawn command per OS (ADR T-2).

### Requirements

1. `TerminalLauncher` with per-OS candidate order (macOS: iTerm2/Ghostty/WezTerm/
   Kitty/Alacritty/Terminal.app; Linux: Ghostty/WezTerm/Kitty/Alacritty/GNOME/
   Konsole; Windows: wt/WezTerm/Alacritty).
2. Map `(terminal, command)` → correct "open new tab/window running command" flag.
   `[med]` exact flags verified here.
3. Settings: `terminal.choice` = `embedded | external | ask` + explicit terminal id.
4. Frontend "Open in terminal" button on a stream invokes the launcher.
5. Tests: launcher resolves a terminal and builds a valid command per OS.

### target_files (Coder)

```yaml
target_files:
  - dialgent_terminal/src/launcher.rs   # or .py
  - dialgent_frontend/src/components/TerminalPanel.tsx
  - dialgent_backend/dialgent/api/agents.py
```

### Out of scope

- Rust PTY sidecar parity (D-track); signing.

### Done

- [ ] "Open in terminal" launches configured terminal with CLI client
- [ ] Auto-detect works per OS
- [ ] Settings respected
- [ ] Tests pass
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-T3`

---

## EV0 — Seed schema + interview packet/report flow

### Goal

Define the project "seed" (goals, constraints, DNA) as an event-log artifact and
the Ouroboros-style interview that produces it (ADR EV-1). No critics yet.

### Requirements

1. `models/seed.py` — `ProjectSeed` schema (goals, constraints, invariants, dna).
2. `EventType` gains `seed_interview_started`, `seed_interview_answer`,
   `seed_generated` (§4.1 reserved).
3. Interview is a packet/report pair to the orchestrator; answers append
   `seed_interview_answer` events.
4. `seed_generated` folds into `StateProjection.seed`.
5. Unit tests: interview round-trip; seed folds into state; schema validation.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/seed.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/dialgent/models/state.py
  - dialgent_backend/tests/test_seed.py
```

### Out of scope

- Bootstrap integration (EV1); critics (EV2/EV3); UI.

### Done

- [ ] `ProjectSeed` schema exists
- [ ] Interview packet/report flow works
- [ ] Seed folds into `StateProjection.seed`
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-EV0`

---

## EV1 — Seed in bootstrap `state_summary`

### Goal

Every fresh/reset role sees the project DNA: the seed rides in the bootstrap
`state_summary` (ARCHITECTURE.md §19.4, §24.1; ADR EV-1).

### Requirements

1. `engine/bootstrap.py` includes a compact seed digest in `state_summary`.
2. Bounded size — seed digest is a summary, not the full seed blob.
3. Unit tests: fresh role bootstrap contains seed digest; size bounded.
4. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/bootstrap.py
  - dialgent_backend/tests/test_seed_bootstrap.py
```

### Out of scope

- Seed schema (EV0); critics (EV2/EV3).

### Done

- [ ] Bootstrap `state_summary` carries seed digest
- [ ] Digest is bounded
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-EV1`

---

## EV2 — Adversarial critic role (critic_before_green)

### Goal

Add a Hyperresearch-style adversarial critic as a **role** with
`cycle_position: critic_before_green`, `can_verdict: true` (ADR EV-2). It runs
before GREEN and emits patches, not regenerations.

### Requirements

1. Critic role template `agents/critic.md` (frontmatter + system prompt).
2. `CyclePosition.critic_before_green` wired into the cycle: critic runs before a
   GREEN is accepted.
3. Critic emits a verdict + **patch/change-request** (never a full regeneration).
4. A RED critic verdict routes back like any RED (§8).
5. Unit tests: critic runs before GREEN; RED routes back; output is a patch.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/agents/critic.md
  - dialgent_backend/dialgent/engine/state_machine.py
  - dialgent_backend/dialgent/engine/router.py
  - dialgent_backend/tests/test_critic.py
```

### Out of scope

- Seed (EV0/EV1); multi-critic panel (EV3); UI.

### Done

- [ ] Critic role runs before GREEN
- [ ] RED critic verdict routes back
- [ ] Critic emits patches, not regenerations
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-EV2`

---

## EV3 — Critic panel + verdict aggregation

### Goal

Support multiple critics (a panel) before GREEN, aggregating their verdicts into a
single gate decision (ARCHITECTURE.md §24.1).

### Requirements

1. Multiple `critic_before_green` roles can be enabled.
2. Aggregation rule: any RED critic → route back; all GREEN → proceed (YELLOW =
   proceed + risk note, per §8).
3. `critic_verdict` event per critic; aggregated decision recorded.
4. Unit tests: panel aggregation (RED wins); all-GREEN proceeds.
5. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/state_machine.py
  - dialgent_backend/dialgent/engine/router.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/tests/test_critic_panel.py
```

### Out of scope

- Single critic (EV2); seed; UI.

### Done

- [ ] Multiple critics run before GREEN
- [ ] Aggregation: RED wins, all-GREEN proceeds
- [ ] `critic_verdict` events recorded
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-EV3`

---

## V0 — Local STT service (whisper.cpp)

### Goal

A local speech-to-text service using whisper.cpp. Audio never leaves the process
(ADR V-1). No UI yet — just the transcription capability.

### Requirements

1. `engine/stt.py` — wraps a local whisper.cpp model; `transcribe(wav) -> (text,
   confidence)`.
2. Audio stays local; no network egress. `[high]`
3. Model size configurable (accuracy vs latency tradeoff) `[med]`.
4. Unit tests: a sample WAV transcribes to expected text; no network calls.
5. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/stt.py
  - dialgent_backend/tests/test_stt.py
```

### Out of scope

- Voice endpoint (V1); frontend mic (V2); UI.

### Done

- [ ] Local transcription works
- [ ] No network egress
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-V0`

---

## V1 — Voice command endpoint → orchestrator inject

### Goal

`POST /command/voice` accepts a WAV, transcribes locally (V0), and injects the
transcript as a `human_message`/`human_inject` to the **orchestrator only**
(ADR V-1). Optional `voice_transcript` event records confidence + audio ref.

### Requirements

1. `POST /command/voice` (WAV upload) in `api/commands.py`.
2. Transcript becomes a `human_message`/`human_inject` (orchestrator-only).
3. Optional `voice_transcript` event (confidence + audio ref for replay).
4. Voice is an input channel, never a direct agent command (Principle 4).
5. Unit tests: upload → transcript → human_message; orchestrator-only routing.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/api/commands.py
  - dialgent_backend/dialgent/models/events.py
  - dialgent_backend/tests/test_voice_command.py
```

### Out of scope

- STT service (V0); frontend mic capture (V2).

### Done

- [ ] `POST /command/voice` transcribes + injects
- [ ] Routes to orchestrator only
- [ ] `voice_transcript` event recorded
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-V1`

---

## V2 — Frontend mic capture + voice button

### Goal

Frontend mic button records audio and posts to `POST /command/voice` (V1). Handles
mic permission flow; transcript surfaces as a normal human message.

### Requirements

1. Mic capture (MediaRecorder) → WAV → `POST /command/voice`.
2. Mic permission flow (webview vs desktop shell) `[low]`.
3. Transcript appears in the chat as a human message.
4. `npm run build` passes.

### target_files (Coder)

```yaml
target_files:
  - dialgent_frontend/src/components/VoiceButton.tsx
  - dialgent_frontend/src/hooks/useMic.ts
```

### Out of scope

- STT (V0); endpoint (V1); desktop mic perms (D-track).

### Done

- [ ] Mic records + posts to voice endpoint
- [ ] Transcript shows as human message
- [ ] Permission flow handled
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-V2`

---

## P0 — Project model + ProjectRegistry skeleton

### Goal

Introduce the `Project` model and a `ProjectRegistry` that maps project id →
isolated runtime, replacing the `AppRuntime` singleton (ADR P-1). No migration yet.

### Requirements

1. `models/project.py` — `Project` (id, name, event_log_path, agents_dir, git_root).
2. `engine/registry.py` — `ProjectRegistry` keyed by project id; each entry owns its
   own `OrchestratorAutomaton` + event log path.
3. Refactor `engine/runtime.py` `AppRuntime` singleton into a registry-backed
   accessor (keep behaviour for a single default project).
4. Unit tests: registry creates/isolates runtimes per id.
5. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/project.py
  - dialgent_backend/dialgent/engine/registry.py
  - dialgent_backend/dialgent/engine/runtime.py
  - dialgent_backend/tests/test_registry.py
```

### Out of scope

- Migration (P1); project-scoped API (P2); frontend (P3).

### Done

- [ ] `ProjectRegistry` isolates runtimes per id
- [ ] Single default project still works
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-P0`

---

## P1 — Default-project migration of existing events.jsonl

### Goal

On first run under multi-project, migrate the existing `events.jsonl` into a
**default project** so single-project installs keep working with no manual
migration (ADR P-2).

### Requirements

1. Detect a legacy root `events.jsonl`; move/reference it under the default project
   (`<projects>/default/events.jsonl`).
2. Idempotent — re-running does not re-migrate or lose history.
3. Default project's `agents/` and git root resolve as before.
4. Unit tests: migration moves the log once; history preserved; idempotent.
5. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/engine/registry.py
  - dialgent_backend/dialgent/engine/event_log.py
  - dialgent_backend/tests/test_project_migration.py
```

### Out of scope

- Registry skeleton (P0); project-scoped API (P2); frontend (P3).

### Done

- [ ] Existing log migrates into default project
- [ ] Migration idempotent; history preserved
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-P1`

---

## P2 — Project-scoped API + WS `project_id`

### Goal

`/projects` CRUD; `state`/`events`/`commands`/`config`/`files` become
project-scoped; the WS carries a `project_id` so one client follows one project
(ARCHITECTURE.md §24.3; ADR P-1).

### Requirements

1. `api/projects.py` — `/projects` CRUD.
2. `state`/`events`/`commands`/`config`/`files` take a project id (path or query)
   and resolve via the registry.
3. WS messages carry `project_id`; `ConnectionManager` routes per project.
4. Checkpoints scoped to the project's git root.
5. Unit tests: two projects isolated end-to-end; WS routes by project_id.
6. `pytest` green; buildable.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/api/projects.py
  - dialgent_backend/dialgent/api/state.py
  - dialgent_backend/dialgent/api/events.py
  - dialgent_backend/dialgent/api/commands.py
  - dialgent_backend/dialgent/api/ws.py
  - dialgent_backend/tests/test_project_api.py
```

### Out of scope

- Registry (P0/P1); frontend project switcher (P3).

### Done

- [ ] `/projects` CRUD works
- [ ] Routers are project-scoped
- [ ] WS routes by `project_id`
- [ ] Two projects isolated
- [ ] `pytest` green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-P2`

---

## P3 — Frontend project switcher

### Goal

Frontend project selector/creator; the UI follows one project's WS stream at a
time (ARCHITECTURE.md §24.3).

### Requirements

1. Project switcher (list/create/select) calling `/projects`.
2. WS subscribes with the active `project_id`; canvas/HUD/panels reflect it.
3. Switching projects re-subscribes cleanly (no stale events).
4. `npm run build` passes.

### target_files (Coder)

```yaml
target_files:
  - dialgent_frontend/src/components/ProjectSwitcher.tsx
  - dialgent_frontend/src/hooks/useProject.ts
  - dialgent_frontend/src/App.tsx
```

### Out of scope

- Backend project API (P0–P2).

### Done

- [ ] Project switcher works
- [ ] WS follows active project
- [ ] Clean re-subscribe on switch
- [ ] `npm run build` passes
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-P3`

---

## D0 — Tauri shell + Rust PTY sidecar

### Goal

Scaffold the Tauri desktop app and the Rust `portable-pty` sidecar that shares PTY
code with the terminal track (ADR D-1, T-1). The sidecar speaks the same
`agent_pty_chunk` contract as the dev stdlib PTY.

### Requirements

1. Tauri project scaffold (`dialgent_desktop/`); webview loads the Vite build.
2. Rust PTY sidecar using `portable-pty`; emits the identical `agent_pty_chunk`
   contract as the dev backend.
3. Sidecar <-> backend wiring so the embedded panel can use either implementation.
4. Build: `cargo tauri build` produces a runnable app (unsigned OK).
5. Tests: Rust sidecar output matches the stdlib PTY contract.

### target_files (Coder)

```yaml
target_files:
  - dialgent_desktop/            # Tauri scaffold
  - dialgent_terminal/src/pty.rs # portable-pty sidecar
```

### Out of scope

- PyInstaller backend sidecar (D1); signing/auto-update (D-3, deferred).

### Done

- [ ] Tauri app loads the webview
- [ ] Rust PTY sidecar matches `agent_pty_chunk` contract
- [ ] `cargo tauri build` succeeds
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-D0`

---

## D1 — PyInstaller backend sidecar + `/health` gating

### Goal

Bundle the FastAPI backend as a PyInstaller sidecar, spawned on launch and gated by
`/health` before the webview connects (ADR D-2).

### Requirements

1. PyInstaller spec builds the backend into a single sidecar binary.
2. Tauri spawns the sidecar on launch; waits for `/health` before opening the UI.
3. Single-instance guard; graceful shutdown on app quit.
4. Cross-platform build (macOS/Linux/Windows) `[high]`.
5. Tests: sidecar boots, `/health` responds, clean shutdown.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent.spec   # PyInstaller spec
  - dialgent_desktop/src-tauri/      # sidecar spawn + health gate
```

### Out of scope

- Tauri shell (D0); signing/auto-update (D-3).

### Done

- [ ] Backend bundles as sidecar
- [ ] UI gated on `/health`
- [ ] Single-instance + graceful shutdown
- [ ] Cross-platform build works
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-D1`

---

## D2 — Packaged end-to-end smoke + localhost IPC unchanged

### Goal

Verify the packaged app runs the full loop over the **same localhost IPC** as dev —
no protocol change introduced by packaging (ADR D-2).

### Requirements

1. Packaged app: backend sidecar + webview connect over localhost REST/WS.
2. Full round (dispatch → agent → report → verdict) works in the packaged build.
3. Embedded terminal + voice (if present) work in the packaged build.
4. Smoke test script for the packaged app.

### target_files (Coder)

```yaml
target_files:
  - dialgent_desktop/
  - QA/                            # packaged smoke suite
```

### Out of scope

- Signing/notarization, auto-update (D-3, deferred follow-up).

### Done

- [ ] Packaged app runs a full round over localhost IPC
- [ ] No protocol change vs dev
- [ ] Terminal/voice work packaged
- [ ] Smoke suite green
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-D2`

---

> **Deferred (post-D2, ADR D-3):** macOS code-signing/notarization and auto-update —
> a later step, not part of the initial desktop milestone.

---

> **Design draft for Orchestrator — OCR track (ADR OCR-1, 2026-07-26).**
> Three steps: OCR0 (backend config + secrets), OCR1 (dispatch integration),
> OCR2 (frontend UI). Suggested order: OCR0 → OCR1 → OCR2.
> Track can start after any completed milestone; no dependency on CL/T/EV/V/P/D.

---

## OCR0 — Backend: OCR assistant config schema + secrets store

### Goal

Add `ocr_assistant` as an optional block in `RoleConfig` and implement a local
secrets store (`~/.dialgent/secrets.json`) for the OCR API key. No dispatch
changes yet — this step is data-layer only.

### Requirements

1. `RoleConfig` gains an optional `ocr_assistant: OcrAssistantConfig | None`
   field (default `None`). `OcrAssistantConfig` has:
   - `enabled: bool = False`
   - `model_hint: ModelHint` (reuses existing schema; `source`, `model`, `fallback`)
   - `info_url: str = "https://open-codereview.ai/"`
2. `agents/loader.py` parses `ocr_assistant:` from frontmatter (absent = `None`).
3. New module `dialgent/secrets.py`:
   - `get_secret(role_id: str, key: str) -> str | None`
   - `set_secret(role_id: str, key: str, value: str) -> None`
   - Storage: `~/.dialgent/secrets.json`, created with chmod 600 on first write.
   - Key format in JSON: `"<role_id>.<key>"`, e.g. `"reviewer.ocr_api_key"`.
4. `GET /config/role/{id}/ocr` returns `{ enabled, model_hint, info_url, has_key }`.
   `has_key` is `true` iff a secret exists for that role; raw key is never returned.
5. `PUT /config/role/{id}/ocr` accepts `{ enabled, model_hint, info_url, api_key? }`.
   - `api_key` is write-only: stored via `set_secret`, never echoed in response.
   - Emits `config_changed` event (payload: `role_id`, `ocr_enabled`,
     `ocr_source`, `ocr_model` — no key material).
6. Existing tests unaffected; new unit tests for secrets store + OCR config parse.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/roles.py      # OcrAssistantConfig + RoleConfig field
  - dialgent_backend/dialgent/agents/loader.py     # frontmatter parse for ocr_assistant
  - dialgent_backend/dialgent/secrets.py           # NEW: secrets store
  - dialgent_backend/dialgent/api/config.py        # GET/PUT /config/role/{id}/ocr
  - dialgent_backend/tests/test_secrets.py         # NEW
  - dialgent_backend/tests/test_ocr_config.py      # NEW
```

### Out of scope

- Dispatch integration (OCR1).
- Frontend UI (OCR2).
- Any change to verdict routing or state machine.

### Done

- [ ] `OcrAssistantConfig` in `roles.py`; `RoleConfig.ocr_assistant` optional
- [ ] `secrets.py` with get/set; chmod 600 on file creation
- [ ] `GET/PUT /config/role/{id}/ocr` live; `has_key` flag correct
- [ ] `config_changed` event emitted on PUT (no key in payload)
- [ ] `pytest` green; new tests pass
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-OCR0`

---

## OCR1 — Backend: OCR assistant dispatch integration in AgentShell

### Goal

When `reviewer.ocr_assistant.enabled: true`, `AgentShell.execute()` calls the
OCR assistant model (via `ModelAdapter`) before the main reviewer LLM call and
injects the output into the reviewer's context. When disabled, behaviour is
identical to today.

### Requirements

1. In `AgentShell.execute()`, after building the base context and before the
   main LLM call: check `role_config.ocr_assistant`.
2. If `enabled` and `secrets.get_secret(role_id, "ocr_api_key")` is not `None`:
   a. Resolve the OCR model via `ModelAdapter.resolve(ocr_assistant.model_hint)`.
   b. Build an OCR prompt: "Analyse the following diff/files for visual and
      structural issues: <diff or target_files content>".
   c. Call the OCR model; capture the text response.
   d. Prepend `## OCR Assistant Analysis\n<response>` to the reviewer context.
   e. Append an `ocr_assistant_called` note to the report metadata (not a new
      event type — rides in the existing `report_received` payload).
3. If disabled or key missing: skip silently; log a debug message.
4. OCR call failure (timeout, API error): log warning, skip OCR section,
   proceed with normal review (non-fatal).
5. No change to verdict routing, state machine, or event types.
6. `StateProjection` gains `node_phase: str | None = None` (see ARCHITECTURE §6.4).
   - Before the OCR call: set `node_phase = "ocr"` on the projection and broadcast
     `state_updated` over the existing WebSocket.
   - After the OCR call completes (success or failure): set `node_phase = None`
     and broadcast again before the main LLM call begins.
   - When OCR is disabled or key missing: `node_phase` is never set; no extra
     broadcasts.

### target_files (Coder)

```yaml
target_files:
  - dialgent_backend/dialgent/models/state.py       # node_phase field on StateProjection
  - dialgent_backend/dialgent/agents/shell.py       # OCR pre-call + node_phase broadcasts
  - dialgent_backend/tests/test_ocr_dispatch.py     # NEW
```

### Out of scope

- Frontend UI (OCR2) and canvas phase rendering (OCR3).
- New event types.
- Changes to `reviewer.md` system prompt (the OCR section is injected at runtime).

### Done

- [ ] OCR call fires only when `enabled: true` AND key present
- [ ] OCR output appears in reviewer context as `## OCR Assistant Analysis`
- [ ] OCR failure is non-fatal (review proceeds)
- [ ] Disabled path: zero extra LLM calls, identical behaviour to pre-OCR
- [ ] `node_phase = "ocr"` broadcast before OCR call; `node_phase = None` after
- [ ] `node_phase` never set when OCR disabled
- [ ] `pytest` green; new dispatch tests pass (mock model)
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-OCR1`

---

## OCR2 — Frontend: OCR Assistant section in RoleEditor (reviewer only)

### Goal

Add a collapsible "OCR Assistant" section to `RoleEditor` that appears only for
the `reviewer` role. The user can toggle the assistant, select a provider/model,
enter an API key, and see an info link. All persistence goes through the
existing `/config/role/{id}/ocr` endpoints (OCR0).

### Requirements

1. `RoleEditor` checks `config.id === 'reviewer'`; if true, renders an
   "OCR Assistant" collapsible section below the existing form fields.
2. Section contents (top to bottom):
   a. Enable/disable toggle (switch component, matches existing UI style).
   b. Provider select: `<select>` with `MODEL_SOURCES` (API / Proxy / Local /
      Mock) — same constant already used for `model_hint.source`.
   c. Model text input (free text, e.g. `qwen-vl-max`, `claude-sonnet-4-20250514`).
   d. API-key password input: type `password`; on save, sent as `api_key` in
      PUT body; on load, shows placeholder `"••••••••"` if `has_key: true`,
      empty if `has_key: false`. Never displays the raw key.
   e. Info link: `<a href={info_url} target="_blank">` with a short label
      (e.g. "What is the OCR assistant?"). `info_url` comes from the config.
3. Section is collapsed by default; toggle header shows enabled/disabled state.
4. Save button in the section calls `PUT /config/role/{id}/ocr` (not the main
   role save). Dirty state tracked independently from the main form.
5. On load: `GET /config/role/{id}/ocr` populates the section.
6. `api/client.ts`: add `fetchOcrConfig(roleId)` and `updateOcrConfig(roleId, payload)`.
7. No changes to canvas or HUD (canvas phase indication is OCR3).

### target_files (Coder)

```yaml
target_files:
  - dialgent_frontend/src/components/RoleEditor.tsx  # OCR section
  - dialgent_frontend/src/api/client.ts              # fetchOcrConfig / updateOcrConfig
  - dialgent_frontend/src/types.ts                   # OcrConfig type
```

### Out of scope

- Backend changes (OCR0/OCR1).
- Changes to any role other than reviewer.
- New pages or routes.

### Done

- [ ] OCR section visible only for `reviewer` role
- [ ] Toggle, provider select, model input, API-key field, info link all render
- [ ] Save calls `PUT /config/role/{id}/ocr`; `has_key` reflected on reload
- [ ] Raw API key never displayed in the UI
- [ ] `npm run build` passes; no TypeScript errors
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-OCR2`

---

## OCR3 — Frontend: Canvas phase indication for reviewer OCR sub-phase

### Goal

When the backend broadcasts `node_phase = "ocr"` for the reviewer node, the
Canvas renders the reviewer node with a distinct violet OCR accent color and a
small "OCR" label. When `node_phase` clears to `null`, the node reverts to its
standard amber reviewer appearance. No changes to any other node.

### Requirements

1. `types.ts`: add `node_phase?: string | null` to the `BackendState` interface
   (mirrors `StateProjection.node_phase` from OCR1).
2. `Canvas.tsx` node render block (the `roles.map(agent => ...)` section):
   - Compute `isOcrPhase = backendState?.current_node === agent.id
     && backendState?.node_phase === 'ocr'`.
   - When `isOcrPhase` is true for the reviewer node:
     a. Node ring/glow color: `#a78bfa` (violet-400) instead of the standard
        reviewer amber `#f59e0b`.
     b. Status dot class: `bg-violet-400 animate-pulse shadow-[0_0_12px_#a78bfa]
        border border-violet-300/30` (replaces the green active dot).
     c. Render a small label below the node name:
        `<span className="text-[9px] font-mono font-bold tracking-widest
        text-violet-400 uppercase">OCR</span>`.
   - When `isOcrPhase` is false: no change to existing rendering logic.
3. No changes to `RoleEditor`, HUD, Sidebar, or any other component.
4. No changes to demo/offline animation path (OCR phase only appears when
   `backendState` is present).

### target_files (Coder)

```yaml
target_files:
  - dialgent_frontend/src/types.ts                   # node_phase on BackendState
  - dialgent_frontend/src/components/Canvas.tsx      # isOcrPhase rendering
```

### Out of scope

- Backend changes (OCR0/OCR1).
- RoleEditor OCR settings section (OCR2).
- Any node other than reviewer.

### Done

- [ ] `node_phase` present on `BackendState` in `types.ts`
- [ ] Reviewer node shows violet glow + "OCR" label when `node_phase === 'ocr'`
- [ ] Reviewer node reverts to amber when `node_phase` is `null`
- [ ] All other nodes unaffected
- [ ] Demo/offline mode unaffected (no `backendState` → no OCR phase)
- [ ] `npm run build` passes; no TypeScript errors
- [ ] Verifier approved

### Rollback

Tag `dialgent/pre-OCR3`
