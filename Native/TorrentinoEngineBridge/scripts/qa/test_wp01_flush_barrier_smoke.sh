#!/usr/bin/env bash
#
# QA WP-01 — flush_cache barrier / deterministic digest verification (feature 10).
#
# The recurring soak bug was a read-before-flush race: the payload SHA-256 was
# computed before libtorrent's async disk writes landed. The fix is a
# deterministic barrier (flush_cache() + cache_flushed_alert) in soak.cpp.
#
# Verifies:
#   * the barrier is present in source (flush_cache + cache_flushed_alert);
#   * a short isolated soak run produces ZERO "payload digest mismatch";
#   * the run is clean (exit 0, error_alerts=0, iterations>0).
#
# Isolation: runs the harness binary directly with a disposable workspace so it
# never touches the shared runs/soak state of the long 24h burn-in.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"
BIN="${BRIDGE_DIR}/.build/harness-${LT_DEFAULT_VERSION}-release/torrentino-harness"
[[ -x "${BIN}" ]] || qa_die "harness binary missing: ${BIN}"
SOAK_SRC="${BRIDGE_DIR}/harness/src/soak.cpp"

# --- static: the barrier is wired in ---------------------------------------
src="$(cat "${SOAK_SRC}")"
assert_contains "${src}" "flush_cache()" "flush_cache() barrier present in soak.cpp"
assert_contains "${src}" "cache_flushed_alert" "cache_flushed_alert wait present in soak.cpp"
assert_contains "${src}" "payload digest mismatch" "digest verification present in soak.cpp"

# --- dynamic: short soak, no digest mismatch -------------------------------
ws="$(qa_mktemp)/work"
report="$(qa_mktemp)/soak-report.json"
log="$(qa_mktemp)/soak.log"
qa_log "running 25s soak smoke to exercise the flush barrier"
set +e
"${BIN}" soak --duration 25 --report-interval 10 --timeout 60 \
	--workspace "${ws}" --report "${report}" >"${log}" 2>&1
st=$?
set -e
assert_eq "${st}" "0" "flush-barrier soak smoke exit code"

logtext="$(cat "${log}")"
assert_eq "$(grep -c 'payload digest mismatch' "${log}" || true)" "0" "no payload digest mismatch"
assert_contains "${logtext}" "soak finished: status=ok" "soak finished cleanly"
assert_ge "$(grep -c 'digest ok' "${log}" || true)" "1" "at least one verified digest"

assert_file "${report}" "soak report written"
jq -e . "${report}" >/dev/null || qa_die "soak report invalid JSON"
assert_eq "$(jq -r .status "${report}")" "ok" "report status"
assert_eq "$(jq -r .error_alerts "${report}")" "0" "report error_alerts"
assert_ge "$(jq -r .iterations "${report}")" "1" "report iterations"

qa_pass
