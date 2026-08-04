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
