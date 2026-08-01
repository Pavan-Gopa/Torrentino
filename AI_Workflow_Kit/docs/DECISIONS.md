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
