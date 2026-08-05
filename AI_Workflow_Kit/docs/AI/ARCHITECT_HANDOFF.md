# Architect → Orchestrator handoff — WP-11 Creator contract retry

## Feature / Change

Это **один чистый retry текущего WP-11**, не новый WP и не перенос его обязательных stop-gates в WP-12 или RELEASE. Цель остаётся ровно плановой: production-correct CPU-only creator v1/v2/hybrid без зависимости от Metal. Retry закрывает шесть записанных Reviewer contract/evidence blockers: binding plan token к полному option snapshot, source generation при output внутри source tree, race-safe destination transaction, независимые v1/v2/hybrid identity/recheck доказательства, конечную §15.5 matrix и отображение authoritative progress UI.

## Decision summary (ADR id)

- **ADR-016 — WP-11 Creator commit is option-bound, descriptor-anchored, and independently verified.**
  - Token означает агентский immutable plan, а не состояние SwiftUI. План структурно связывает source path, весь canonical `CreateOptions` snapshot, ordered tracker tiers, resolved output, source generation и destination identity. `CommitCreateRequest` несёт полный immutable asserted `CreateOptions`; до любой работы agent требует canonical structural equality asserted snapshot с snapshot этого token. Криптографический token payload не нужен: token opaque и единственный authority — actor `CreatorPlanStore`.
  - UI обязан синхронно инвалидировать token для **каждого** изменения source path, output path, format, любой операции с tracker tiers/URL и их порядком, private, manual/automatic piece size, comment, source tag, start seeding и hidden-file option. Пока request повторного inspect не вернул ответ для той же revision полной формы, commit disabled. Поздний ответ старой revision отбрасывается. Даже при ошибочном вызове commit после mutation current asserted snapshot не совпадёт со старым plan и будет отклонён до hashing/writing.
  - Source generation — root device/inode плюс полный includable manifest и scan policy; directory mtimes не являются generation equality. Исключается только exact planned output leaf. Включённый файл, root identity, file membership/identity/size/high-resolution mtime изменились — fail closed на pre-hash, post-hash и pre-seed rechecks. Созданный allowed `.torrent` внутри source tree не считается source mutation и остаётся после успеха.
  - Destination parent существует уже на inspect, descriptor-walk без symlink фиксирует `st_dev`/`st_ino`; commit требует ту же identity. После acquisition все leaf actions строго descriptor-relative: no-replace check, `openat` temp creation, full write/sync/close, no-replace rename, final `openat` read, verification, rollback `unlinkat` и directory durability. Никаких output path-based temp/read/delete fallbacks. Любой identity/symlink/durability/cleanup error — fail closed; unresolved cleanup явно возвращается как storage failure и никогда не означает success/seeding.
  - `HashingResult.v1InfoHash` удаляется как ложный placeholder. Expected v1 SHA-1 и v2 SHA-256 вычисляются только после metadata generation из exact raw bencoded `info` span. Final bytes, прочитанные из anchored final FD, must be parsed through the pinned libtorrent bridge; returned v1/v2 identities точно сравниваются с independently computed bytes и requested format shape. Domain piece/root/layer and manifest checks остаются дополнительными, но не называются независимой проверкой.
  - Публичный creator progress contract **не сужается**: sheet показывает stage, backend, processed/total bytes, processed/total files, ETA (либо explicit unavailable), percent и cancellation requested/terminal state. `OperationID` filtering распространяется на каждое отображаемое поле.

### Six blocker contracts, failure semantics, and observable acceptance

1. **CreatorPlanToken / UI options — selected contract: invalidation + immutable structural binding.**
   - **Invariants:** The agent never derives options at commit from UI; it accepts only the complete immutable asserted `CreateOptions` from `CommitCreateRequest` after canonical equality with the immutable plan snapshot. The UI has no committable token while dirty or inspecting. Tracker tiers are an ordered `[[String]]`; no deduplication/normalization may reorder tiers or URLs after validation. A token is one-shot and is consumed only on a successful terminal commit.
   - **Failure semantics:** Unknown/expired/invalidated token, stale inspection revision, or asserted-options mismatch produces a re-inspect-required failure before hashing/writing. It creates neither output nor seed. Option validation remains fail-closed (including private-tracker admission).
   - **Why §15 is met:** §15.1 form values and §15.4 immutable inspect → commit contract are represented by the same plan; UI is explicitly not source of truth.
   - **Acceptance:** For each option listed above, mutate it after inspection and prove: old token + current asserted options is rejected before hashing/writing; a response for an older async inspection cannot re-enable commit; the newly inspected token plus matching asserted snapshot produces metadata/seed behavior for the new value. A multi-tier vector proves exact tier order and URL order in the emitted announce-list, plus private, piece size, comment/source, format, output location, hidden-file manifest effect, and start-seeding effect.

2. **Output inside source tree — selected contract: manifest generation, not directory-mtime generation.**
   - **Invariants:** Source root identity stays fixed; every includable file entry is rechecked exactly as §15.4 requires. The exact resolved output leaf is excluded consistently from inspection and every rescan. Root or ancestor directory mtime alone is diagnostic only, never equality evidence; a newly added included file is still caught because canonical membership differs.
   - **Failure semantics:** Any included content/addition/removal/replacement/root identity drift fails before publication or triggers anchored rollback before terminal success. An excluded output write alone cannot trigger this failure.
   - **Why §15 is met:** This preserves “source is not modified,” required source-epoch checks and “output inside source tree is excluded” simultaneously; it removes only an unobservable/ambiguous directory-mtime signal, not file-generation validation.
   - **Acceptance:** End-to-end inspect → commit with `output.torrent` inside the source directory succeeds; final output remains at that path, was absent from the source manifest, passes independent recheck, and source payload file identities/bytes are unchanged. Separate tests add/replace/delete an includable file at pre-hash, during hashing, and after final write/pre-seed; each fails closed and no final/temp/seed remains.

