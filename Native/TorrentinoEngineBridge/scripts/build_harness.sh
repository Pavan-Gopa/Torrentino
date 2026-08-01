#!/usr/bin/env bash
#
# Torrentino — build the headless engine harness (WP-01).
#
# Role:    configures and builds harness/ against the pinned libtorrent prefix
#          produced by Native/ThirdParty/libtorrent/build.sh, then proves the
#          resulting binary has no Homebrew/local runtime dependency.
# Must not: fall back to a system libtorrent, Boost or OpenSSL.
#
# Usage: bash Native/TorrentinoEngineBridge/scripts/build_harness.sh [options]
#   --flavor <release|asan>       must match a built third-party flavor
#   --lt-version <2.1.0|2.0.13>   libtorrent release to link against
#   --jobs <N>                    parallel jobs
#   --clean                       reconfigure from scratch
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NATIVE_DIR="$(cd "${BRIDGE_DIR}/.." && pwd)"
THIRD_PARTY_DIR="${NATIVE_DIR}/ThirdParty"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

FLAVOR="release"
LT_VERSION="${LT_DEFAULT_VERSION}"
JOBS="$(sysctl -n hw.ncpu)"
DO_CLEAN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--flavor)     FLAVOR="$2"; shift 2 ;;
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--jobs)       JOBS="$2"; shift 2 ;;
		--clean)      DO_CLEAN=1; shift ;;
		-h|--help)    sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

PREFIX_ROOT="${THIRD_PARTY_DIR}/.build/prefix"
LT_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-${FLAVOR}"
BOOST_PREFIX="${PREFIX_ROOT}/boost-${BOOST_VERSION}"
OPENSSL_PREFIX="${PREFIX_ROOT}/openssl-${OPENSSL_VERSION}"
BUILD_DIR="${BRIDGE_DIR}/.build/harness-${LT_VERSION}-${FLAVOR}"

if [[ ! -f "${LT_PREFIX}/lib/libtorrent-rasterbar.a" ]]; then
	echo "error: pinned libtorrent not built for ${LT_VERSION}/${FLAVOR}." >&2
	echo "       run: bash Native/ThirdParty/libtorrent/build.sh --lt-version ${LT_VERSION} --flavor ${FLAVOR}" >&2
	exit 1
fi

[[ ${DO_CLEAN} -eq 1 ]] && rm -rf "${BUILD_DIR}"

CMAKE_BUILD_TYPE="Release"
EXTRA_FLAGS=""
if [[ "${FLAVOR}" == "asan" ]]; then
	# Must match the flags libtorrent was built with, otherwise the sanitizer
	# runtime and the library disagree about container annotations.
	CMAKE_BUILD_TYPE="RelWithDebInfo"
	EXTRA_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-optimize-sibling-calls -O1 -g"
fi

declare -a CMAKE_ARGS=(
	-S "${BRIDGE_DIR}/harness" -B "${BUILD_DIR}"
	-DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}"
	-DCMAKE_OSX_ARCHITECTURES="${TORRENTINO_ARCH}"
	-DCMAKE_OSX_DEPLOYMENT_TARGET="${TORRENTINO_DEPLOYMENT_TARGET}"
	-DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
	-DCMAKE_PREFIX_PATH="${LT_PREFIX};${BOOST_PREFIX};${OPENSSL_PREFIX}"
	-DBOOST_ROOT="${BOOST_PREFIX}"
	-DBoost_INCLUDE_DIR="${BOOST_PREFIX}/include"
	-DBoost_NO_SYSTEM_PATHS=ON
	-DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}"
	-DOPENSSL_USE_STATIC_LIBS=ON
	-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
	-DCMAKE_POLICY_DEFAULT_CMP0167=OLD
	-DCMAKE_POLICY_WARNING_CMP0167=OFF
	-DCMAKE_C_FLAGS="${EXTRA_FLAGS}"
	-DCMAKE_CXX_FLAGS="${EXTRA_FLAGS}"
)
if command -v ninja >/dev/null 2>&1; then
	CMAKE_ARGS+=(-G Ninja)
else
	CMAKE_ARGS+=(-G "Unix Makefiles")
fi

echo "==> configuring harness [${LT_VERSION}/${FLAVOR}]"
cmake "${CMAKE_ARGS[@]}"
echo "==> building harness with ${JOBS} jobs"
cmake --build "${BUILD_DIR}" --parallel "${JOBS}"

BINARY="${BUILD_DIR}/torrentino-harness"
[[ -x "${BINARY}" ]] || { echo "error: harness binary missing" >&2; exit 1; }

bash "${SCRIPT_DIR}/verify_no_homebrew.sh" "${BINARY}"

echo
echo "harness ready: ${BINARY}"
"${BINARY}" version
