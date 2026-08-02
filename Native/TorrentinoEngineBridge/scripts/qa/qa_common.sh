#!/usr/bin/env bash
#
# Torrentino — shared helpers for WP-01 QA scripts (Test Engineer).
#
# Role:     sourced (never executed) by every test_wp01_*.sh. Provides path
#           resolution, isolated mktemp workspaces with guaranteed cleanup, and
#           a small set of deterministic assert helpers.
# Invariant: exit 0 == pass, exit 1 == fail. Every test is isolated: scratch data
#           lives under $TMPDIR and is removed on exit, so no temp data, helper
#           process or mounted image survives a run. Production Application
#           Support is never touched (the harness only uses --workspace/$TMPDIR).
#
# NOTE: macOS ships bash 3.2 — keep this portable (no mapfile/readarray).

# --- path resolution (relative to this file) -------------------------------
QA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${QA_DIR}/.." && pwd)"
BRIDGE_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
NATIVE_DIR="$(cd "${BRIDGE_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${NATIVE_DIR}/.." && pwd)"
THIRD_PARTY_DIR="${NATIVE_DIR}/ThirdParty"
LOCK_FILE="${THIRD_PARTY_DIR}/versions.lock"
BUILD_SH="${THIRD_PARTY_DIR}/libtorrent/build.sh"
RUN_TESTS_SH="${SCRIPTS_DIR}/run_tests.sh"
RUN_SANITIZERS_SH="${SCRIPTS_DIR}/run_sanitizers.sh"
RUN_SOAK_SH="${SCRIPTS_DIR}/run_soak.sh"
VERIFY_NO_HOMEBREW_SH="${SCRIPTS_DIR}/verify_no_homebrew.sh"
CACHE_DIR="${THIRD_PARTY_DIR}/.build/cache"
PREFIX_ROOT="${THIRD_PARTY_DIR}/.build/prefix"

# --- isolated scratch space ------------------------------------------------
QA_TMP_DIRS=()
qa_mktemp() {
	local d
	d="$(mktemp -d "${TMPDIR:-/tmp}/qa_wp01.XXXXXX")"
	QA_TMP_DIRS+=("${d}")
	printf '%s\n' "${d}"
}
qa_cleanup() {
	local d
	for d in ${QA_TMP_DIRS[@]+"${QA_TMP_DIRS[@]}"}; do
		[[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"
	done
}
trap qa_cleanup EXIT

# --- logging / assert helpers ----------------------------------------------
qa_log() { printf '\033[1;34m[qa]\033[0m %s\n' "$*"; }
qa_ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
qa_die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
qa_pass() { printf '\n\033[1;32mRESULT: PASS\033[0m — %s\n' "$(basename "${BASH_SOURCE[1]:-$0}")"; exit 0; }

# assert_eq <actual> <expected> <message>
assert_eq() { [[ "$1" == "$2" ]] || qa_die "$3: expected '$2', got '$1'"; qa_ok "$3 (= $2)"; }
# assert_ne <actual> <forbidden> <message>
assert_ne() { [[ "$1" != "$2" ]] || qa_die "$3: got forbidden value '$1'"; qa_ok "$3 (!= $2)"; }
# assert_ge <actual> <minimum> <message>  (numeric)
assert_ge() { [[ "$1" -ge "$2" ]] || qa_die "$3: $1 < $2"; qa_ok "$3 ($1 >= $2)"; }
# assert_contains <haystack> <needle> <message>
assert_contains() { case "$1" in *"$2"*) qa_ok "$3";; *) qa_die "$3: missing '$2'";; esac; }
# assert_not_contains <haystack> <needle> <message>
assert_not_contains() { case "$1" in *"$2"*) qa_die "$3: forbidden '$2' present";; *) qa_ok "$3";; esac; }
# assert_file <path> <message>
assert_file() { [[ -f "$1" ]] || qa_die "$2: missing file: $1"; qa_ok "$2"; }
# assert_match <text> <regex> <message>  (POSIX ERE via bash =~)
assert_match() { [[ "$1" =~ $2 ]] || qa_die "$3: no match for /$2/"; qa_ok "$3"; }
