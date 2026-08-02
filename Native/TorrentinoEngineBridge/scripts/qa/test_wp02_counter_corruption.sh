#!/usr/bin/env bash
#
# QA WP-02 — counter corruption detection (feature 3b).
#
# Verifies:
#   * a flipped byte in the v2 payload is rejected at bootstrap;
#   * direct agent launch exits 1 (fault);
#   * stderr/logs contain "counter store corrupt" (or FATAL bootstrap);
#   * the corrupt file is NOT silently overwritten;
#   * truncated file also rejected.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${QA_DIR}/qa_wp02_common.sh"

wp02_require_app
wp02_trap_cleanup
wp02_reset

wp02_resolve_standalone_agent || qa_die "standalone TorrentinoEngineAgent binary missing"
AGENT="${WP02_STANDALONE_AGENT}"
qa_log "AGENT=${AGENT}"

# Seed a valid v2 counter via SMAppService, then stop cleanly so we own the file.
wp02_register_and_wait || qa_die "register failed"
wp02_cli increment; assert_contains "${WP02_CLI_OUT}" "counter=1" "seed counter=1"
wp02_cli shutdown
wp02_wait_for 10 wp02_agent_gone || true
# Unregister so no launchd job fights our direct-launch probes.
wp02_cli unregister
launchctl bootout "${WP02_DOMAIN}/${WP02_LABEL}" >/dev/null 2>&1 || true
sleep 0.5

assert_file "${WP02_COUNTER}" "seeded counter.dat present"
BEFORE_HASH="$(shasum -a 256 "${WP02_COUNTER}" | awk '{print $1}')"
BEFORE_MAGIC="$(wp02_counter_magic)"
assert_eq "${BEFORE_MAGIC}" "TTC2" "seed magic TTC2"

# --- corrupt: flip a data byte (offset 4 = first value byte) ----------------
printf '\xff' | dd of="${WP02_COUNTER}" bs=1 seek=4 count=1 conv=notrunc 2>/dev/null
CORRUPT_HASH="$(shasum -a 256 "${WP02_COUNTER}" | awk '{print $1}')"
assert_ne "${CORRUPT_HASH}" "${BEFORE_HASH}" "file changed after byte flip"

log="$(qa_mktemp)/corrupt.log"
set +e
"${AGENT}" >"${log}" 2>&1
cor_rc=$?
set -e
qa_log "corrupt direct launch rc=${cor_rc}"
cat "${log}" | while IFS= read -r line; do qa_log "  | ${line}"; done || true

assert_eq "${cor_rc}" "1" "corrupt counter → exit 1"
body="$(cat "${log}")"
# Product message: "counter store corrupt" (CounterStoreError) or FATAL bootstrap
if echo "${body}" | grep -qiE 'counter store corrupt|checksum|FATAL'; then
	qa_ok "corruption fatal message present"
else
	qa_die "expected corruption/FATAL message in stderr, got: ${body}"
fi

# File must not have been rewritten to a clean store (checksum still flipped).
AFTER_HASH="$(shasum -a 256 "${WP02_COUNTER}" | awk '{print $1}')"
assert_eq "${AFTER_HASH}" "${CORRUPT_HASH}" "corrupt file not silently overwritten"

# No residual agent serving.
wp02_agent_running && qa_die "agent still running after corrupt bootstrap" || qa_ok "no agent after corrupt exit"

# --- edge: truncated file ---------------------------------------------------
printf 'TTC2' > "${WP02_COUNTER}"  # only magic, no value/checksum
log2="$(qa_mktemp)/trunc.log"
set +e
"${AGENT}" >"${log2}" 2>&1
trunc_rc=$?
set -e
assert_eq "${trunc_rc}" "1" "truncated counter → exit 1"
assert_match "$(cat "${log2}")" "(corrupt|FATAL|truncated|too short)" "truncated fatal message"

# --- edge: unknown magic ----------------------------------------------------
printf 'XXXX\x01\x00\x00\x00\x00\x00\x00\x00' > "${WP02_COUNTER}"
log3="$(qa_mktemp)/magic.log"
set +e
"${AGENT}" >"${log3}" 2>&1
magic_rc=$?
set -e
assert_eq "${magic_rc}" "1" "unknown magic → exit 1"

qa_pass
