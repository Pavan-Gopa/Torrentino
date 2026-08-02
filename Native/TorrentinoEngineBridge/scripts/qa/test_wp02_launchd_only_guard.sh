#!/usr/bin/env bash
#
# QA WP-02 — launchd-only serving guard (feature 6).
#
# Verifies:
#   * direct execution of the agent binary (no XPC_SERVICE_NAME) exits 1;
#   * stderr contains FATAL + launchd / SMAppService messaging;
#   * agent does NOT stay resident as a zombie listener;
#   * when launched via SMAppService (XPC_SERVICE_NAME set by launchd), serving works.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

# Ensure no SMAppService job owns the Mach port.
wp02_cli unregister >/dev/null 2>&1 || true
launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
rm -rf "${WP02_ENGINE_DIR}"

# --- error: direct binary, no XPC_SERVICE_NAME ------------------------------
# Unset any inherited XPC_SERVICE_NAME for a clean probe.
log="$(qa_mktemp)/direct.log"
set +e
env -u XPC_SERVICE_NAME "${WP02_AGENT_BIN}" >"${log}" 2>&1
direct_rc=$?
set -e
qa_log "direct launch rc=${direct_rc}"
body="$(cat "${log}")"
echo "${body}" | while IFS= read -r line; do qa_log "  | ${line}"; done || true

assert_eq "${direct_rc}" "1" "direct launch without XPC_SERVICE_NAME → exit 1"
assert_contains "${body}" "FATAL" "FATAL on stderr"
assert_match "${body}" "(launchd|SMAppService|XPC_SERVICE_NAME|Mach)" "mentions launchd/Mach guard"
wp02_agent_running && qa_die "zombie agent after direct launch" || qa_ok "no residual process"

# --- edge: explicit empty XPC_SERVICE_NAME also fails -----------------------
log2="$(qa_mktemp)/empty-env.log"
set +e
env XPC_SERVICE_NAME= "${WP02_AGENT_BIN}" >"${log2}" 2>&1
empty_rc=$?
set -e
assert_eq "${empty_rc}" "1" "empty XPC_SERVICE_NAME → exit 1"

# --- happy: launchd-managed (SMAppService) serves ---------------------------
wp02_register_and_wait || qa_die "SMAppService register failed"
wp02_cli hello
assert_eq "${WP02_CLI_RC}" "0" "hello works when launchd-managed"
assert_contains "${WP02_CLI_OUT}" "OK hello" "launchd-managed XPC OK"

qa_pass
