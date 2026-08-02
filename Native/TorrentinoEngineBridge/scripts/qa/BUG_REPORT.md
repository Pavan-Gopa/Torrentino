# BUG REPORT — WP-03 Test Engineer

**Date:** 2026-08-02  
**Role:** Test Engineer (detect only — no product fix)  
**Verdict:** **FAIL**  
**Suite log:** `/tmp/torrentino_qa_suite_wp03.log`  
**XCTest log:** `/tmp/torrentino_wp03_xctest2.log`

---

## Summary

| Metric | Value |
| --- | --- |
| Total QA scripts | 32 |
| Pass | 30 |
| Fail | 2 |
| WP-01 regression | 11 / 11 PASS |
| WP-02 regression | 13 / 13 PASS |
| WP-03 new | 6 / 8 PASS (2 FAIL) |
| Suite result | **FAIL** |

Root cause of both failing scripts is the **same product defect**: `EngineError` does not conform to `LocalizedError`.

---

## Bug 1 — EngineError missing LocalizedError (P1)

| Field | Value |
| --- | --- |
| **ID** | WP03-BUG-001 |
| **Severity** | P1 (kick contract + UI error surface) |
| **Component** | `Native/TorrentinoDomain/EngineError.swift` |
| **Detected by** | `TorrentinoDomainTests.testEngineErrorLocalizedErrorConformance` |
| **Scripts FAIL** | `test_wp03_domain_types.sh`, `test_wp03_xctest_pass.sh` |

### Expected (from WP-03 kick)

> `TorrentinoDomain.EngineError` — enum (xpcUnavailable, agentDenied, timeout, internalError).  
> Unit: all cases, **Error** conformance, **LocalizedError**.

### Actual

```swift
public enum EngineError: Error, Sendable, Equatable, CustomStringConvertible {
    case xpcUnavailable
    case agentDenied
    case timeout
    case internalError
    // … CustomStringConvertible only — no LocalizedError
}
```

### Evidence

```
Test case 'TorrentinoDomainTests.testEngineErrorLocalizedErrorConformance()' failed
XCTAssertTrue failed - EngineError must conform to LocalizedError for UI-facing copy
** TEST FAILED **
```

Runtime check:

```swift
EngineError.xpcUnavailable is LocalizedError  // → false
```

### Impact

- UI cannot reliably use `error.localizedDescription` / `errorDescription` for domain errors.
- String Catalog has `error.*` keys, but the domain type does not expose `LocalizedError` mapping.
- Kick gate “Unit test target запускается (xcodebuild test)” fails while this assertion stands.

### Suggested fix (for Coder — not applied by Tester)

1. Conform `EngineError: LocalizedError`.
2. Implement `errorDescription` (and optionally `failureReason`) per case.
3. Optionally map cases to String Catalog keys used by the app (`error.xpc_unavailable`, etc.).
4. Keep existing `CustomStringConvertible` or derive `description` from `errorDescription`.

### Reproduction

```bash
cd "/Users/pavan/Documents/AI Projects/Torrentino"
xcodebuild test \
  -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:TorrentinoDomainTests/TorrentinoDomainTests/testEngineErrorLocalizedErrorConformance \
  CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=438UQRF7JV
```

---

## What passed (not bugs)

| Area | Result |
| --- | --- |
| TorrentState all cases + Codable + unknown decode fail + concurrent reads | PASS |
| TorrentInfo immutable + Codable + edges + fuzz + concurrent stress | PASS |
| EngineError cases + Error + descriptions + equality | PASS (except LocalizedError) |
| IPCVersion current=1.0, ordering, backward-compat major check | PASS |
| IPCEnvelope round-trip, tampered/truncated/garbage decode fail, stress | PASS |
| EngineCommand / EngineEvent Codable + unknown fail | PASS |
| TestProfile temp dir, not production path, tearDown cleanup | PASS |
| String Catalog valid JSON, EN+RU complete | PASS |
| Strict concurrency config + clean build (0 warning lines) | PASS |
| Empty state ContentView + catalog keys + AppTests | PASS |
| Legacy/ git clean | PASS |
| Full WP-01 + WP-02 regression (24 scripts) | PASS |

---

## Gate status (from plan)

| Gate | Status | Notes |
| --- | --- | --- |
| Clean build without warnings | **PASS** | `test_wp03_strict_concurrency.sh` |
| Unit test target runs green | **FAIL** | LocalizedError assertion |
| App shows native empty state | **PASS** | static + AppTests |
| Legacy/ untouched | **PASS** | `test_wp03_legacy_untouched.sh` |

---

## Artifacts added this cycle (test-only)

| Path | Role |
| --- | --- |
| `Native/Tests/TorrentinoDomainTests/TorrentinoDomainTests.swift` | Expanded ADR-010 domain coverage |
| `Native/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift` | Expanded IPC / envelope / fuzz / stress |
| `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift` | Empty-state catalog + linkage |
| `scripts/qa/test_wp03_*.sh` (8 scripts) | Dedicated WP-03 feature gates |
| `scripts/qa/run_qa_suite.sh` | Now picks wp01 + wp02 + wp03 |
| `scripts/qa/BUG_REPORT.md` | This file |
| `scripts/qa/COVERAGE.md` | Updated inventory |
| `scripts/qa/REPORT.md` | Suite table (FAIL) |

Product code was **not** modified. No git commit / push.
