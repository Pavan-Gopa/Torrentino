# Architect → Orchestrator handoff

## Feature

Optional OCR assistant as a reviewer add-on (OCR track, ADR OCR-1).
User-controlled toggle + provider/model selection + API-key input.
When enabled, the reviewer's dispatch calls a vision model before the main
LLM review and injects the output as extra context. When disabled (default),
zero cost, zero latency, identical behaviour to today.

Canvas phase indication: when the OCR sub-phase is active, the reviewer node
pulses violet (`#a78bfa`) with an "OCR" label; reverts to standard amber when
the main LLM review begins. Driven by `StateProjection.node_phase` (new
optional field, broadcast via existing `state_updated` WebSocket).

## Decision summary (ADR ids)

- **OCR-1** (2026-07-26): Optional OCR assistant as a reviewer add-on.
  - Per-role add-on, not a new role or CyclePosition.
  - `model_hint` reuse → any provider (Claude, Qwen, Ollama, proxy, mock).
  - API key in `~/.dialgent/secrets.json` (chmod 600); never in agents/*.md,
    event log, or frontend.
  - `config_changed` event on settings change (no key material in payload).
  - IPC: `GET/PUT /config/role/{id}/ocr`.
  - `StateProjection.node_phase: str | None` — set to `"ocr"` before OCR call,
    cleared to `None` after; broadcast via existing `state_updated` WS.
  - Canvas: reviewer node violet + "OCR" label during OCR sub-phase.

## Docs updated

- `ARCHITECTURE.md`: §6.4 added — reviewer OCR assistant add-on (config schema,
  dispatch flow, IPC, UI summary, canvas phase indication with `node_phase`).
- `DECISIONS.md`: ADR OCR-1 appended.
- `DIALGENT_STEPS.md` (draft): OCR0, OCR1, OCR2, OCR3 step cards appended
  (marked "design draft for Orchestrator").

## Recommended track / steps

1. **OCR0** — Backend: `OcrAssistantConfig` schema + `secrets.py` +
   `GET/PUT /config/role/{id}/ocr`. No dispatch changes.
2. **OCR1** — Backend: OCR pre-call in `AgentShell.execute()` for reviewer +
   `node_phase` field on `StateProjection` + WS broadcasts. Depends on OCR0.
3. **OCR2** — Frontend: collapsible OCR section in `RoleEditor` (reviewer only).
   Depends on OCR0 (endpoints must exist).
4. **OCR3** — Frontend: Canvas phase indication — violet glow + "OCR" label on
   reviewer node when `node_phase === 'ocr'`. Depends on OCR1 (field must exist
   in `BackendState`).

Order: OCR0 → OCR1 → OCR2 → OCR3. OCR2 and OCR3 are independent of each other
and can run in parallel after OCR1. No dependency on CL/T/EV/V/P/D tracks.

## target_files (for first coding step — OCR0)

```yaml
target_files:
  - dialgent_backend/dialgent/models/roles.py
  - dialgent_backend/dialgent/agents/loader.py
  - dialgent_backend/dialgent/secrets.py          # NEW
  - dialgent_backend/dialgent/api/config.py
  - dialgent_backend/tests/test_secrets.py        # NEW
  - dialgent_backend/tests/test_ocr_config.py     # NEW
```

## Non-goals

- No new role, no new CyclePosition, no new event type.
- No changes to verdict routing or state machine.
- No changes to any role other than reviewer.
- No signing/notarization/auto-update (D-3, deferred).
- No multi-project scoping of secrets (P-track concern; v1 = global secrets file).

## Open questions for Human

All resolved:
- `info_url` default: `https://open-codereview.ai/` (confirmed by Human).
- OCR assistant scope: reviewer-only, no tester in v1 or future (confirmed by Human).

## Next human action

Передай оркестратору. Скажи: «открой следующий step PRE / обнови STATE / зови
кодер» — после твоего (Orchestrator) разбора handoff.
