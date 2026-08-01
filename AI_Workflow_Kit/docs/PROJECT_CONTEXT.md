# DialGent — Project Context

## Identity

| Item | Value |
|------|--------|
| Product | **DialGent** |
| Slogan | **Your Diligent Agent Loop** |
| Platform | macOS (primary), cross-platform later |
| Frontend | React 19 + Vite 6 + Tailwind CSS 4 + Motion |
| Backend | Python 3.12+ (FastAPI, Pydantic v2, WebSocket) |
| Metaphor | Dial (circle) + Gent (agents) + Diligent (discipline) |

## Paths

```text
DialGent/                              ← product + git root
  AI_Workflow_Kit/                     ← orchestration (this kit)
    docs/
      PROJECT_CONTEXT.md               ← this file
      ARCHITECTURE.md                  ← architectural spec v1 + delta
      DIALGENT_STEPS.md                ← executable step cards
      DECISIONS.md                     ← ADR log
      AI/
        STATE.yaml                     ← what to do right now
        TEAM_CONTRACT.md               ← roles + rules
        ORCHESTRATOR.md                ← orchestrator prompt
        FEEDBACK.md                    ← review output
        REVIEW_TEMPLATE.md             ← review template
        IMPLEMENTATION_ENGINEER.md     ← coder prompt
        VERIFICATION_ENGINEER.md       ← verifier prompt
        QA_ENGINEER.md                 ← QA prompt
        GIT_CHECKPOINTS.md             ← checkpoint rules
    script/
      checkpoint.sh                    ← git checkpoint script
      graphify_rebuild.sh              ← rebuild local knowledge graph (dev tokens)
  graphify-out/                        ← knowledge graph for agents (token savings)
  dialgent_frontend/                   ← React prototype (working base)
    src/
      types.ts                         ← AppState, AgentInfo, AGENTS[5]
      data.ts                          ← INITIAL_DOCUMENTS, INITIAL_LOGS (hardcoded)
      projectFiles.ts                  ← virtual FS with agentIds (isolation!)
      App.tsx                          ← root component
      components/
        Canvas.tsx                     ← radial agent circle + SVG + HUD
        Header.tsx                     ← top bar + mode toggle
        Sidebar.tsx                    ← left nav: orchestrator + agents
        LeftPanel.tsx                  ← file explorer + code editor
        RightPanel.tsx                 ← live activity + rework path
        AgentDetailPanel.tsx           ← skills + temperature + config
    package.json                       ← React 19, Vite 6, Tailwind 4, Motion
  chat-export.json                     ← full design history (reference)

```

## Graphify (dev workflow — token savings)

For **agents building DialGent**, not only the product Graphify feature (M2).

### CLI (always available)

```bash
cd "/Users/pavan/Documents/AI Projects/DialGent"
./AI_Workflow_Kit/script/graphify_rebuild.sh          # rebuild graphify-out/
./AI_Workflow_Kit/script/graphify_rebuild.sh --force  # after large deletes

graphify explain "EventLogStore" --graph graphify-out/graph.json
graphify path "OrchestratorAutomaton" "EventLogStore" --graph graphify-out/graph.json
graphify query "how does event log fold work" --graph graphify-out/graph.json
```

### Cline Skills

**Only `graphify`** in the DialGent project (token savings / codebase navigation).

- **Project:** `DialGent/.cline/skills/graphify/SKILL.md`
- Role skills (coder / reviewer / architect) are **not** used — short kick prompts instead
- **Global** `~/.cline/skills/` should not contain DialGent role skills

```bash
./AI_Workflow_Kit/script/install_cline_skills.sh              # ensure graphify only + strip extras
./AI_Workflow_Kit/script/install_cline_skills.sh --remove-global
# Restart Cline CLI — Skills UI should list only graphify
```

### Cline MCP (agents see Graphify tools in Cline CLI)

Config is written to:

- `~/.cline/data/settings/cline_mcp_settings.json` (Cline settings UI path)
- `~/.cline/mcp.json` (CLI convention)

```bash
./AI_Workflow_Kit/script/cline_graphify_mcp.sh           # install/update MCP entry
./AI_Workflow_Kit/script/cline_graphify_mcp.sh --rebuild # rebuild graph + install
./AI_Workflow_Kit/script/cline_graphify_mcp.sh --status
```

