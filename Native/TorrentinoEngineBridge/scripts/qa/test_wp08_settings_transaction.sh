#!/usr/bin/env bash
#
# QA WP-08 - Settings validate/persist/apply/rollback integration.
#
# Pure SettingsTransaction behavior is covered by TorrentinoIPCTests. This
# script additionally verifies that the UI and agent actually call that
# transaction instead of bypassing it with ad-hoc persistence.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

SETTINGS="${NATIVE_DIR}/TorrentinoIPC/Settings.swift"
VIEW="${NATIVE_DIR}/TorrentinoApp/Features/Settings/SettingsView.swift"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
IPCTESTS="${NATIVE_DIR}/Tests/TorrentinoIPCTests/TorrentinoIPCTests.swift"

for file in "${SETTINGS}" "${VIEW}" "${COORDINATOR}" "${IPCTESTS}"; do
	[[ -f "${file}" ]] || qa_die "missing settings transaction test input ${file}"
done

python3 - "${SETTINGS}" "${VIEW}" "${COORDINATOR}" "${IPCTESTS}" <<'PY'
import re
import sys
from pathlib import Path

settings, view, coordinator, tests = [Path(p).read_text(encoding="utf-8") for p in sys.argv[1:]]
issues = []

if "SettingsTransaction.run" not in view:
    issues.append("SettingsView validates and sends ApplySettings directly; SettingsTransaction.run is not used")
if "SettingsTransaction.run" not in coordinator:
    issues.append("TransferCoordinator persists settings directly; SettingsTransaction.run is not used")

run_match = re.search(r'public static func run\(.*?(?=\n\s*\}\n\nextension EngineFault)', settings, re.S)
run_body = run_match.group(0) if run_match else ""
validation_at = run_body.find("let errors = validation(candidate)")
persist_at = run_body.find("context.persist")
rollback_at = run_body.find("context.rollback")
if validation_at < 0 or persist_at < 0 or validation_at > persist_at:
    issues.append("transaction validation does not precede persistence")
if rollback_at < 0:
    issues.append("apply failure has no rollback call")

for name in (
    "testSettingsTransactionApplied",
    "testSettingsTransactionValidationFailed",
    "testSettingsTransactionRevisionConflict",
    "testSettingsTransactionRollbackOnApplyFailure",
    "testSettingsTransactionPersistFailureNoRollback",
):
    if f"func {name}" not in tests:
        issues.append(f"missing unit axis {name}")

if issues:
    for issue in issues:
        print(f"FAIL: {issue}", file=sys.stderr)
    sys.exit(1)

print("OK: SettingsTransaction integration and happy/error/rollback unit axes are present")
PY

qa_ok "settings transaction source and unit-test contract"
qa_pass
