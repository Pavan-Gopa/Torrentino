#!/usr/bin/env bash
# checkpoint.sh — git checkpoint manager for DialGent
# Usage:
#   ./checkpoint.sh pre  <step>              # create pre-tag + commit
#   ./checkpoint.sh post <step> "<summary>"  # create post-tag + commit
#   ./checkpoint.sh list                     # list dialgent tags
#
# Rules (see GIT_CHECKPOINTS.md):
#   1. Idempotent — existing tag not overwritten
#   2. Scope-guard — git root must equal product root
#   3. Push local by default — only if remote configured
#   4. Commit convention enforced

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRODUCT_NAME="dialgent"

# --- Scope guard ---
GIT_ROOT="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$GIT_ROOT" ]; then
  echo "ERROR: not a git repository at $PROJECT_ROOT" >&2
  exit 1
fi
if [ "$GIT_ROOT" != "$PROJECT_ROOT" ]; then
  echo "ERROR: git root ($GIT_ROOT) != product root ($PROJECT_ROOT)" >&2
  echo "       Refusing to checkpoint outside product scope." >&2
  exit 1
fi

cd "$PROJECT_ROOT"

# --- Helpers ---
has_remote() {
  git remote get-url origin &>/dev/null
}

push_if_remote() {
  if has_remote; then
    echo "Pushing tags to origin..."
    git push origin --tags 2>/dev/null || echo "WARN: push failed (offline?)"
  else
    echo "No remote configured — skipping push."
  fi
}

# --- Commands ---
cmd_pre() {
  local step="$1"
  local tag="${PRODUCT_NAME}/pre-${step}"

  if git rev-parse "$tag" &>/dev/null; then
    echo "Tag $tag already exists — skipping (idempotent)."
    return 0
  fi

  echo "Creating PRE checkpoint: $tag"
  git add -A
  git commit -m "chore(${PRODUCT_NAME}): checkpoint before ${step}" --allow-empty
  git tag "$tag"
  push_if_remote
  echo "PRE checkpoint $tag created."
}

cmd_post() {
  local step="$1"
  local summary="${2:-step complete}"
  local tag="${PRODUCT_NAME}/${step}-done"

  if git rev-parse "$tag" &>/dev/null; then
    echo "Tag $tag already exists — skipping (idempotent)."
    return 0
  fi

  echo "Creating POST checkpoint: $tag"
  git add -A
  git commit -m "feat(${PRODUCT_NAME}): ${step} — ${summary}" --allow-empty
  git tag "$tag"
  push_if_remote
  echo "POST checkpoint $tag created."
}

cmd_list() {
  echo "DialGent checkpoint tags:"
  git tag -l "${PRODUCT_NAME}/*" --sort=-creatordate
}

# --- Main ---
case "${1:-}" in
  pre)
    [ -z "${2:-}" ] && { echo "Usage: checkpoint.sh pre <step>" >&2; exit 1; }
    cmd_pre "$2"
    ;;
  post)
    [ -z "${2:-}" ] && { echo "Usage: checkpoint.sh post <step> [summary]" >&2; exit 1; }
    cmd_post "$2" "${3:-}"
    ;;
  list)
    cmd_list
    ;;
  *)
    echo "Usage: checkpoint.sh {pre|post|list} <step> [summary]" >&2
    exit 1
    ;;
esac
