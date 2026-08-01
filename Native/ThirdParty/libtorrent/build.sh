#!/usr/bin/env bash
#
# Torrentino — pinned libtorrent toolchain build (WP-01).
#
# Role:    reproducible, self-contained build of libtorrent 2.x + its pinned
#          dependencies (Boost, OpenSSL) as arm64 *static* libraries for
#          macOS 13+. Output is consumed by TorrentinoEngineBridge.
# Owns:    Native/ThirdParty/.build (cache, sources, prefixes, logs, manifests).
# Must not: link, install or otherwise reference anything from /opt/homebrew or
#          /usr/local — the shipped .dmg must run on a machine with no dev tools.
# Invariant: nothing is built from an archive whose SHA-256 differs from
#          Native/ThirdParty/versions.lock.
#
# Usage: bash Native/ThirdParty/libtorrent/build.sh [options]
#   --lt-version <2.1.0|2.0.13>   libtorrent release to build (default: lock)
#   --flavor <release|asan>       release, or ASan+UBSan instrumented build
#   --jobs <N>                    parallel build jobs (default: all cores)
#   --deps-only                   build Boost/OpenSSL only
#   --clean                       wipe build dir of the selected flavor first
#   --print-prefix                print install prefix of the selection and exit
#   --no-tls                      build without OpenSSL (no HTTPS trackers)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THIRD_PARTY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCK_FILE="${THIRD_PARTY_DIR}/versions.lock"

# shellcheck source=../versions.lock
source "${LOCK_FILE}"

BUILD_ROOT="${THIRD_PARTY_DIR}/.build"
CACHE_DIR="${BUILD_ROOT}/cache"
SRC_DIR="${BUILD_ROOT}/src"
PREFIX_ROOT="${BUILD_ROOT}/prefix"
WORK_DIR="${BUILD_ROOT}/work"
LOG_DIR="${BUILD_ROOT}/logs"

LT_VERSION="${LT_DEFAULT_VERSION}"
FLAVOR="release"
JOBS="$(sysctl -n hw.ncpu)"
DEPS_ONLY=0
DO_CLEAN=0
PRINT_PREFIX_ONLY=0
WITH_TLS=1

while [[ $# -gt 0 ]]; do
	case "$1" in
		--lt-version) LT_VERSION="$2"; shift 2 ;;
		--flavor)     FLAVOR="$2"; shift 2 ;;
		--jobs)       JOBS="$2"; shift 2 ;;
		--deps-only)  DEPS_ONLY=1; shift ;;
		--clean)      DO_CLEAN=1; shift ;;
		--print-prefix) PRINT_PREFIX_ONLY=1; shift ;;
		--no-tls)     WITH_TLS=0; shift ;;
		-h|--help)    sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown option '$1'" >&2; exit 2 ;;
	esac
done

case " ${LT_SUPPORTED_VERSIONS} " in
	*" ${LT_VERSION} "*) ;;
	*) echo "error: libtorrent ${LT_VERSION} is not pinned in versions.lock" >&2; exit 2 ;;
esac
case "${FLAVOR}" in
	release|asan) ;;
	*) echo "error: unknown flavor '${FLAVOR}' (release|asan)" >&2; exit 2 ;;
esac

# Indirect lookup of the pins of the selected release (LT_2_1_0_* / LT_2_0_13_*).
LT_KEY="LT_${LT_VERSION//./_}"
lt_pin() { local n="${LT_KEY}_$1"; printf '%s' "${!n}"; }

OPENSSL_PREFIX="${PREFIX_ROOT}/openssl-${OPENSSL_VERSION}"
BOOST_PREFIX="${PREFIX_ROOT}/boost-${BOOST_VERSION}"
LT_PREFIX="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-${FLAVOR}"

