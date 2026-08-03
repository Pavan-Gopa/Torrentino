#!/usr/bin/env bash
#
# QA WP-08 - notification authorization and duplicate prevention.
#
# In addition to checking authorization call sites, this catches an impossible
# all-complete predicate and requires dedicated tests for completion, all-
# complete, and error transitions.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

DELEGATE="${NATIVE_DIR}/TorrentinoApp/App/AppDelegate.swift"
SETTINGS="${NATIVE_DIR}/TorrentinoApp/Features/Settings/SettingsView.swift"
MANAGER="${NATIVE_DIR}/TorrentinoApp/App/NotificationManager.swift"
TESTS_DIR="${NATIVE_DIR}/Tests"

for file in "${DELEGATE}" "${SETTINGS}" "${MANAGER}"; do
	[[ -f "${file}" ]] || qa_die "missing notification input ${file}"
done

python3 - "${DELEGATE}" "${SETTINGS}" "${MANAGER}" "${TESTS_DIR}" <<'PY'
import sys
from pathlib import Path

delegate, settings, manager = [Path(p).read_text(encoding="utf-8") for p in sys.argv[1:4]]
tests = "\n".join(p.read_text(encoding="utf-8") for p in Path(sys.argv[4]).rglob("*.swift"))
issues = []

if "NotificationManager.shared.requestAuthorization()" not in delegate:
    issues.append("launch does not request notification authorization")
if settings.count("NotificationManager.shared.requestAuthorization()") < 3:
    issues.append("notification toggles do not request authorization for every enable path")
for needle, description in (
    ("previousStates", "previous activity state tracking"),
    ("completedTorrents", "completion de-duplication state"),
    ("processSnapshots", "snapshot notification processing"),
):
    if needle not in manager:
        issues.append(f"missing {description}")

if "if hasActive && allFinished" in manager:
    issues.append("all-complete notification condition is impossible: hasActive and allFinished cannot both be true")

for name in ("testNotificationCompletion", "testNotificationAllComplete", "testNotificationError"):
    if f"func {name}" not in tests:
        issues.append(f"missing dedicated unit axis {name}")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: launch/toggle authorization, transition tracking, and notification unit axes are present")
PY

qa_ok "notification source and test contract"
qa_pass
