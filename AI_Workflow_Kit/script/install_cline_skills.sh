#!/usr/bin/env bash
# install_cline_skills.sh — DialGent keeps ONLY the Graphify skill for Cline
#
# Project:  DialGent/.cline/skills/graphify/
# Does NOT install role skills (coder/reviewer/architect) — use short kicks instead.
# Does NOT install to ~/.cline/skills/ by default.
#
# Usage:
#   ./install_cline_skills.sh              # sync graphify into project .cline/skills + strip globals
#   ./install_cline_skills.sh --remove-global
#   ./install_cline_skills.sh --global     # optional: also install graphify to ~/.cline/skills

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/.cline/skills"
GLOBAL="${HOME}/.cline/skills"
# Only graphify is allowed for Cline in this project
ALLOWED=(graphify)
# Always strip these if present
STRIP=(dialgent-architect dialgent-coder dialgent-reviewer graphify-dialgent graphify)

mode="${1:-project}"

strip_role_skills() {
  local base="$1"
  for name in dialgent-architect dialgent-coder dialgent-reviewer graphify-dialgent; do
    if [[ -d "$base/$name" ]]; then
      rm -rf "$base/$name"
      echo "Removed: $base/$name"
    fi
  done
}

sync_graphify_project() {
  mkdir -p "$SRC/graphify"
  if [[ -f "$ROOT/.agents/skills/graphify/SKILL.md" ]]; then
    cp "$ROOT/.agents/skills/graphify/SKILL.md" "$SRC/graphify/SKILL.md"
    echo "Synced graphify → $SRC/graphify/SKILL.md"
  elif [[ ! -f "$SRC/graphify/SKILL.md" ]]; then
    echo "ERROR: no graphify SKILL.md under .agents or .cline" >&2
    exit 1
  fi
  strip_role_skills "$SRC"
}

remove_global_dialgent() {
  mkdir -p "$GLOBAL"
  for name in "${STRIP[@]}"; do
    if [[ -d "$GLOBAL/$name" ]]; then
      rm -rf "$GLOBAL/$name"
      echo "Removed global: $GLOBAL/$name"
    fi
  done
}

install_graphify_global() {
  mkdir -p "$GLOBAL/graphify"
  cp "$SRC/graphify/SKILL.md" "$GLOBAL/graphify/SKILL.md"
  echo "Installed global: $GLOBAL/graphify (optional)"
}

case "$mode" in
  project|"")
    sync_graphify_project
    remove_global_dialgent
    echo ""
    echo "OK: Cline project skills = graphify only ($SRC/graphify)"
    echo "Role skills removed. Use short kick prompts for coder/reviewer/architect."
    ;;
  --remove-global)
    remove_global_dialgent
    ;;
  --global)
    sync_graphify_project
    install_graphify_global
    echo "WARN: graphify also in ~/.cline/skills — visible in all Cline sessions."
    ;;
  *)
    echo "Usage: $0 [project|--global|--remove-global]" >&2
    exit 2
    ;;
esac

echo "Restart Cline CLI (DialGent workspace). Skills UI should show only: graphify"
echo "MCP (separate): ./AI_Workflow_Kit/script/cline_graphify_mcp.sh --status"
