#!/usr/bin/env bash
#
# QA WP-08 - focus restoration after sheets and reconnect generations.
#
# Source-level UI checks are the deterministic minimum here; runtime AppKit
# focus automation remains a residual audit item for a signed UI test host.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

MODEL="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListViewModel.swift"
LIST="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
APP_TESTS="${NATIVE_DIR}/Tests/TorrentinoAppTests/TorrentinoAppTests.swift"

for file in "${MODEL}" "${LIST}" "${APP_TESTS}"; do
	[[ -f "${file}" ]] || qa_die "missing focus/reconnect input ${file}"
done

python3 - "${MODEL}" "${LIST}" "${APP_TESTS}" <<'PY'
import sys
from pathlib import Path

model, view, app_tests = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]
issues = []

for needle, description in (
    ("connectionGeneration", "connection generation state"),
    ("connectionGeneration &+= 1", "generation increment"),
    ("client.setReconnectHandler", "reconnect callback registration"),
    ("recoverAfterReconnect", "authoritative reconnect recovery"),
    ("fetchFullSnapshot", "full snapshot restoration"),
    ("searchFocusRequest", "explicit search focus request"),
):
    if needle not in model:
        issues.append(f"{description} is missing from TorrentListViewModel")

for needle, description in (
    (".onChange(of: viewModel.showAddSheet)", "sheet-dismiss focus hook"),
    (".onChange(of: viewModel.connectionGeneration)", "reconnect focus hook"),
    ("viewModel.focusSearch()", "focus request after lifecycle transition"),
    ("SearchFieldFocusBridge.focusFirstResponder()", "first-responder restoration"),
    ("window.makeFirstResponder(searchField)", "AppKit first-responder assignment"),
    ("DispatchQueue.main.async", "deferred responder restoration"),
):
    if needle not in view:
        issues.append(f"{description} is missing from TorrentListView")

if "testTorrentListProjectionSearchFilterAndSort" not in app_tests:
    issues.append("projection/search identity XCTest is missing")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: sheet/reconnect focus restoration and authoritative generation recovery are wired")
PY

qa_ok "focus restoration and reconnect generation source contract"
qa_pass
