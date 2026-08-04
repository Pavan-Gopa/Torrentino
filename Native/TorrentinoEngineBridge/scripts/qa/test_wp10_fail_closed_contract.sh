#!/usr/bin/env bash
#
# QA WP-10 - fail-closed journal mutation contract.
#
# This is intentionally a strict detector. Ignoring a persistence or engine
# error with try? on a mutation/recovery path can leave durable evidence and
# in-memory state divergent. A failure here is a product bug, not a QA waiver.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
JOURNAL="${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/RemovalJournal.swift"
FAILPOINTS="${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/FailpointInjector.swift"
TESTS="${NATIVE_DIR}/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift"

for file in "${COORDINATOR}" "${JOURNAL}" "${FAILPOINTS}" "${TESTS}"; do
	[[ -f "${file}" ]] || qa_die "missing WP-10 fail-closed input: ${file}"
done

python3 - "${COORDINATOR}" "${JOURNAL}" "${FAILPOINTS}" "${TESTS}" <<'PY'
import sys
from pathlib import Path

coordinator, journal, failpoints, tests = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]
issues = []

def function_body(source: str, marker: str) -> str:
    start = source.find(marker)
    if start < 0:
        return ""
    opening = source.find("{", start)
    if opening < 0:
        return ""
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    return ""

mutation_checks = (
    ("handlePrepareRemoval(_ request: PrepareRemovalRequest)", "(try? await persistence.removalTokenCount()", "pending token limit defaults open on persistence failure"),
    ("handleFetchPendingRemovals(_ request: FetchPendingRemovalsRequest)", "try? await persistence.trashJournalEntries", "pending progress defaults to fabricated zero evidence"),
    ("recoverInterruptedMoves()", "try? await persistence.deleteMoveJournal", "move recovery ignores journal cleanup failure"),
    ("handleCommitRemoval(_ request: CommitRemovalRequest)", "try? await persistence.deleteTrashJournal", "removal cleanup ignores journal deletion failure"),
    ("handleCommitRemoval(_ request: CommitRemovalRequest)", "try? await persistence.pruneSettledRemovalTokens", "removal cleanup ignores token-prune failure"),
    ("handleMoveStorage(_ request: MoveStorageRequest)", "(try? await persistence.moveJournal", "move admission treats journal lookup failure as no journal"),
    ("handleMoveStorage(_ request: MoveStorageRequest)", "try? await persistence.deleteMoveJournal", "successful move hides journal deletion failure"),
    ("handleMoveStorage(_ request: MoveStorageRequest)", "try? await engine.recheck", "move recheck failure is silently discarded"),
)
for marker, forbidden, description in mutation_checks:
    body = function_body(coordinator, marker)
    if not body:
        issues.append(f"could not locate {marker}")
    elif forbidden in body:
        issues.append(f"{description}: {forbidden}")

for needle, description in (
    ("try FailpointInjector.fire(.beforeTrashJournalAppend)", "append failpoint"),
    ("try FailpointInjector.fire(.beforeTrashJournalUpdate)", "update failpoint"),
    ("try FailpointInjector.fire(.beforeRemovalTokenSettle)", "settle failpoint"),
):
    if needle not in journal:
        issues.append(f"{description} is missing")

for needle, description in (
    ("beforeTrashJournalAppend", "append failpoint enum"),
    ("beforeTrashJournalUpdate", "update failpoint enum"),
    ("beforeRemovalTokenSettle", "settle failpoint enum"),
):
    if needle not in failpoints:
        issues.append(f"{description} is missing")

if "testWP10JournalAppendFailureAbortsBatchBeforeAnyMutation" not in tests:
    issues.append("append failpoint XCTest is missing")
if "testWP10JournalUpdateFailureAbortsFailClosedAndResumes" not in tests:
    issues.append("update failpoint XCTest is missing")
if "testWP10SettleFailureFailsClosedAndPendingTokenSurvivesRestart" not in tests:
    issues.append("settle failpoint XCTest is missing")
if "testWP10CommittedOutcomeReplayRepairsRecordAfterSettlementCrash" not in tests:
    issues.append("convergent committed-outcome repair XCTest is missing")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    raise SystemExit(1)

print("OK: journal mutation paths are fail-closed and convergent")
PY

qa_ok "fail-closed journal mutation contract"
qa_pass
