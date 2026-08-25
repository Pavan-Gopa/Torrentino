#!/usr/bin/env bash
#
# QA WP-08 / WP-22 - 100/500 row fixture performance evidence plus the
# no-production-demo contract.
#
# Test-side contract: the deterministic row generator lives in the app TEST
# target (TorrentinoAppTests.swift) and both boundary sizes must be exercised
# by tests with a real measurement, otherwise a regression can hide behind the
# default 100-row size.
#
# Production-side contract (WP-22.D10, demo-mode removal): the app target must
# not contain the fixture generator, demo row names, or the removed fixture
# note key at all; an unreachable engine lands in the truthful empty library.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

APP_DIR="${NATIVE_DIR}/TorrentinoApp"
TESTS_DIR="${NATIVE_DIR}/Tests"
TEST_FIXTURES="${TESTS_DIR}/TorrentinoAppTests/TorrentinoAppTests.swift"

[[ -d "${APP_DIR}" ]] || qa_die "TorrentinoApp source directory is missing"
[[ -f "${TEST_FIXTURES}" ]] || qa_die "test-side FixtureLibrary.swift is missing"

python3 - "${APP_DIR}" "${TEST_FIXTURES}" "${TESTS_DIR}" <<'PY'
import re
import sys
from pathlib import Path

app_dir = Path(sys.argv[1])
fixture_path = Path(sys.argv[2])
fixtures = fixture_path.read_text(encoding="utf-8")
tests = "\n".join(p.read_text(encoding="utf-8") for p in Path(sys.argv[3]).rglob("*.swift"))
runtime_sources = {
    path: path.read_text(encoding="utf-8")
    for path in app_dir.rglob("*.swift")
}
issues = []

fixture = re.search(r'enum FixtureLibrary\s*\{(?P<body>.*)', fixtures, re.S)
body = fixture.group("body") if fixture else ""
if not re.search(r'static func snapshot\(count:\s*Int\s*=\s*100\)', body):
    issues.append("FixtureLibrary does not expose a count-driven snapshot API with a 100-row default")
if "(1...count).map" not in body:
    issues.append("FixtureLibrary does not generate one row per requested count")
if not re.search(r'FixtureLibrary\.snapshot\(count:\s*100\)', tests):
    issues.append("no test executes FixtureLibrary with count 100")
if not re.search(r'FixtureLibrary\.snapshot\(count:\s*500\)', tests):
    issues.append("no test executes FixtureLibrary with count 500")
if "measure" not in tests and "XCTMeasure" not in tests:
    issues.append("no performance measurement covers the fixture sizes")

for forbidden in ("FixtureLibrary", "usingFixture", "Demo Archive", "fixture.note"):
    for path, source in runtime_sources.items():
        if forbidden in source:
            issues.append(
                f"production demo mode leaked into {path.relative_to(app_dir)}: {forbidden!r}"
            )

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: 100/500-row fixture/perf coverage intact; app target contains no demo mode")
PY

qa_ok "fixture/performance test coverage + no-production-demo source contract"
qa_pass
