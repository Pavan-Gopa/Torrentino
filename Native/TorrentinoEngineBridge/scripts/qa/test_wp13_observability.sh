#!/usr/bin/env bash
#
# QA WP-13 — disposable end-to-end observability matrix.
#
# Role: runs the command/transfer matrix in XCTest, then confirms the live XPC
#       connect/peer-verification path writes into the same disposable log.
# Must-not: read, delete, or overwrite a pre-existing Human Engine directory or
#           the user's persistent log directory.
# Invariant: the temporary log directory and WP-02 live fixture are removed on
#            every exit path, including a failed assertion.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

PROJECT="${NATIVE_DIR}/Torrentino.xcodeproj"
LOG_ROOT="$(qa_mktemp)/wp13-observability-logs"
XCODE_LOG="$(qa_mktemp)/wp13-observability-xcodebuild.log"
ORIGINAL_LAUNCHD_LOG_DIR="$(launchctl getenv TORRENTINO_LOG_DIRECTORY 2>/dev/null || true)"
mkdir -p "${LOG_ROOT}"

assert_empty_live_fixture() {
    [[ ! -e "${WP02_ENGINE_DIR}" ]] || qa_die "refusing observability proof over pre-existing Engine directory"
    if launchctl print "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1; then
        qa_die "refusing observability proof over pre-existing launchd job"
    fi
    wp02_agent_gone || qa_die "refusing observability proof over pre-existing agent process"
}

cleanup() {
    local rc=$?
    if [[ -n "${ORIGINAL_LAUNCHD_LOG_DIR}" ]]; then
        launchctl setenv TORRENTINO_LOG_DIRECTORY "${ORIGINAL_LAUNCHD_LOG_DIR}" >/dev/null 2>&1 || true
    else
        launchctl unsetenv TORRENTINO_LOG_DIRECTORY >/dev/null 2>&1 || true
    fi
    wp02_cleanup
    qa_cleanup
    exit "${rc}"
}

wp02_require_app
assert_empty_live_fixture
wp02_reset
export TORRENTINO_LOG_DIRECTORY="${LOG_ROOT}"
launchctl setenv TORRENTINO_LOG_DIRECTORY "${LOG_ROOT}" || qa_die "could not set disposable launchd log directory"
trap cleanup EXIT

qa_log "Running disposable command/transfer observability matrix..."
set +e
xcodebuild test \
    -project "${PROJECT}" \
    -scheme Torrentino \
    -destination 'platform=macOS,arch=arm64' \
    -only-testing:TorrentinoEngineAgentTests/WP13DiagnosticsSecurityTests/testObservabilityCommandMatrixWritesEveryRequiredClass \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM=438UQRF7JV \
    2>&1 | tee "${XCODE_LOG}"
xcode_rc=${PIPESTATUS[0]}
set -e
assert_eq "${xcode_rc}" "0" "command/transfer observability XCTest"

qa_log "Running disposable live XPC connect and peer-verification probe..."
wp02_cli register
assert_eq "${WP02_CLI_RC}" "0" "observability register exit 0"
wp02_wait_for 15 wp02_agent_running || qa_die "observability agent did not spawn"
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "observability hello exit 0"
wp02_cli health
assert_eq "${WP02_CLI_RC}" "0" "observability health exit 0"
wp02_cli unregister
assert_eq "${WP02_CLI_RC}" "0" "observability unregister exit 0"
wp02_wait_for 10 wp02_agent_gone || qa_die "observability agent did not stop"

LOG_FILE="${LOG_ROOT}/engine_log_current.log"
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "${LOG_FILE}" ]] && break
    sleep 0.2
done
assert_file "${LOG_FILE}" "disposable engine log exists"
log_content="$(<"${LOG_FILE}")"

for marker in \
    "inspectAddSource" "commitAdd" "fetchFiles" "setFileSelection" \
    "pause" "resume" "reannounce" "prepareRemoval" "commitRemoval" \
    "checkpoint" "state transition" "bridge alerts drained" \
    "libtorrent alert type=" "severity=" "message=" \
    "xpc connect" "peer verification accepted"; do
    assert_contains "${log_content}" "${marker}" "observability marker ${marker}"
done

assert_not_contains "${log_content}" "bridge alerts drained count=0" "idle bridge drain does not spam the log"
alert_record_found=0
while IFS= read -r line; do
    if [[ "${line}" == *"libtorrent alert type="* && "${line}" == *"severity="* && "${line}" == *"message="* ]]; then
        alert_record_found=1
        break
    fi
done <<< "${log_content}"
if [[ "${alert_record_found}" -ne 1 ]]; then
    qa_die "live libtorrent alert record has an empty type, severity, or message"
fi

assert_not_contains "${log_content}" "${HOME}/" "home path is absent from engine log"
assert_not_contains "${log_content}" "qa-token" "token is absent from engine log"
assert_not_contains "${log_content}" "qa-passkey" "passkey is absent from engine log"
assert_not_contains "${log_content}" "Authorization: Bearer" "bearer material is absent from engine log"

qa_pass