3. **Destination directory safety — selected contract: inspection-bound identity plus descriptor-relative transaction.**
   - **Invariants:** The planned destination is an existing descriptor-resolvable directory with a single valid leaf name. At inspect its device/inode are recorded; at commit a component-wise no-follow descriptor walk must resolve the same identity. The acquired directory FD (and an anchored duplicate retained for rollback) owns every operation on temp/final names. Temp and final are regular files, created no-replace with restrictive mode; final is never overwritten.
   - **Failure semantics:** Missing destination, unsafe symlink/path component, directory identity mismatch, existing final, write/ENOSPC, file sync, rename, parent sync, final read/verification, cancellation before linearization, or rollback error fails closed. Before success, injected failures must leave neither final nor matching temporary artefacts. If the OS prevents confirmed descriptor-anchored cleanup, return an explicit unresolved-cleanup storage failure, do not seed or report success, and never attempt an unsafe pathname cleanup.
   - **Why §15 is met:** Temp remains on the output filesystem; data sync precedes no-replace atomic rename; directory durability follows it; rename/fsync failure cannot be turned into a successful-looking creator result. The contract is macOS-compatible and accurately limits its claim to FD-anchored operations.
   - **Acceptance:** A deterministic swap before commit replaces the selected directory with a symlink/substitute and fails identity/no-follow with zero writes in either substitute. A swap after the FD identity barrier proves temp/final/verification/rollback target only the captured directory identity, never the replacement path; a required current-path identity recheck before publication prevents success when the controlled swap is observed. Assert no temp/final leak after each failure injection and that an existing final is unchanged.

4. **Independent metadata and info hashes — selected contract: remove placeholder; raw-span expectations + libtorrent verifier.**
   - **Invariants:** `HashingResult` contains only content piece hashes/Merkle artifacts. Exact raw bencoded `info` bytes are the sole input to expected SHA-1 v1 and SHA-256 v2 identities after metadata exists. v1 expects only v1; v2 only v2; hybrid exactly both. The bridge’s pinned libtorrent parser reads the FD-anchored final bytes and must return the same byte-for-byte identities and valid shape. Existing Swift semantic verification continues to compare manifest, v1 pieces, v2 roots and piece layers.
   - **Failure semantics:** Missing, unexpected, malformed, or byte-unequal v1/v2 identity; libtorrent parse error; format-shape mismatch; or semantic mismatch is corrupt-data failure followed by anchored rollback and no seeding.
   - **Why §15 is met:** This fulfills §15.4 independent parse/recheck without a circular `MetainfoParser` round trip, and checks the two identities that identify the exact encoded `info` dictionary.
   - **Acceptance:** Immutable external-style v1, v2 and hybrid vectors carry pinned expected identities. Tests prove the raw-span computation and libtorrent result match the vectors and one another; generated v1/v2/hybrid outputs are loaded from final files by libtorrent and match expected presence/exact bytes. A real libtorrent add-with-source/force-recheck test reports successful data recheck for each format; it is not replaced by the Swift parser.

5. **§15.5 evidence — selected contract: deterministic, stage-complete verification matrix.**
   - **Invariants:** A green aggregate count is not evidence. Each irreversible boundary has a deterministic test control and observable filesystem/operation result. No test substitutes read-only permissions for ENOSPC, or a direct closure cancel for the creator’s UI/IPC cancellation path.
   - **Failure semantics:** The test-only controls inject only a named boundary; production has no user-reachable fault arming. Every failure/cancel pre-success asserts terminal typed outcome, no final/temp artifact, unchanged source, and no seed admission. At seeding, cancellation is tested before admission; after durable admission the operation linearizes to success rather than an inconsistent cancelled state.
   - **Why §15 is met:** It gives concrete proof for cancel at every §15.3 stage, disk-full/durability failures and all listed edge classes without weakening source, atomic-output or independent-recheck gates.
   - **Acceptance:** The matrix below is mandatory evidence for WP-11 Reviewer approval; retain all existing regression cases and add/strengthen the specified rows.

6. **Authoritative progress UI contract — selected contract: full projection, not scope reduction.**
   - **Invariants:** Creator progress events for the active `OperationID` are authoritative. Every creator stage supplies known plan totals where available; hashing counters are monotonic; ETA may be unavailable but UI must render that fact rather than inventing a value. Cancel request produces visible “cancelling” state until its matching terminal outcome. Foreign/stale operation events mutate no creator progress, detail, cancellation or terminal field.
   - **Failure semantics:** A malformed/missing optional detail is displayed as unavailable, never fabricated. Cancel transport failure is surfaced as a command error; it cannot reset the operation ID or falsely claim cancellation. A matching failed/cancelled completion clears the active operation only after the visible terminal outcome is recorded.
   - **Why §15 is met:** §15.3 explicitly requires bytes, files, ETA, backend and Cancel. Keeping the existing IPC DTO authoritative and rendering it satisfies that requirement without new product capability.
   - **Acceptance:** A UI/view-model projection test injects a complete matching detail and observes all required display-model fields; then injects another operation ID and observes no change; then injects matching cancellation progress/completion and observes cancellation state. A creator IPC integration test asserts tracker-tier ordering and progress DTO bytes/files/ETA/cancellation values cross the command/event boundary.

