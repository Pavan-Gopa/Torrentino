# DialGent — Architectural Specification v2.0

> Synthesis of the chat-export.json design session + KiTiX protocol adaptation,
> consolidated with the former Research/License addendum and the Context/Terminal
> addendum into ONE self-contained spec.
> This document is the entry point for any agent joining the project.

**Version:** 2.0 (2026-07-24)
**Status:** Phases 0–4 implemented (steps F0–R3, 23 steps, GREEN). Phase 5+ tracks
are accepted design, not yet implemented.
**Supersedes:** `ARCHITECTURE_ADDENDUM.md` and `ARCHITECTURE_CONTEXT_TERMINAL_ADDENDUM.md`
— both are fully merged below and may be deleted by the orchestrator.

**Accuracy tags:** `[high]` confirmed / implemented, `[med]` direction fixed but a
detail must be verified at implementation, `[low]` open / non-critical.

**Reading convention for implementation status:**
- Text without a tag describes what **is built** (F0–R3).
- Sections §19–§24 describe **accepted design** for Phase 5+ tracks (Context
  Lifecycle, Terminal, Agent-Shell/Permission-Gate hardening, later tracks). Their
  executable step cards live in `DIALGENT_STEPS.md` (CL, T, EV, V, P, D tracks).
- Event types marked **†** in §4.1 are accepted spec pending their implementation
  track; all others are implemented.

---

## 1. Product

**DialGent** — visual multi-agent system for software development.
Core metaphor: **radial agent cycle** — task visually moves around a circle
from Orchestrator to specialized roles and back.

**Slogan:** Your Diligent Agent Loop

## 2. Principles

1. **Event-log = source of truth.** State is a projection (fold) of the log.
2. **Role isolation.** Each role sees only its packet context. Full context = Orchestrator only.
3. **Packet protocol.** JSON envelope + Markdown body. One packet in → one report + verdict out.
4. **Human ↔ Orchestrator only.** No direct agent editing. Config changes via orchestrator chat.
5. **Supervision modes switchable at runtime.** AUTO / GATED / SUPERVISED.
6. **Frontend is a working base.** Feed real data, do not rewrite layout.
7. **Role = string id, not enum.** Roles loaded from `agents/*.md`.
8. **Safety by default.** RolePermissions in schema; prompt cannot grant extra rights.
9. **Configuration = user-editable files.** MD+frontmatter in `agents/`.
10. **Context is reassembled, not accumulated.** A role's working context is rebuilt
    fresh for each unit of work; it is never the unbounded growth of a long
    conversation. Concretely (full policy in §19): **executor** roles get a clean
    context every loop; the **architect** resets on model change with a handoff
    summary; the **orchestrator** resets every N loops after a confirmation chat.
    This is the operational defence against context-rot and post-~100K-token
    degradation (over-thinking, aimless repo browsing, hallucinations).
11. **One event source, many live projections.** The embedded terminal and the
    external terminal are *equal clients of one event source* (the ledger / WS
    stream). The terminal is a live transparency layer that complements Live
    Activity and the ledger; the external terminal is an option for advanced users
    and does not replace the embedded one (§20).
12. **External services = connectors.** Third-party systems integrate as clients of
    their API/CLI/MCP; their code never enters the repo unless permissively licensed
    (§22 rule of thumb).

## 3. System topology

```
┌──────────────────────────────────────────────────────────────────┐
│                      DialGent Desktop App                          │
│                                                                  │
│  ┌───────────────┐  ┌───────────────┐  ┌──────────────────────┐  │
│  │  Frontend      │  │  Backend       │  │  Memory Layer        │  │
│  │  (React 19)    │  │  (FastAPI)     │  │                      │  │
│  │               │  │               │  │  Graphify MCP (core) │  │
│  │  Canvas       │◄─┤  Event Log    │  │  git-history + ADR   │  │
│  │  Panels       │WS│  State Mach.  │  │  QMD semantic (opt)  │  │
│  │  HUD          │  │  Router       │  │                      │  │
│  │  Config UI    │  │  Agent Shell  │  └──────────────────────┘  │
│  │  TerminalPanel│  │  (Agno)       │                            │
│  │  (xterm.js)   │  │  PTY Manager  │  ┌──────────────────────┐  │
│  └───────────────┘  │  Model Router │  │  External Terminal   │  │
│          ▲          │  API/Proxy/   │  │  (user's own: iTerm/ │  │
│          │          │  Local        │  │   Ghostty/WezTerm…)  │  │
│          │          └───────────────┘  │  runs `dialgent      │  │
│          └──────── same WS ───────────┤  attach <id>` client │  │
│                                       └──────────────────────┘  │
│  Skills = SKILL.md (agent-skills) + own stack scanner            │
│  Tools  = MCP client (Graphify etc.)                             │
└──────────────────────────────────────────────────────────────────┘
```

Topology notes:
- **Frontend** is React 19 + Vite 6 + Tailwind 4 + Motion (the working prototype in
  `dialgent_frontend/`). `TerminalPanel` (xterm.js) is added by the T-track (§20).
- **Backend** is Python 3.12 + FastAPI + uvicorn (`dialgent_backend/`). The **PTY
  manager** streams raw process output over WebSocket (§20); in the Tauri desktop
  build it is a Rust `portable-pty` sidecar, in the dev backend a stdlib PTY.
- **External terminal** is the user's own terminal application running our CLI
  client (`dialgent attach <agent-id>`); it connects over the *same* WS as the
  frontend (§20). It is a client, never a forwarded PTY.

## 4. Event-sourcing

### 4.1 Event schema

```python
class Event(BaseModel):
    id: str            # ULID
    ts: datetime       # UTC
    round: int
    type: EventType
    actor: str         # RoleId | "human" | "orchestrator"
    packet_id: str | None
    payload: dict
```

**EventType (implemented, F0–R3):**
`round_started`, `round_finished`, `packet_dispatched`, `report_received`,
`route_decision`, `verdict`, `human_message`, `human_pause`, `human_resume`,
`human_approve`, `human_inject`, `human_force_orchestrator`, `mode_changed`,
`agent_toggled`, `skill_toggled`, `model_changed`, `checkpoint_pre`,
`checkpoint_post`, `escalation`, `config_changed`, `error`.

**EventType (accepted spec, pending their track) †:**
- `agent_pty_chunk` † — raw PTY output frame from the PTY manager (§20, T-track).
- `context_reset` † — records a role context reset + the handoff/bootstrap summary
  carried into the fresh context (§19, CL-track).