Server command: `python -m graphify.serve <DialGent>/graphify-out/graph.json` (stdio).

**After install: fully quit and restart Cline CLI**, then MCP panel should list **graphify**.  
Graph is loaded at MCP process start — after `graphify_rebuild.sh`, reconnect/restart Cline.

Requires `uv tool install graphifyy` (CLI at `~/.local/bin/graphify`). See TEAM_CONTRACT hard rule 15.

## Build commands

### Frontend (current prototype)

```bash
cd "/Users/pavan/Documents/AI Projects/DialGent/dialgent_frontend"
npm install
npm run dev          # dev server on :3000
npm run build        # production build
npm run lint         # tsc --noEmit
```

### Backend (dialgent_backend — Pydantic schemas in F1, FastAPI IPC in F2, Agent Config Loader in F3, Event Log Store in E0, State Machine Automaton in E1, Verdict Router in E2, Checkpoint Manager in E3, Live IPC Wiring in E4, Agno Agent Shell in E5, Unified Model Adapter in M0, Skill Loader in M1, MCP Client + Graphify in M2)

```bash
cd "/Users/pavan/Documents/AI Projects/DialGent/dialgent_backend"
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
pytest               # unit, API, agent loader, event log, state machine, router, checkpoint, commands, agent shell, model adapter, skill loader & MCP/Graphify tests
uvicorn dialgent.main:app --reload  # dev server on :8000
```

## Frontend prototype — what exists

| Component | Lines | Status | Maps to (spec) |
|-----------|-------|--------|----------------|
| `Canvas.tsx` | ~1023 | Working, hardcoded | Radial cycle visualization |
| `Header.tsx` | ~73 | Working | Mode switcher AUTO/GATED/SUPERVISED |
| `Sidebar.tsx` | ~102 | Working | Agent toggles + orchestrator |
| `LeftPanel.tsx` | ~505 | Working, virtual FS | File explorer + active stages |
| `RightPanel.tsx` | ~222 | Working, hardcoded | Live activity + rework path |
| `AgentDetailPanel.tsx` | ~217 | Working, hardcoded | RoleConfig editor |
| `types.ts` | ~101 | Working | → Pydantic contract (F0) |
| `data.ts` | ~274 | Hardcoded demo | → WebSocket stream (U-track) |
| `projectFiles.ts` | ~467 | Virtual FS + agentIds | → context_slice.target_files |

## Key architectural decisions (from chat-export.json)

1. **Event-log = source of truth.** STATE = projection (fold).
2. **Packet protocol** = JSON envelope + Markdown body.
3. **Role = string id** (not enum). Loaded from `agents/*.md`.
4. **CyclePosition** = data-driven routing in cycle.
5. **RolePermissions** = safety by default (all false).
6. **Config = MD+frontmatter** files in `agents/`.
7. **Models** = 3 backends: API / proxy / local.
8. **Memory** = Graphify + git-history + ADR index.
9. **Supervision modes** switchable at runtime.
10. **Human ↔ Orchestrator only.**

## Stack (target)

| Layer | Technology |
|-------|------------|
| Frontend | React 19, Vite 6, Tailwind 4, Motion, Lucide |
| Backend | Python 3.12+, FastAPI, Pydantic v2, uvicorn |
| IPC | WebSocket (events) + REST (commands, config) |
| Event store | Append-only JSONL (MVP) → SQLite (later) |
| Agent runtime | Agno (Apache-2.0) as single-agent shell |
| Model routing | Thin adapter: API / OmniRoute / local |
| Knowledge graph | Graphify (MIT, MCP server) |
| Skills | agent-skills format (MIT) + own scanner |
| Checkpoints | Git tags (`dialgent/pre-*`, `dialgent/*-done`) |

### Skills system (M1)

- **SKILL.md format**: agent-skills anatomy (YAML frontmatter: `name`, `description`; markdown body: Overview, When to Use, Core Process, Rationalizations, Red Flags, Verification).
- **Loader**: `dialgent/skills/loader.py` — parses SKILL.md into `SkillDef` (id, name, description, prompt_fragment), loads from `dialgent_backend/skills/` (supports nested `skills/<name>/SKILL.md` and flat `skills/<name>.md` layouts).
- **Binding**: `RoleConfig.skill_set` (list of skill IDs) resolved to loaded `SkillDef` objects at shell build time. Prompt fragments injected into agent system prompt under `## Active Skills`.
- **Scanner stub**: `dialgent/skills/scanner.py` — `scan_stack()` returns empty list (full autoskills deferred).
- **Shell integration**: `AgentShell.from_config()` accepts optional `skills_dir` param; loads and resolves skills, injects prompt fragments into system prompt via `_build_system_prompt()`.

