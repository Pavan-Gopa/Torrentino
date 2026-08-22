#!/usr/bin/env bash
#
# Torrentino — headless engine bridge smoke test (WP-04).
#
# Role:    builds bridge_smoke.cpp against the pinned libtorrent prefix and the
#          EngineBridge facade, then runs the full lifecycle (start/add/check/
#          pause/resume/recheck/remove/shutdown). Exit 0 only on a clean pass.
# Must not: touch the network, use a Homebrew/system libtorrent, or exit 0 while
#          any assertion failed.
#
# Usage: bash Native/TorrentinoEngineBridge/scripts/test_bridge_headless.sh [options]
#   --flavor <release|asan>      match a built third-party flavor (default release)
#   --lt-version <pinned>        libtorrent release to link against; must be
#                                in LT_SUPPORTED_VERSIONS of versions.lock
#   --timeout <seconds>          wall-clock timeout for the whole run
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

while [[ $# -gt 0 ]]; do
	case "$1" in
		--flavor)     FLAVOR="$2"; shift 2 ;;
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--timeout)    TIMEOUT="$2"; shift 2 ;;
		-h|--help)    sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done
# SEC-2 partial-pin closure (WP13-SEC-HARDEN-001 REVIEW-002): fail closed on
# removed pins instead of resolving a stale/absent prefix.
case " ${LT_SUPPORTED_VERSIONS} " in
	*" ${LT_VERSION} "*) ;;
	*) echo "error: libtorrent ${LT_VERSION} is not pinned in versions.lock (supported: ${LT_SUPPORTED_VERSIONS})" >&2; exit 2 ;;
esac

PREFIX_ROOT="${THIRD_PARTY_DIR}/.build/prefix"
LT_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-${FLAVOR}"
BOOST_PREFIX="${PREFIX_ROOT}/boost-${BOOST_VERSION}"
OPENSSL_PREFIX="${PREFIX_ROOT}/openssl-${OPENSSL_VERSION}"

if [[ ! -f "${LT_PREFIX}/lib/libtorrent-rasterbar.a" ]]; then
	echo "error: pinned libtorrent not built for ${LT_VERSION}/${FLAVOR}." >&2
	exit 1
fi

BUILD_DIR="${BRIDGE_DIR}/.build/smoke-${LT_VERSION}-${FLAVOR}"
mkdir -p "${BUILD_DIR}"
BINARY="${BUILD_DIR}/bridge-smoke"

# Instrumented flavor mirrors the harness asan flags (must match libtorrent).
EXTRA_FLAGS=""
if [[ "${FLAVOR}" == "asan" ]]; then
	EXTRA_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-optimize-sibling-calls -O1 -g"
fi

DEFINES=(
	-DTORRENT_ABI_VERSION=2
	-DTORRENT_USE_I2P=0
	-DTORRENT_USE_RTC=0
	-DTORRENT_USE_OPENSSL
	-DTORRENT_USE_LIBCRYPTO
	-DTORRENT_SSL_PEERS
)

echo "==> building bridge adapter [objc++ compile check]"
# WP-04 CHANGES_REQUESTED 3-1: the ObjC++ adapter must compile (and link against
# the EngineBridge facade) so syntax regressions in the Swift-facing boundary are
# caught by the same headless pipeline that covers the C++ core.
ADAPTER_OBJ="${BUILD_DIR}/EngineBridgeAdapter.o"
clang++ -std=c++17 -O1 -x objective-c++ -fobjc-arc -fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE_DIR}/bridge" \
	-I"${BRIDGE_DIR}/adapter" \
	-I"${LT_PREFIX}/include" \
	-I"${BOOST_PREFIX}/include" \
	-I"${OPENSSL_PREFIX}/include" \
	"${DEFINES[@]}" \
	-DTORRENT_NO_DEPRECATE=1 \
	-c "${BRIDGE_DIR}/adapter/EngineBridgeAdapter.mm" \
	-o "${ADAPTER_OBJ}"

echo "==> building bridge smoke [${LT_VERSION}/${FLAVOR}]"
# Warnings are errors. The macOS SDK's own headers must not pollute our flags;
# libtorrent/Boost headers arrive via -I and are not SYSTEM, so we keep them
# out of -Werror by scoping strictness to our translation unit via pragma-free
# -Wno-* for third-party noise only where unavoidable. Currently none needed.
clang++ -std=c++17 -O1 ${EXTRA_FLAGS} \
	-fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE_DIR}/bridge" \
	-I"${LT_PREFIX}/include" \
	-I"${BOOST_PREFIX}/include" \
	-I"${OPENSSL_PREFIX}/include" \
	"${DEFINES[@]}" \
	-DTORRENT_NO_DEPRECATE=1 \
	"${BRIDGE_DIR}/bridge/bridge_smoke.cpp" \
	"${BRIDGE_DIR}/bridge/EngineBridge.cpp" \
	"${ADAPTER_OBJ}" \
	"${LT_PREFIX}/lib/libtorrent-rasterbar.a" \
	"${OPENSSL_PREFIX}/lib/libssl.a" \
	"${OPENSSL_PREFIX}/lib/libcrypto.a" \
	-framework Foundation \
	-framework CoreFoundation \
	-framework SystemConfiguration \
	-o "${BINARY}"

RUN_DIR="${BRIDGE_DIR}/runs/smoke-${LT_VERSION}-${FLAVOR}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/smoke.log"

echo "==> running bridge smoke -> ${LOG}"
set +e
"${BINARY}" 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
set -e

if [[ "${status}" -eq 0 ]]; then
	echo "RESULT: PASS — bridge headless lifecycle clean (${LOG})"
else
	echo "RESULT: FAIL with status ${status} (${LOG})" >&2
fi
exit "${status}"