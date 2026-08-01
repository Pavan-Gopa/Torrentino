# AI Team Contract — DialGent

## Source of truth (priority)

1. `AI_Workflow_Kit/docs/AI/STATE.yaml` — **what to do right now**
2. `AI_Workflow_Kit/docs/DIALGENT_STEPS.md` — step card for `current_step`
3. `AI_Workflow_Kit/docs/ARCHITECTURE.md` — architectural specification v1 + delta
4. `AI_Workflow_Kit/docs/PROJECT_CONTEXT.md` — repo map + build commands
5. `AI_Workflow_Kit/docs/DECISIONS.md` — ADR log
6. Chat export (`chat-export.json`) — full design history (reference only)
7. Frontend prototype (`dialgent_frontend/`) — working UI base, not a mockup

## Roles

| Role | Actor | Writes code? | Updates |
|------|-------|--------------|---------|
| **Architect** *(on demand)* | Qwen 3.8 Max / Claude | no product features | ADR → DECISIONS, ARCHITECTURE.md |
| **Planner** *(on demand)* | Qwen 3.8 Max / Claude | no product features | DIALGENT_STEPS.md |
| **Orchestrator** | Grok / Claude | only if attempts ≥ 3 | STATE, DECISIONS, checkpoints; triages bugs |
| **Implementation Engineer** | Coder / Claude / Hy3 | **yes** product | `target_files` only |
| **Verification Engineer** | Gemini / Claude | no | `FEEDBACK.md`, code review |
| **QA Script Engineer** | Qwen 3.8 Max | **QA scripts only** under `QA/` | `QA/scripts`, `manifest.json`, `BUG_REPORT.md`, `REPORT.md` |
| **Human** | Pavel | — | switch models; paste kickoffs; dogfood |

## Workflow (hub = Orchestrator)

Каждая роль открывается в **новом терминальном окне** (пустой контекст).
Поэтому **каждый** kick-промпт пишет **Orchestrator**; Human только копирует.

```
Human ↔ Orchestrator only (control plane)
  Orchestrator: PRE + STATE
  → Orchestrator выдаёт kick Coder (full prompt)
  → Human: новое окно → Coder
  → Coder: code + FEEDBACK waiting_review → «вернись к оркестратору»
  → Human → Orchestrator «статус»
  → Orchestrator выдаёт kick Reviewer (full prompt)
  → Human: новое окно → Reviewer
  → Reviewer: FEEDBACK APPROVED|CHANGES_REQUESTED → «вернись к оркестратору»
  → Human → Orchestrator
  → if approved: Orchestrator выдаёт kick QA (full prompt)
  → QA: REPORT/BUG_REPORT → «вернись к оркестратору»
  → Orchestrator: green → POST + PRE next + kick Coder; red → fix step + kick Coder
```

### Who does what when QA finds a bug

| Actor | Action |
|-------|--------|
| **QA** | Detects failure, writes `QA/BUG_REPORT.md`, tells Human: «вернись к оркестратору» |
| **Orchestrator** | Reads bugs, opens fix/retry, **issues full Coder kick** |
| **Coder** | **Only one who fixes product code** |
| **Verifier** | Re-reviews after Orchestrator issues Reviewer kick |
| **QA** | Re-runs suite after Orchestrator issues QA kick |

**Do not:** send QA bugs only to Verifier to "fix". Verifier does not write product code.
**Do not:** skip Orchestrator (STATE/checkpoints/kicks get lost).
**Do not:** let Coder/Reviewer/QA tell Human to open the next role without Orchestrator.
**OK for minor/flaky:** Orchestrator may open a tiny fix step with Coder in one hop.

Architecture work: only when Orchestrator issues an **Architect packet** (not every step).

## Hard rules