### MCP / Graphify connector (M2)

- **MCP client**: `dialgent/mcp/client.py` — wraps the official `mcp` Python SDK (`stdio_client` + `ClientSession`) for stdio transport. Provides `connect()`, `disconnect()`, `list_tools()`, `call_tool()`, `list_resources()`, `read_resource()`.
- **MockMCPClient**: Same interface as MCPClient but returns predefined responses — full offline testing without a real MCP server.
- **Graphify connector**: `dialgent/mcp/graphify.py` — `GraphifyClient` wraps MCPClient for Graphify-specific operations. `query()` method sends natural-language queries to the Graphify knowledge graph.
- **Query tool**: `build_graphify_query_tool()` creates a synchronous Agno tool (`graphify_query`) that wraps the async `GraphifyClient.query()` via `asyncio.run()`. Read-only (query only, no mutations). Available to all roles when a `graphify_client` is provided.
- **MockGraphifyClient**: Mock for testing with predefined query results.
- **Auto-rebuild hook**: `rebuild_graphify()` stub — returns True (full implementation deferred).
- **Shell integration**: `AgentShell.from_config()` accepts optional `graphify_client` param; `build_tools()` adds `graphify_query` tool when provided.
- **No vendoring**: Only MCP protocol client + Graphify connector; no Graphify source code is vendored.

### Local model detection + compression (M3)

- **Local detect**: `dialgent/routing/local_detect.py` — OS autodetect for local LLM servers (Nativ, llama.cpp, vLLM, LM Studio). Non-destructive: opt-in `detect_local_servers()` / `get_best_local_server()` only probe localhost (127.0.0.1) with short timeouts (2 s). TCP port check precedes HTTP health probe. No network requests at import time. No silent/background requests.
- **Compression**: `dialgent/routing/compression.py` — Two strategies: (1) `light` — whitespace normalisation, verbose-phrase shortening, optional middle-truncation for long texts; (2) `omnioroute` — delegates to OmniRoute proxy (server-side, local no-op). Verdict tags (`VERDICT:...|SUMMARY:...`) are always preserved. Compression is opt-in via `CompressionConfig.enabled` (default False).
- **Adapter wiring**: `resolve_single_model()` and `resolve_model()` accept `local_autodetect=True` (default) — when `source="local"`, probes for running local servers and uses the detected base_url. `ModelAdapter` accepts `compression_config` and exposes `compress()` method. Autodetect failures are non-fatal (logged at debug, falls through to configured `local_base_url`).
- **Tests**: `tests/test_local_detect.py` (28 tests, all mocked) + `tests/test_compression.py` (47 tests, all offline). 75 new tests, 0 network calls.

### Frontend WebSocket + event stream (U0)

