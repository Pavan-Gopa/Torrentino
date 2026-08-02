# WP-05 Implementation Feedback

## RESULT: waiting_review

## WP-05 Reviewer CHANGES_REQUESTED — 3 fixes applied

1. **HIGH — PeerValidation without automated tests**
   - Added 5 tests in `Native/Tests/TorrentinoAppTests/TorrentinoAppTests.swift`: nonexistent path → `.agentBinaryNotFound`; unsigned/dummy file → rejected (`.unsignedPeer` or `.codeSigningUnavailable`, OS-dependent); frozen `expectedAgentRequirement` pins `identifier "com.torrentino.app.engine-agent"` + `certificate leaf[subject.OU] = "438UQRF7JV"` and still compiles; invalid requirement expressions rejected (the `.requirementInvalid` guard); `isEnforcementActive` false in Debug / true in Release.
   - `PeerValidation.swift` registered in the TorrentinoAppTests target Sources (pbxproj) so the tests exercise the real production code.
2. **LOW — Handshake.negotiate comment/behavior mismatch**
   - `Handshake.swift`: negotiation now returns the floor (smallest overlapping version = most conservative), matching the documented invariant; new test `testHandshakePicksMostConservativeOverlap` pins the behavior.
3. **LOW — testEnvelopeEventKindValidation incomplete**
   - Added case: event envelope carrying a command payload → `.unexpectedPayload`.

Verification: `xcodebuild test ... -only-testing:TorrentinoIPCTests -only-testing:TorrentinoAppTests` → ** TEST SUCCEEDED ** (82/82).

## Summary
Torrentino XPC protocol v1 (WP-05) implemented: versioned IPC contract framework `TorrentinoIPC` (16 files, 32 commands / 11 events / discriminated-union envelopes), agent handshake negotiation, UI-side peer code-signing policy, and a 73-test contract suite. Full scheme builds clean (0 warnings), contract tests 73/73 green, QA regression 45/45 GREEN.

## Files Created/Modified

### Native/TorrentinoIPC/ (new contract framework, versioned)
- **Identity.swift** — TorrentRecordID, ContentIdentity, AddOperationID, OperationID, RequestID, IdempotencyKey (UUID-based, Codable+Sendable)
- **State.swift** — DesiredTorrentState, TorrentActivity, TorrentHealth, TransferProgress/Rates, PeerSummary, FileSelectionItem, PersistedLocation, TransferLimits, AddSource, ProxyConfiguration, EngineLifecycleState
- **Snapshot.swift** — TorrentSnapshot, EngineSnapshot, TorrentDelta (+ revision/sequence model)
- **ErrorContract.swift** — EngineErrorCode (24 frozen codes), FaultSeverity, EngineFault (stable localizationKey `fault.<rawValue>`, recovery actions, redacted context) + factories
- **Pagination.swift** — PageCursor/FileCursor, Page<T>, FileEntry/PeerEntry/TrackerEntry/ActivityEntry/RemovalManifestEntry/CreatorManifestEntry, PageSize.maximum=200
- **Settings.swift** — EngineSettings, SettingsRules (pure validation), SettingsTransaction (validate → revision check → persist → apply → rollback, injected side effects)
- **Handshake.swift** — HelloRequest/HelloResponse, HandshakeResult, negotiation + response validation, IPCVersion (in IPCVersion.swift, current=1.0)
- **Commands.swift** — EngineCommandV1: 32-case enum (all payload structs, success payloads, requestID/idempotencyKey, manual allCases)
- **Events.swift** — EngineEventV1: 11-case enum + payload structs (manual allCases)
- **Idempotency.swift** — IdempotencyTracker actor (canonical key: requestID+command+key), replay = same outcome
- **Reconciliation.swift** — SnapshotReconciliation (requested→delta→revision merge)
- **ReconnectPolicy.swift** — ClientReconnectPolicy.standard (5 attempts, 250ms→4s backoff, shared budget contract)
- **IPCEnvelope.swift** — REWRITTEN: concrete non-generic v1 discriminated union (version/kind/requestID/command/event/result), Kind, SuccessPayload, EngineCommandResult, EnvelopeValidationError (fault mapping), IPCPayloadLimit (4 MiB)
- **IPCVersion.swift** — wire version 1.0 (was already present; now used by envelope)
- **EngineCommand.swift / EngineEvent.swift** — UNTOUCHED (legacy WP-03 surface, kept for QA compatibility)

