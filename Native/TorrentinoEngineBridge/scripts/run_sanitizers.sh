#!/usr/bin/env bash
#
# Torrentino — ASan + UBSan run of the WP-01 harness.
#
# Role:    builds the instrumented flavor (libtorrent and harness compiled with
#          -fsanitize=address,undefined) and runs the full scenario suite with
#          the sanitizers configured to fail hard.
# Why:     the engine owns user data on disk; a memory or UB bug here is a data
#          loss bug later, so "clean" means zero reports, not "few reports".
#
# Usage: bash Native/TorrentinoEngineBridge/scripts/run_sanitizers.sh [--lt-version X]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
THIRD_PARTY_DIR="$(cd "${BRIDGE_DIR}/../ThirdParty" && pwd)"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

LT_VERSION="${LT_DEFAULT_VERSION}"
TIMEOUT="300"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--timeout)    TIMEOUT="$2"; shift 2 ;;
		-h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

BINARY="${BRIDGE_DIR}/.build/harness-${LT_VERSION}-asan/torrentino-harness"
if [[ ! -x "${BINARY}" ]]; then
	bash "${THIRD_PARTY_DIR}/libtorrent/build.sh" --flavor asan --lt-version "${LT_VERSION}"
	bash "${SCRIPT_DIR}/build_harness.sh" --flavor asan --lt-version "${LT_VERSION}"
fi

RUN_DIR="${BRIDGE_DIR}/runs/sanitizers-${LT_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/sanitizers.log"

# detect_leaks is unavailable on macOS ASan; leaks are covered by the soak RSS
# trend and by `leaks` in later WPs.
export ASAN_OPTIONS="abort_on_error=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:detect_container_overflow=1:print_stats=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:report_error_type=1"
export MallocNanoZone=0 # required so ASan can install its allocator on macOS

echo "==> ASan/UBSan scenario run [${LT_VERSION}] -> ${LOG}"
set +e
"${BINARY}" run-all --timeout "${TIMEOUT}" --workspace "${RUN_DIR}/work" 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
set -e

reports="$(grep -cE 'ERROR: AddressSanitizer|runtime error:|SUMMARY: UndefinedBehaviorSanitizer' "${LOG}" || true)"
echo
echo "sanitizer reports: ${reports}"
if [[ "${status}" -ne 0 || "${reports}" -ne 0 ]]; then
	echo "RESULT: FAIL (status ${status}, ${reports} sanitizer report(s)) — ${LOG}" >&2
	exit 1
fi
echo "RESULT: PASS — ASan/UBSan clean (${LOG})"
