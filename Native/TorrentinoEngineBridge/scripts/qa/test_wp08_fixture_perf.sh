#!/usr/bin/env bash
#
# QA WP-08 - 100/500 row FixtureLibrary generation and UI performance evidence.
#
# The generic count parameter is necessary but not sufficient: both boundary
# sizes must be exercised by a test, otherwise a regression can hide behind
# the default 100-row fallback.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

MODEL="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListViewModel.swift"
TESTS_DIR="${NATIVE_DIR}/Tests"

[[ -f "${MODEL}" ]] || qa_die "TorrentListViewModel.swift is missing"

python3 - "${MODEL}" "${TESTS_DIR}" <<'PY'
import re
import sys
from pathlib import Path

model = Path(sys.argv[1]).read_text(encoding="utf-8")
tests = "\n".join(p.read_text(encoding="utf-8") for p in Path(sys.argv[2]).rglob("*.swift"))
issues = []

fixture = re.search(r'enum FixtureLibrary\s*\{(?P<body>.*)', model, re.S)
body = fixture.group("body") if fixture else ""
if not re.search(r'static func snapshot\(count:\s*Int\s*=\s*100\)', body):
    issues.append("FixtureLibrary does not expose a count-driven snapshot API with a 100-row default")
if "(1...count).map" not in body:
    issues.append("FixtureLibrary does not generate one row per requested count")
if "FixtureLibrary.snapshot(count: 100)" not in model:
    issues.append("degraded UI path does not exercise the 100-row fixture")
if not re.search(r'FixtureLibrary\.snapshot\(count:\s*100\)', tests):
    issues.append("no test executes FixtureLibrary with count 100")
if not re.search(r'FixtureLibrary\.snapshot\(count:\s*500\)', tests):
    issues.append("no test executes FixtureLibrary with count 500")
if "measure" not in tests and "XCTMeasure" not in tests:
    issues.append("no performance measurement covers the fixture sizes")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: FixtureLibrary executes 100/500-row cases with performance measurement")
PY

qa_ok "100-500 row fixture/performance source and test contract"
qa_pass
