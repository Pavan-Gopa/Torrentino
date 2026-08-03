#!/usr/bin/env bash
#
# QA WP-08 - per-torrent bandwidth limits and seed goals.
#
# ratioLimit and seedTimeSeconds must be visible in the Inspector, invalid
# values must stay invalid, and valid bandwidth values must survive a round trip.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

STATE="${NATIVE_DIR}/TorrentinoIPC/State.swift"
INSPECTOR="${NATIVE_DIR}/TorrentinoApp/Features/InspectorView.swift"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
TESTS_DIR="${NATIVE_DIR}/Tests"

for file in "${STATE}" "${INSPECTOR}" "${COORDINATOR}"; do
	[[ -f "${file}" ]] || qa_die "missing per-torrent limit input ${file}"
done

python3 - "${STATE}" "${INSPECTOR}" "${COORDINATOR}" "${TESTS_DIR}" <<'PY'
import re
import sys
from pathlib import Path

state = Path(sys.argv[1]).read_text(encoding="utf-8")
inspector = Path(sys.argv[2]).read_text(encoding="utf-8")
coordinator = Path(sys.argv[3]).read_text(encoding="utf-8")
tests = "\n".join(p.read_text(encoding="utf-8") for p in Path(sys.argv[4]).rglob("*.swift"))
issues = []

for field in ("ratioLimit", "seedTimeSeconds"):
    if field not in state:
        issues.append(f"TransferLimits is missing {field}")
    if field not in inspector:
        issues.append(f"Inspector has no control or display for {field}")

handler = re.search(r'private func handleSetLimits\(.*?(?=\n\s*private func handleApplySettings)', coordinator, re.S)
body = handler.group(0) if handler else ""
if "request.limits" not in body:
    issues.append("handleSetLimits ignores request.limits and cannot persist or apply limits")
if "validationError" not in body or "invalidArgument" not in body:
    issues.append("handleSetLimits has no strict validation or typed invalidArgument fault")

for name in (
    "testTransferLimitsRoundTrip",
    "testTransferLimitsRejectsNegativeWithoutMutation",
    "testTransferLimitsRejectsOverflowWithoutMutation",
    "testTransferLimitsRejectsNonFiniteAtJSONBoundaryWithoutMutation",
    "testTransferLimitsRejectsInspectorParseFailureWithoutMutation",
    "testTransferLimitsEmptyAndZeroMeanUnlimited",
    "testSeedGoalsRoundTrip",
):
    if f"func {name}" not in tests:
        issues.append(f"missing unit axis {name}")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: per-torrent limits and seed goals have UI, strict validation, round-trip, and rejection coverage")
PY

qa_ok "per-torrent limits/seed-goals source and test contract"
qa_pass
