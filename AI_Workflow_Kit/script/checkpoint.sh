#!/usr/bin/env bash
# Torrentino checkpoint helper — git tags for WP lifecycle.
# Usage:
#   ./AI_Workflow_Kit/script/checkpoint.sh pre WP-01
#   ./AI_Workflow_Kit/script/checkpoint.sh post WP-01 "summary"
#   ./AI_Workflow_Kit/script/checkpoint.sh list
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

ACTION="${1:-}"
WP="${2:-}"
MSG="${3:-}"

case "$ACTION" in
  pre)
    TAG="torrentino/pre-${WP}"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
      echo "Tag $TAG already exists. Skipping."
    else
      git tag -a "$TAG" -m "pre-${WP}: checkpoint before ${WP}"
      echo "Created tag: $TAG"
    fi
    ;;
  post)
    TAG="torrentino/${WP}-done"
    if git rev-parse "$TAG" >/dev/null 2>&1; then
      echo "Tag $TAG already exists. Skipping."
    else
      git tag -a "$TAG" -m "${WP}-done: ${MSG:-completed}"
      echo "Created tag: $TAG"
    fi
    ;;
  list)
    echo "=== Torrentino tags ==="
    git tag -l 'torrentino/*' --sort=-creatordate
    echo "=== Backup tags ==="
    git tag -l 'backup/*' --sort=-creatordate
    ;;
  *)
    echo "Usage: checkpoint.sh {pre|post|list} [WP-ID] [message]"
    exit 1
    ;;
esac
