#!/usr/bin/env bash
#
# QA WP-05 — Snapshot reconciliation: dropped delta -> full snapshot (plan §8.2).
#
# Verifies via existing unit tests:
#   * Instance change -> full snapshot required
#   * First connection (no currentInstanceID) -> full snapshot
#   * Delta applicable only when contiguous
#   * Gap > 1 -> full snapshot required
#   * Engine revisions strictly monotonic
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

NATIVE_DIR="$(cd "${QA_DIR}/../../.." && pwd)"
PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"

qa_log "Running TorrentinoIPCTests reconciliation tests..."
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testInstanceChangeRequiresFullSnapshot \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testDroppedDeltaRequiresFullSnapshot \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testContiguousDeltaApplicable \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testFirstSnapshotAlwaysFull \
    -only-testing:TorrentinoIPCTests/TorrentinoIPCTests/testSnapshotRevisionMonotonic \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tail -30

RC=${PIPESTATUS[0]}
if [[ ${RC} -ne 0 ]]; then
    qa_die "Reconciliation tests FAILED"
fi
qa_ok "Reconciliation tests GREEN"

qa_pass