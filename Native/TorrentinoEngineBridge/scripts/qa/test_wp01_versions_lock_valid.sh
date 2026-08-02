#!/usr/bin/env bash
#
# QA WP-01 — versions.lock validity (feature 2).
#
# Verifies:
#   * versions.lock is a valid, sourceable shell fragment (no logic/paths, pins only);
#   * every required pin is present and non-empty (libtorrent x2, Boost, OpenSSL);
#   * SHA-256 pins are 64 hex chars, git commits are 40 hex chars;
#   * the default libtorrent version is one of the supported versions;
#   * the platform contract is arm64 / macOS 13.0;
#   * pins match reality: every cached archive hash equals its pin, and a built
#     prefix exists for each supported libtorrent version.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

# 1. The file must be a pure shell fragment: syntax-check then source it.
bash -n "${LOCK_FILE}" || qa_die "versions.lock is not valid shell syntax"
qa_ok "versions.lock passes bash -n"
# shellcheck disable=SC1090
source "${LOCK_FILE}"

require_nonempty() { [[ -n "${!1:-}" ]] || qa_die "missing/empty pin: $1"; }

# 2. Global pins.
for v in LT_DEFAULT_VERSION LT_SUPPORTED_VERSIONS \
	BOOST_VERSION BOOST_COMMIT BOOST_URL BOOST_ARCHIVE BOOST_SHA256 BOOST_DIR \
	OPENSSL_VERSION OPENSSL_TAG OPENSSL_URL OPENSSL_ARCHIVE OPENSSL_SHA256 OPENSSL_DIR \
	TORRENTINO_ARCH TORRENTINO_DEPLOYMENT_TARGET TORRENTINO_CXX_STANDARD; do
	require_nonempty "${v}"
done
qa_ok "all global pins present and non-empty"

# 3. Per-version libtorrent pins (indirect lookup over LT_SUPPORTED_VERSIONS).
count=0
for ver in ${LT_SUPPORTED_VERSIONS}; do
	key="LT_${ver//./_}"
	for suffix in TAG COMMIT URL ARCHIVE SHA256 DIR; do
		name="${key}_${suffix}"
		require_nonempty "${name}"
	done
	count=$((count + 1))
done
assert_ge "${count}" 2 "supported libtorrent versions pinned"

# 4. Format checks.
for s in "${BOOST_SHA256}" "${OPENSSL_SHA256}"; do
	assert_match "${s}" '^[0-9a-f]{64}$' "SHA-256 pin format"
done
for c in "${BOOST_COMMIT}"; do
	assert_match "${c}" '^[0-9a-f]{40}$' "git commit pin format"
done
for ver in ${LT_SUPPORTED_VERSIONS}; do
	key="LT_${ver//./_}"
	sha="${key}_SHA256"; commit="${key}_COMMIT"
	assert_match "${!sha}" '^[0-9a-f]{64}$' "libtorrent ${ver} SHA-256 format"
	assert_match "${!commit}" '^[0-9a-f]{40}$' "libtorrent ${ver} commit format"
done

# 5. Default must be supported; platform contract.
case " ${LT_SUPPORTED_VERSIONS} " in
	*" ${LT_DEFAULT_VERSION} "*) qa_ok "default version ${LT_DEFAULT_VERSION} is supported" ;;
	*) qa_die "default ${LT_DEFAULT_VERSION} not in supported set '${LT_SUPPORTED_VERSIONS}'" ;;
esac
assert_eq "${TORRENTINO_ARCH}" "arm64" "platform arch contract"
assert_eq "${TORRENTINO_DEPLOYMENT_TARGET}" "13.0" "platform minOS contract"

# 6. Pins match reality.
for ver in ${LT_SUPPORTED_VERSIONS}; do
	key="LT_${ver//./_}"
	arch_var="${key}_ARCHIVE"; sha_var="${key}_SHA256"
	cached="${CACHE_DIR}/${!arch_var}"
	if [[ -f "${cached}" ]]; then
		assert_eq "$(shasum -a 256 "${cached}" | awk '{print $1}')" "${!sha_var}" \
			"cached ${!arch_var} matches pinned SHA-256"
	fi
	[[ -d "${PREFIX_ROOT}/libtorrent-${ver}-release" ]] \
		|| qa_die "no built release prefix for libtorrent ${ver}"
	qa_ok "built release prefix exists for libtorrent ${ver}"
done
for pair in "boost-${BOOST_VERSION}" "openssl-${OPENSSL_VERSION}"; do
	[[ -d "${PREFIX_ROOT}/${pair}" ]] || qa_die "no built prefix: ${pair}"
	qa_ok "built prefix exists: ${pair}"
done

qa_pass
