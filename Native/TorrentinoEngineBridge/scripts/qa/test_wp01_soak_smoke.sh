#!/usr/bin/env bash
#
# QA WP-01 — soak driver smoke (feature 6).
#
# Verifies:
#   * run_soak.sh status exits 0 and its output parses (RUNNING or NOT running);
#   * a short (25s) soak run of the harness exits 0;
#   * the soak JSON report is valid and reports status=ok, iterations>0,
#     error_alerts=0;
#   * the soak log has no ERROR/FATAL lines.
#
# Isolation: the short soak runs the harness binary DIRECTLY with a disposable
# mktemp workspace and report path, so it never touches the shared runs/soak
# state used by the long 24h burn-in (which may be running concurrently).
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"
BIN="${BRIDGE_DIR}/.build/harness-${LT_DEFAULT_VERSION}-release/torrentino-harness"
[[ -x "${BIN}" ]] || qa_die "harness binary missing: ${BIN}"

# --- Part A: status subcommand parses --------------------------------------
status_out="$(qa_mktemp)/status.log"
set +e
bash "${RUN_SOAK_SH}" status >"${status_out}" 2>&1
st=$?
set -e
assert_eq "${st}" "0" "run_soak.sh status exit code"
stext="$(cat "${status_out}")"
if [[ "${stext}" == *"soak RUNNING"* || "${stext}" == *"soak NOT running"* ]]; then
	qa_ok "status output parses (RUNNING/NOT running)"
else
	qa_die "status output did not parse: ${stext}"
fi

# --- Part B: short soak smoke via the binary directly ----------------------
ws="$(qa_mktemp)/work"
report="$(qa_mktemp)/soak-report.json"
log="$(qa_mktemp)/soak.log"
qa_log "running 25s soak smoke (isolated workspace)"
set +e
"${BIN}" soak --duration 25 --report-interval 10 --timeout 60 \
	--workspace "${ws}" --report "${report}" >"${log}" 2>&1
soak_status=$?
set -e
assert_eq "${soak_status}" "0" "soak smoke exit code"

logtext="$(cat "${log}")"
assert_contains "${logtext}" "soak finished: status=ok" "soak finished cleanly"
assert_eq "$(grep -cE 'ERROR|FATAL' "${log}" || true)" "0" "no ERROR/FATAL in soak smoke log"

assert_file "${report}" "soak JSON report written"
jq -e . "${report}" >/dev/null || qa_die "soak report is not valid JSON"
qa_ok "soak report is valid JSON"
assert_eq "$(jq -r .status "${report}")" "ok" "report status"
assert_ge "$(jq -r .iterations "${report}")" "1" "report iterations"
assert_eq "$(jq -r .error_alerts "${report}")" "0" "report error_alerts"

qa_pass
