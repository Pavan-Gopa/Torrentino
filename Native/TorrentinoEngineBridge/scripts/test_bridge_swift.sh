#!/usr/bin/env bash
#
# Torrentino — Swift-side bridge integration test (WP-04).
#
# Role:    proves the EngineCoordinator → EngineBridgeAdapter → EngineBridge
#          path with real Swift, ObjC++ and C++ code: start (peer-id from
#          config), add (magnet), pause/resume/recheck carrying the torrent id,
#          and the not-found error path for an unknown id. Exit 0 only on a
#          clean pass. This is the only test that exercises the Swift actor.
# Must not: touch the network, use a Homebrew/system libtorrent, or exit 0
#          while any assertion failed.
#
# Usage: bash Native/TorrentinoEngineBridge/scripts/test_bridge_swift.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NATIVE_DIR="$(cd "${BRIDGE_DIR}/.." && pwd)"
THIRD_PARTY_DIR="$(cd "${NATIVE_DIR}/ThirdParty" && pwd)"

# shellcheck source=../../ThirdParty/versions.lock
source "${THIRD_PARTY_DIR}/versions.lock"

PREFIX_ROOT="${THIRD_PARTY_DIR}/.build/prefix"
LT_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_DEFAULT_VERSION}-release"
BOOST_PREFIX="${PREFIX_ROOT}/boost-${BOOST_VERSION}"
OPENSSL_PREFIX="${PREFIX_ROOT}/openssl-${OPENSSL_VERSION}"

if [[ ! -f "${LT_PREFIX}/lib/libtorrent-rasterbar.a" ]]; then
	echo "error: pinned libtorrent not built for ${LT_DEFAULT_VERSION}/release." >&2
	exit 1
fi

BUILD_DIR="${BRIDGE_DIR}/.build/swift-${LT_DEFAULT_VERSION}-release"
mkdir -p "${BUILD_DIR}"

DEFINES=(
	-DTORRENT_ABI_VERSION=2
	-DTORRENT_USE_I2P=0
	-DTORRENT_USE_RTC=0
	-DTORRENT_USE_OPENSSL
	-DTORRENT_USE_LIBCRYPTO
	-DTORRENT_SSL_PEERS
)

echo "==> building bridge adapter [objc++ compile check]"
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

echo "==> building engine core [c++17, -Werror]"
BRIDGE_OBJ="${BUILD_DIR}/EngineBridge.o"
clang++ -std=c++17 -O1 -fexceptions \
	-Wall -Wextra -Wpedantic -Werror \
	-I"${BRIDGE_DIR}/bridge" \
	-I"${LT_PREFIX}/include" \
	-I"${BOOST_PREFIX}/include" \
	-I"${OPENSSL_PREFIX}/include" \
	"${DEFINES[@]}" \
	-DTORRENT_NO_DEPRECATE=1 \
	-c "${BRIDGE_DIR}/bridge/EngineBridge.cpp" \
	-o "${BRIDGE_OBJ}"

echo "==> building TorrentinoIPC module [Swift 6, strict concurrency]"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
	-module-name TorrentinoIPC \
	-emit-module -emit-module-path "${BUILD_DIR}/TorrentinoIPC.swiftmodule" \
	-emit-library -o "${BUILD_DIR}/libTorrentinoIPC.dylib" \
	"${NATIVE_DIR}/TorrentinoIPC/"*.swift

# TorrentinoDomain is built against the freshly built TorrentinoIPC module so
# its #if canImport(TorrentinoIPC) shims (EngineFault/FileKind/Page fallbacks)
# stay out: the agent sources compiled below import both modules, and the
# standalone shims would otherwise collide with the real IPC types.
echo "==> building TorrentinoDomain module [Swift 6, strict concurrency]"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
	-module-name TorrentinoDomain \
	-I "${BUILD_DIR}" \
	-emit-module -emit-module-path "${BUILD_DIR}/TorrentinoDomain.swiftmodule" \
	-emit-library -o "${BUILD_DIR}/libTorrentinoDomain.dylib" \
	-L "${BUILD_DIR}" -lTorrentinoIPC \
	-Xlinker -rpath -Xlinker "${BUILD_DIR}" \
	"${NATIVE_DIR}/TorrentinoDomain/"*.swift

echo "==> building + linking swift integration test"
BINARY="${BUILD_DIR}/bridge-swift-test"
AGENT_SOURCES=(
	"${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinator.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineBridgeDTOs.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/EngineCoordinator/EngineCoordinatorError.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Agent/EngineAlertDTOLogMapping.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/AdvisoryLock.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/AtomicGeneration.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/FailpointInjector.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/PersistenceError.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/PersistenceStore.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/OperationJournal.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/QuarantineManager.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/RemovalJournal.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/ShutdownCoordinator.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/SQLiteConnection.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Persistence/StartupReconciler.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/BridgeTransferEngine.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/HTTPSourceFetcher.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/MoveStorageRecovery.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/Preflight.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/RemovalManifest.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/StatusCache.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TorrentAdder.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferCoordinator.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferEventBus.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TransferRecord.swift"
	"${NATIVE_DIR}/TorrentinoEngineAgent/Transfer/TrashService.swift"
)
swiftc -o "${BINARY}" \
	-swift-version 6 -strict-concurrency=complete \
	-parse-as-library \
	-I "${BUILD_DIR}" \
	-L "${BUILD_DIR}" -lTorrentinoIPC -lTorrentinoDomain \
	-import-objc-header "${NATIVE_DIR}/TorrentinoEngineAgent/TorrentinoEngineAgent-Bridging-Header.h" \
	-I "${NATIVE_DIR}/TorrentinoEngineBridge/adapter" \
	"${BRIDGE_DIR}/harness/bridge_swift_test.swift" \
	"${AGENT_SOURCES[@]}" \
	"${ADAPTER_OBJ}" "${BRIDGE_OBJ}" \
	"${LT_PREFIX}/lib/libtorrent-rasterbar.a" \
	"${OPENSSL_PREFIX}/lib/libssl.a" \
	"${OPENSSL_PREFIX}/lib/libcrypto.a" \
	-lsqlite3 \
	-Xlinker -rpath -Xlinker "${BUILD_DIR}" \
	-Xlinker -lc++ \
	-framework Foundation \
	-framework CoreFoundation \
	-framework SystemConfiguration

RUN_DIR="${BRIDGE_DIR}/runs/swift-${LT_DEFAULT_VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${RUN_DIR}"
LOG="${RUN_DIR}/swift-test.log"

echo "==> running swift bridge test -> ${LOG}"
set +e
"${BINARY}" 2>&1 | tee "${LOG}"
status="${PIPESTATUS[0]}"
set -e

if [[ "${status}" -eq 0 ]]; then
	echo "RESULT: PASS — Swift bridge integration clean (${LOG})"
else
	echo "RESULT: FAIL with status ${status} (${LOG})" >&2
fi
exit "${status}"