## Docs updated

- `AI_Workflow_Kit/docs/DECISIONS.md`: ADR-016 appended.
- `AI_Workflow_Kit/docs/AI/ARCHITECT_HANDOFF.md`: this complete WP-11 retry handoff replaced the template.
- Not updated: `STATE.yaml`, `FEEDBACK.md`, plan/WP cards, Git state, product code and tests.

## Recommended track / WP

1. **WP-11 retry — Creator contract closure and verification evidence.** Depends on: no later WP. All existing WP-11 §15.4/§15.5 gates remain stop-gates in this retry; do not create WP-12 or RELEASE work to absorb any of them.

### Required ordering and parallelism boundaries

1. **Freeze fundamental contracts first (single serial owner):** canonical plan-option binding/revision invalidation, resolved output/destination identity, manifest-based source generation, removal of the false `v1InfoHash` promise, and the raw-info identity contract. These share `CreatorPlanStore`, `CreateOptions` meaning and terminal failure semantics; they must not be patched independently.
2. **Implement one integrated execution transaction second (serial with step 1):** descriptor-only output transaction, rollback/durability semantics, FD-anchored read, and libtorrent verifier bridge. Destination safety, verification and source post-write recheck are one commit path; they cannot safely be parallelized or merged as isolated fixes.
3. **Project UI only after the contracts are frozen:** form invalidation/reinspection and full progress/cancellation presentation can proceed together after step 1 defines token and detail state. It must not race a changing option snapshot or progress lifecycle contract.
4. **Add evidence after the implementation boundaries exist:** deterministic stage/failure controls, XPC command/event integration, destination race, external vector/libtorrent recheck and UI projection tests. Test work may parallelize by target only after steps 1–3 are stable; Tester makes no product fixes.

### Mandatory verification matrix (invariant → level / control → observable assertion → owning target/file)

| Gate / invariant | Test level and deterministic control | Observable assertions | Owning target/file |
|---|---|---|---|
| Full option snapshot and token freshness | App/UI projection + agent/XPC integration; mutate one field at a time after inspect, submit old token with new asserted snapshot, out-of-order inspect completion | old token disabled/rejected before hashing/writing; only matching plan/assertion commits; output metadata/seed action matches each changed field | `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift` |
| Ordered tracker tiers | Agent integration with multi-tier/multi-URL fixture | exact tier and URL ordering survives inspect → final bencode/libtorrent parse; no stale private-without-tracker commit | `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |
| Excluded output inside source vs real source mutation | End-to-end CreatorPlanStore integration; output under source; controlled included-file add/replace/delete at three recheck boundaries | final remains on success; output absent from manifest; source payload unchanged; real mutation fails with no final/temp/seed | `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |
| Destination identity and no path escape | Adversarial filesystem integration; destination symlink/substitute swap before FD acquisition and barrier-controlled swap after | identity/no-follow rejection before write, or all transaction effects constrained to captured identity; replacement dir untouched; no temp/final leak after failure | `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |
| Atomic write/durability and disk full | Creator output syscall/fault seam injects ENOSPC on write, temp-file sync failure, rename failure, parent sync failure, final-read/verifier failure | correct terminal storage/corrupt fault; final and matching temp absent; existing final unchanged; source unchanged; no seed admission | `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |
| Cancellation at Scanning, Hashing, Writing, Verification, Seeding | Encoded `.commitCreate` / `.cancelOperation` command path with a stage latch at each boundary; app cancel projection separately | matching cancelled outcome; no final/temp and no seed before admission; UI shows cancelling then matching terminal state; post-admission cancellation deterministically completes success | `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift`; `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift` |
| Exact v1/v2/hybrid info identities | Domain vector unit plus bridge/agent integration; immutable externally-derived fixtures and generated final files | expected raw-info SHA-1/SHA-256 equals libtorrent return; v1/v2 presence exactly matches selected format | `Native/Tests/TorrentinoDomainTests/TorrentCreatorDomainTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |
| Independent generated torrent recheck | Real pinned libtorrent integration: load final file with source save path, force recheck and await outcome; no Swift-parser-only substitute | v1, v2 and hybrid recheck all succeed against source data; bridge identities exactly match | `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` (or existing linked bridge test target only if the XCTest target cannot instantiate the real bridge) |
| Progress DTO and operation isolation | IPC command/event integration plus view-model projection with complete/foreign/cancel details | bytes/files/ETA/backend/stage/cancel all represented; foreign operation ID changes nothing | `Native/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift`; `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TransferSmokeTests.swift` |
| Remaining §15.5 edge cases | Preserve and strengthen existing Domain/Agent regressions: empty folder, zero byte, unreadable/disappearing source, volume/destination failure, Unicode collision, long path, bounded large file count, passkey, invalid manual size | typed fail-closed results and no artifacts where output was not successfully committed | `Native/Tests/TorrentinoDomainTests/TorrentCreatorDomainTests.swift`; `Native/Tests/TorrentinoEngineAgentTests/TorrentCreatorAgentTests.swift` |

## target_files (for first coding step)

```yaml
target_files:
  - Native/TorrentinoIPC/Commands.swift
  - Native/TorrentinoDomain/CreatorPlanStore.swift
  - Native/TorrentinoDomain/SourceScanner.swift
  - Native/TorrentinoDomain/HashingTypes.swift
  - Native/TorrentinoDomain/CPUHasher.swift
  - Native/TorrentinoDomain/MetainfoIdentity.swift # new: raw-info identity boundary, if not placed in an existing Domain file
  - Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift
  - Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift
  - Native/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift
  - Native/TorrentinoEngineBridge/bridge/EngineBridge.h
  - Native/TorrentinoEngineBridge/bridge/EngineBridge.cpp
  - Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.h
  - Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm
  - Native/TorrentinoIPC/Events.swift
  - Native/TorrentinoApp/EngineClient/EngineClient.swift
  - Native/TorrentinoApp/Features/TorrentListViewModel.swift
  - Native/TorrentinoApp/Features/CreateTorrentSheet.swift
  - Native/TorrentinoApp/Resources/Localizable.xcstrings