- **REST client**: `dialgent_frontend/src/api/client.ts` — `fetchState()` (GET /state), `fetchEvents()` (GET /events), `postCommand()` (POST /command/*). All return null on failure (graceful degradation). Base URL via `VITE_BACKEND_URL` env (default `http://localhost:8000`).
- **WebSocket client**: `dialgent_frontend/src/api/ws.ts` — `EventStreamClient` class. Connects to `ws://localhost:8000/events`, sends `{"type":"subscribe"}` on connect, handles `ack` and `event` messages. Auto-reconnect with exponential backoff (max 5 attempts).
- **Event stream hook**: `dialgent_frontend/src/hooks/useEventStream.ts` — React hook wrapping `EventStreamClient`. Returns `{events, isConnected, isConnecting, error}`. Deduplicates events by ID.
- **Backend state hook**: `dialgent_frontend/src/hooks/useBackendState.ts` — React hook polling GET /state + GET /events every 5s. Returns `{state, events, isLoading, error, refetch}`.
- **Event → log conversion**: `dialgent_frontend/src/data.ts` — `eventToLog()` and `eventsToLogs()` convert backend `BackendEvent` to frontend `ActivityLog` format (timestamp, message, type, detail). Maps all 22 EventType values.
- **App.tsx wiring**: Uses both hooks; merges REST + WS events (deduplicated); derives `appState` from `BackendState` (live/error/default); passes `events` to RightPanel and `backendState` to Canvas. Falls back to demo mode (INITIAL_LOGS, hardcoded Canvas animation) when backend is offline.
- **RightPanel**: Accepts `events` and `backendState` props. Renders live event tape (timestamp, type icon, message, detail) when events available. Falls back to existing demo content.
- **Canvas**: Accepts `backendState` prop. Uses `arc_progress` for progress bar and `current_node` for active agent highlighting. Falls back to demo animation when backend offline. Layout and CSS classes unchanged.
- **Types**: `types.ts` extended with `BackendEvent`, `BackendState`, `NodeTelemetry`, `SupervisionMode`, `WSMessage`, `EventLogResponse`, `CommandResponse` — matching Python Pydantic models.
- **Build**: `npm run build` passes (2088 modules, 423.84 kB). `tsc --noEmit` clean (0 errors).

### Dynamic roles from config API (U1)

- **Backend config**: `dialgent/api/config.py` — `GET /config/roles` now loads all 6 RoleConfig objects from `agents/*.md` via `RoleConfigLoader` (`load_all_roles_from_dir`). Broken configs are logged and skipped. Falls back to sample orchestrator config if directory is missing.
- **REST client**: `src/api/client.ts` — added `fetchRoles()` (GET /config/roles). Returns `RoleConfig[] | null` on failure.
- **Roles hook**: `src/hooks/useRoles.ts` — React hook polling GET /config/roles every 10s. Returns `{roles, isLoading, error, refetch}`. Falls back to null when backend offline.
- **RoleConfig → AgentInfo mapping**: `src/data.ts` — `roleConfigToAgentInfo()` converts backend RoleConfig to frontend AgentInfo, computing circular position, mapping hex colors to Tailwind classes, and mapping icon names to Lucide icons.
- **App.tsx wiring**: Uses `useRoles` hook; maps `RoleConfig[]` to `AgentInfo[]` via `roleConfigToAgentInfo()`; syncs `activeAgents` state with backend roles via `useEffect`. Passes `roles` prop to Canvas, Sidebar, RightPanel, AgentDetailPanel. Falls back to hardcoded `AGENTS` when backend offline.
- **Canvas**: Accepts `roles` prop (AgentInfo[], default AGENTS). Uses `roles.filter()` and `roles.map()` for dynamic agent rendering. Progress and active agent driven by `backendState` (from U0) or demo animation.
- **Sidebar**: Accepts `roles` prop. Renders dynamic agent buttons from `roles` instead of hardcoded `AGENTS`.
- **AgentDetailPanel**: Accepts `backendRoles` prop (RoleConfig[] | null). Shows skills from backend `RoleConfig.skill_set` when available, falls back to hardcoded `agentSkillsMap`.
- **CreateAgentWizard**: New stub component — slide-over form with id, display_name, icon, color, cycle_position fields. "Create" button is a no-op (logs to console). Wired to floating "+" button in App.tsx.
- **Types**: `types.ts` extended with `RoleConfig`, `RoleConfigModelHint`, `RoleConfigPermissions`, `RoleCyclePosition` — matching Python Pydantic models.
- **Build**: `npm run build` passes (2090 modules, 432.66 kB). `tsc --noEmit` clean (0 errors).

## Dependencies / licenses

| Project | License | Usage |
|---------|---------|-------|
| Agno | Apache-2.0 | Agent shell (code OK) |
| agent-skills | MIT | SKILL.md format (code OK) |
| Graphify | MIT | Knowledge graph (code OK) |
| Ouroboros | MIT | Patterns (ideas) |
| Hyperresearch | MIT | Adversarial critics (ideas) |
| OpenCodex | MIT | Proxy inspiration (ideas) |
| OmniRoute | MIT | Model routing (connector) |
| Nativ | Unknown | Local models (connector via HTTP) |
| Herdr | AGPL-3.0 | **Ideas only** — no code copy |
| autoskills | CC-BY-NC | **Ideas only** — own scanner |