- `pre_reset_ritual` † — records the orchestrator's confirmation chat before an
  `every_n_rounds` reset (§19, CL-track).

**Reserved for later tracks (not yet in the enum):** `voice_transcript` (V-track),
`seed_interview_*` / `seed_generated` (EV-track), `critic_verdict` (EV-track),
`project_created` / `project_switched` (P-track). Added by their tracks (§24).

### 4.2 Event log

- Append-only JSONL: `events.jsonl` (one file per process today; per-project path
  is introduced by the P-track, §24).
- No in-place edits. Correction = new event.
- State = `fold(events)`.

### 4.3 State projection

```python
class StateProjection(BaseModel):
    current_round: int
    current_step: str
    current_node: str
    supervision_mode: SupervisionMode
    implementation_status: str
    review_status: str
    test_status: str
    attempts: int
    paused: bool
    active_agents: dict[str, bool]
```

## 5. Packet protocol

### 5.1 Packet (Orchestrator → Role)

```python
class Packet(BaseModel):
    id: str
    round: int
    from_role: str = "orchestrator"
    to_role: RoleId
    step_id: str
    step_card_md: str
    context_slice: ContextSlice
    skill_set: list[str]
    model_hint: ModelHint
    constraints: list[str]
```

**ContextSlice** — the isolated slice a role receives (role isolation, Principle 2):

```python
class ContextSlice(BaseModel):
    state_projection: dict       # filtered cut of current state
    target_files: list[str]      # hard file scope from the step card
    plan_files: list[str]        # reference docs / plan files
    prior_feedback: str | None   # body when re-running after changes_requested
    # --- bootstrap orientation fields (accepted spec, CL-track §19) ---
    state_summary: str | None       # † compact fold digest — orientation, not history
    graphify_summary: str | None    # † scoped `graphify query` for target_files
    recent_verdicts: list[dict] | None  # † tail of recent verdict events
```

The bootstrap fields (†) let a freshly-reset role re-orient without inheriting the
old conversation (§19). They are *summaries*, never a replay of the prior context.

### 5.2 Report (Role → Orchestrator)

```python
class Report(BaseModel):
    id: str
    packet_id: str
    round: int
    from_role: RoleId
    to_role: str = "orchestrator"
    verdict: Verdict          # GREEN | YELLOW | RED
    evidence: str             # build logs, test output (Markdown)
    summary_md: str
    next_hint: str | None
```

**Verdict semantics:** GREEN → proceed; YELLOW → proceed + risk note;
RED → return to implementer/orchestrator, bump `attempts`.

## 6. Roles & permissions

### 6.1 RoleConfig (parsed from `agents/<id>.md` frontmatter)

```python
class RoleConfig(BaseModel):
    id: RoleId                      # str, NOT an enum
    display_name: str
    icon: str | None
    color: str | None
    system_prompt_md: str
    model_hint: ModelHint
    skill_set: list[str]
    constraints: list[str]
    cycle_position: CyclePosition
    permissions: RolePermissions
    enabled: bool = True
    context_policy: ContextPolicy | None   # † accepted spec, CL-track §19
```

`ContextPolicy` (†, defined in §19) declares *when* the role's working context is
reset (`every_round` | `on_model_change` | `every_n_rounds` | `never`) plus the
`n` for `every_n_rounds`. When absent, the default for the role's class applies
(executor → `every_round`, architect → `on_model_change`, orchestrator →
`every_n_rounds`).

