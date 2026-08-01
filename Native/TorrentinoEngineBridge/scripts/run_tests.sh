#!/usr/bin/env bash
#
# Torrentino — run the WP-01 harness scenario suite.
#
# Role:    one command that builds (if needed) and runs every acceptance
#          scenario against a pinned libtorrent flavor, and fails loudly.
# Usage:   bash Native/TorrentinoEngineBridge/scripts/run_tests.sh [options]
#            --flavor <release|asan>      default release
#            --lt-version <2.1.0|2.0.13>  default from versions.lock
#            --timeout <seconds>          per-step timeout (default 120)
#            --scenario <name>            run a single scenario
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
THIRD_PARTY_DIR="$(cd "${BRIDGE_DIR}/../ThirdParty" && pwd)"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

FLAVOR="release"
LT_VERSION="${LT_DEFAULT_VERSION}"
TIMEOUT="120"
SCENARIO=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--flavor)     FLAVOR="$2"; shift 2 ;;
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--timeout)    TIMEOUT="$2"; shift 2 ;;
		--scenario)   SCENARIO="$2"; shift 2 ;;
		-h|--help)    sed -n '2,13p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

BINARY="${BRIDGE_DIR}/.build/harness-${LT_VERSION}-${FLAVOR}/torrentino-harness"
if [[ ! -x "${BINARY}" ]]; then
	bash "${SCRIPT_DIR}/build_harness.sh" --flavor "${FLAVOR}" --lt-version "${LT_VERSION}"
fi

RUN_DIR="${BRIDGE_DIR}/runs/tests-${LT_VERSION}-${FLAVOR}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/scenarios.log"

echo "==> running scenarios [${LT_VERSION}/${FLAVOR}] -> ${LOG}"
set +e
if [[ -n "${SCENARIO}" ]]; then
	"${BINARY}" run "${SCENARIO}" --timeout "${TIMEOUT}" --workspace "${RUN_DIR}/work" 2>&1 | tee "${LOG}"
else
	"${BINARY}" run-all --timeout "${TIMEOUT}" --workspace "${RUN_DIR}/work" 2>&1 | tee "${LOG}"
fi
status="${PIPESTATUS[0]}"
set -e

echo
if [[ "${status}" -eq 0 ]]; then
	echo "RESULT: PASS (log: ${LOG})"
else
	echo "RESULT: FAIL with status ${status} (log: ${LOG})" >&2
fi
exit "${status}"
