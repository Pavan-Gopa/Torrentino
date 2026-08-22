#!/usr/bin/env bash
# Debug build of bridge_smoke (release flavor) for WP-04 diagnosis.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
BRIDGE="Native/TorrentinoEngineBridge"
PREFIX="Native/ThirdParty/.build/prefix"
# Single source of truth for the libtorrent pin (SEC-2 partial-pin fix):
# always link the release prefix of the versions.lock DEFAULT version.
# shellcheck source=../../ThirdParty/versions.lock
source "Native/ThirdParty/versions.lock"
LT="${PREFIX}/libtorrent-${LT_DEFAULT_VERSION}-release"
BOOST="${PREFIX}/boost-1.91.0"
OPENSSL="${PREFIX}/openssl-3.5.7"
OUT="$1"
SRC="${2:-${BRIDGE}/bridge/bridge_smoke.cpp}"
mkdir -p "$(dirname "$OUT")"
clang++ -std=c++17 -O1 -g -fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE}/bridge" -I"${LT}/include" -I"${BOOST}/include" -I"${OPENSSL}/include" \
	-DTORRENT_ABI_VERSION=2 -DTORRENT_USE_I2P=0 -DTORRENT_USE_RTC=0 \
	-DTORRENT_USE_OPENSSL -DTORRENT_USE_LIBCRYPTO -DTORRENT_SSL_PEERS -DTORRENT_NO_DEPRECATE=1 \
	"${SRC}" "${BRIDGE}/bridge/EngineBridge.cpp" \
	"${LT}/lib/libtorrent-rasterbar.a" "${OPENSSL}/lib/libssl.a" "${OPENSSL}/lib/libcrypto.a" \
	-framework CoreFoundation -framework SystemConfiguration \
	-o "${OUT}"