if [[ ${PRINT_PREFIX_ONLY} -eq 1 ]]; then
	printf '%s\n' "${LT_PREFIX}"
	exit 0
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
# Build-time tools may come from anywhere (Xcode, Homebrew); only *runtime*
# linkage is constrained. Still fail loudly on a missing prerequisite so the
# error is one line instead of a 500-line compiler dump.
preflight() {
	[[ "$(uname -s)" == "Darwin" ]] || die "macOS host required"
	[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon host required (got $(uname -m))"
	local tool
	for tool in curl tar shasum cmake perl xcrun make; do
		command -v "${tool}" >/dev/null 2>&1 || die "missing build tool: ${tool}"
	done
	local cmake_ver
	cmake_ver="$(cmake --version | head -1 | awk '{print $3}')"
	printf '%s\n%s\n' "3.20.0" "${cmake_ver}" | sort -V -c >/dev/null 2>&1 \
		|| die "cmake >= 3.20 required (got ${cmake_ver})"
	SDK_PATH="$(xcrun --show-sdk-path)"
	[[ -d "${SDK_PATH}" ]] || die "macOS SDK not found"
	mkdir -p "${CACHE_DIR}" "${SRC_DIR}" "${PREFIX_ROOT}" "${WORK_DIR}" "${LOG_DIR}"
}

# --- fetch + integrity -----------------------------------------------------
fetch() { # url archive sha256
	local url="$1" archive="$2" want="$3" path got
	path="${CACHE_DIR}/${archive}"
	if [[ -f "${path}" ]]; then
		got="$(shasum -a 256 "${path}" | awk '{print $1}')"
		if [[ "${got}" == "${want}" ]]; then
			log "cached ${archive} (sha256 ok)"
			return 0
		fi
		warn "cached ${archive} has an unexpected hash, re-downloading"
		rm -f "${path}"
	fi
	log "downloading ${archive}"
	curl -fL --retry 5 --retry-delay 2 -o "${path}" "${url}" \
		|| die "download failed: ${url}"
	got="$(shasum -a 256 "${path}" | awk '{print $1}')"
	[[ "${got}" == "${want}" ]] \
		|| die "SHA-256 mismatch for ${archive}: expected ${want}, got ${got}"
	log "verified ${archive} (sha256 ${got})"
}

extract() { # archive dirname
	local archive="$1" dirname="$2" stamp="${SRC_DIR}/.${2}.extracted"
	if [[ -f "${stamp}" && -d "${SRC_DIR}/${dirname}" ]]; then
		log "sources ready: ${dirname}"
		return 0
	fi
	log "extracting ${archive}"
	rm -rf "${SRC_DIR:?}/${dirname}"
	tar -xf "${CACHE_DIR}/${archive}" -C "${SRC_DIR}"
	[[ -d "${SRC_DIR}/${dirname}" ]] || die "archive ${archive} did not yield ${dirname}"
	: > "${stamp}"
}

apply_patches() { # source-dir patch-subdir
	local src="$1" dir="${SCRIPT_DIR}/patches/$2" p
	[[ -d "${dir}" ]] || return 0
	shopt -s nullglob
	for p in "${dir}"/*.patch; do
		if [[ -f "${src}/.patched-$(basename "${p}")" ]]; then continue; fi
		log "applying patch $(basename "${p}")"
		patch -p1 -d "${src}" < "${p}" || die "patch failed: ${p}"
		: > "${src}/.patched-$(basename "${p}")"
	done
	shopt -u nullglob
}

# --- OpenSSL ---------------------------------------------------------------
# Static libcrypto/libssl. Built once (release only): the sanitizer flavor
# instruments libtorrent and the harness, which is where our bugs live; ASan
# still intercepts allocations made inside non-instrumented OpenSSL code.
build_openssl() {
	[[ ${WITH_TLS} -eq 1 ]] || { log "TLS disabled, skipping OpenSSL"; return 0; }
	if [[ -f "${OPENSSL_PREFIX}/lib/libssl.a" && -f "${OPENSSL_PREFIX}/lib/libcrypto.a" ]]; then
		log "openssl ${OPENSSL_VERSION} already installed"
		return 0
	fi
	local src="${SRC_DIR}/${OPENSSL_DIR}" logf="${LOG_DIR}/openssl-${OPENSSL_VERSION}.log"
	log "building openssl ${OPENSSL_VERSION} (log: ${logf})"
	(
		cd "${src}"
		# no-shared: static only.
		# no-legacy: the legacy provider is the only artifact OpenSSL would
		#   install as a .dylib; libtorrent never calls EVP ciphers (it hashes
		#   through libcrypto and implements MSE/RC4 itself), so dropping it
		#   keeps the prefix 100% static.
		# no-apps/no-docs/no-tests: we only need the libraries.
		perl ./Configure darwin64-arm64-cc no-shared no-legacy no-apps no-docs no-tests \
			--prefix="${OPENSSL_PREFIX}" --openssldir="${OPENSSL_PREFIX}/ssl" \
			"-mmacosx-version-min=${TORRENTINO_DEPLOYMENT_TARGET}"
		make -j"${JOBS}"
		make install_sw
	) >"${logf}" 2>&1 || { tail -40 "${logf}" >&2; die "openssl build failed (see ${logf})"; }
	[[ -f "${OPENSSL_PREFIX}/lib/libssl.a" ]] || die "openssl: libssl.a missing after install"
	log "openssl installed to ${OPENSSL_PREFIX}"
}

# --- Boost -----------------------------------------------------------------
# Header-only install, on purpose:
#   * libtorrent 2.x links no compiled Boost library — Boost.System has been
#     header-only since 1.69, everything else it uses (Asio, Pool, CRC, ...) is
#     headers;
#   * b2 writes an unquoted --prefix into project-config.jam and therefore
#     cannot bootstrap inside a path containing spaces (this repository has
#     one), so we do not depend on b2 at all.
# CMake finds this layout through BOOST_ROOT + FindBoost in header-only mode.
build_boost() {
	local src="${SRC_DIR}/${BOOST_DIR}"
	if [[ -f "${BOOST_PREFIX}/include/boost/asio.hpp" \
		&& -f "${BOOST_PREFIX}/include/boost/version.hpp" ]]; then
		log "boost ${BOOST_VERSION} already installed"
		return 0
	fi
	log "installing boost ${BOOST_VERSION} headers"
	mkdir -p "${BOOST_PREFIX}/include"
	rm -rf "${BOOST_PREFIX:?}/include/boost"
	cp -R "${src}/boost" "${BOOST_PREFIX}/include/"
	[[ -f "${BOOST_PREFIX}/include/boost/asio.hpp" ]] || die "boost: headers missing after install"
	local declared
	declared="$(awk '/#define BOOST_LIB_VERSION/{gsub(/[",]/,"",$3); print $3}' \
		"${BOOST_PREFIX}/include/boost/version.hpp")"
	[[ "${declared}" == "${BOOST_UNDERSCORE%_0}" ]] \
		|| die "boost: header tree reports ${declared}, expected ${BOOST_UNDERSCORE%_0}"
	log "boost installed to ${BOOST_PREFIX} (headers only, BOOST_LIB_VERSION=${declared})"
}

# --- libtorrent ------------------------------------------------------------
build_libtorrent() {
	local src="${SRC_DIR}/$(lt_pin DIR)"
	local build_dir="${WORK_DIR}/libtorrent-${LT_VERSION}-${FLAVOR}"
	local logf="${LOG_DIR}/libtorrent-${LT_VERSION}-${FLAVOR}.log"
	if [[ ${DO_CLEAN} -eq 1 ]]; then rm -rf "${build_dir}" "${LT_PREFIX}"; fi

	local build_type="Release" extra_c="" extra_cxx=""
	if [[ "${FLAVOR}" == "asan" ]]; then
		# -O1 + frame pointers: readable sanitizer stacks without a debug-build
		# slowdown that would make the soak scenarios time out.
		build_type="RelWithDebInfo"
		extra_c="-fsanitize=address,undefined -fno-omit-frame-pointer -fno-optimize-sibling-calls -O1 -g"
		extra_cxx="${extra_c}"
	fi

	local -a cmake_args=(
		-S "${src}" -B "${build_dir}"
		-DCMAKE_BUILD_TYPE="${build_type}"
		-DCMAKE_INSTALL_PREFIX="${LT_PREFIX}"
		-DCMAKE_OSX_ARCHITECTURES="${TORRENTINO_ARCH}"
		-DCMAKE_OSX_DEPLOYMENT_TARGET="${TORRENTINO_DEPLOYMENT_TARGET}"
		-DCMAKE_OSX_SYSROOT="${SDK_PATH}"
		-DCMAKE_CXX_STANDARD="${TORRENTINO_CXX_STANDARD}"
		-DCMAKE_CXX_STANDARD_REQUIRED=ON
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON
		-DBUILD_SHARED_LIBS=OFF
		-Dstatic_runtime=OFF
		-Dbuild_tests=OFF -Dbuild_examples=OFF -Dbuild_tools=OFF -Dpython-bindings=OFF
		-Ddht=ON -Dencryption=ON -Dexceptions=ON -Dlogging=ON -Di2p=OFF
		-Ddeprecated-functions=ON
		-DBOOST_ROOT="${BOOST_PREFIX}"
		-DBoost_INCLUDE_DIR="${BOOST_PREFIX}/include"
		-DBoost_NO_SYSTEM_PATHS=ON
		-DCMAKE_PREFIX_PATH="${BOOST_PREFIX};${OPENSSL_PREFIX}"
		# Hard guard: never pick up a Homebrew/local build of anything.
		-DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
		# CMP0167 OLD keeps the FindBoost module, which supports the header-only
		# layout we install; BoostConfig.cmake would require a full b2 install.
		-DCMAKE_POLICY_DEFAULT_CMP0167=OLD
		-DCMAKE_POLICY_WARNING_CMP0167=OFF
		-DCMAKE_C_FLAGS="${extra_c}"
		-DCMAKE_CXX_FLAGS="${extra_cxx}"
	)
	if [[ ${WITH_TLS} -eq 1 ]]; then
		cmake_args+=(-DOPENSSL_ROOT_DIR="${OPENSSL_PREFIX}" -DOPENSSL_USE_STATIC_LIBS=ON)
	fi
	# WebTorrent (2.1+) drags in libdatachannel (MPL-2.0) + a WebRTC stack we do
	# not ship in v1; keep the dependency surface and the SBOM minimal.
	if [[ "${LT_VERSION}" == 2.1.* ]]; then
		cmake_args+=(-Dwebtorrent=OFF)
	fi
	if command -v ninja >/dev/null 2>&1; then
		cmake_args+=(-G Ninja)
	else
		cmake_args+=(-G "Unix Makefiles")
	fi

	log "configuring libtorrent ${LT_VERSION} [${FLAVOR}] (log: ${logf})"
	cmake "${cmake_args[@]}" >"${logf}" 2>&1 \
		|| { tail -60 "${logf}" >&2; die "libtorrent configure failed (see ${logf})"; }
	log "building libtorrent ${LT_VERSION} [${FLAVOR}] with ${JOBS} jobs"
	cmake --build "${build_dir}" --parallel "${JOBS}" >>"${logf}" 2>&1 \
		|| { tail -60 "${logf}" >&2; die "libtorrent build failed (see ${logf})"; }
	cmake --install "${build_dir}" >>"${logf}" 2>&1 \
		|| { tail -40 "${logf}" >&2; die "libtorrent install failed (see ${logf})"; }
	log "libtorrent installed to ${LT_PREFIX}"
}

# --- verification ----------------------------------------------------------
# Gate evidence: arm64-only static archives, no dylibs, no Homebrew/local paths
# leaking through CMake/pkg-config metadata into anything we ship.
verify_prefix() {
	local failures=0 lib archs
	log "verifying artifacts in ${LT_PREFIX}"

	local -a libs=()
	while IFS= read -r lib; do libs+=("${lib}"); done < <(
		find "${LT_PREFIX}" "${BOOST_PREFIX}" "${OPENSSL_PREFIX}" -name '*.a' 2>/dev/null | sort
	)
	[[ ${#libs[@]} -gt 0 ]] || die "no static libraries found"

	for lib in "${libs[@]}"; do
		printf '    %s\n' "${lib#"${PREFIX_ROOT}/"}"
		printf '      file : %s\n' "$(file -b "${lib}")"
		archs="$(lipo -archs "${lib}" 2>/dev/null || echo '?')"
		printf '      lipo : %s\n' "${archs}"
		if [[ "${archs}" != "${TORRENTINO_ARCH}" ]]; then
			warn "unexpected architecture in ${lib}: ${archs}"
			failures=$((failures + 1))
		fi
	done

	# A dylib in the prefix would become a runtime dependency of the .dmg.
	local dylibs
	dylibs="$(find "${LT_PREFIX}" "${BOOST_PREFIX}" "${OPENSSL_PREFIX}" \
		\( -name '*.dylib' -o -name '*.so' \) 2>/dev/null || true)"
	if [[ -n "${dylibs}" ]]; then
		warn "shared libraries present in prefix:"; printf '%s\n' "${dylibs}" >&2
		failures=$((failures + 1))
	fi

	# Build metadata must not point at Homebrew or /usr/local either: those paths
	# would silently reappear in a downstream link line.
	local hits
	hits="$(grep -rlE '/opt/homebrew|/usr/local' \
		"${LT_PREFIX}/lib/cmake" "${LT_PREFIX}/lib/pkgconfig" 2>/dev/null || true)"
	if [[ -n "${hits}" ]]; then
		warn "Homebrew/usr-local paths referenced by libtorrent build metadata:"
		printf '%s\n' "${hits}" >&2
		failures=$((failures + 1))
	fi

	# LC_BUILD_VERSION of the first object tells us the effective minimum OS.
	# `awk ... exit` closes the pipe early, so otool dies of SIGPIPE: pipefail
	# must be off here or the whole script would abort on a successful check.
	local minos
	set +o pipefail
	minos="$(otool -l "${LT_PREFIX}/lib/libtorrent-rasterbar.a" 2>/dev/null \
		| awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
	set -o pipefail
	printf '      minos: %s (expected %s)\n' "${minos:-unknown}" "${TORRENTINO_DEPLOYMENT_TARGET}"
	if [[ -n "${minos}" && "${minos}" != "${TORRENTINO_DEPLOYMENT_TARGET}" ]]; then
		warn "deployment target mismatch: ${minos}"
		failures=$((failures + 1))
	fi

	[[ ${failures} -eq 0 ]] || die "artifact verification failed (${failures} problem(s))"
	log "artifact verification passed"
}

# Machine-readable record of exactly what produced this prefix. Consumed by the
# harness (--print-manifest) and by the release SBOM in later WPs.
write_manifest() {
	local manifest="${BUILD_ROOT}/manifest-${LT_VERSION}-${FLAVOR}.json"
	cat > "${manifest}" <<JSON
{
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": {
    "os": "$(sw_vers -productVersion)",
    "arch": "$(uname -m)",
    "clang": "$(clang --version | head -1)",
    "cmake": "$(cmake --version | head -1)",
    "sdk": "$(xcrun --show-sdk-version)"
  },
  "target": {
    "arch": "${TORRENTINO_ARCH}",
    "deployment_target": "${TORRENTINO_DEPLOYMENT_TARGET}",
    "cxx_standard": "${TORRENTINO_CXX_STANDARD}",
    "flavor": "${FLAVOR}"
  },
  "dependencies": [
    {
      "name": "libtorrent",
      "version": "${LT_VERSION}",
      "tag": "$(lt_pin TAG)",
      "commit": "$(lt_pin COMMIT)",
      "archive": "$(lt_pin ARCHIVE)",
      "sha256": "$(lt_pin SHA256)",
      "license": "BSD-3-Clause",
      "prefix": "${LT_PREFIX}"
    },
    {
      "name": "boost",
      "version": "${BOOST_VERSION}",
      "commit": "${BOOST_COMMIT}",
      "archive": "${BOOST_ARCHIVE}",
      "sha256": "${BOOST_SHA256}",
      "license": "BSL-1.0",
      "prefix": "${BOOST_PREFIX}"
    },
    {
      "name": "openssl",
      "version": "${OPENSSL_VERSION}",
      "tag": "${OPENSSL_TAG}",
      "archive": "${OPENSSL_ARCHIVE}",
      "sha256": "${OPENSSL_SHA256}",
      "license": "Apache-2.0",
      "enabled": $([[ ${WITH_TLS} -eq 1 ]] && echo true || echo false),
      "prefix": "${OPENSSL_PREFIX}"
    }
  ]
}
JSON
	log "manifest written to ${manifest}"
}

# --- main ------------------------------------------------------------------
main() {
	preflight
	log "libtorrent ${LT_VERSION} ($(lt_pin TAG) @ $(lt_pin COMMIT))"
	log "flavor=${FLAVOR} jobs=${JOBS} tls=$([[ ${WITH_TLS} -eq 1 ]] && echo openssl || echo none)"

	if [[ ${WITH_TLS} -eq 1 ]]; then
		fetch "${OPENSSL_URL}" "${OPENSSL_ARCHIVE}" "${OPENSSL_SHA256}"
		extract "${OPENSSL_ARCHIVE}" "${OPENSSL_DIR}"
	fi
	fetch "${BOOST_URL}" "${BOOST_ARCHIVE}" "${BOOST_SHA256}"
	extract "${BOOST_ARCHIVE}" "${BOOST_DIR}"
	fetch "$(lt_pin URL)" "$(lt_pin ARCHIVE)" "$(lt_pin SHA256)"
	extract "$(lt_pin ARCHIVE)" "$(lt_pin DIR)"
	apply_patches "${SRC_DIR}/$(lt_pin DIR)" "libtorrent-${LT_VERSION}"

	build_openssl
	build_boost
	if [[ ${DEPS_ONLY} -eq 1 ]]; then
		log "--deps-only: stopping after Boost/OpenSSL"
		exit 0
	fi
	build_libtorrent
	verify_prefix
	write_manifest

	cat <<EOF

libtorrent ${LT_VERSION} [${FLAVOR}] ready.
  prefix : ${LT_PREFIX}
  cmake  : -DCMAKE_PREFIX_PATH="${LT_PREFIX};${BOOST_PREFIX};${OPENSSL_PREFIX}"
EOF
}

main "$@"