**CyclePosition:** `on_dispatch`, `after_implementer`, `critic_before_green`,
`on_request_only`, `advisor`. (`critic_before_green` is the hook the Evolutionary
track's adversarial critics use — §24.)

### 6.2 Built-in roles (implemented, F2)

| id | cycle_position | key permissions | context_reset |
|----|----------------|-----------------|---------------|
| orchestrator | advisor | can_move_state, can_edit_configs (dispatcher: no can_verdict, no can_write_product) | every_n_rounds |
| architect | on_request_only | can_write_product (docs only) | on_model_change |
| planner | on_dispatch | can_write_product (plan files) | every_round |
| implementer | on_dispatch | can_write_product | every_round |
| reviewer | after_implementer | can_verdict | every_round |
| tester | after_implementer | can_verdict | every_round |

The `context_reset` column is the default `ContextPolicy` per role class (§19); it
is overridable per role in `agents/<id>.md`.

### 6.3 RolePermissions (safety by default — all default False)

```python
class RolePermissions(BaseModel):
    can_write_product: bool = False
    can_verdict: bool = False
    can_move_state: bool = False
    can_edit_configs: bool = False
```

Permissions are enforced in code; a system prompt cannot grant a right the schema
denies. The dangerous-tool registry that backs the Permission Gate lives in
`dialgent/models/roles.py` (`DANGEROUS_TOOLS`, `is_dangerous_tool`) — see §21.

### 6.4 Reviewer OCR assistant add-on (accepted design, OCR-track; ADR OCR-1)

The `reviewer` role supports an **optional OCR assistant** — a per-role add-on
that enriches the reviewer's context with vision-model analysis before the main
LLM review. It is **not** a new role or `CyclePosition`; the reviewer remains
the sole verdict authority.

**Configuration** (stored in `agents/reviewer.md` frontmatter, new optional block):

```yaml
ocr_assistant:
  enabled: false            # default off — zero cost unless user opts in
  model_hint:
    source: api             # api | proxy | local | mock (same as §10)
    model: qwen-vl-max      # any vision-capable model the provider offers
    fallback: []
  info_url: https://open-codereview.ai/   # link shown in UI so the user can read about it
```

**API key** is stored separately in `~/.dialgent/secrets.json` (chmod 600),
keyed by role id (`reviewer.ocr_api_key`). It is never written to `agents/*.md`,
the event log, or sent to the frontend (the frontend sees only `has_key: bool`).

**Dispatch flow** (when `ocr_assistant.enabled: true`):

1. `AgentShell.execute()` for the reviewer detects the OCR add-on config.
2. Before the main LLM call, it invokes the OCR assistant model (resolved via
   the add-on's `model_hint` through the existing `ModelAdapter`, §10) with the
   diff / target files as image or text input.
3. The OCR output is prepended to the reviewer's context as a
   `## OCR Assistant Analysis` section.
4. The main reviewer LLM call proceeds as normal, now with richer context.
5. Verdict routing is unchanged (§8) — the reviewer emits GREEN/YELLOW/RED.

**When disabled** (default): steps 1–4 are skipped entirely; the reviewer
behaves identically to the pre-OCR implementation.

**IPC:** `GET/PUT /config/role/{id}/ocr` — read/update OCR settings (no key
material in GET response; PUT accepts `api_key` write-only). Emits
`config_changed` event (payload: `role_id`, `ocr_enabled`, `ocr_source`,
`ocr_model`).

**UI (RoleEditor, reviewer only):** collapsible "OCR Assistant" section:
toggle → provider select (source dropdown) → model input → API-key password
field → info link. Collapsed by default; appears only for `reviewer` role.

**Canvas phase indication (OCR-1 addendum):**

`StateProjection` gains one optional field:

```python
node_phase: str | None = Field(
    default=None,
    description="Sub-phase label for the current node, e.g. 'ocr' when the "
                "reviewer's OCR assistant is running. Cleared to None when the "
                "main LLM call begins.",
)
```

Backend lifecycle (inside `AgentShell.execute()` for reviewer with OCR enabled):

1. Before OCR call: set `node_phase = "ocr"` → broadcast `state_updated`.
2. After OCR call completes (or fails): set `node_phase = None` → broadcast.
3. Main reviewer LLM call proceeds with `node_phase = None`.

Frontend (`Canvas.tsx` node render, reviewer node only):

- When `backendState.current_node === 'reviewer'` AND
  `backendState.node_phase === 'ocr'`:
  - Node ring/glow uses OCR accent color (`#a78bfa`, violet-400) instead of
    the standard reviewer amber (`#f59e0b`).
  - Status dot: `bg-violet-400 animate-pulse shadow-[0_0_12px_#a78bfa]`.
  - A small "OCR" label appears below the node name (same style as the
    existing status dot row, `text-[9px] font-mono tracking-widest`).
- When `node_phase` is `null` (or any other value): standard reviewer
  rendering — amber color, green active pulse, no extra label.
- No changes to any other node's rendering logic.

## 7. State machine & supervision

The `OrchestratorAutomaton` (`engine/state_machine.py`) advances the radial cycle.
Every transition appends an `Event`; it never performs LLM inference and never
bypasses the append-only log.

### 7.1 Round lifecycle

`start_round(step, target_files)` → `dispatch_packet(to_role, step_card)` →
role executes → `handle_verdict(from_role, verdict, …)` → route (§8) →
`round_finished` on GREEN at the orchestrator node.

### 7.2 Supervision modes (runtime-switchable)

`set_supervision_mode(mode)` appends a `mode_changed` event (actor `human`).
`tick()` enforces boundaries:

- **AUTO** — advance freely through the cycle.
- **GATED** — pause at round/step boundaries (when implementation is
  `paused`/`done`, or a review is `approved`); resume on human action.
- **SUPERVISED** — pause after any review outcome (`changes_requested`/`approved`)
  or once `attempts > 0`; every continuation needs an explicit human go-ahead.

### 7.3 Two distinct pause mechanisms — do not conflate

There are **two independent gates**, both surfaced to the human but triggered
differently (full detail in §21):

1. **Permission Gate (tool-level).** When a role is about to call a *dangerous
   tool* (`DANGEROUS_TOOLS`: `write_file`, `run_shell_command`, `git_commit`,
   `git_push`) under SUPERVISED, execution pauses for a `human_approve` on *that
   tool call*. Backed by Agno's `requires_approval` (§21). This is per-tool-call.
2. **Supervision pause (round/node-level).** The `tick()` boundary pauses above
   (GATED/SUPERVISED). This is our orchestrator logic, *not* Agno.

A `human_approve` event satisfies the Permission Gate; `human_resume` / explicit
dispatch satisfies a supervision pause. They are different events for a reason.

### 7.4 Context-reset mechanic (accepted spec, CL-track §19)

Reset decisions are evaluated **only at loop/step boundaries** (never mid-turn),
driven by each role's `ContextPolicy` (§6.1):

- **executor roles (`every_round`)** — a brand-new agent instance is created for
  each dispatch and discarded on report. No reset event needed; freshness is the
  default. The dispatch carries the bootstrap slice (§5.1) for orientation.
- **architect (`on_model_change`)** — on a `model_changed` event for the architect,
  emit a handoff summary, append a `context_reset` † event carrying it, and start
  the architect fresh with that summary as bootstrap.
- **orchestrator (`every_n_rounds`)** — when the loop count reaches `n`, run the
  **pre-reset ritual** (§7.5) before resetting.

### 7.5 Pre-reset ritual (accepted spec, CL-track §19)

Before an `every_n_rounds` orchestrator reset:
1. Append a `pre_reset_ritual` † event and **pause** for a confirmation chat with
   the human (Principle 4 — human ↔ orchestrator only).
2. The human confirms (or adjusts the handoff). On `human_approve`, append a
   `context_reset` † event with the agreed handoff summary and start the
   orchestrator fresh, bootstrapped from that summary.

This keeps the orchestrator's long-running coordination context from rotting while
preserving human oversight of what is carried forward.

## 8. Verdict routing & escalation

The `VerdictRouter` (`engine/router.py`) maps a report's verdict to the next node:

- **GREEN** → advance to the next node; at the orchestrator node, `round_finished`
  (`status: approved`).
- **YELLOW** → advance to the next node **plus** a risk note carried in state.
- **RED** → return to the implementer (or orchestrator); bump `attempts`.

**Escalation:** when `attempts >= 3` on a RED route, the automaton appends an
`escalation` event and dispatches an **architect** packet ("scope narrowing and
architecture review required") before further retries. This is the structural
escape hatch from a failing loop.

## 9. Skills

Skills follow the **agent-skills** format: each is a `SKILL.md` in `skills/`,
referenced by id from a role's `skill_set`. A `SkillRef` carries `id`, `name`,
`description`, `enabled`. Skills are resolved at runtime by the skills loader and
can be toggled per role (`skill_toggled` event). A stack scanner proposes skills
relevant to the detected project stack.

## 10. Model routing

`ModelHint` routes a role to a backend: `source ∈ {api, proxy, local, mock}` with a
`model` id and an ordered `fallback` chain.

- **api** — direct provider API.
- **proxy** — OmniRoute-style aggregator `[med]` (idea adopted; not a code
  dependency — §22).
- **local** — Ollama / LM Studio.
- **mock** — deterministic stub for tests.

A `model_changed` event records a runtime model switch; for the architect this is
also the trigger for an `on_model_change` context reset (§7.4).

## 11. Human ↔ Orchestrator

The human interacts **only** with the orchestrator (Principle 4). Channels:

- **Chat** — `human_message`; orchestrator triages and dispatches.
- **Control** — `human_pause` / `human_resume`, `human_approve` (Permission Gate,
  §7.3), `human_inject` (inject context/instruction into the active round),
  `human_force_orchestrator` (pull control back to the orchestrator node).
- **Pre-reset ritual chat** † — the confirmation dialog before an orchestrator
  `every_n_rounds` reset (§7.5).
- **Voice input** (later track, §24 V) — an *input channel* that transcribes to a
  `human_message`/`human_inject`; it does not create a new interaction surface.

All human actions are events; the orchestrator is the only role that reads the
full log and decides routing.

## 12. Frontend

React 19 + Vite 6 + Tailwind 4 + Motion (`dialgent_frontend/`). The prototype is
the working base (Principle 6) — we feed it real data over WS/REST, not rewrite it.

Key surfaces:
- **Canvas** — the radial agent cycle; nodes = roles, animated token = the active
  packet moving around the ring.
- **Panels** — per-role detail (current packet, report, verdict).
- **HUD** — round/step/attempts/supervision-mode/attempts, live activity feed.
- **Config UI** — edit `agents/*.md`, toggle agents/skills, switch model + mode.
- **TerminalPanel** † (T-track, §20) — embedded xterm.js (WebGL renderer) with tabs
  for model stdout, agent command output, and engine logs; one instance per stream,
  disposed on close. An **"Open in terminal"** button hands a stream to the user's
  external terminal via the CLI client (§20).

The frontend is a pure projection of the event stream: it renders WS events and
issues commands; it holds no authoritative state.

## 13. IPC & API

Transport: **REST** for commands/queries + **WebSocket** for the live event stream.
The same WS contract serves the frontend, the embedded terminal, and the external
terminal's CLI client (Principle 11).

**REST routers (implemented, `dialgent/api/`):** `events`, `commands`, `config`,
`files`, `state`, plus `/health`.

- `events` — append/query events; WS broadcasts every appended event.
- `commands` — human actions (pause/resume/approve/inject/force/mode).
- `config` — read/write role configs, toggles, model hints.
- `files` — scoped file access for role work (target_files enforced).
- `state` — current `StateProjection` (fold).

**WS envelope:** `{"type": "event", "event": <event_json>}` pushed to all
subscribers (`ConnectionManager.broadcast_event`).

**Accepted-spec additions (pending their tracks):**
- `GET /agents/{id}` † — agent/role runtime metadata for the terminal "Open in
  terminal" flow (T-track, §20).
- **PTY chunk channel** † — `agent_pty_chunk` events streamed over the same WS so
  embedded and external terminals render identical bytes (T-track, §20).
- `POST /command/voice` † — voice upload → transcript → inject (V-track, §24).
- `/projects` CRUD + project-scoped state/events/commands + WS `project_id` †
  (P-track, §24).

**CLI client** † (T-track): `dialgent attach <agent-id>` and
`dialgent logs <id> --follow` connect over the same WS and render PTY chunks in the
user's own terminal. The external terminal is a *client*, never a forwarded PTY.

## 14. Memory & code-map layer

DialGent's memory is layered, cheapest-first:

1. **Event log** (§4) — the authoritative memory; state = fold(log).
2. **Graphify code-map (core)** — the `graphify` MCP / CLI
   (`graphify query|explain|path --graph graphify-out/graph.json`) is the primary
   code-orientation tool. Roles orient via *scoped* Graphify queries, never by
   dumping the whole tree or grepping the repo (Principle 10; bootstrap slice §5.1).
3. **git history + ADRs** — `DECISIONS.md` (ADRs) and VCS history are durable,
   human-readable memory that survives any context reset.
4. **QMD semantic layer (optional)** `[med]` — a connector/idea adopted from QMD:
   an optional semantic-memory index over docs/notes. It is a *connector* we may
   query, not code we vendor (§22 rule of thumb). Graphify remains the core
   code-map; QMD, if adopted, augments doc/idea recall only.

## 15. Phases & roadmap

### Phase 0–4 — DONE (implemented, F0–R3, 23 steps, all GREEN)

| Phase | Tracks | Status |
|-------|--------|--------|
| 0 — Foundations | F0–F3: event schema/log/fold, packet/report models, role configs, state projection | ✅ DONE |
| 1 — Engine | E0–E5: event log store, state machine, verdict router, checkpoint, runtime, agent shell (Agno) | ✅ DONE |
| 2 — API | A0–A4: events, commands, config, files, state routers + WS broadcast | ✅ DONE |
| 3 — Frontend wiring | U0–U4: canvas, panels, HUD, config UI, WS live feed | ✅ DONE |
| 4 — Safety & supervision | R0–R3: RolePermissions, Permission Gate registry (DANGEROUS_TOOLS), supervision modes, escalation | ✅ DONE |

This is **fact**, not plan: the backend (`dialgent_backend/`) and frontend
(`dialgent_frontend/`) implement the above; `STATE.yaml` records F0–R3 complete.

### Phase 5+ — later tracks (accepted design, not yet implemented)

Each track has full step cards in `DIALGENT_STEPS.md` and ADRs in `DECISIONS.md`:

- **CL — Context Lifecycle** (CL0–CL2): implements §19. Backend-only; unblocks
  context-rot protection. *Recommended first* (small, high-value).
- **T — Embedded & External Terminal** (T0–T3): implements §20. PTY manager +
  xterm.js + "Open in terminal" CLI client. Shares the Rust PTY work with D.
- **EV — Evolutionary layer** (EV0–EV3): Ouroboros interview→seed + Hyperresearch
  adversarial critics (reuses `critic_before_green`).
- **V — Voice input** (V0–V2): mic → local STT → orchestrator inject.
- **P — Multi-project** (P0–P3): `AppRuntime` singleton → `ProjectRegistry`;
  project-scoped event log/IPC/WS.
- **D — Desktop packaging** (D0–D2): Tauri shell + PyInstaller backend sidecar.

Suggested ordering: **CL → T → P → EV → V → D** (CL and T are foundational and
low-risk; P is a refactor that should land before features that assume one
project; D last, reusing T's Rust PTY).

## 16. Directory layout

```
DialGent/
├── dialgent_backend/
│   ├── dialgent/
│   │   ├── models/        # events, packets, roles, state, ipc (data contracts)
│   │   ├── engine/        # event_log, state_machine, router, checkpoint, runtime
│   │   ├── agents/        # shell.py (Agno wrapper), loader
│   │   └── api/           # events, commands, config, files, state routers
│   └── agents/*.md        # role configs (frontmatter + system prompt)
├── dialgent_frontend/
│   └── src/               # App.tsx, types.ts, components/ (React 19)
├── dialgent_terminal/     # † T/D-track: Rust PTY manager (portable-pty) + CLI
│                          #   client (`dialgent attach`); Tauri shell lives here too
├── skills/                # SKILL.md files (agent-skills format)
├── graphify-out/          # graphify code-map (graph.json)
└── AI_Workflow_Kit/docs/  # ARCHITECTURE.md, DECISIONS.md, DIALGENT_STEPS.md,
                           # PROJECT_CONTEXT.md, AI/STATE.yaml
```

(† = created by its track.)

## 17. Onboarding a new agent

1. Read this file top-to-bottom — it is self-contained as of v2.0.
2. Read `PROJECT_CONTEXT.md` for product framing and `AI/STATE.yaml` for what is
   already done (F0–R3).
3. Read `DECISIONS.md` for the ADRs that constrain your work.
4. Pick up your step card in `DIALGENT_STEPS.md`; respect its `target_files` and
   `Rollback` tag.
5. Orient with **Graphify** (`graphify query|explain|path`), not by dumping the
   tree or grepping the repo.

> Note: the former `ARCHITECTURE_ADDENDUM.md` and
> `ARCHITECTURE_CONTEXT_TERMINAL_ADDENDUM.md` are fully merged into §14, §19–§24
> and the amended §2/§5/§6/§7/§11/§12/§13. They are obsolete and may be deleted.

## 18. Invariants & memory stakes

Non-negotiable invariants (a violation is a RED):

- **I1** Event log is append-only; state is always a fold of the log.
- **I2** RolePermissions default False; prompts cannot grant rights.
- **I3** Roles are string ids loaded from `agents/*.md`, never a hardcoded enum.
- **I4** Human ↔ orchestrator only; no direct agent editing by the human.
- **I5** One packet in → one report + verdict out.
- **I6** `target_files` is a hard scope; writes outside it are forbidden.

**Memory stakes** (what must survive a context reset / a new agent joining):

- The **event log** and its fold — authoritative state.
- **Graphify** code-map — orientation without re-reading the repo.
- **DECISIONS.md / ADRs** — durable rationale.
- **Context Lifecycle policy (§19)** — the rule that context is reassembled, not
  accumulated; the stake is *avoiding context-rot*, the failure mode this whole
  layer exists to prevent.
- **Terminal transparency (§20)** — the stake is *one event source, many live
  projections*; embedded and external terminals must never diverge.
- **Permission Gate / Agno split (§21)** — the stake is *dangerous tools always
  require human approval under SUPERVISED*, independent of round-level pauses.
- **License rule of thumb (§22)** — the stake is *keeping the repo clean*: ideas
  and connectors yes, copyleft/AGPL code no.

---

# Part III — Accepted design: Phase 5+ tracks (§19–§24)

> Sections §19–§24 are **accepted architecture**, not yet implemented. Each maps to
> executable step cards in `DIALGENT_STEPS.md` and ADRs in `DECISIONS.md`. Items
> marked † introduce new event types / fields listed in §4.1 and §5.1.

## 19. Context Lifecycle Policy

### 19.1 Problem

Long-lived agent conversations degrade. Past roughly **100K tokens** models
over-think, browse the repo aimlessly, re-derive settled decisions, and
hallucinate — "context rot". DialGent runs many loops, so an orchestrator or
architect that accumulates every round's transcript will rot. The fix is
structural, not prompt-based: **reassemble context per unit of work; never let it
grow unbounded** (Principle 10).

### 19.2 Policy by role type

| Role class | Examples | Reset trigger | What is carried forward |
|------------|----------|---------------|--------------------------|
| **Executor** | implementer, planner, reviewer, tester | `every_round` — fresh instance per dispatch, discarded on report | Bootstrap slice only (§19.4) |
| **Long-lived specialist** | architect | `on_model_change` — reset when its model changes | Handoff summary → bootstrap |
| **Coordinator** | orchestrator | `every_n_rounds` (default `n` configurable) | Pre-reset ritual handoff (§19.5) |
| **Advisor / on-request** | (custom) | `never` (opt-in) | n/a |

The default per class is applied when a role's `context_policy` is absent (§6.1);
each role may override it in `agents/<id>.md`.

### 19.3 Models

```python
class ContextResetMode(str, Enum):
    every_round = "every_round"          # executors
    on_model_change = "on_model_change"  # architect
    every_n_rounds = "every_n_rounds"    # orchestrator
    never = "never"                       # opt-out

class ContextPolicy(BaseModel):
    mode: ContextResetMode
    n: int | None = None          # required when mode == every_n_rounds
    bootstrap: list[str] = [      # which bootstrap fields to build (§19.4)
        "state_summary", "graphify_summary", "recent_verdicts",
    ]
```

`ContextPolicy` is added to `RoleConfig` (§6.1). `context_reset` † and
`pre_reset_ritual` † are added to `EventType` (§4.1).

### 19.4 Bootstrap slice (orientation, not history)

When a role starts fresh it receives the normal `ContextSlice` (§5.1) **plus** the
bootstrap fields named in its policy. They are built cheaply from the fold and the
code-map — never by replaying the old conversation:

- **`state_summary`** — a compact digest of the `StateProjection`: current step,
  current node, attempts, open risk notes, last verdict per role. A few lines.
- **`graphify_summary`** — the result of a *scoped* `graphify query`/`explain` over
  the step's `target_files` (Principle 10). Never a whole-tree dump, never grep.
- **`recent_verdicts`** — the tail of recent `verdict` events (role, verdict,
  one-line evidence) so the role knows what already passed/failed.

For a reset (not a first dispatch), the bootstrap also carries the **handoff
summary** recorded in the triggering `context_reset` † event.

### 19.5 Fresh-context-at-dispatch (executors)

Executor roles are **stateless across rounds**: each `dispatch_packet` creates a
brand-new agent instance seeded only from the packet (step card + context slice +
bootstrap). On `report_received` the instance is discarded. No `context_reset`
event is needed — freshness *is* the default. This is the cheapest and strongest
defence against rot and applies to implementer/planner/reviewer/tester.

### 19.6 Pre-reset ritual (coordinator)

For `every_n_rounds` roles (orchestrator), when `current_round` crosses a multiple
of `n`:
1. Append `pre_reset_ritual` † (payload: rounds covered, proposed handoff summary)
   and **pause** — open a confirmation chat with the human (Principle 4).
2. Human confirms or edits the handoff. On `human_approve`, append `context_reset` †
   (payload: final handoff summary) and start the role fresh, bootstrapped from it.

The ritual guarantees a human sees what is being carried forward before the old
context is dropped.

### 19.7 Plug-in points (state machine)

Resets are evaluated **only at boundaries** in `OrchestratorAutomaton` (§7.4/§7.5):
- after `round_finished` (executor freshness is implicit; coordinator `n` check);
- on `model_changed` for an `on_model_change` role (architect);
- never mid-turn and never inside a role's tool execution.

### 19.8 Verify

- [ ] Executor dispatch builds a fresh instance; two consecutive rounds share no
      conversation state.
- [ ] Bootstrap fields are summaries (bounded size), not transcript replays.
- [ ] `graphify_summary` comes from a scoped query, never a tree dump/grep.
- [ ] Architect reset fires on `model_changed` and carries a handoff summary.
- [ ] Orchestrator reset pauses for the pre-reset ritual and requires `human_approve`.
- [ ] No reset occurs mid-turn.

## 20. Embedded & External Terminal

### 20.1 Why a web terminal (not a native GPU terminal app)

DialGent is a webview app (§24 D). Embedding a full native GPU terminal (Alacritty/
Kitty internals) inside a webview is the wrong fight. The right call: render
terminal output with **xterm.js** (a mature, GPU-accelerated *canvas* terminal
emulator that runs in the webview), fed by a real **PTY** on the backend. For
advanced users who prefer their own terminal, we offer an **external terminal**
option that is a *client of the same event source* — not a forked PTY (Principle 11).

### 20.2 Architecture

```
 agent process / model stdout / engine logs
        │ (raw bytes)
        ▼
 ┌──────────────────────┐   spawn/reap, read PTY
 │  PTY Manager          │──────────────────────┐
 │  (Rust portable-pty   │                      │
 │   sidecar in Tauri;   │                      ▼
 │   stdlib pty in dev)  │            agent_pty_chunk events
 └──────────────────────┘                      │
        ▲                                      ▼
        │ same WS contract              EventLogStore + WS broadcast
        │                                      │
 ┌──────────────────────┐         ┌────────────┴─────────────┐
 │ External terminal     │         │ Frontend TerminalPanel    │
 │ (`dialgent attach`)   │◄────────┤ (xterm.js, WebGL)         │
 └──────────────────────┘  same    └───────────────────────────┘
                            bytes
```

Both terminals subscribe to the **same** `agent_pty_chunk` † stream over the same
WS, so embedded and external always render identical bytes.

### 20.3 PTY manager

- Owns one PTY per agent/command process; reads output, reaps on exit.
- Emits `agent_pty_chunk` † events (payload: stream id, byte chunk, seq) which the
  WS broadcasts like any event.
- **Implementation path (ADR T-1):** dev backend uses Python stdlib `pty`
  (zero-dep MVP); the production Tauri build uses a **Rust `portable-pty` sidecar**
  (`dialgent_terminal/`), sharing its PTY code with the desktop track (§24 D).
  Both speak the identical `agent_pty_chunk` contract, so the frontend is agnostic.

### 20.4 Streams & tabs

Three logical stream kinds, one xterm.js instance each, disposed on close (no leak):
- **model stdout** — the role's raw model/tool output for the active round;
- **agent command output** — a specific agent's shell commands (gated by the
  Permission Gate, §21, when dangerous);
- **engine logs** — backend/automaton logs for debugging.

### 20.5 "Open in terminal" → external terminal

The **Open in terminal** button on a stream does **not** forward a PTY (ADR T-2).
Instead it launches the user's chosen terminal running our CLI client:

```
dialgent attach <agent-id>        # live PTY chunks for that agent
dialgent logs <agent-id> --follow # engine/log stream, follow mode
```

The CLI client connects over the **same WS** as the frontend, subscribes to the
stream's `agent_pty_chunk` † events, and renders them with the host terminal's own
renderer. Because it is a client of the event source, the external view can never
diverge from the embedded one, and closing the app cleanly detaches it.

`GET /agents/{id}` † returns the metadata the launcher needs (stream ids, display
name, current round).

### 20.6 Cross-platform launcher

`TerminalLauncher` resolves the user's terminal (settings override, else OS
auto-detect) and builds the spawn command:

| OS | Candidates (auto-detect order) |
|----|--------------------------------|
| macOS | iTerm2 (AppleScript), Ghostty, WezTerm, Kitty, Alacritty, Terminal.app |
| Linux | Ghostty, WezTerm, Kitty, Alacritty, GNOME Terminal, Konsole |
| Windows | Windows Terminal (`wt`), WezTerm, Alacritty |

Each has its own "open new tab/window running command" flag; the launcher maps a
`(terminal, command)` to the right invocation. `[med]` exact flags verified in T3.

### 20.7 Settings

- `terminal.choice` — `embedded` | `external` | `ask`; plus an explicit terminal id.
- `terminal.fontSize`, `terminal.scrollback` — xterm.js options for the embedded panel.

### 20.8 Verify

- [ ] Embedded and external terminals show byte-identical output for one stream.
- [ ] PTY processes are reaped on agent exit (no orphans).
- [ ] Each xterm.js instance is disposed on tab close (no DOM/memory leak).
- [ ] "Open in terminal" launches the configured terminal with the CLI client.
- [ ] Closing the app detaches external clients cleanly.
- [ ] Dangerous commands shown in a terminal still pass the Permission Gate (§21).

## 21. Agent Shell & Permission Gate (Agno)

### 21.1 Agent shell

Roles execute inside an **Agno** agent wrapper (`dialgent/agents/shell.py`,
`agno>=2.8.0`). The shell turns a `Packet` into an Agno run (system prompt from
`RoleConfig.system_prompt_md`, tools from the role's skills/permissions) and turns
the result into a `Report`. MCP tools (e.g. Graphify) attach via `mcp>=1.0.0`.

Set **`AGNO_TELEMETRY=false`** in the runtime environment — no third-party
telemetry leaves the process. `[high]`

### 21.2 Permission Gate (tool-level approval)

Agno's `requires_approval` flag is wired to our Permission Gate: when a role is
about to call a **dangerous tool** and the supervision mode is **SUPERVISED**, the
tool call pauses until a human `human_approve` event lands (§7.3).

The canonical dangerous-tool registry lives in **`dialgent/models/roles.py`**
(*not* in a role's markdown):

```python
DANGEROUS_TOOLS = ["write_file", "run_shell_command", "git_commit", "git_push"]
is_dangerous_tool(name)  # normalizes "_write_file_tool" -> "write_file"
```

`canonical_tool_name` strips the `_*_tool` wrapper naming so the policy list is
stable regardless of shell.py's function names. Any future dedicated git tool is
auto-gated by canonical name.

### 21.3 Permission Gate vs supervision pauses — the split

Two mechanisms, deliberately separate (§7.3):

| | Permission Gate | Supervision pause |
|---|---|---|
| Granularity | per **tool call** | per **round / node boundary** |
| Trigger | dangerous tool under SUPERVISED | GATED/SUPERVISED boundary in `tick()` |
| Backed by | Agno `requires_approval` | our `OrchestratorAutomaton` |
| Released by | `human_approve` | `human_resume` / explicit dispatch |

Agno only supplies the tool-level hook; the round/node gating is entirely ours. Do
not implement supervision pauses inside Agno.

### 21.4 Verify (Agno API names)

`[med]` The exact Agno symbols (`requires_approval`, tool-registration API, MCP
mount API, telemetry env var) must be confirmed against the pinned `agno` version
during E-track hardening; the *behaviour* above is fixed regardless of naming.

## 22. Dependencies & Licensing

> This consolidated table **supersedes** any earlier partial license tables (incl.
> the one in `PROJECT_CONTEXT.md`; that file is not owned by the architect and is
> only flagged here, not edited).

### 22.1 Rule of thumb

- **Permissive** (MIT / BSD / Apache-2.0) → OK as a real dependency.
- **Weak copyleft** (MPL-2.0) → OK as a dependency; keep our code in separate files
  (we do not modify the lib's own files).
- **Strong copyleft / AGPL** → **ideas and connectors only**. We adopt the concept
  and integrate over API/CLI/MCP; we **never vendor or copy the code** into the
  repo. (This is the repowise/AGPL rule.)

### 22.2 Runtime & build dependencies

| Dependency | Use | License | Status | Confidence |
|------------|-----|---------|--------|------------|
| FastAPI | backend HTTP/WS | BSD-3-Clause | used | `[high]` |
| uvicorn | ASGI server | BSD-3-Clause | used | `[high]` |
| pydantic | data contracts | MIT | used | `[high]` |
| PyYAML | frontmatter/config | MIT | used | `[high]` |
| websockets | WS transport | BSD-3-Clause | used | `[high]` |
| Agno | agent shell | MPL-2.0 | used | `[med]` verify exact |
| mcp (python) | MCP tools (Graphify) | MIT | used | `[high]` |
| React | frontend UI | MIT | used | `[high]` |
| Vite | frontend build | MIT | used | `[high]` |
| Tailwind CSS | styling | MIT | used | `[high]` |
| xterm.js | embedded terminal | MIT | T-track | `[high]` |
| portable-pty (Rust) | PTY manager sidecar | MIT | T/D-track | `[high]` |
| Tauri | desktop shell | MIT / Apache-2.0 | D-track | `[high]` |
| PyInstaller | bundle Python backend | GPL-2.0 + bootloader exception | D-track | `[med]` flag |
| whisper.cpp | local STT | MIT | V-track | `[high]` |

### 22.3 Research sources — ideas & connectors only (no code)

| Source | What we take | License | Handling | Confidence |
|--------|--------------|---------|----------|------------|
| repowise | repo-understanding ideas | **AGPL-3.0** | **ideas only — never copy code** | `[high]` |
| OmniRoute | model-proxy routing concept | n/a (hallmark/reference) | idea only; `ModelHint.source=proxy` | `[med]` |
| QMD | semantic-memory layer | n/a | optional connector/idea (§14) | `[med]` |
| Ouroboros | interview→seed pattern | MIT | pattern adopted, own code (EV) | `[high]` |
| Hyperresearch | adversarial-critic pattern | MIT | pattern adopted, own code (EV) | `[high]` |

Even where the license is permissive (Ouroboros/Hyperresearch), we re-implement the
pattern in our own code to keep the event-sourced/packet contracts native.

## 23. Risks & open questions

Consolidated "verify during implementation" register. Tags: `[high]` confirmed,
`[med]` direction fixed / detail to verify, `[low]` open / non-critical.

| # | Item | Track | Tag |
|---|------|-------|-----|
| 1 | Agno API symbol names (`requires_approval`, tool/MCP mount, telemetry env) vs pinned version | E/§21 | `[med]` |
| 2 | Agno exact license text (assumed MPL-2.0) | §22 | `[med]` |
| 3 | Bootstrap `graphify_summary` must stay scoped/bounded under large repos | CL/§19 | `[med]` |
| 4 | Pre-reset ritual UX: how the handoff summary is edited by the human | CL/§19 | `[low]` |
| 5 | PTY language path: stdlib `pty` MVP vs Rust `portable-pty` sidecar parity | T/§20 | `[med]` |
| 6 | External-terminal launch flags per app/OS (iTerm2 AppleScript, wt, etc.) | T/§20 | `[med]` |
| 7 | xterm.js WebGL renderer fallback on older GPUs / VMs | T/§20 | `[low]` |
| 8 | Local STT accuracy/latency (whisper.cpp model size vs realtime) | V/§24 | `[med]` |
| 9 | Voice privacy: audio must stay local; retention policy for replay | V/§24 | `[high]` |
| 10 | Mic permission flow in webview vs desktop shell | V/D | `[low]` |
| 11 | `AppRuntime` singleton → `ProjectRegistry` refactor touches lifespan + every handler | P/§24 | `[high]` |
| 12 | WS multiplexing by `project_id`; migration of existing `events.jsonl` → default project | P/§24 | `[med]` |
| 13 | Cross-platform Python bundling (PyInstaller sidecar) + startup `/health` gating | D/§24 | `[high]` |
| 14 | macOS code-signing / notarization; auto-update | D/§24 | `[med]` |
| 15 | PyInstaller GPL-2.0+exception compatibility with our distribution | D/§22 | `[med]` |
| 16 | Critic "patch-not-regenerate" contract: critics emit patches, not full redos | EV/§24 | `[med]` |
| 17 | Seed schema stability: how much of the seed is frozen vs evolvable | EV/§24 | `[low]` |

Open architectural questions (to resolve in the relevant track's first ADR review):
- Should `context_reset`/`pre_reset_ritual` payloads be size-capped in the schema,
  or only by builder convention? (CL)
- Does the PTY stream belong in the main event log (durable, replayable) or a
  sidecar ring buffer (cheap, ephemeral)? Current spec: events, capped. (T)

## 24. Later tracks — architecture summaries

Four product tracks (plus CL/T above, which implement §19/§20). Each preserves the
core invariants (§18): everything is an event, roles are string ids, human ↔
orchestrator only, supervision modes apply. Full step cards: `DIALGENT_STEPS.md`;
ADRs: `DECISIONS.md`.

### 24.1 EV — Evolutionary layer (cards EV0–EV3; ADRs EV-1, EV-2)

**Goal.** Let a project improve itself over time: (a) **Ouroboros interview→seed**
extracts a durable project *seed* (goals, constraints, "DNA") via a structured
interview; (b) **Hyperresearch adversarial critics** stress a plan/implementation
before it goes GREEN.

**Boundaries.** The seed is an *artifact in the event log*, not a separate store
(ADR EV-1). Critics are *roles*, not a new subsystem — they reuse the existing
`CyclePosition.critic_before_green` (§6.1). Critics emit **patches, not full
regenerations** (ADR EV-2).

**Integration.**
- *Event log:* new types `seed_interview_*`, `seed_generated`, `critic_verdict`
  (§4.1 reserved). Seed folds into `StateProjection.seed`.
- *Packet protocol:* interview is a packet/report pair; the seed rides in the
  bootstrap `state_summary` (§19.4) so every fresh role sees the project DNA.
- *Roles:* critic role templates with `cycle_position: critic_before_green`,
  `can_verdict: true`.
- *Routing:* a critic runs before GREEN; a RED critic verdict routes back like any
  RED (§8).
- *Supervision:* unchanged; critic verdicts surface in GATED/SUPERVISED like others.

**Risks/deps/license.** Patch-not-regenerate contract `[med]`; seed schema
stability `[low]`. Ouroboros MIT, Hyperresearch MIT — patterns re-implemented in
our own code (§22). Depends on: nothing (can start after CL).

### 24.2 V — Voice input (cards V0–V2; ADR V-1)

**Goal.** Speak to the orchestrator instead of typing.

**Boundaries.** Voice is an **input channel to the orchestrator only** (Principle
4) — it produces a `human_message`/`human_inject`, never a new interaction surface
or a direct agent command. Transcription is **local** (whisper.cpp); audio does not
leave the process (ADR V-1).

**Integration.**
- *IPC:* `POST /command/voice` (WAV upload) → transcript (§13).
- *Event log:* optional `voice_transcript` event (confidence + audio ref for
  replay); the transcript itself becomes a `human_message`/`human_inject`.
- *Roles:* none new. *Supervision:* a voice transcript is a human message, gated
  exactly like a typed one.

**Risks/deps/license.** STT accuracy/latency `[med]`; **privacy — must stay local**
`[high]`; mic perms `[low]`. whisper.cpp MIT. Depends on: nothing; pairs naturally
with D (desktop mic access).

### 24.3 P — Multi-project support (cards P0–P3; ADRs P-1, P-2)

**Goal.** Run several independent projects in one DialGent instance.

**Boundaries.** A *project* is an **isolated runtime**: its own event-log path
(`<projects>/<id>/events.jsonl`), its own `OrchestratorAutomaton`, its own
`agents/` dir, its own git root for checkpoints. The current `AppRuntime`
**singleton** (`engine/runtime.py`) becomes a **`ProjectRegistry`** keyed by
project id (ADR P-1). A **default project** absorbs the existing `events.jsonl`
for backward compatibility (ADR P-2).

**Integration.**
- *Event log:* one JSONL per project; fold is per-project.
- *IPC:* `/projects` CRUD; `state`/`events`/`commands`/`config`/`files` become
  project-scoped; the WS carries a `project_id` so one client can follow one
  project (§13).
- *Roles:* `agents/*.md` resolved per project dir.
- *Checkpoints:* scoped to the project's git root (already scope-guarded).
- *Supervision:* per-project mode.

**Risks/deps/license.** Singleton→registry refactor touches `lifespan` + every
handler `[high]`; WS multiplexing by `project_id` `[med]`; migration of the
existing log `[med]`. No new third-party license `[high]`. Depends on: land before
features that assume one project; recommended after CL/T.

### 24.4 D — Desktop packaging (cards D0–D2; ADRs D-1, D-2, D-3)

**Goal.** Ship DialGent as a native desktop app.

**Recommendation: Tauri** `[med]` (ADR D-1) — small native bundle and **Rust
synergy** with the §20 PTY manager (`portable-pty`) and `TerminalLauncher`. The
Python backend is bundled as a **PyInstaller sidecar**, spawned on launch, gated by
`/health`; the webview then connects over the **same localhost IPC** (ADR D-2 — no
protocol change). Signing/notarization and auto-update are deferred (ADR D-3).

**Integration.**
- *Backend:* unchanged — FastAPI on localhost; the sidecar just manages its
  process lifecycle (spawn, single-instance, graceful shutdown).
- *Frontend:* the Vite build is the bundled webview content.
- *Terminal:* reuses T's Rust PTY sidecar and launcher (§20) — one codebase.
- *Voice:* desktop mic access pairs with V (§24.2).

**Risks/deps/license.** Cross-platform Python bundling + `/health` gating `[high]`;
macOS signing/notarization `[med]`; native PTY permissions `[med]`; auto-update
`[low]`. Tauri MIT/Apache `[high]`; PyInstaller GPL-2.0 + bootloader exception
`[med]` (flag, §22). Depends on: T (shares the Rust PTY); recommended last.

---

*End of ARCHITECTURE.md v2.0. The former `ARCHITECTURE_ADDENDUM.md` and
`ARCHITECTURE_CONTEXT_TERMINAL_ADDENDUM.md` are fully merged above and obsolete.*
