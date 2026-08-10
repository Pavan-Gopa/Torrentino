# Architect Handoff — Creator Productization

**Lane:** `[WP13-ARCH-CREATOR-PRODUCTIZE-001]`  
**Date:** 2026-08-10  
**Status:** Accepted by Orchestrator (design-only)  
**Decision:** **Option A** — Creator already complete; Human live acceptance only. No new ADR. No speculative Coder lanes under ADR-020.

---

## Problem

Human wants to create own torrents in Torrentino. Inventory shows WP-11 already shipped a full Creator stack (ADR-016/017, CPU-only per ADR-018).

## Current-state map (anchors)

```
Menu File → Create Torrent (⌘⌥N)
  TorrentinoApp.swift → showCreateSheet
  ContentView.sheet → CreateTorrentSheet
    TorrentListViewModel.inspectCreateSource / commitCreate / progress projection
      EngineClient creator commands
        XPC EngineCommandV1.inspectCreateSource | fetchCreatorManifestPage | commitCreate | cancelOperation
          TransferCoordinator creator handlers
            CreatorPlanStore (inspect token, manifest page, commit)
              SourceScanner → CPUHasher → MetainfoGenerator
              FD-anchored atomic write + rollback
              CreatorIndependentVerifier (libtorrent bridge)
              optional admitCreatedTorrent → durable add/seed path
```

Key paths:
- `Native/TorrentinoApp/Features/CreateTorrentSheet.swift`
- `Native/TorrentinoApp/Features/TorrentListViewModel.swift` (creator section)
- `Native/TorrentinoApp/EngineClient/EngineClient.swift` (creator API)
- `Native/TorrentinoDomain/CreatorPlanStore.swift`, `CPUHasher.swift`, `MetainfoGenerator.swift`, `SourceScanner.swift`
- `Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift` (creator handlers)
- Tests: `TorrentCreatorAgentTests`, `TorrentCreatorDomainTests`, `test_wp11_*.sh`

## Gap analysis

| Hypothesis | Finding |
|---|---|
| No backend | False — full domain/agent/bridge path exists |
| No UI | False — sheet + 78 `creator.*` EN/RU strings |
| No menu entry | False — File → Create Torrent, ⌘⌥N |
| Needs Metal | False — ADR-018 REJECT; CPU path intentional |
| Needs greenfield module | False — would violate ADR-016/017 |
| Possible user confusion | Discoverability (menu only), sheet stays open on success, no Reveal-in-Finder polish |

## Options

| | Option | Verdict |
|---|---|---|
| **A** | Already complete; live checklist only | **Recommended** |
| B | Speculative polish lanes before Human tries | Reject under ADR-020 without defect evidence |
| C | Partial rebuild | Reject — no defect evidence; high regression risk |

## Non-goals

Metal revisit; App Sandbox; second creator; Legacy; full security audit; CreatorPlanStore decomposition; watch-folder; batch create.

## Risks (mitigated in code)

Source mutation fail-closed; no silent overwrite (fail-closed); private trackers enforced; cancel/rollback pre-seed; seed via durable add path; symlink-safe destination walk.

UX notes (not automatic bugs): sheet does not auto-dismiss; no post-create Reveal in Finder.

## ADR

**No new ADR.**

## Implementation plan

Only step until Human live results:

### LIVE-CHECKLIST-001 — Human Creator acceptance

Run on current signed Debug build with working agent. Report pass/fail per row.

| # | Check | How |
|---|---|---|
| C1 | Entry visible | Menu **File → Create Torrent** or **⌘⌥N** opens sheet titled Create Torrent |
| C2 | Source browse | Choose a small folder or file; inspection runs; file count + total size appear |
| C3 | Output browse | Choose existing destination folder; default name acceptable |
| C4 | Format | Switch v1 / v2 / hybrid; inspection remains valid or re-inspects cleanly |
| C5 | Trackers | Add URL; optional second tier; private toggle with empty trackers shows clear error |
| C6 | Commit | Create succeeds; progress stage/bytes/files update; no crash |
| C7 | Output artifact | `.torrent` exists at chosen output; opens/parses in Torrentino (add) or external tool |
| C8 | Seed option | With start seeding on: new transfer appears and is healthy/actionable |
| C9 | Cancel | Start create on larger folder; Cancel before finish; no valid-looking partial `.torrent` left |
| C10 | Source safety | Source folder contents unchanged after create |
| C11 | Overwrite fail-closed | Point output at existing `.torrent` name → clear failure, original preserved |
| C12 | Localization | RU UI strings present for main creator labels (spot-check) |

**Pass rule:** C1–C8 + C10 required for “Creator accepted”. C9/C11 strongly recommended. Failures → Orchestrator opens narrow Coder fix lanes (not rebuild).

## Orchestrator routing after Human

- All required checks pass → record acceptance; keep freeze or open only requested polish.
- Any fail → FEEDBACK bug entries + Coder lane with exact repro; Reviewer → Tester.
- Do **not** open Option B polish lanes without Human request or live fail evidence.
