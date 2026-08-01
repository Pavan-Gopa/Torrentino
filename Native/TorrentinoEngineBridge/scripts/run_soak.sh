#!/usr/bin/env bash
#
# Torrentino — start (or attach to) the WP-01 24h soak.
#
# Role:    launches the harness soak detached from the terminal, records the PID
#          and log location, and can report the current status. The WP-01 gate
#          is "24h without crash or hang", which nobody can babysit interactively.
#
# Usage:
#   bash Native/TorrentinoEngineBridge/scripts/run_soak.sh start [--duration 86400]
#   bash Native/TorrentinoEngineBridge/scripts/run_soak.sh status
#   bash Native/TorrentinoEngineBridge/scripts/run_soak.sh stop
#
# `stop` sends SIGTERM: the soak stops after the current iteration and still
# writes its JSON report.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
THIRD_PARTY_DIR="$(cd "${BRIDGE_DIR}/../ThirdParty" && pwd)"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

COMMAND="${1:-status}"
[[ $# -gt 0 ]] && shift || true

FLAVOR="release"
LT_VERSION="${LT_DEFAULT_VERSION}"
DURATION="86400"        # 24 hours
REPORT_INTERVAL="300"   # 5 minutes
ITERATION_TIMEOUT="300" # a loopback cycle takes seconds; 5 min means "hung"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--flavor)          FLAVOR="$2"; shift 2 ;;
		--lt-version)      LT_VERSION="$2"; shift 2 ;;
		--duration)        DURATION="$2"; shift 2 ;;
		--report-interval) REPORT_INTERVAL="$2"; shift 2 ;;
		--timeout)         ITERATION_TIMEOUT="$2"; shift 2 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

SOAK_DIR="${BRIDGE_DIR}/runs/soak"
PID_FILE="${SOAK_DIR}/soak.pid"
LOG_FILE="${SOAK_DIR}/soak.log"
REPORT_FILE="${SOAK_DIR}/soak-report.json"
BINARY="${BRIDGE_DIR}/.build/harness-${LT_VERSION}-${FLAVOR}/torrentino-harness"

soak_running() {
	[[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

case "${COMMAND}" in
start)
	if soak_running; then
		echo "soak already running (pid $(cat "${PID_FILE}"))"
		exit 0
	fi
	# Always build/rebuild harness to ensure latest code changes are compiled
	bash "${SCRIPT_DIR}/build_harness.sh" --flavor "${FLAVOR}" --lt-version "${LT_VERSION}"
	mkdir -p "${SOAK_DIR}/work"
	: > "${LOG_FILE}"
	# Detach fully: the soak has to survive the terminal that started it.
	nohup "${BINARY}" soak \
		--duration "${DURATION}" \
		--report-interval "${REPORT_INTERVAL}" \
		--timeout "${ITERATION_TIMEOUT}" \
		--workspace "${SOAK_DIR}/work" \
		--report "${REPORT_FILE}" \
		>>"${LOG_FILE}" 2>&1 </dev/null &
	echo $! > "${PID_FILE}"
	sleep 2
	echo "soak started"
	echo "  pid    : $(cat "${PID_FILE}")"
	echo "  binary : ${BINARY}"
	echo "  log    : ${LOG_FILE}"
	echo "  report : ${REPORT_FILE}"
	echo "  ends   : $(date -v +"${DURATION}"S 2>/dev/null || date)"
	;;
status)
	if soak_running; then
		pid="$(cat "${PID_FILE}")"
		echo "soak RUNNING (pid ${pid})"
		ps -o pid,etime,%cpu,rss -p "${pid}" | tail -n +1
		echo "--- last progress lines ---"
		grep 'soak progress' "${LOG_FILE}" 2>/dev/null | tail -5 || echo "(no progress report yet)"
		echo "--- errors so far ---"
		grep -cE 'ERROR|FATAL' "${LOG_FILE}" 2>/dev/null || true
	else
		echo "soak NOT running"
		if [[ -f "${REPORT_FILE}" ]]; then
			echo "--- last report ---"
			cat "${REPORT_FILE}"
		fi
		[[ -f "${LOG_FILE}" ]] && { echo "--- log tail ---"; tail -5 "${LOG_FILE}"; }
	fi
	;;
stop)
	if soak_running; then
		pid="$(cat "${PID_FILE}")"
		kill -TERM "${pid}"
		echo "SIGTERM sent to ${pid}; it stops after the current iteration"
	else
		echo "soak not running"
	fi
	;;
*)
	echo "usage: run_soak.sh {start|status|stop} [options]" >&2
	exit 2
	;;
esac
