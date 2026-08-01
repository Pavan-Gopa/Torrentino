# Verification Template — DialGent

Verification Engineer fills this into `FEEDBACK.md`.

Step: see `STATE.yaml` → `current_step`
Requirements: `DIALGENT_STEPS.md` (same step)

---

### 1. Build & tests
- Builds/tests after changes? (Yes/No/N/A)
- Commands run:
*Comment:*

### 2. Step compliance
- All requirements of **current** step met?
- No work from future steps?
- `target_files` only?
*Comment:*

### 3. Product invariants
- No fake telemetry / fake agent states?
- Event-log integrity maintained?
- Packet protocol respected?
- Frontend prototype not rewritten (only extended)?
*Comment:*

### 4. Comments & readability
- New modules/types have a short role header?
- Non-obvious logic explained with **why** (not restating code)?
- Async/ownership notes where relevant?
- Public API types/invariants clear?
- No noisy or outdated comments?
*Comment:*

### 5. If changes_requested — concrete list
1. …
2. …

---

**RESULT:** [APPROVED] or [CHANGES_REQUESTED]
