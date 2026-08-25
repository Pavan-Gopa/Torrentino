#!/usr/bin/env bash
#
# QA WP-13 — disposable closure evidence for the Human-reported bug records.
#
# This runner is fail-closed around user state. It refuses to start if the
# product Engine directory, launchd job, or agent already exists, then uses a
# clean app build with no torrent admission for the live lifecycle proof. Native
# libtorrent priority behavior is exercised separately by the isolated bridge
# smoke fixture; all XCTest data stays under TestProfile.
#
# Must-not: inspect, modify, or delete a pre-existing Human record/payload.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
APP_TESTS="${NATIVE_DIR}/Tests/TorrentinoAppTests/TorrentinoAppTests.swift"
ENGINE_PROTOCOL="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferRecord.swift"
BRIDGE_ENGINE="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift"
COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
ENGINE_COORDINATOR="${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
PAGINATION="${NATIVE_DIR}/TorrentinoIPC/Pagination.swift"
BRIDGE_CPP="${NATIVE_DIR}/TorrentinoEngineBridge/bridge/EngineBridge.cpp"
BRIDGE_SMOKE="${NATIVE_DIR}/TorrentinoEngineBridge/scripts/test_bridge_headless.sh"
BRIDGE_SWIFT="${NATIVE_DIR}/TorrentinoEngineBridge/scripts/test_bridge_swift.sh"
WPSAFE_TESTS="${NATIVE_DIR}/Tests/TorrentinoEngineAgentTests/WPSafeFileOperationsTests.swift"
LOG_DIR="$(qa_mktemp)"
TEST_LOG="${LOG_DIR}/wp13-bug-closure-xcodebuild.log"
BRIDGE_LOG="${LOG_DIR}/wp13-bridge-headless.log"
SWIFT_LOG="${LOG_DIR}/wp13-bridge-swift.log"

require_source() {
    local file="$1"
    local needle="$2"
    local label="$3"
    if grep -Fq "$needle" "$file"; then
        qa_ok "$label"
    else
        qa_die "$label: missing '$needle' in ${file}"
    fi
}

assert_clean_live_fixture() {
    if [[ -e "${WP02_ENGINE_DIR}" ]]; then
        qa_die "refusing live proof: pre-existing Engine directory would be touched (${WP02_ENGINE_DIR})"
    fi
    if launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1; then
        qa_die "refusing live proof: pre-existing launchd job ${WP02_LABEL}"
    fi
    if wp02_agent_running; then
        qa_die "refusing live proof: pre-existing TorrentinoEngineAgent process"
    fi
    qa_ok "live proof starts from an empty Engine directory with no agent/job"
}

qa_log "Running disposable BUG-002/BUG-003/BUG-004/BUG-005 regression tests..."
set +e
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testCommitAddImmediateStartRunningNotIdle \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testMultiFileRunningDesiredStateAndOfflineRecovery \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSetFileSelectionInvalidatesInspection \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testSetFileSelectionDurableAcrossRestart \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testPersistedFileSelectionIsAppliedWhenRestoreReaddsEngineRecord \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFilesPageWithDirectoryDrillDown \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFileSelectionPrioritiesRoundTrip \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFileSelectionRejectsUnknownPath \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFilesPageReportsMetadataNotFetchedForMagnet \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testFilePageUsesOnDiskProgressWhenPayloadExists \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13InspectPreflightRejectsInsufficientSpaceBeforeAdmission \
    -only-testing:TorrentinoEngineAgentTests/TransferSmokeTests/testWP13CommitPreflightRunsBeforePersistence \
    -only-testing:TorrentinoEngineAgentTests/WPSafeFileOperationsTests/testWP13FaultedRecordRemovalSupportsKeepAndDeleteData \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testTorrentHealthLocalizedMessages \
    -only-testing:TorrentinoAppTests/TorrentinoAppTests/testTorrentHealthActionableMessagesHaveEnglishAndRussianEntries \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tee "${TEST_LOG}"
xcode_rc=${PIPESTATUS[0]}
set -e

if [[ ${xcode_rc} -eq 0 ]]; then
    qa_ok "BUG-002 desired-state, BUG-003 files, BUG-004 preflight, and BUG-005 faulted-removal tests GREEN"
else
    qa_die "Disposable BUG-002/BUG-003/BUG-004/BUG-005 XCTest selection FAILED (log: ${TEST_LOG})"
fi

qa_log "Checking the BUG-001 AppKit seam and source contracts..."
require_source "${APP_TESTS}" "#if WP13_APP_SEAM" "BUG-001 conditional seam guard exists"
require_source "${APP_TESTS}" "testEngineViewModelStatusRefreshAndReconnect" "BUG-001 status/reconnect XCTest seam exists"
require_source "${APP_TESTS}" "didBecomeActiveNotification" "BUG-001 activation notification is covered by the seam"
require_source "${APP_TESTS}" "onStatusRestored" "BUG-001 reconnect callback is covered by the seam"

