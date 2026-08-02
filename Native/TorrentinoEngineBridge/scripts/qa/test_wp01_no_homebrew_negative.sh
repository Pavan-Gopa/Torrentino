#!/usr/bin/env bash
#
# QA WP-01 — verify_no_homebrew.sh negative path (feature 7, negative test).
#
# Proves the gate actually FAILS on a poisoned binary, so a "CLEAN" result is
# meaningful. Builds throwaway Mach-O images (never run) that:
#   (a) carry a dylib load command whose install name points into /opt/homebrew;
#   (b) carry an LC_RPATH pointing into /opt/homebrew;
#   (c) do not exist at all.
# Each must make verify_no_homebrew.sh exit non-zero with the right diagnostic.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

work="$(qa_mktemp)"
printf 'int fake(void){return 42;}\n' > "${work}/fake.c"
printf 'int main(void){return 0;}\n' > "${work}/main.c"

# A dylib whose install name lives in /opt/homebrew (the binary is never
# executed, so the dylib need not exist at that path).
clang -arch arm64 -mmacosx-version-min=13.0 -dynamiclib \
	-install_name /opt/homebrew/lib/libfake.dylib \
	"${work}/fake.c" -o "${work}/libfake.dylib" || qa_die "could not build fake dylib"

# Link the executable against it AND give it a Homebrew rpath. arch/minOS are
# correct on purpose, so the ONLY failures are the Homebrew references.
clang -arch arm64 -mmacosx-version-min=13.0 -Wl,-rpath,/opt/homebrew/lib \
	"${work}/main.c" -L"${work}" -lfake -o "${work}/poisoned" \
	|| qa_die "could not build poisoned binary"

# (a)+(b): poisoned binary must fail with both diagnostics.
set +e
out="$(bash "${VERIFY_NO_HOMEBREW_SH}" "${work}/poisoned" 2>&1)"
st=$?
set -e
assert_ne "${st}" "0" "poisoned binary rejected (non-zero exit)"
assert_contains "${out}" "Homebrew or /usr/local runtime link detected" "dylib-link detection fired"
assert_contains "${out}" "rpath points at Homebrew or /usr/local" "rpath detection fired"

# (c): a missing file must also fail.
set +e
out2="$(bash "${VERIFY_NO_HOMEBREW_SH}" "${work}/does-not-exist" 2>&1)"
st2=$?
set -e
assert_ne "${st2}" "0" "missing binary rejected (non-zero exit)"
assert_contains "${out2}" "file does not exist" "missing-file diagnostic fired"

qa_pass
