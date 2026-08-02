#!/usr/bin/env bash
#
# QA WP-01 — build.sh idempotency + artifact integrity (feature 1).
#
# Verifies:
#   * a repeat `build.sh --flavor release` run exits 0 (rebuild never fails);
#   * the produced libtorrent-rasterbar.a is arm64 with minOS 13.0;
#   * the rebuild is functionally idempotent: the *object content* of the static
#     archive is byte-identical across runs. (The raw .a hash is NOT compared:
#     BSD ar re-stamps the __.SYMDEF symbol-table member with the current time on
#     re-archive, which is benign metadata, not content drift.)
#   * the cached source archive still matches the SHA-256 pinned in versions.lock;
#   * the build manifest is valid JSON.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"
source "${LOCK_FILE}"

LT_VERSION="${LT_DEFAULT_VERSION}"
LT_KEY="LT_${LT_VERSION//./_}"
archive_var="${LT_KEY}_ARCHIVE"; sha_var="${LT_KEY}_SHA256"
LT_ARCHIVE="${!archive_var}"; LT_SHA256="${!sha_var}"
LIB="${PREFIX_ROOT}/libtorrent-${LT_VERSION}-release/lib/libtorrent-rasterbar.a"
MANIFEST="${THIRD_PARTY_DIR}/.build/manifest-${LT_VERSION}-release.json"

# content hash = SHA-256 over the SHA-256 of every .o member (excludes __.SYMDEF).
content_hash() {
	local lib="$1" d
	d="$(qa_mktemp)"
	( cd "${d}" && ar -x "${lib}" && find . -name '*.o' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}' )
}

qa_log "artifact: ${LIB}"
[[ -f "${LIB}" ]] || bash "${BUILD_SH}" --flavor release --lt-version "${LT_VERSION}" >/dev/null
assert_file "${LIB}" "static archive present before rebuild"
before="$(content_hash "${LIB}")"
qa_log "object content hash before: ${before}"

qa_log "running build.sh again (must be idempotent)"
build_log="$(qa_mktemp)/build.log"
bash "${BUILD_SH}" --flavor release --lt-version "${LT_VERSION}" >"${build_log}" 2>&1 \
	|| { tail -40 "${build_log}" >&2; qa_die "repeat build.sh exited non-zero"; }
qa_ok "repeat build.sh exited 0"

after="$(content_hash "${LIB}")"
qa_log "object content hash after:  ${after}"
assert_eq "${after}" "${before}" "object content idempotent across rebuilds"

assert_eq "$(lipo -archs "${LIB}" 2>/dev/null)" "arm64" "artifact architecture"
assert_contains "$(cat "${build_log}")" "sha256 ok" "cached archive integrity re-checked"
assert_contains "$(cat "${build_log}")" "artifact verification passed" "artifact verification ran"

# Supply-chain pin still holds: cached archive hash == versions.lock.
cached="${CACHE_DIR}/${LT_ARCHIVE}"
assert_file "${cached}" "cached source archive present"
assert_eq "$(shasum -a 256 "${cached}" | awk '{print $1}')" "${LT_SHA256}" "cached archive SHA-256 == versions.lock"

assert_file "${MANIFEST}" "build manifest present"
jq -e . "${MANIFEST}" >/dev/null || qa_die "manifest is not valid JSON"
qa_ok "build manifest is valid JSON"

qa_pass
