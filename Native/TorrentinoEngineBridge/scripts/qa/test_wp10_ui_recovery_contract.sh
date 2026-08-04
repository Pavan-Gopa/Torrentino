#!/usr/bin/env bash
#
# QA WP-10 - pending-removal UI recovery contract.
#
# This deterministic source-level gate covers the UI surface that is difficult
# to exercise in a headless XCTest host: connect/reconnect refresh, explicit
# retry only, inline result state, recovery banner wiring, and the seven new
# EN/RU localization entries.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

MODEL="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListViewModel.swift"
VIEW="${NATIVE_DIR}/TorrentinoApp/Features/TorrentListView.swift"
COMMANDS="${NATIVE_DIR}/TorrentinoIPC/Commands.swift"
ENVELOPE="${NATIVE_DIR}/TorrentinoIPC/IPCEnvelope.swift"
CATALOG="${NATIVE_DIR}/TorrentinoApp/Resources/Localizable.xcstrings"

for file in "${MODEL}" "${VIEW}" "${COMMANDS}" "${ENVELOPE}" "${CATALOG}"; do
	[[ -f "${file}" ]] || qa_die "missing WP-10 UI recovery input: ${file}"
done

python3 - "${MODEL}" "${VIEW}" "${COMMANDS}" "${ENVELOPE}" "${CATALOG}" <<'PY'
import json
import sys
from pathlib import Path

model, view, commands, envelope, catalog_path = [Path(path).read_text(encoding="utf-8") for path in sys.argv[1:]]
catalog = json.loads(catalog_path)
issues = []

for needle, description in (
    ("lastRemovalResult", "lastRemovalResult state"),
    ("pendingRemovals", "pendingRemovals state"),
    ("func refreshPendingRemovals()", "pending-removal refresh method"),
    ("func retryRemoval(_ summary: PendingRemovalSummary)", "explicit retry method"),
    ("fetchPendingRemovals", "read-only pending-removal IPC command"),
    ("lastRemovalResult = result", "removal result assignment"),
    ("client.setReconnectHandler", "reconnect callback"),
    ("recoverAfterReconnect", "reconnect recovery"),
):
    if needle not in model and needle not in commands:
        issues.append(f"{description} is missing")

if model.count("await refreshPendingRemovals()") < 2:
    issues.append("pending removals are not refreshed on both initial connect and reconnect/flow completion")
if "EngineCommandV1.commitRemoval" not in model:
    issues.append("retry path does not send commitRemoval")

for needle, description in (
    ("removalRecoveryBanner", "recovery banner property"),
    ("viewModel.retryRemoval(summary)", "banner retry action"),
    ("viewModel.pendingRemovals", "pending list projection"),
    ("viewModel.lastRemovalResult", "last result projection"),
    ("remove.result.partial", "partial outcome rendering"),
    ("remove.result.failed", "failed outcome rendering"),
):
    if needle not in view:
        issues.append(f"{description} is missing")

if "case pendingRemovals([PendingRemovalSummary])" not in envelope:
    issues.append("pending-removal result is missing from the IPC success union")

required_keys = (
    "remove.pendingLookupFailed",
    "remove.pending.title",
    "remove.pending.detail",
    "remove.pending.resume",
    "remove.result.completed",
    "remove.result.partial",
    "remove.result.failed",
)
strings = catalog.get("strings", {})
for key in required_keys:
    entry = strings.get(key)
    if not isinstance(entry, dict):
        issues.append(f"catalog key {key} is missing")
        continue
    localizations = entry.get("localizations", {})
    for language in ("en", "ru"):
        value = ((localizations.get(language) or {}).get("stringUnit") or {}).get("value")
        if not isinstance(value, str) or not value.strip():
            issues.append(f"catalog key {key} has no non-empty {language} value")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    raise SystemExit(1)

print("OK: pending-removal state, connect/reconnect refresh, explicit retry, banner, and EN/RU catalog are wired")
PY

qa_ok "pending-removal UI and localization contract"
qa_pass
