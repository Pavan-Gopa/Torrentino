# BUG REPORT

> Main Orchestrator writes this after verifying a Tester's structured
> functional failure evidence. For security findings use `SECURITY_REPORT.md`.
> Main routes accepted fixes to a fresh Coder. Tester never patches product
> source or writes workflow reports directly.

## Meta

| Field | Value |
|-------|--------|
| Step | WP-13 `[WP13-DIAGNOSTIC-EXPORT-FIX-001]` |
| Date | 2026-08-22 |
| bugs_open | 0 |

## Bugs

_None open._

### Resolved this lane (history)

- **B-1 (HIGH)** Production rejected `exportDiagnostics`
  (`TransferCoordinator.swift:749-750` stub) — RESOLVED: real handler with
  structured password-free settings projection, hardened escaped-secret
  redaction (compiled + lockstep mirror + behavioral parity test), fresh/empty
  destination discipline with surfaced rollback failures, deterministic
  mid-write failpoint rollback test, degraded-mode admission per plan §9.7.
- **B-2 (MEDIUM)** Orphaned `WP13DiagnosticsSecurityTests` /
  `WP13StabilizationCampaign002Tests` not in pbxproj with false-green QA
  script — RESOLVED: both suites registered and executing (18 + 14 tests),
  `test_wp13_diagnostics_security.sh` fails closed on zero-collect.

Environmental notes (not bugs):

- Live observability probe remains guarded by the Human engine guard;
  isolated matrix covered in-process (sentinel-enforced).
