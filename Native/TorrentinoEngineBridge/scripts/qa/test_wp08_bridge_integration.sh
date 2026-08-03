#!/usr/bin/env bash
#
# QA WP-08 - real Swift/ObjC++/C++ bridge integration coverage.
#
# The bridge runners are executed separately because they build the pinned
# native toolchain. This contract keeps their WP-08 scenarios from silently
# regressing out of the executable test harness.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SWIFT_TEST="${NATIVE_DIR}/TorrentinoEngineBridge/harness/bridge_swift_test.swift"
CPP_TEST="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/bridge_smoke.cpp"
HEADLESS="${NATIVE_DIR}/TorrentinoEngineBridge/scripts/test_bridge_headless.sh"
SWIFT_RUNNER="${NATIVE_DIR}/TorrentinoEngineBridge/scripts/test_bridge_swift.sh"

for file in "${SWIFT_TEST}" "${CPP_TEST}" "${HEADLESS}" "${SWIFT_RUNNER}"; do
	[[ -f "${file}" ]] || qa_die "missing bridge integration input ${file}"
done

python3 - "${SWIFT_TEST}" "${CPP_TEST}" <<'PY'
import sys
from pathlib import Path

swift, cpp = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]
issues = []

for needle, description in (
    ("coordinator.setLimits", "Swift per-torrent limits path"),
    ("unsupportedOperation", "typed unsupported ratio/seed mapping"),
    ("maxDownloadBytesPerSec: -1", "Swift invalid bandwidth mapping"),
    ("trackers: []", "Swift explicit empty tracker replacement"),
    ("coordinator.reannounce", "Swift reannounce path"),
    ("adapter.editTrackers(withPayloadData", "adapter malformed tracker path"),
    ("non-array tracker payload", "non-array tracker assertion"),
    ("non-string tracker payload element", "malformed tracker element assertion"),
    ("seedTimeSeconds: Int64.max", "native signed-range invalidArgument path"),
    ("agentBandwidth", "full-stack bandwidth IPC success"),
    ("agentRatio", "full-stack ratio unsupported IPC fault"),
    ("agentSeed", "full-stack seed unsupported IPC fault"),
    ("agentInvalid", "full-stack invalidArgument IPC fault"),
    ("agentTrackers", "full-stack tracker replace IPC success"),
    ("agentEmptyTrackers", "full-stack empty tracker IPC success"),
    ("agentReannounce", "full-stack reannounce IPC success"),
):
    if needle not in swift:
        issues.append(f"{description} is missing from bridge_swift_test")

for needle, description in (
    ("live session settings", "native session settings scenario"),
    ("bridge.apply(applied)", "native live settings apply"),
    ("currentLimits", "native bandwidth readback"),
    ("unsupported ratio goal", "native ratio unsupported assertion"),
    ("unsupported seed-time goal", "native seed unsupported assertion"),
    ("nativeRangeFailure", "native seed range invalidArgument assertion"),
    ("malformed tracker URL", "native malformed tracker corpus"),
    ("empty tracker list", "native explicit empty tracker assertion"),
    ("reannounce must reach", "native reannounce assertion"),
):
    if needle not in cpp:
        issues.append(f"{description} is missing from bridge_smoke")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: real bridge harness covers live settings, limits, trackers, reannounce, and typed IPC faults")
PY

qa_ok "Swift/ObjC++/C++ bridge integration contract"
qa_pass
