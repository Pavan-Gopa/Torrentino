#!/usr/bin/env bash
#
# QA WP-03 — Legacy/ tree must be untouched by the native WP work.
#
# Uses git to detect any staged/unstaged/untracked changes under Legacy/.
#
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qa_common.sh"

LEGACY_DIR="${REPO_ROOT}/Legacy"
assert_file "${LEGACY_DIR}/Tauri/package.json" "Legacy Tauri tree present"

cd "${REPO_ROOT}"

# Any tracked diff under Legacy/
diff_out="$(git diff --name-only -- Legacy/ 2>/dev/null || true)"
diff_cached="$(git diff --cached --name-only -- Legacy/ 2>/dev/null || true)"
# Untracked files under Legacy/
untracked="$(git ls-files --others --exclude-standard -- Legacy/ 2>/dev/null || true)"

if [[ -n "${diff_out}" || -n "${diff_cached}" || -n "${untracked}" ]]; then
	printf 'tracked diff:\n%s\n' "${diff_out}" >&2
	printf 'staged diff:\n%s\n' "${diff_cached}" >&2
	printf 'untracked:\n%s\n' "${untracked}" >&2
	qa_die "Legacy/ has changes — native WP must not touch Legacy/"
fi

qa_ok "git: Legacy/ clean (no diff, no untracked)"
qa_pass
