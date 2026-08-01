# Verification Template — Torrentino

Verification Engineer fills this into `FEEDBACK.md`.

WP: see `STATE.yaml` → `current_step`
Requirements: `TORRENTINO_STEPS.md` (same WP) + plan §WP

---

### 1. Build & tests
- Builds/tests after changes? (Yes/No/N/A)
- Commands run:
*Comment:*

### 2. WP compliance
- All requirements of **current** WP met?
- No work from future WPs?
- `target_files` only?
*Comment:*

### 3. Architecture invariants
- Swift 6 strict concurrency Complete?
- No disk/network/DB/hash on MainActor?
- C++ types hidden behind PIMPL?
- DTO immutable/Sendable?
- UI not source of truth?
- Legacy/Tauri/ untouched?
- No Homebrew runtime links?
*Comment:*

### 4. Comments & readability
- New modules/types have a short role header?
- Non-obvious logic explained with **why** (not restating code)?
- Actor/concurrency notes where relevant?
- XPC protocol documented (message format, error handling)?
- No noisy or outdated comments?
*Comment:*

### 5. If changes_requested — concrete list
1. …
2. …

---

**RESULT:** [APPROVED] or [CHANGES_REQUESTED]
