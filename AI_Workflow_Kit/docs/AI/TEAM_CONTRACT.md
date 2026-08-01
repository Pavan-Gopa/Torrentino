# AI Team Contract — Torrentino Native macOS

## Source of truth (priority)

1. `TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md` — authoritative implementation plan
2. `AI_Workflow_Kit/docs/AI/STATE.yaml` — what to do right now
3. `AI_Workflow_Kit/docs/TORRENTINO_STEPS.md` — condensed WP cards
4. `AI_Workflow_Kit/docs/DECISIONS.md` — ADR log
5. `AI_Workflow_Kit/docs/PROJECT_CONTEXT.md` — repo map + build commands
6. `Legacy/Tauri/` — frozen reference, never modify

## Roles

| Role | Actor | Writes code? | Updates |
|------|-------|--------------|---------|
| **Orchestrator** | Jcode (this session) | no product code | STATE, DECISIONS, checkpoints, kick prompts |
| **Implementation Engineer** | Coder (fresh terminal) | **yes** product | `target_files` only |
| **Verification Engineer** | Reviewer (fresh terminal) | no | `FEEDBACK.md`, code review |
| **Test Engineer** | Tester (fresh terminal) | **test code only** | test targets, QA scripts, `BUG_REPORT.md`, `REPORT.md` |
| **Architect** *(on demand)* | Orchestrator or dedicated | no product features | ADR → DECISIONS |
| **Human** | Pavel | — | switch models, paste kickoffs, approve decisions |

## Workflow (hub = Orchestrator)

Каждая роль открывается в **новом терминальном окне** (пустой контекст).
**Каждый** kick-промпт пишет **Orchestrator**; Human только копирует.

```
Human ↔ Orchestrator only (control plane)
  Orchestrator: PRE tag + STATE update
  → Orchestrator выдаёт kick Coder (full prompt)
  → Human: новое окно → Coder
  → Coder: code + FEEDBACK waiting_review → «вернись к оркестратору»
  → Human → Orchestrator «статус»
  → Orchestrator выдаёт kick Reviewer (full prompt)
  → Human: новое окно → Reviewer
  → Reviewer: FEEDBACK APPROVED|CHANGES_REQUESTED → «вернись к оркестратору»
  → Human → Orchestrator
  → if approved: Orchestrator выдаёт kick Tester (full prompt)
  → Tester: REPORT/BUG_REPORT → «вернись к оркестратору»
  → Orchestrator: green → POST + PRE next + kick Coder; red → fix + kick Coder
```

### Who does what when Tester finds a bug

| Actor | Action |
|-------|--------|
| **Tester** | Detects failure, writes `BUG_REPORT.md`, tells Human: «вернись к оркестратору» |
| **Orchestrator** | Reads bugs, opens fix/retry, **issues full Coder kick** |
| **Coder** | **Only one who fixes product code** |
| **Reviewer** | Re-reviews after Orchestrator issues Reviewer kick |
| **Tester** | Re-runs suite after Orchestrator issues Tester kick |

**Do not:** send bugs to Reviewer to "fix". Reviewer does not write product code.
**Do not:** skip Orchestrator (STATE/checkpoints/kicks get lost).
**Do not:** let workers tell Human to open the next role without Orchestrator.

## Hard rules

1. **Graphify first.** Каждый агент ПЕРЕД началом работы выполняет `graphify query` для получения контекста. Не читать файлы вслепую.
2. **Graphify update.** Оркестратор обновляет граф (`/graphify . --update`) в конце каждого цикла (после POST-чекпоинта, до PRE следующего WP).
3. Keep project **buildable/testable** every step (`xcodebuild build` / `xcodebuild test`).
4. **One WP at a time.** No skipping stop-gates.
5. Diff **only** in `STATE.yaml` → `target_files`.
6. Communication between agents **via files only**.
7. No silent architecture redesign by Coder.
8. No fake data / fake states in production code.
9. Legacy code (`Legacy/Tauri/`) is **frozen** — never modify.
10. **Never** `git add -A` on a parent directory outside Torrentino.
11. Product git root = `Torrentino/`. Tags: `torrentino/pre-<WP>`, `torrentino/<WP>-done`.
12. **Readable, well-commented code** — see § Comments below.
13. Human communicates **only with Orchestrator** for workflow. Workers report via files + «вернись к оркестратору».
14. **Tester прогоняет ВСЕ suite'ы при каждом шаге.** Если любой suite красный — RED.
15. Swift 6 strict concurrency: `Complete` с первого пакета.
16. Никаких disk/network/DB/hash operations на `MainActor`.
17. C++ pointer не пересекает actor boundary.
18. UI не является источником истины.

## Comments (mandatory quality bar)

| Where | What to document |
|-------|------------------|
| File / module header | Role in system (1–5 lines): layer, ownership, must-not |
| Non-obvious logic | **Why**, not a restate of the code |
| Public API | Brief intent + types/invariants |
| Actor / concurrency | Actor ownership, "no blocking here", isolation domain |
| XPC / protocol | Message format, who sends, who receives, error handling |
| Safety / permissions | Path validation, code-signing checks |
| TODOs | `// TODO(WP-07): …` tied to a WP ID |

### Forbidden

- Comment every line of trivial getters/setters
- Outdated comments that contradict code
- Secrets, keys, credentials in comments

### Language

- English for code comments.
- Russian OK in plan docs and Human communication.

## Human short commands

| Phrase | Orchestrator does |
|--------|-------------------|
| `приступай` / `статус` / `дальше` | Read STATE/FEEDBACK; sync; **output full kick** for `next_actor` |
| `зови кодер` | Full Coder kick in reply |
| `зови ревью` | Full Reviewer kick in reply |
| `зови тестер` | Full Tester kick in reply |
| `следующий шаг` | Only if review approved + tests green → PRE next + Coder kick |
| `retry` | Same WP, attempts++; Coder kick with FEEDBACK §5 |

Workers never route Human to another worker. Always: **«вернись к оркестратору»**.