1. Keep project **buildable/testable** every step (`npm run build` / `pytest` / `npm test`).
2. **One step at a time.**
3. Diff **only** in `STATE.yaml` → `target_files`.
4. Communication between agents **via files only**.
5. No silent architecture redesign by Coder.
6. No fake telemetry / fake agent states in production code.
7. Frontend prototype is a **working base** — do not rewrite layout, feed real data.
8. `Role` = string id (`RoleId`), NOT enum. Roles loaded from `agents/*.md`.
9. **Never** `git add -A` on a parent directory outside DialGent.
10. Product git root = `DialGent/`. Tags: `dialgent/pre-<step>`, `dialgent/<step>-done`.
11. **Readable, well-commented code** — see § Comments below.
12. Event-log = source of truth. STATE = projection (fold of event log).
13. Packet protocol: JSON envelope + Markdown body. One packet in → one report out.
14. Human communicates **only with Orchestrator** for workflow. Workers report via files + «вернись к оркестратору». Orchestrator always supplies full kick prompts (fresh terminal windows).
15. **Graphify first (token savings — mandatory for orientation):** Before bulk greps / multi-file dumps, agents **must** query the knowledge graph. Prefer **Cline MCP tools** from server `graphify` if connected; else CLI: `graphify query|explain|path --graph graphify-out/graph.json`. Skill: `.agents/skills/graphify/SKILL.md` (project-scoped). Rebuild: `./AI_Workflow_Kit/script/graphify_rebuild.sh`. This is for **building DialGent**, not product M2.
16. **QA прогоняет ВСЕ suite'ы при каждом шаге** (backend pytest + frontend vitest + frontend build + любые новые тестовые проекты). Если любой suite красный — RED. Тестер отвечает за всё приложение, не только за свой шаг.

## Graphify (development of this repo)

| Item | Path / command |
|------|----------------|
| Graph output | `graphify-out/graph.json` |
| Skill (Agent Skills) | `.agents/skills/graphify/SKILL.md` — install: `graphify install --project --platform agents` |
| Cline MCP | `~/.cline/data/settings/cline_mcp_settings.json` + `~/.cline/mcp.json` — `./AI_Workflow_Kit/script/cline_graphify_mcp.sh` |
| Rebuild | `./AI_Workflow_Kit/script/graphify_rebuild.sh` (`--force` after big deletes) |
| Prefer | MCP tools **or** `graphify query/explain/path` over dumping trees |
| When | Coder, Verifier, QA, Orchestrator — anytime navigating code beyond `target_files` |
| Not | Substitute for `STATE.yaml` / `target_files` / step cards — still follow scope |

## Comments (mandatory quality bar)

Goal: a human or another agent can open a file months later and understand **what / why / constraints** without re-deriving the plan.

### Required

| Where | What to document |
|-------|------------------|
| File / module header | Role in system (1–5 lines): which layer, what it owns, what it must not do |
| Non-obvious logic | **Why**, not a restate of the code |
| Public API | Brief intent + types/invariants |
| Async / concurrency | Event loop ownership, lock rules, "no blocking here" |
| IPC / protocol | Message format, who sends, who receives, error handling |
| Safety / permissions | RolePermissions enforcement, config validation |
| TODOs | `// TODO(F1): …` tied to a step ID when deferred work is intentional |

### Forbidden

- Comment every line of trivial getters/setters
- Outdated comments that contradict code (update or delete)
- Fake explanations for placeholder/stub code
- Secrets, keys, credentials in comments

### Language

- English preferred for code comments (stable tooling / multi-agent).
- Russian OK in plan docs and Human communication.

### Verifier

Treat missing essential comments on new non-trivial code as **changes_requested** when the step introduces types, schemas, engine logic, or IPC paths.

## Human short commands

Human **always** talks to **Orchestrator**. Phrases below mean «Orchestrator, prepare the next kick».

| Phrase | Orchestrator does |
|--------|-------------------|
| `приступай` / `статус` / `дальше` | Read STATE/FEEDBACK; sync; **output full kick** for `next_actor` |
| `зови кодер` | Same as next_actor=implementation → full Coder kick in reply |
| `зови ревью` | Same as waiting_review → full Reviewer kick in reply |
| `зови QA` | Full QA kick in reply |
| `следующий шаг` | Only if review approved + QA green → PRE next + Coder kick |
| `retry` | Same step, attempts++; Coder kick with FEEDBACK §5 |
| Architect | Architect packet (design-only); never product code |

Workers never route Human to another worker. Always: **«вернись к оркестратору»**.
