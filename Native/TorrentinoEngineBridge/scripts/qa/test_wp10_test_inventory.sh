#!/usr/bin/env bash
#
# QA WP-10 - monotonic XCTest/script inventory.
#
# Prevents a green-looking targeted script from silently dropping one of the
# WP-10 adversarial/restart cases. Every testWP10 method must be named by at
# least one WP-10 runner, and the cycle must retain the required 21+ tests.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

TESTS="${NATIVE_DIR}/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift"
QA_DIR_LOCAL="${NATIVE_DIR}/TorrentinoEngineBridge/scripts/qa"
[[ -f "${TESTS}" ]] || qa_die "WPSafeFileOperationsTests.swift is missing"
[[ -d "${QA_DIR_LOCAL}" ]] || qa_die "WP-10 QA directory is missing"

python3 - "${TESTS}" "${QA_DIR_LOCAL}" <<'PY'
import re
import sys
from pathlib import Path

tests_path = Path(sys.argv[1])
qa_dir = Path(sys.argv[2])
test_source = tests_path.read_text(encoding="utf-8")
methods = set(re.findall(r"func\s+(testWP10\w+)\s*\(", test_source))
script_source = "\n".join(
    path.read_text(encoding="utf-8")
    for path in sorted(qa_dir.glob("test_wp10_*.sh"))
)
listed = set(re.findall(r"testWP10\w+", script_source))
missing = sorted(methods - listed)
issues = []
if len(methods) < 21:
    issues.append(f"only {len(methods)} WP-10 XCTest methods found; expected at least 21")
if missing:
    issues.append("WP-10 methods absent from QA runners: " + ", ".join(missing))
if not any("run_qa_suite.sh" in path.read_text(encoding="utf-8") and "test_wp10_" in path.read_text(encoding="utf-8") for path in [qa_dir / "run_qa_suite.sh"]):
    issues.append("run_qa_suite.sh does not collect test_wp10_*.sh")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    raise SystemExit(1)

print(f"OK: {len(methods)} WP-10 XCTest methods are represented by QA runners")
PY

qa_ok "monotonic WP-10 XCTest and QA-script inventory"
qa_pass
