#!/usr/bin/env bash
#
# QA WP-08 - tracker fetch/edit/reannounce, rate limiting, and empty lists.
#
# The engine handler is the security/correctness boundary. Merely exposing an
# IPC enum is not enough: reannounce must be throttled and all public command
# surfaces need happy, error, and edge XCTest coverage.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

COMMANDS="${NATIVE_DIR}/TorrentinoIPC/Commands.swift"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
TESTS_DIR="${NATIVE_DIR}/Tests"

for file in "${COMMANDS}" "${COORDINATOR}"; do
	[[ -f "${file}" ]] || qa_die "missing tracker input ${file}"
done

python3 - "${COMMANDS}" "${COORDINATOR}" "${TESTS_DIR}" <<'PY'
import re
import sys
from pathlib import Path

commands = Path(sys.argv[1]).read_text(encoding="utf-8")
coordinator = Path(sys.argv[2]).read_text(encoding="utf-8")
tests = "\n".join(p.read_text(encoding="utf-8") for p in Path(sys.argv[3]).rglob("*.swift"))
issues = []

for command in ("fetchTrackers", "editTrackers", "reannounce"):
    if f"case {command}" not in commands:
        issues.append(f"IPC command {command} is missing")
    if f"case .{command}" not in coordinator:
        issues.append(f"TransferCoordinator dispatch for {command} is missing")

tracker_match = re.search(r'private func trackers\(request:.*?(?=\n\s*private func peers)', coordinator, re.S)
tracker_body = tracker_match.group(0) if tracker_match else ""
if ("record.trackers.count" not in tracker_body and "record.trackerTiers" not in tracker_body and "rows.count" not in tracker_body) or "items: [], nextCursor: nil" not in tracker_body:
    issues.append("empty tracker list does not return a bounded empty page")

reannounce_match = re.search(r'private func handleReannounce\(.*?(?=\n\s*private func handleEditTrackers)', coordinator, re.S)
reannounce_body = reannounce_match.group(0) if reannounce_match else ""
if not re.search(r'(?i)rate|cooldown|thrott|last.?reannounce|interval|Date', reannounce_body):
    issues.append("handleReannounce has no rate-limit or cooldown state/check")

for name in ("testFetchTrackers", "testEditTrackers", "testReannounce"):
    if f"func {name}" not in tests:
        issues.append(f"missing dedicated unit axis {name} (happy/error/edge coverage cannot be demonstrated)")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: tracker commands, empty-list handling, throttling, and unit axes are present")
PY

qa_ok "trackers/reannounce source and test contract"
qa_pass
