#!/usr/bin/env bash
#
# QA WP-05 — Settings transactional apply, revision conflict, rollback (plan §7.4).
#
# Verifies via existing unit tests:
#   * SettingsValidation rules
#   * SettingsTransaction applied on valid candidate + matching revision
#   * Validation failed returns errors
#   * Revision conflict returns fault
#   * Apply failure triggers rollback
#   * Persist failure returns storeError
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests settings transaction tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsValidationRules \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsRevisionConflictFault \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsTransactionApplied \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsTransactionValidationFailed \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsTransactionRevisionConflict \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsTransactionRollbackOnApplyFailure \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsTransactionPersistFailureNoRollback \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSettingsRoundTrip \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -40

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Settings transaction tests FAILED"
fi
qa_ok "Settings transaction tests GREEN"

qa_pass