### Native/TorrentinoApp/EngineClient/
- **PeerValidation.swift** (NEW) — five frozen identities (app `com.torrentino.app`, agent `com.torrentino.app.engine-agent`, LaunchAgent label, Mach service `com.torrentino.app.engine-agent.mach`, plist filename), team `438UQRF7JV`, expectedAgentRequirement expression, SecStaticCode designated-requirement validation of the embedded agent binary; `isEnforcementActive` gate (Release/Developer ID enforces, Debug skips — dev builds are unsigned and have no embedded agent)
- **EngineClient.swift** (REWRITTEN) — bounded reconnect (ClientReconnectPolicy), ResumeGuard exactly-once continuation resume, peer validation + `setCodeSigningRequirement` before payload decode, hello() performs §7.4 negotiation against agent-advertised ipcVersion, health() requires ipcVersion key
- **EngineClientTypes.swift** (REWRITTEN) — AgentHello now carries negotiatedProtocol: IPCVersion; new EngineClientError cases peerValidationFailed/fault/protocolMismatch; domainError mapper
- **ServiceRegistration.swift** — now reads identities from PeerValidation.identity (frozen constants)

### Native/TorrentinoEngineAgent/Agent/AgentService.swift
- health() reply now advertises `ipcVersion` + `protocolRange` (server range frozen to 1.0...1.0)

### Native/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift
- Fully rewritten: 73 tests — IPCVersion, identity model, state round-trips, snapshots + reconciliation, all 32 command round-trips, all 11 event round-trips, error contract (stable keys, factories), envelope validation/fuzz/truncation/concurrent stress/oversized payload, pagination bounds + entry round-trips, settings rules + transaction (applied/validationFailed/revisionConflict/rollback), handshake negotiation/mismatch/response validation, idempotency replay semantics, reconnect policy contract, TestProfile isolation

### Native/Torrentino.xcodeproj/project.pbxproj
- 16 new file references + 17 build files registered; TorrentinoIPC and EngineClient groups; Sources phases updated (TorrentinoIPC + TorrentinoApp targets)

## Gates Verified

| Gate | Status |
|------|--------|
| TorrentinoIPC framework builds, 0 warnings | ✅ BUILD SUCCEEDED |
| Full scheme `Torrentino` (Developer ID signed) builds | ✅ BUILD SUCCEEDED, 0 warnings |
| Contract tests (TorrentinoIPCTests) | ✅ 73/73 pass |
| QA regression | ✅ run_qa_suite.sh SUITE RESULT: GREEN (45/45) |
| Swift 6 strict concurrency (Complete) | ✅ no warnings |

## Test Results

```
# Contract tests
xcodebuild test -project Native/Torrentino.xcodeproj -scheme Torrentino \
  -destination 'platform=macOS,arch=arm64' -only-testing:TorrentinoIPCTests
** TEST SUCCEEDED ** (73 test cases passed)

# QA Regression
bash Native/TorrentinoEngineBridge/scripts/qa/run_qa_suite.sh
SUITE RESULT: GREEN (45/45 pass — wp01: 11, wp02: 13, wp03: 8, wp04: 13)
```

## Implementation Notes
- **Debug vs Release peer validation**: `SecStaticCode` designated-requirement checks are enforced only in Release (Developer ID) builds. Debug builds cannot satisfy them (no embedded agent, unsigned binaries) — enforced via `PeerValidation.isEnforcementActive` (Debug → skip binary check + skip `setCodeSigningRequirement`). WP-02 QA runs against the Debug app and stays green.
- **Removed `SecStaticCodeCopyDesignatedRequirement`** (not in the current SDK's public headers): team/identifier verification now compiles the frozen requirement expression (`identifier "<agent>" and anchor apple generic and certificate leaf[subject.OU] = "<team>"`) and passes it directly to `SecStaticCodeCheckValidity`.
- **Enums with associated values cannot synthesize `CaseIterable`** → manual allCases for EngineCommandV1 (32) and EngineEventV1 (11).
- **localizationKey convention**: `"fault." + rawValue` (camelCase, e.g. `fault.insufficientSpace`), frozen with the raw values.
- Envelope validation rejects: incompatible version (fatal protocolVersionMismatch fault), missing requestID/command/event/result, requestID mismatch, unexpected payload; >4 MiB payloads rejected (oversizedPayload).

## Architecture Compliance
- ✅ ADR-010: negative/fuzz tests for parsers (envelope truncation/fuzz), concurrency stress (concurrent encode/decode, idempotency)
- ✅ Swift 6 strict concurrency: actors (IdempotencyTracker, EngineClient), Sendable DTOs, immutable contract types
- ✅ TestProfile isolation: tests never touch production Application Support or open XPC connections
- ✅ Peer code-signing (plan §23): validation strictly before any payload decode; transport requirement + static binary check
- ✅ No fake data paths, no App Sandbox, no Homebrew runtime dependencies
