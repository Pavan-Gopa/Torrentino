#!/usr/bin/env bash
#
# Torrentino — runtime dependency gate (WP-01).
#
# Role:    fails if a produced binary is arch-wrong, targets the wrong minimum
#          macOS, or links anything outside the system frameworks — in
#          particular anything from /opt/homebrew or /usr/local.
# Why:     users install a .dmg and have no dev tools; a single Homebrew dylib
#          reference makes the app unlaunchable on their machine.
#
# Usage: bash verify_no_homebrew.sh <binary> [<binary> ...]
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "usage: verify_no_homebrew.sh <binary> [...]" >&2
	exit 2
fi

EXPECTED_ARCH="arm64"
EXPECTED_MINOS="13.0"
failures=0

for binary in "$@"; do
	echo "== ${binary}"
	if [[ ! -e "${binary}" ]]; then
		echo "   error: file does not exist" >&2
		failures=$((failures + 1))
		continue
	fi

	echo "   file : $(file -b "${binary}")"

	archs="$(lipo -archs "${binary}" 2>/dev/null || echo '?')"
	echo "   lipo : ${archs}"
	if [[ "${archs}" != "${EXPECTED_ARCH}" ]]; then
		echo "   error: expected ${EXPECTED_ARCH} only" >&2
		failures=$((failures + 1))
	fi

	# otool -l dumps every load command; stop at the first LC_BUILD_VERSION.
	set +o pipefail
	minos="$(otool -l "${binary}" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
	set -o pipefail
	echo "   minos: ${minos:-unknown}"
	if [[ -n "${minos}" && "${minos}" != "${EXPECTED_MINOS}" ]]; then
		echo "   error: expected minimum macOS ${EXPECTED_MINOS}" >&2
		failures=$((failures + 1))
	fi

	echo "   otool -L:"
	otool -L "${binary}" | tail -n +2 | sed 's/^/     /'

	if otool -L "${binary}" | grep -qE '/opt/homebrew|/usr/local'; then
		echo "   error: Homebrew or /usr/local runtime link detected" >&2
		otool -L "${binary}" | grep -E '/opt/homebrew|/usr/local' >&2
		failures=$((failures + 1))
	fi

	# The sanitizer runtime is a toolchain dylib. It is expected in the `asan`
	# flavor and must never appear in anything we ship, so say so out loud
	# instead of quietly reporting "clean".
	if otool -L "${binary}" | grep -q 'libclang_rt\.'; then
		echo "   note : sanitizer runtime linked — diagnostic build, not shippable"
	fi

	# rpaths pointing outside the bundle are just as fatal at launch time.
	set +o pipefail
	rpaths="$(otool -l "${binary}" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')"
	set -o pipefail
	if [[ -n "${rpaths}" ]]; then
		echo "   rpaths:"
		printf '     %s\n' ${rpaths}
		if printf '%s\n' ${rpaths} | grep -qE '/opt/homebrew|/usr/local'; then
			echo "   error: rpath points at Homebrew or /usr/local" >&2
			failures=$((failures + 1))
		fi
	else
		echo "   rpaths: none"
	fi
done

if [[ ${failures} -ne 0 ]]; then
	echo
	echo "FAILED: ${failures} problem(s) found" >&2
	exit 1
fi

echo
echo "OK: arm64, macOS ${EXPECTED_MINOS}+, system libraries only"
