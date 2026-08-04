# AI Team Contract — Torrentino Native macOS

## Source of truth (priority)

1. `TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md` — authoritative implementation plan
2. `AI_Workflow_Kit/docs/AI/STATE.yaml` — what to do right now
3. `AI_Workflow_Kit/docs/TORRENTINO_STEPS.md` — condensed WP cards
4. `AI_Workflow_Kit/docs/DECISIONS.md` — ADR log
5. `AI_Workflow_Kit/docs/PROJECT_CONTEXT.md` — repo map + build commands
6. `Legacy/Tauri/` — **HARD BAN** (Human-only research). Agents never read for implementation, never edit, never stage/commit, never "fix" drift

## Roles

| Role | Actor | Writes code? | Updates |
|------|-------|--------------|---------|
| **Orchestrator** | Jcode (this session) | no product code | STATE, DECISIONS, checkpoints, kick prompts |
| **Implementation Engineer** | Coder (fresh terminal) | **yes** product | `target_files` only |
| **Verification Engineer** | Reviewer (fresh terminal) | no | `FEEDBACK.md`, code review |
| **Test Engineer** | Tester (fresh terminal) | **test code only** (+ security tests) | test targets, QA scripts, `BUG_REPORT.md`, `REPORT.md`, `SECURITY_FINDINGS.md` |
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

### Who does what when Tester finds a bug or security issue

| Actor | Action |
|-------|--------|
| **Tester** | Detects functional **and security** issues; writes `BUG_REPORT.md` and/or `SECURITY_FINDINGS.md`; tells Human: «вернись к оркестратору». **Never** patches product code. |
| **Orchestrator** | Reads reports, prioritizes, opens fix/retry, **issues full Coder kick** (functional + security fixes). |
| **Coder** | **Only one who fixes product code** |
| **Reviewer** | Re-reviews after Orchestrator issues Reviewer kick |
| **Tester** | Re-runs suite + security regression after Orchestrator issues Tester kick |

### Tester security mandate (every WP)

Torrentino is network-facing (BitTorrent, magnet/HTTP sources, XPC, filesystem paths, Keychain). On **every** Tester turn the agent must:

1. Run functional regression + new feature tests (as always).
2. Perform a **WP-scoped security pass**: threat model the *new/changed* surfaces; add **negative/abuse tests** where practical; record residual risks.
3. Write findings to `Native/TorrentinoEngineBridge/scripts/qa/SECURITY_FINDINGS.md` (append or rewrite section for current WP).
4. **Never** exploit production systems outside the local TestProfile harness; **never** write real malware/exploits against external hosts; use local disposable fixtures only.
5. Security findings do **not** auto-block PRODUCT GREEN alone if severity is Low/Informational — but **High/Critical** product-reachable issues → treat as FAIL for the WP until Orchestrator routes a Coder fix (or Human accepts residual risk in DECISIONS).

Security themes (pick those relevant to the WP): path traversal / symlink / TOCTOU; XPC authz & untrusted payloads; SSRF/unsafe URL fetch; injection in bencode/magnet/HTTP; IPC deserialization; secret leakage (logs, diagnostics, Keychain misuse); sandbox-adjacent assumptions; DoS via unbounded queues/payloads; permission / volume spoofing.
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
7. **Коммитит только Orchestrator.** Воркеры (Coder, Reviewer, Tester) делают работу, оставляют файлы в working tree. Orchestrator проверяет результат и коммитит + пушит. Воркеры НЕ делают `git commit` / `git push`.
8. No silent architecture redesign by Coder.
9. No fake data / fake states in production code.
10. **`Legacy/Tauri/` HARD BAN (all roles, no exceptions):**
    - Do **not** modify, create, delete, move, reformat, or "fix" anything under `Legacy/`.
    - Do **not** use Legacy as implementation reference, copy-paste source, or design authority for Native work.
    - Do **not** `git add` / commit / restore / checkout Legacy except **Orchestrator** undoing accidental dirty tree back to HEAD.
    - Do **not** open Legacy files to "understand how it worked" — Native plan + current Native code + DECISIONS are enough.
    - Human alone may touch Legacy offline for personal research; agents must ignore that worktree noise and never "help" with it.
    - If `git status` shows Legacy dirty: **leave it alone**, report to Orchestrator in handoff; do not revert unless you are Orchestrator restoring frozen tree.
    - Reviewer/Tester may only **detect** Legacy path changes via `git diff -- Legacy/` (no file edits). Untouched Legacy is a hard gate.
11. **Never** `git add -A` on a parent directory outside Torrentino.
12. Product git root = `Torrentino/`. Tags: `torrentino/pre-<WP>`, `torrentino/<WP>-done`.
13. **Readable, well-commented code** — see § Comments below.
14. Human communicates **only with Orchestrator** for workflow. Workers report via files + «вернись к оркестратору».
15. **Tester прогоняет ВСЕ suite'ы при каждом шаге.** Если любой suite красный — RED.
16. Swift 6 strict concurrency: `Complete` с первого пакета.
17. Никаких disk/network/DB/hash operations на `MainActor`.
18. C++ pointer не пересекает actor boundary.
19. UI не является источником истины.

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