```

This list is intentionally limited to the six blockers’ contract and execution boundaries. Test-only files are assigned in the matrix to the Test Engineer after the product retry; no `Legacy/` path is permitted.

## Non-goals

- Metal implementation, a Metal gate, or any dependency on Metal; CPU remains mandatory and sufficient.
- New product capabilities outside Creator (new transfer features, tracker redesign, unrelated persistence/UI redesign).
- A broad IPC, Xcode project, engine-session or architecture rewrite unrelated to the six blockers.
- Any new WP, deferral of a WP-11 stop-gate to WP-12/RELEASE, release tagging, commits, branch work, or separate security/release engagement.
- Reading, changing, staging, restoring, using as a reference, or otherwise touching anything under `Legacy/`.

## Open questions for Human

- None. Plan §15, the current ADRs and the pinned libtorrent bridge provide enough authority to choose the safe contracts above. The pre-existing, non-symlink destination-parent requirement is an explicit ADR-016 safety tradeoff, not a decision deferred to Human.

## Next human action

Передать handoff Оркестратору. Оркестратор должен сохранить работу в **WP-11**, обновить только своё workflow-состояние по своей роли и выдать один упорядоченный Coder retry по этому документу; затем обычный Reviewer → Tester цикл проверит matrix без переноса stop-gates.

## WP-11 Escalation Addendum — Structured Tracker Topology and Domain Fault Parity

### Scope

Это узкий architecture escalation packet для **того же WP-11**, а не новый Work
Package. Он закрывает ровно два оставшихся product contract defects из верхнего
`FEEDBACK.md`:

1. ordered tracker topology не проходит целиком через durable persistence,
   Creator admission, restart, fetch/edit и live bridge;
2. standalone Domain fallback не имеет полного Creator `EngineFault` factory
   surface, хотя production IPC surface уже имеет его.

Authority для этого addendum: plan §15.1–§15.5, ADR-016, затем текущий
`FEEDBACK.md` и actual Native interfaces. Уже принятые Creator contracts не
пересматриваются. `[[String]]` topology в `CreateOptions`, генераторе и parser
остаётся исходной формой; исправляется только ownership после этой границы.

### Decision summary

- **Canonical tracker model:** architecture name `TrackerTopology`, concrete
  Swift value `[[String]]`. Existing `Codable`/`Sendable` immutable DTOs carry
  this value in fields named `trackers` or `trackerTiers`; a second nominal
  wrapper is not introduced in this retry. The nested arrays are the only
  structured source of truth.
- **Topology invariants:** tier order and URL order are significant; repeated
  valid URLs are preserved; an outer empty topology `[]` means no trackers and
  is valid only for a non-private torrent; an inner empty tier is invalid;
  private admission requires at least one URL; the existing URL policy and
  512-total-URL bound remain the validation policy.
- **Durable authority:** add a schema-v3 `torrent_tracker_topology` table with
  a versioned JSON value. The old `session_state` JSON `[String]` value remains
  migration input only and is never a lifecycle source.
- **Engine authority:** structured edit crosses Swift as `[[String]]`, the
  bridge adapter as nested JSON, and C++ as nested tier vectors. The scalar
  bridge edit API is removed; old scalar payloads are rejected rather than
  mapped to one-URL tiers.
- **Fault authority:** production `TorrentinoIPC.EngineFault` and its frozen
  `EngineErrorCode` vocabulary remain the only wire/user-facing authority. The
  Domain fallback is a compile-only API mirror with exact Creator factory names
  and classifications, not a second production error universe.
- **ADR:** ADR-016 is insufficiently explicit about post-admission persistence
  and bridge ownership. One narrow ADR-017 is appended to
  `AI_Workflow_Kit/docs/DECISIONS.md`; no ADR is created for formality for the
  fallback mirror itself.

### Canonical tracker topology contract

**Concrete immutable DTO value**

- The canonical structured value is ordered `[[String]]`; every outer element
  is one announce-list tier and every inner element is one URL position.
- `CreateOptions.trackers` remains the complete requested topology, not a flat
  tracker list. `Metainfo.trackerTiers`, `TransferRecord.trackerTiers`,
  `EditTrackersRequest.trackerTiers`, the persistence value and the bridge edit
  payload all carry the same nested shape.
- Enclosing DTOs remain immutable `let` values and conform to the existing
  `Codable`, `Sendable` and `Equatable` contracts. No class, mutable shared
  buffer, `Set`, dictionary keyed by URL, or URL-as-identity map may represent
  the lifecycle topology.
- Validation is performed before admission/use at Creator options validation,
  metainfo generation, metainfo parse, persistence restore, structured edit and
  bridge decode. Validation preserves bytes, order, tier boundaries and
  repeated entries; it does not trim, deduplicate, sort or normalize a valid
  URL.
- `[]` is the only valid no-tracker topology. `[[]]`, `[[], ["url"]]` and any
  other empty inner tier are invalid. A generated no-tracker metainfo omits
  `announce` and `announce-list`; an input empty `announce-list` has the same
  semantic result `[]`. A non-empty topology emits `announce` equal to the
  first URL of tier zero and an `announce-list` whose nested list is byte-order
  equivalent to the requested topology.

**Boundary map**

| Boundary | Required value and authority |
|---|---|
| `CreateOptions` | Complete asserted `[[String]]`; canonical snapshot retains exact tier/URL sequence. |
| Generated metainfo | `announce-list` is nested in exact tier order; scalar `announce` is a derived BEP-3 field only. |
| Metainfo parse | Parsed `trackerTiers` is the exact nested announce-list; repeated URLs remain distinct. |
| Creator admission | `CreatorPlanStore` validates requested topology before work and compares parsed generated topology with the requested value before seed admission. |
| Durable persistence | Versioned structured JSON stores nested tiers; no flattening. |
| Restart restore | Structured durable value and parsed metainfo must agree; neither is reconstructed from a flat value. |
| Fetch/projection | `TrackerEntry.tierIndex` and `TrackerEntry.urlIndex` are zero-based, stable positions in tier-major/URL-major order. |
| Structured edit | Complete replacement of `[[String]]`; repeated URL removal, if exposed by UI, removes one indexed occurrence only. |
| Engine coordinator/bridge | JSON contains nested `tracker-tiers`; C++ receives nested vectors and assigns each URL its requested tier. |

**Flat compatibility rule**

- `Metainfo.trackers` and `TransferRecord.trackers` may remain only as derived,
  read-only `trackerTiers.flatMap { $0 }` projections for existing presentation
  consumers. They must not be persisted, used to restore a record, used to
  build a structured edit, used to roll back an edit, or used as the Creator
  admission source.
- A page is allowed to be a linear list of `TrackerEntry` rows because each row
  carries both structured indices. Repeated URLs are different rows and must
  not use URL text as the UI identity.
- `addedURLs`/`removedURLs` are not an accepted lifecycle edit representation.
  The existing fields may remain only to decode an older command shape; when
  `trackerTiers` is absent, the agent returns typed `invalidPayload` and does
  not reconstruct topology from those scalar arrays.
- No code may use a fallback equivalent to
  `persistedTrackers?.map { [$0] }`, `flatMap` followed by persistence, or a
  scalar bridge payload to recreate or overwrite tier boundaries.

### Persistence and migration contract

**Schema and value format**

- Increase the persistence schema to v3 and add one table, using the existing
  SQLite WAL/checksum/generation discipline:

  ```sql
  CREATE TABLE torrent_tracker_topology (
      torrent_id TEXT PRIMARY KEY NOT NULL REFERENCES torrents(id) ON DELETE CASCADE,
      topology_json BLOB NOT NULL,
      checksum TEXT NOT NULL,
      generation INTEGER NOT NULL
  )
  ```

- `topology_json` is the UTF-8 JSON encoding of the versioned v1 envelope:

  ```json
  {"version":1,"tiers":[["tracker-A","tracker-B"],["tracker-A","tracker-C"]]}
  ```

  The `tiers` array is ordered and is compared as an array, never as a set. The
  existing checksum and generation fields cover the exact stored JSON bytes.
- New persistence APIs are structured, for example
  `setTorrentTrackerTiers(... [[String]])` and
  `torrentTrackerTiers(...) -> [[String]]?`. A method returning the old
  `[String]` representation may exist only under an explicitly named migration
  path and may not be called by normal restore, admission, fetch or edit.
- The stored metainfo bytes remain durable and must contain the same parsed
  topology. They are an independent consistency check, not permission to
  replace the structured table with a flattened projection.

**Migration and restart**

- For a pre-v3 record with valid durable metainfo, parse the metainfo first and
  backfill the v1 structured row from its exact `trackerTiers`. This is the only
  allowed reconstruction during migration; the legacy flat array is not used.
- If both structured data and metainfo exist, restore succeeds only when their
  topologies are exactly equal. A mismatch is corrupt data and must not choose
  one copy silently.
- A pre-v3 record with only legacy `torrent_trackers.<id>` JSON `[String]` has
  insufficient information to recover tier boundaries. Mark it unsupported or
  quarantine it with a typed failure; do not map each URL to a singleton tier.
  The record must not be re-added to the engine, exposed as a successful
  structured fetch, or edited until a new structured representation exists.
- Missing structured data without authoritative metainfo is also fail-closed;
  absence is not proof of an empty topology. New records always write an
  explicit `[]` when the public topology is empty.
- Corrupt JSON, unsupported envelope version, checksum failure, failed
  metainfo reconstruction or failed v3 migration leaves the durable record
  intact for diagnostics, publishes no healthy in-memory record and does not
  fall back to the old flat key. The error is typed and localized at the
  existing engine boundary.
- Restore must not use `try?` to hide topology decode/migration errors. A
  restored record is visible only after its structured topology has been
  decoded, validated and reconciled with metainfo.
- Structured topology, metainfo bytes and the record journal follow the
  existing persist-before-visible rule. Edit rollback restores both the prior
  structured JSON and prior metainfo bytes; a failed rollback is a storage
  failure, never a successful edit.

### Admission/fetch/edit/bridge contract

**Creator admission**

- The requested topology in `CreateOptions` is validated before scan/hash/write
  and remains the asserted value through `CreatorPlanToken`.
- After `MetainfoGenerator` produces bytes, `MetainfoParser.parse` must return
  exactly the requested `trackerTiers`. Any missing tier, changed URL order,
  deduplication, flattening or scalar reconstruction is corrupt-data failure
  before seed admission.
- `admitCreatedTorrent` continues to use the common durable add path. Its
  `handleCommitAdd` receives the parsed structured topology, stores it in the
  v3 table and only then publishes the `TransferRecord`; the exact generated
  metainfo bytes are the input to engine add.
- Private-tracker admission remains unchanged in meaning: a private torrent
  with zero URLs is rejected before persistence/engine work, with no bypass via
  a scalar compatibility field.

**Fetch and UI projection**

- The agent flattens only into ordered `TrackerEntry` rows for pagination. The
  row sequence is tier 0 URL 0..n, tier 1 URL 0..n, and so on.
- `tierIndex` and `urlIndex` are zero-based and refer to the canonical nested
  topology. `totalCount` counts URL occurrences, not unique URL values or
  tiers. A repeated URL has a distinct pair of indices and a distinct row.
- Cursor pagination must preserve this sequence across pages and use the
  record revision already returned by the page. Empty topology returns zero
  rows; an empty inner tier can never produce a row because it is invalid.
- UI add/remove operations submit a complete structured replacement. Adding
  to an empty topology creates one tier; removing an occurrence uses its
  `(tierIndex, urlIndex)` position and removes only that occurrence. A tier is
  removed only when its last URL is explicitly removed, so no empty tier is
  sent.

**Structured edit and idempotency**

- An accepted `EditTrackersRequest` contains a complete `trackerTiers` value and
  no non-empty delta fields. The request is validated before metainfo rewrite,
  persistence or engine call.
- The requested sequence is persisted and applied exactly. No deduplication,
  tier collapse, URL sorting or scalar rewrite is allowed. A public torrent
  may explicitly become `[]`; a private torrent may not.
- The existing `idempotencyKey` applies to the complete topology. Replaying the
  same key and identical topology is an idempotent acknowledgement. Reusing it
  with a different topology is `creatorOperationConflict`/idempotency conflict
  and changes nothing.
- Durable structured state and updated metainfo are staged before the record
  revision is published. If live engine edit rejects the topology, both
  durable values are restored and the in-memory record/revision is unchanged.

**Engine coordinator and bridge**

- Swift engine edit accepts `[[String]]` and encodes this exact payload shape:

  ```json
  {"torrent-id":"<id>","tracker-tiers":[["tracker-A","tracker-B"],["tracker-A","tracker-C"]]}
  ```

- The bridge adapter decodes only the nested `tracker-tiers` array for this
  operation. A scalar `trackers` key, a mixed payload, an empty inner tier, an
  invalid URL or an over-limit topology is rejected before calling C++.
- `EngineBridge::editTrackers` accepts a nested C++ vector (or an equivalent
  bridge-private structured value), validates every URL, preserves vector
  order/repetition and assigns the outer index as the libtorrent announce
  tier when constructing `announce_entry` values. Swift sees only Codable
  `[[String]]`; no C++ type crosses the Swift/ObjC++ boundary.
- The scalar signatures
  `EngineCoordinator.editTrackers(... trackers: [String])`,
  `TransferEngine.editTrackers(... trackers: [String])`,
  `EngineBridge::editTrackers(... vector<string>)` and the adapter's scalar
  JSON contract are removed or narrowed to reject-only compatibility stubs.
  The accepted live edit path is structured end-to-end.

### Standalone Domain fault-surface contract

**Selected boundary model: exact fallback parity**

- `Native/TorrentinoIPC/ErrorContract.swift` owns the production wire fault
  vocabulary, stable raw codes, localization keys, recovery actions and
  `redactedContext` semantics. Its six Creator factories are already the
  production authority and must remain localized as they are.
- `Native/TorrentinoDomain/HashingTypes.swift` fallback declarations are
  compile-only mirrors used only when `canImport(TorrentinoIPC)` is false. They
  must expose the same Creator factory names, callable signatures and stable
  classifications required by `CreatorPlanStore`:

  | Factory | Code classification | Stable localization key |
  |---|---|---|
  | `creatorPrivateTrackerMissing()` | `invalidPayload` | `creator.fault.private_tracker_missing` |
  | `creatorStalePlan(details:)` | `invalidPayload` | `creator.fault.stale_plan` |
  | `creatorAssertionMissing(details:)` | `invalidPayload` | `creator.fault.assertion_mismatch` |
  | `creatorAssertionMismatch(details:)` | `invalidPayload` | `creator.fault.assertion_mismatch` |
  | `creatorOperationConflict(details:)` | `idempotencyConflict` | `creator.fault.operation_conflict` |
  | `creatorCancelled(details:)` | `operationCancelled` | `creator.fault.cancelled` |

- Default detail strings and recovery-action semantics must match the
  production factories. The fallback vocabulary must include the conflict
  classification it uses; it must not invent a second Creator-specific code.
- Fallback `EngineFault.errorDescription` returns a safe stable key or code,
  never `redactedContext`. Technical details remain diagnostics-only in both
  builds. Domain code may throw the stable generic factories it already needs
  (`invalidPayload`, storage/corrupt/volume/cancelled and the six Creator
  factories), but it may not render localization, read `redactedContext` for a
  user message, or depend on C++/ObjC++/SQLite text.
- Production IPC and standalone fallback must not be compiled as two
  interchangeable definitions in one supported product artifact. Production
  Xcode builds compile Domain with `TorrentinoIPC` available, so the fallback
  branch is not emitted. A Domain-only smoke may compile the fallback; a
  combined standalone bridge build must compile/link IPC first, compile Domain
  with that module visible, and never link a fallback-built Domain module with
  the real IPC module.
- The four existing WP-04 helper failures are therefore split correctly:
  product contract work makes the fallback API complete; after that, the Test
  Engineer owns the helper's module ordering/current source list so the
  supported combined build exercises one type universe.

### Failure semantics

| Condition | Required typed result | Side effects allowed |
|---|---|---|
| Empty inner tier, invalid URL, >512 URLs, private empty topology, malformed structured bridge payload | `EngineFault.invalidPayload` or Creator invalid-options classification | No generated commit, persistence write, engine call, revision or seed. |
| Old flat-only durable representation | Explicit unsupported/corrupt topology failure using the existing typed fault boundary | Preserve row for diagnostics; no singleton-tier reconstruction, restore re-add, fetch success or edit. |
| Corrupt/unsupported structured JSON, checksum mismatch, metainfo/topology mismatch, migration reconstruction failure | Typed corrupt-data/storage failure | No healthy record publication; no engine admission; no scalar fallback. |
| SQLite/table/checksum/generation write failure | Existing persistence/storage fault (`storeError`/mapped storage classification) | No in-memory mutation; rollback any staged metainfo/topology; unresolved rollback is also storage failure. |
| Live engine rejects structured edit | Existing bridge-to-`EngineFault` mapping for the rejection | Restore prior durable values and metainfo; do not bump record revision or publish success. |
| Same idempotency key with a different topology or active edit conflict | Existing idempotency/Creator operation conflict | No persistence or engine mutation. |
| Creator fault presentation | Production stable localization key and recovery actions | `redactedContext` is diagnostics-only and never copied into a user-facing string. |

### Ordered Coder implementation sequence

1. Freeze the existing `[[String]]` topology semantics and the fallback
   `EngineFault` parity surface in IPC/Domain. Do not introduce a second
   tracker wrapper or a second production fault vocabulary.
2. Add the v3 structured persistence table/APIs and explicit migration result
   handling. Remove all normal-path reads/writes of the legacy flat value.
3. Close Domain generation/parse/Creator admission equality: validate the
   requested topology before work and compare parsed output topology before
   seed admission.
4. Change `TransferCoordinator` and `TransferRecord` restore/admission/edit
   ownership to structured topology. Keep any flat property derived-only and
   remove scalar persistence, rollback and Creator re-add use.
5. Make fetch pagination and UI edits position-aware. Submit complete
   structured replacements and preserve repeated URL occurrences.
6. Change the Swift engine protocol/coordinator DTO and ObjC++ adapter to the
   nested `tracker-tiers` payload, then change the C++ bridge to preserve tier
   indices and repetition.
7. Recheck the production Xcode module path and the standalone Domain/fallback
   path for one fault vocabulary per build. Do not repair helper scripts or
   test fixtures in the product retry.

The sequence is serial at steps 1–4. Bridge and UI work may proceed only after
the structured contract is frozen; evidence changes wait until the product
interfaces are complete.

### Product target files

The following is the complete narrow product list for the next retry. It
contains no tests and no QA scripts:

```text
Native/TorrentinoIPC/Commands.swift
Native/TorrentinoDomain/HashingTypes.swift
Native/TorrentinoDomain/Metainfo.swift
Native/TorrentinoDomain/MetainfoGenerator.swift
Native/TorrentinoDomain/CreatorPlanStore.swift
Native/TorrentinoEngineAgent/Persistence/PersistenceStore.swift
Native/TorrentinoEngineAgent/Transfer/TransferRecord.swift
Native/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift
Native/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift
Native/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift
Native/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift
Native/TorrentinoApp/Features/TorrentListViewModel.swift
Native/TorrentinoApp/Features/InspectorView.swift
Native/TorrentinoEngineBridge/bridge/EngineBridge.h
Native/TorrentinoEngineBridge/bridge/EngineBridge.cpp
Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.h
Native/TorrentinoEngineBridge/adapter/EngineBridgeAdapter.mm
Native/TorrentinoEngineAgent/Transfer/TorrentAdder.swift
```

Explicitly **not** product targets for this retry:

- `Native/TorrentinoIPC/Pagination.swift`: `TrackerEntry` already carries the
  required `tierIndex`/`urlIndex`; verify and consume those fields, do not
  replace them with URL identity.
- `Native/TorrentinoIPC/ErrorContract.swift`: production Creator factories and
  localization already provide the authoritative surface; only the fallback
  mirror is incomplete.
- `Native/TorrentinoApp/Features/CreateTorrentSheet.swift`: it already retains
  ordered `[[String]]`; invalid empty tiers continue to fail closed at the
  existing Creator validation boundary.
- `Native/TorrentinoApp/EngineClient/EngineClient.swift`, Xcode project files,
  `STATE.yaml`, `FEEDBACK.md` and all QA scripts.
- Unrelated magnet-only scalar compatibility code may not be promoted into the
  Creator topology lifecycle. The Creator `.torrent` path uses exact metainfo
  bytes; no new magnet capability is part of this packet.

### Test Engineer ownership after product review

Only after the product interfaces above compile, the Test Engineer owns the
evidence and fixture corrections. Product code must not be changed to satisfy
stale tests or static paths.

- Add the tracker vector evidence for generated bencode, parse, Creator
  admission, v3 JSON persistence, restart, paginated indices, structured edit,
  bridge payload and repeated URL/no-flatten assertions.
- Update the four WP-04 helper fixtures
  `test_wp04_bridge_swift.sh`, `test_wp04_dto_codable.sh`,
  `test_wp04_peer_id_config.sh` and `test_wp04_torrent_id_payload.sh` only as
  needed to use current source paths and the supported IPC-first module
  topology. The helper must never combine fallback Domain and production IPC
  type definitions.
- Add/retain standalone Domain compile evidence for all six Creator factories,
  production IPC compile evidence, and a combined-build duplicate-type check.
- Prove `redactedContext` is absent from user-facing Creator presentation while
  remaining available to diagnostics.
- Correct the already-classified stale tracker fixtures, including the old
  600-flat-URL expectation and any `record.trackers.count` static expectation,
  without weakening the 512 bound or structured topology assertions.
- No Test Engineer change is permission to alter product fault localization,
  persistence ownership, bridge signatures, or the existing accepted WP-11
  contracts.

### Non-goals

- No Metal work, Metal gate or Metal dependency.
- No new product capability outside the Creator tracker lifecycle.
- No broad engine, persistence, IPC, UI or Xcode-project rewrite.
- No mutation of existing WP-11 contracts except the necessary structured
  tracker lifecycle boundary and standalone fault-surface parity.
- No signing, release, security engagement or dependency work.
- No commit, tag, branch or push work.
- No deferred WP-11 stop-gate and no creation of WP-12/RELEASE work to absorb
  this defect.
- No QA-script, test-file, `STATE.yaml`, `FEEDBACK.md` or `Legacy/` changes in
  the Architect packet.

### Acceptance matrix

**Tracker topology vector**

Input vector, in exact order:

```text
tier 1: [tracker-A, tracker-B]
tier 2: [tracker-A, tracker-C]
```

| # | Boundary | Required proof |
|---|---|---|
| 1 | Generated bencode | `announce-list` contains exactly `[[tracker-A, tracker-B], [tracker-A, tracker-C]]` in that order; `announce` is `tracker-A`; no URL is removed or moved. |
| 2 | Metainfo parse | Parsed `trackerTiers` equals the input vector exactly, including both occurrences of `tracker-A`. |
| 3 | Creator admission | `CreateOptions`/plan validation, generated parse verification and `admitCreatedTorrent` all observe the same requested nested value before persistence/seed. |
| 4 | Durable persistence | v3 `topology_json` decodes to `{"version":1,"tiers":[["tracker-A","tracker-B"],["tracker-A","tracker-C"]]}`; checksum/generation are valid; no legacy `[String]` value is authoritative. |
| 5 | Restart/fetch | After shutdown and restore, `TransferRecord.trackerTiers` equals the vector; fetch returns four URL occurrences in tier-major order and reconstructs the same vector. |
| 6 | UI projection | Rows return `(tierIndex,urlIndex)` `(0,0)`, `(0,1)`, `(1,0)`, `(1,1)`; duplicate URL rows remain distinct and pagination does not reorder them. |
| 7 | Structured edit | A complete edit to another requested sequence, including repeated URLs and changed tier order, persists and fetches exactly that sequence. A delta-only request is rejected. |
| 8 | Live bridge edit | Swift DTO JSON uses nested `tracker-tiers`; adapter and C++ receive both tiers and both `tracker-A` occurrences, not only a flat URL vector. |
| 9 | Negative topology controls | No silent deduplication, flattening, reorder or scalar reconstruction occurs at any boundary; invalid inner tiers, malformed URLs and private-empty topology fail before side effects. |

**Standalone Domain vector**

| # | Boundary | Required proof |
|---|---|---|
| 1 | Standalone Domain build | Domain-only compilation succeeds when IPC is unavailable and the fallback declarations are selected. |
| 2 | Creator factories | `creatorPrivateTrackerMissing`, `creatorStalePlan`, `creatorAssertionMissing`, `creatorAssertionMismatch`, `creatorOperationConflict` and `creatorCancelled` all compile and expose the required classifications. |
| 3 | Production IPC build | Xcode/production IPC compilation succeeds and retains the existing catalog-backed Creator fault localization. |
| 4 | Combined supported build | IPC-first Domain compilation and bridge integration use one compatible fault/type universe; no fallback/IPC duplicate ambiguity or missing factory error remains. |
| 5 | Diagnostics boundary | `redactedContext` is available only to diagnostics; neither fallback `errorDescription` nor production user-facing Creator projection emits it. |
| 6 | WP-04 helper evidence | The four assigned WP-04 helpers can pass after their source-list/module-order fixture corrections; product code is not weakened to make stale fixtures compile. |

### ADR update decision

ADR-016 already fixes ordered tiers inside the immutable Creator option snapshot,
but it does not unambiguously assign that structured value as the durable
source of truth or require a nested live bridge edit payload. This escalation
changes the public command/engine-edit and persistence ownership boundary, so a
new narrow **ADR-017** is required and has been appended to
`AI_Workflow_Kit/docs/DECISIONS.md`.

No separate ADR is needed for fallback fault parity: production IPC remains the
only wire authority, and the fallback change is a compile-only compatibility
mirror with no new product API or localization behavior.

### Open questions for Human

None blocking. This packet deliberately chooses fail-closed behavior for
legacy flat-only records. Supporting recovery of unknown tier boundaries would
require a separate product decision and must not be smuggled into this WP-11
retry as singleton-tier reconstruction.

### Next human action

Вернуться к Оркестратору в рамках **WP-11** и сказать «статус» или «приступай».
Новый Work Package и новый role prompt для этого escalation packet не нужны.
