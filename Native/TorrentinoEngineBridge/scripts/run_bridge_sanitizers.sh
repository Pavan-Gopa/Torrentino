#!/usr/bin/env bash
#
# Torrentino — sanitizer run of the WP-04 engine bridge.
#
# Role:    builds the instrumented bridge smoke test (libtorrent + EngineBridge
#          compiled with -fsanitize=address,undefined) and runs the full bridge
#          lifecycle with sanitizers configured to fail hard. Separately runs a
#          ThreadSanitizer pass (TSan is incompatible with ASan in one binary)
#          using the release-prefix libtorrent and a TSan-instrumented build of
#          the bridge translation units.
# Why:     the engine owns user data on disk; here "clean" means zero reports.
#
# Usage: bash Native/TorrentinoEngineBridge/scripts/run_bridge_sanitizers.sh [--lt-version X]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
THIRD_PARTY_DIR="$(cd "${BRIDGE_DIR}/../ThirdParty" && pwd)"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

LT_VERSION="${LT_DEFAULT_VERSION}"
TIMEOUT="120"
while [[ $# -gt 0 ]]; do
	case "$1" in
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--timeout)    TIMEOUT="$2"; shift 2 ;;
		-h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

PREFIX_ROOT="${THIRD_PARTY_DIR}/.build/prefix"
LT_ASAN_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-asan"
LT_RELEASE_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-release"
BOOST_PREFIX="${PREFIX_ROOT}/boost-${BOOST_VERSION}"
OPENSSL_PREFIX="${PREFIX_ROOT}/openssl-${OPENSSL_VERSION}"

if [[ ! -f "${LT_ASAN_PREFIX}/lib/libtorrent-rasterbar.a" ]]; then
	echo "error: asan libtorrent prefix missing for ${LT_VERSION}" >&2
	exit 1
fi

RUN_DIR="${BRIDGE_DIR}/runs/sanitizers-bridge-${LT_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/sanitizers.log"

DEFINES=(
	-DTORRENT_ABI_VERSION=2
	-DTORRENT_USE_I2P=0
	-DTORRENT_USE_RTC=0
	-DTORRENT_USE_OPENSSL
	-DTORRENT_USE_LIBCRYPTO
	-DTORRENT_SSL_PEERS
)

ASAN_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-optimize-sibling-calls -O1 -g"

# --- ASan + UBSan -----------------------------------------------------------
echo "==> building bridge smoke [asan/ubsan]"
ASAN_BIN="${BRIDGE_DIR}/.build/smoke-${LT_VERSION}-asan/bridge-smoke"
mkdir -p "$(dirname "${ASAN_BIN}")"
clang++ -std=c++17 ${ASAN_FLAGS} \
	-fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE_DIR}/bridge" \
	-I"${LT_ASAN_PREFIX}/include" \
	-I"${BOOST_PREFIX}/include" \
	-I"${OPENSSL_PREFIX}/include" \
	"${DEFINES[@]}" \
	-DTORRENT_NO_DEPRECATE=1 \
	"${BRIDGE_DIR}/bridge/bridge_smoke.cpp" \
	"${BRIDGE_DIR}/bridge/EngineBridge.cpp" \
	"${LT_ASAN_PREFIX}/lib/libtorrent-rasterbar.a" \
	"${OPENSSL_PREFIX}/lib/libssl.a" \
	"${OPENSSL_PREFIX}/lib/libcrypto.a" \
	-framework CoreFoundation \
	-framework SystemConfiguration \
	-o "${ASAN_BIN}"

# detect_leaks is unavailable on macOS ASan; leaks are covered by RSS trends.
export ASAN_OPTIONS="abort_on_error=1:detect_stack_use_after_return=1:strict_string_checks=1:check_initialization_order=1:detect_container_overflow=1"
export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1:report_error_type=1"
export MallocNanoZone=0

echo "==> running bridge smoke [asan/ubsan] -> ${LOG}"
set +e
"${ASAN_BIN}" 2>&1 | tee "${LOG}"
asan_status="${PIPESTATUS[0]}"
set -e

asan_reports="$(grep -cE 'ERROR: AddressSanitizer|runtime error:|SUMMARY: UndefinedBehaviorSanitizer' "${LOG}" || true)"

# --- TSan (separate binary; TSan + ASan cannot share one process) ------------
echo "==> building bridge smoke [tsan]"
TSAN_BIN="${BRIDGE_DIR}/.build/smoke-${LT_VERSION}-tsan/bridge-smoke"
mkdir -p "$(dirname "${TSAN_BIN}")"
clang++ -std=c++17 -fsanitize=thread -fno-omit-frame-pointer -O1 -g \
	-fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE_DIR}/bridge" \
	-I"${LT_RELEASE_PREFIX}/include" \
	-I"${BOOST_PREFIX}/include" \
	-I"${OPENSSL_PREFIX}/include" \
	"${DEFINES[@]}" \
	-DTORRENT_NO_DEPRECATE=1 \
	"${BRIDGE_DIR}/bridge/bridge_smoke.cpp" \
	"${BRIDGE_DIR}/bridge/EngineBridge.cpp" \
	"${LT_RELEASE_PREFIX}/lib/libtorrent-rasterbar.a" \
	"${OPENSSL_PREFIX}/lib/libssl.a" \
	"${OPENSSL_PREFIX}/lib/libcrypto.a" \
	-framework CoreFoundation \
	-framework SystemConfiguration \
	-o "${TSAN_BIN}"

TSAN_LOG="${RUN_DIR}/tsan.log"
export TSAN_OPTIONS="halt_on_error=1"
echo "==> running bridge smoke [tsan] -> ${TSAN_LOG}"
set +e
"${TSAN_BIN}" 2>&1 | tee "${TSAN_LOG}"
tsan_status="${PIPESTATUS[0]}"
set -e

tsan_reports="$(grep -cE 'WARNING: ThreadSanitizer' "${TSAN_LOG}" || true)"

echo
echo "asan/ubsan status: ${asan_status}, reports: ${asan_reports}"
echo "tsan status:       ${tsan_status}, reports: ${tsan_reports}"
if [[ "${asan_status}" -ne 0 || "${asan_reports}" -ne 0 || "${tsan_status}" -ne 0 || "${tsan_reports}" -ne 0 ]]; then
	echo "RESULT: FAIL — sanitizer reports found (${LOG})" >&2
	exit 1
fi
echo "RESULT: PASS — bridge clean under ASan/UBSan + TSan (${LOG})"