require_source "${ENGINE_PROTOCOL}" "func setFileSelection" "BUG-003 TransferEngine exposes a file-selection operation"
require_source "${PAGINATION}" "public let progressFraction" "BUG-003 FileEntry exposes per-file progress"
require_source "${BRIDGE_ENGINE}" "coordinator.setFilePriorities" "BUG-003 production bridge forwards live file selection"
require_source "${ENGINE_COORDINATOR}" "setFilePriorities(" "BUG-003 Swift coordinator owns the native priority boundary"
require_source "${BRIDGE_CPP}" "prioritize_files(" "BUG-003 C++ bridge applies priorities through libtorrent"
require_source "${COORDINATOR}" "storage preflight failed" "BUG-004 add preflight failure path is wired"
require_source "${COORDINATOR}" "requiredBytes" "BUG-004 required byte calculation is present"
require_source "${WPSAFE_TESTS}" "testWP13FaultedRecordRemovalSupportsKeepAndDeleteData" "BUG-005 disposable faulted-record proof exists"

qa_log "Running live launchd recovery on a clean app with no torrent records..."
source "${QA_DIR}/qa_wp02_common.sh"
wp02_require_app
assert_clean_live_fixture
wp02_trap_cleanup
wp02_reset

wp02_cli register
assert_eq "${WP02_CLI_RC}" "0" "BUG-001 register exit 0"
assert_contains "${WP02_CLI_OUT}" "status=enabled" "BUG-001 register reports enabled"
wp02_wait_for 15 wp02_agent_running || qa_die "BUG-001 agent did not spawn after register"
wp02_cli status
assert_eq "${WP02_CLI_RC}" "0" "BUG-001 status exit 0 while registered"
assert_contains "${WP02_CLI_OUT}" "STATE operational" "BUG-001 registered state is operational"

wp02_cli unregister
assert_eq "${WP02_CLI_RC}" "0" "BUG-001 unregister exit 0"
assert_contains "${WP02_CLI_OUT}" "status=notRegistered" "BUG-001 unregister reports notRegistered"
wp02_wait_for 10 wp02_agent_gone || qa_die "BUG-001 agent did not stop after unregister"
wp02_cli status
assert_eq "${WP02_CLI_RC}" "3" "BUG-001 degraded status exit 3 after unregister"
assert_contains "${WP02_CLI_OUT}" "STATE degraded" "BUG-001 status is degraded without launchd"
assert_contains "${WP02_CLI_OUT}" "reason=service-notRegistered" "BUG-001 degraded reason is explicit"
assert_eq "$(wp02_agent_pid)" "" "BUG-001 degraded probe does not spawn an in-process agent"

wp02_cli register
assert_eq "${WP02_CLI_RC}" "0" "BUG-001 re-register exit 0"
assert_contains "${WP02_CLI_OUT}" "status=enabled" "BUG-001 re-register reports enabled"
wp02_wait_for 15 wp02_agent_running || qa_die "BUG-001 agent did not respawn after re-register"
wp02_cli status
assert_eq "${WP02_CLI_RC}" "0" "BUG-001 recovered status exit 0"
assert_contains "${WP02_CLI_OUT}" "STATE operational" "BUG-001 recovered state is operational without app restart"
qa_ok "BUG-001 live launchd recovery completed without admitting a torrent record"

qa_log "Running isolated native libtorrent priority proof..."
set +e
bash "${BRIDGE_SMOKE}" --timeout 120 2>&1 | tee "${BRIDGE_LOG}"
bridge_rc=${PIPESTATUS[0]}
set -e
assert_eq "${bridge_rc}" "0" "BUG-003 native bridge smoke exit 0"
bridge_output="$(<"${BRIDGE_LOG}")"
assert_contains "${bridge_output}" "priority evidence: files=3 skip=1 normal=2 skipped_allocated=false" "BUG-003 libtorrent applies skip/normal and does not allocate skipped file"
assert_contains "${bridge_output}" "bridge smoke: PASS" "BUG-002/BUG-003 native lifecycle smoke is GREEN"

qa_log "Running Swift -> ObjC++ adapter -> C++ integration proof..."
set +e
bash "${BRIDGE_SWIFT}" 2>&1 | tee "${SWIFT_LOG}"
swift_rc=${PIPESTATUS[0]}
set -e
assert_eq "${swift_rc}" "0" "BUG-003 Swift bridge integration exit 0"
swift_output="$(<"${SWIFT_LOG}")"
assert_contains "${swift_output}" "bridge swift test: PASS" "BUG-003 Swift adapter integration is GREEN"

qa_pass
